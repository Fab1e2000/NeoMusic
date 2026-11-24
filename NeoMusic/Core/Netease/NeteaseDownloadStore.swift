import Foundation
import Observation

@MainActor @Observable
final class NeteaseDownloadStore {
    typealias IndexWriter = @Sendable (Data, URL) async throws -> Void
    typealias Processor = @Sendable (URL, String, DownloadedAudioTags.Metadata, URL) async throws -> URL
    private(set) var states: [Int64: NeteaseDownloadState] = [:]
    private(set) var records: [Int64: NeteaseDownloadRecord] = [:]
    private(set) var availableFileIDs: Set<Int64> = []
    private(set) var collections: [String: NeteaseDownloadCollection] = [:]
    private(set) var isRestored = false
    private(set) var error: String?
    private(set) var userID: Int64?
    @ObservationIgnored let sessionScope = NeteaseSessionScope()
    var sessionRevision: UUID { sessionScope.revision }
    var quality: NeteaseMusicQuality {
        didSet { defaults.set(quality.rawValue, forKey: AppDefaultsKey.neteaseDownloadQuality) }
    }
    var allowsCellular: Bool {
        didSet {
            defaults.set(allowsCellular, forKey: AppDefaultsKey.neteaseDownloadCellular)
            if oldValue != allowsCellular { Task { await restartTransfersForNetworkPolicy() } }
        }
    }
    @ObservationIgnored private let artworkSession = URLSession(configuration: NeteaseAccountClient.sessionConfiguration())
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onProgressChanged: ((Int64) -> Void)?
    @ObservationIgnored var onFileCommitted: ((String) -> Void)?
    @ObservationIgnored var onRecordsChanged: (() -> Void)?
    let musicDirectory: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: NeteaseDownloadTransport
    @ObservationIgnored private let process: Processor
    @ObservationIgnored private let writeIndex: IndexWriter
    @ObservationIgnored private var committingJobs: Set<UUID> = []
    @ObservationIgnored private var session: NeteaseSavedSession?
    @ObservationIgnored private var jobs: [UUID: NeteaseDownloadJob] = [:]
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    private struct PlanningTask { let id: UUID; let task: Task<Void, Error> }
    @ObservationIgnored private var plans: [String: PlanningTask] = [:]
    @ObservationIgnored private var transferring: Set<UUID> = []
    @ObservationIgnored private var eventsBeforeRestore: [NeteaseDownloadTransport.Event] = []
    @ObservationIgnored private var changingSession = false
    @ObservationIgnored private var changingNetwork = false
    @ObservationIgnored private var hasActivated = false
    @ObservationIgnored private var persistenceTask: Task<Void, Error>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    private struct Snapshot: Codable, Sendable {
        var records: [NeteaseDownloadRecord]
        var collections: [NeteaseDownloadCollection]
        var jobs: [NeteaseDownloadJob]
    }

    init(client: NeteaseMusicClient = NeteaseMusicClient(),
         directory: URL = AppStoragePaths.neteaseDownloads,
         musicDirectory: URL = AppStoragePaths.music,
         defaults: UserDefaults = .standard, transport: NeteaseDownloadTransport? = nil,
         process: @escaping Processor = NeteaseDownloadStore.prepare,
         writeIndex: @escaping IndexWriter = NeteaseDownloadStore.writeIndexFile) {
        self.client = client; self.directory = directory; self.musicDirectory = musicDirectory; self.defaults = defaults
        self.quality = defaults.string(forKey: AppDefaultsKey.neteaseDownloadQuality).flatMap(NeteaseMusicQuality.init(rawValue:)) ?? .lossless
        self.allowsCellular = defaults.object(forKey: AppDefaultsKey.neteaseDownloadCellular) as? Bool ?? true
        self.transport = transport ?? NeteaseDownloadTransport(spool: directory.appending(path: "Transfers"))
        self.process = process; self.writeIndex = writeIndex
        self.transport.onEvent = { [weak self] in self?.receive($0) }
        self.transport.onFinishedEvents = { [weak self] in
            guard let self else { return }
            for work in self.workers.values { await work.value }
            _ = await self.persistenceTask?.result
        }
    }

    nonisolated private static func prepare(_ source: URL, _ type: String, _ tags: DownloadedAudioTags.Metadata,
                                           _ staging: URL) async throws -> URL {
        let file = try await NeteaseDownloadedAudio.prepare(source, declaredType: type, staging: staging)
        do {
            try await DownloadedAudioTags.write(tags, to: file)
            try Task.checkCancellation()
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    @concurrent private static func readSnapshot(from directory: URL) async throws -> Snapshot? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AtomicJSONStore.read(Snapshot.self, from: directory.appending(path: "index.json"))
    }

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        guard !isRestored else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRestore()
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private func performRestore() async {
        do {
            if let snapshot = try await Self.readSnapshot(from: directory) {
                records = Dictionary(snapshot.records.map { ($0.songID, $0) }, uniquingKeysWith: { _, last in last })
                collections = Dictionary(snapshot.collections.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
                jobs = Dictionary(snapshot.jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            }
            transferring = await transport.activeIDs()
            for job in jobs.values {
                if job.cancelled { continue }
                states[job.metadata.song.id] = job.error.map(NeteaseDownloadState.failed) ?? .queued
            }
            let available = await Self.availableSongIDs(records: records, musicDirectory: musicDirectory)
            availableFileIDs = available
            for id in available { states[id] = .downloaded }
            for id in jobs.keys where jobs[id]?.stagedFilename == nil {
                let file = transport.spool.appending(path: id.uuidString + ".transfer")
                if FileManager.default.fileExists(atPath: file.path) { jobs[id]?.stagedFilename = file.lastPathComponent }
            }
            isRestored = true
            let buffered = eventsBeforeRestore; eventsBeforeRestore = []
            for event in buffered { receive(event) }
            onRecordsChanged?(); onChange?()
        } catch { self.error = "读取下载记录失败：\(error.localizedDescription)" }
    }

    func activate(_ saved: NeteaseSavedSession?) async {
        await restore()
        guard isRestored, !Task.isCancelled else { return }
        let sameIdentity = userID == saved?.profile.userID && session?.credential == saved?.credential
        if hasActivated, !changingSession, sameIdentity {
            session = saved
            pump()
            return
        }
        changingSession = true
        let revision = sessionScope.advance()
        session = saved; userID = saved?.profile.userID
        let obsolete = Set(jobs.values.filter {
            $0.cancelled || $0.ownerID != saved?.profile.userID || (hasActivated && !sameIdentity)
        }.map(\.id))
        for id in obsolete { jobs[id]?.cancelled = true }
        let transfers = obsolete.union(transferring.filter { jobs[$0] == nil })
        let drain = sessionScope.cancelAndDrain { await self.transport.cancel(ids: transfers) }
        await drain.value
        guard sessionRevision == revision else { return }
        plans = [:]; workers = [:]
        transferring.subtract(obsolete)
        for id in obsolete {
            guard let job = jobs[id] else { continue }
            cleanupTransfer(job)
            if resource(songID: job.metadata.song.id) == nil { states.removeValue(forKey: job.metadata.song.id) }
        }
        jobs = jobs.filter { !obsolete.contains($0.key) }
        hasActivated = true; changingSession = false
        do { try await persist() }
        catch { if sessionRevision == revision { self.error = error.localizedDescription } }
        guard sessionRevision == revision else { return }
        onChange?(); pump()
    }

    func enqueue(songIDs: [Int64]) async throws {
        let ids = Array(Set(songIDs)).sorted()
        try await plan(key: Self.songPlanKey(ids)) { saved in
            let values = try await self.downloadSongs(ids: ids, credential: saved.credential)
            return (values, nil)
        }
    }

    private static func songPlanKey(_ sortedIDs: [Int64]) -> String {
        "songs:" + sortedIDs.map(String.init).joined(separator: ",")
    }

    func enqueueAlbum(id: Int64) async throws {
        try await plan(key: "album:\(id)") { saved in
            let detail = try await self.client.albumDetail(id: id, credential: saved.credential)
            var values = try await self.downloadSongs(ids: detail.songs.map(\.id), credential: saved.credential)
            for index in values.indices {
                values[index].albumArtist = detail.album.artist
                if values[index].trackNumber == 0 { values[index].trackNumber = index + 1 }
            }
            return (values, .init(kind: .album, id: id, ownerID: saved.profile.userID,
                                 title: detail.album.title, artist: detail.album.artist, orderedSongIDs: detail.songs.map(\.id)))
        }
    }

    func enqueuePlaylist(id: Int64) async throws {
        try await plan(key: "playlist:\(id)") { saved in
            let detail = try await self.client.detail(id: id, credential: saved.credential, trackLimit: 0)
            let values = try await self.downloadSongs(ids: detail.orderedTrackIDs, credential: saved.credential)
            return (values, .init(kind: .playlist, id: id, ownerID: saved.profile.userID,
                                 title: detail.playlist.title, artist: detail.playlist.creator, orderedSongIDs: detail.orderedTrackIDs))
        }
    }

    private func downloadSongs(ids: [Int64], credential: NeteaseCredential) async throws -> [NeteaseDownloadSong] {
        try await client.downloadSongs(ids: ids, credential: credential,
            onAuthenticationRequired: sessionScope.authenticationHandler(signedIn: true))
    }

    private func plan(key: String, build: @escaping @MainActor (NeteaseSavedSession) async throws -> ([NeteaseDownloadSong], NeteaseDownloadCollection?)) async throws {
        try Task.checkCancellation()
        if let plan = plans[key] { return try await plan.task.value }
        guard let saved = session, !changingSession else { throw NeteaseAccountError.authenticationRequired }
        let revision = sessionRevision, selectedQuality = quality, planID = UUID()
        let task = sessionScope.throwingTask { [weak self] in
            guard let self else { return }
            let (songs, collection): ([NeteaseDownloadSong], NeteaseDownloadCollection?)
            do {
                (songs, collection) = try await build(saved)
            } catch {
                self.sessionScope.report(error, revision: revision, signedIn: true)
                throw error
            }
            try Task.checkCancellation()
            guard self.sessionRevision == revision else { throw NeteaseDownloadError.accountChanged }
            guard !songs.isEmpty else { throw NeteaseDownloadError.unavailable }
            let oldCollections = self.collections, oldJobs = self.jobs, oldStates = self.states
            var existingFiles = Set<Int64>()
            if let collection { self.collections[collection.key] = collection }
            for metadata in songs {
                let songID = metadata.song.id
                if self.resource(songID: songID) != nil {
                    self.states[songID] = .downloaded
                    existingFiles.insert(songID)
                    continue
                }
                if self.jobs.values.contains(where: { $0.metadata.song.id == songID && !$0.cancelled && $0.error == nil }) { continue }
                self.jobs = self.jobs.filter { $0.value.metadata.song.id != songID }
                let job = NeteaseDownloadJob(id: UUID(), ownerID: saved.profile.userID, metadata: metadata,
                                            requestedQuality: selectedQuality)
                self.jobs[job.id] = job
                self.states[songID] = .queued
            }
            let submittedCollections = self.collections, submittedJobs = self.jobs, submittedStates = self.states
            do { try await self.persist() }
            catch {
                for key in Set(oldCollections.keys).union(submittedCollections.keys) where self.collections[key] == submittedCollections[key] {
                    self.collections[key] = oldCollections[key]
                }
                for key in Set(oldJobs.keys).union(submittedJobs.keys) where self.jobs[key] == submittedJobs[key] {
                    self.jobs[key] = oldJobs[key]
                }
                for key in Set(oldStates.keys).union(submittedStates.keys) where self.states[key] == submittedStates[key] {
                    self.states[key] = oldStates[key]
                }
                throw error
            }
            for (id, previous) in oldJobs where self.jobs[id] == nil { self.cleanupTransfer(previous) }
            try Task.checkCancellation()
            guard self.sessionRevision == revision else { throw NeteaseDownloadError.accountChanged }
            if !existingFiles.isSubset(of: self.availableFileIDs) { self.availableFileIDs.formUnion(existingFiles) }
            self.error = nil; self.onRecordsChanged?(); self.onChange?(); self.pump()
        }
        plans[key] = PlanningTask(id: planID, task: task)
        defer { if plans[key]?.id == planID { plans.removeValue(forKey: key) } }
        do { try await task.value }
        catch {
            if sessionRevision != revision || task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            self.error = error.localizedDescription
            throw error
        }
    }

    private func cancelPlan(key: String) async {
        guard let plan = plans[key] else { return }
        plan.task.cancel()
        _ = await plan.task.result
        if plans[key]?.id == plan.id { plans.removeValue(forKey: key) }
    }

    func stopCollection(key: String) async {
        let revision = sessionRevision
        await cancelPlan(key: key)
        guard sessionRevision == revision, let collection = collections[key] else { return }
        await stop(songIDs: collection.orderedSongIDs)
    }

    func stopSongSelection(songIDs: [Int64]) async {
        let revision = sessionRevision
        await cancelPlan(key: Self.songPlanKey(Array(Set(songIDs)).sorted()))
        guard sessionRevision == revision else { return }
        await stop(songIDs: songIDs)
    }

    func stop(songIDs: [Int64]) async {
        let songs = Set(songIDs), ids = Set(jobs.values.filter { songs.contains($0.metadata.song.id) }.map(\.id))
        for id in ids { jobs[id]?.cancelled = true; workers[id]?.cancel() }
        await transport.cancel(ids: ids)
        for id in ids { await workers[id]?.value; if let job = jobs[id] { cleanupTransfer(job) }; jobs.removeValue(forKey: id) }
        transferring.subtract(ids)
        for id in songs where resource(songID: id) == nil { states.removeValue(forKey: id) }
        do { try await persist() } catch { self.error = error.localizedDescription }
        onChange?(); pump()
    }

    func remove(songIDs: [Int64]) async throws {
        await stop(songIDs: songIDs)
        defer {
            let missing = Set(songIDs).filter { resource(songID: $0) == nil }
            for id in missing { states.removeValue(forKey: id) }
            if !availableFileIDs.isDisjoint(with: missing) { availableFileIDs.subtract(missing) }
            onRecordsChanged?(); onChange?()
        }
        for id in Set(songIDs) {
            guard let record = records[id] else { continue }
            for path in [record.relativePath, record.lyricsRelativePath].compactMap({ $0 }) {
                let url = try ownedFile(path)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            states.removeValue(forKey: id)
        }
        try await persist()
    }

    func resource(songID: Int64) -> URL? {
        guard let record = records[songID], let url = try? ownedFile(record.relativePath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func waitForProcessing() async {
        while !workers.isEmpty { for task in workers.values { await task.value } }
        _ = await persistenceTask?.result
    }
    func lyricsURL(songID: Int64) -> URL? {
        guard let path = records[songID]?.lyricsRelativePath else { return nil }
        return try? ownedFile(path)
    }

    func reconcileFiles() async {
        let snapshot = records
        let available = await Self.availableSongIDs(records: snapshot, musicDirectory: musicDirectory)
        guard !Task.isCancelled, records == snapshot else { return }
        if reconcileFileAvailability(available) { onRecordsChanged?() }
    }

    @discardableResult
    func reconcileFileAvailability(_ availableSongIDs: Set<Int64>) -> Bool {
        let checked = availableSongIDs.filter {
            records[$0] != nil && (states[$0] != .processing || availableFileIDs.contains($0))
        }
        let availabilityChanged = availableFileIDs != checked
        if availabilityChanged { availableFileIDs = checked }
        let missing = records.keys.filter { states[$0] == .downloaded && !checked.contains($0) }
        let returned = checked.filter { states[$0] == nil }
        guard availabilityChanged || !missing.isEmpty || !returned.isEmpty else { return false }
        for id in missing { states.removeValue(forKey: id) }
        for id in returned { states[id] = .downloaded }
        onChange?()
        return true
    }

    @concurrent private static func availableSongIDs(records: [Int64: NeteaseDownloadRecord],
                                                     musicDirectory: URL) async -> Set<Int64> {
        let root = musicDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var available = Set<Int64>()
        for record in records.values {
            if Task.isCancelled { return [] }
            if let url = try? ownedFile(record.relativePath, resolvedRoot: root),
               FileManager.default.fileExists(atPath: url.path) {
                available.insert(record.songID)
            }
        }
        return available
    }

    private func pump() {
        guard isRestored, let saved = session, !changingSession, !changingNetwork else { return }
        for job in jobs.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard workers.count + transferring.count < 3 else { return }
            guard !job.cancelled, job.error == nil, job.ownerID == saved.profile.userID,
                  workers[job.id] == nil, !transferring.contains(job.id) else { continue }
            let revision = sessionRevision
            workers[job.id] = sessionScope.task { [weak self] in
                guard let self else { return }
                defer { self.workers.removeValue(forKey: job.id); self.pump() }
                do {
                    if let filename = job.stagedFilename {
                        try await self.finish(job, file: self.transport.spool.appending(path: filename), saved: saved, revision: revision)
                    } else {
                        let source = try await self.client.downloadSource(id: job.metadata.song.id, quality: job.requestedQuality, credential: saved.credential)
                        try self.check(job.id, revision: revision)
                        self.jobs[job.id]?.actualQuality = source.quality; self.jobs[job.id]?.type = source.type
                        self.jobs[job.id]?.expectedSize = source.size
                        try await self.persist()
                        try self.check(job.id, revision: revision)
                        self.transferring.insert(job.id)
                        self.transport.start(id: job.id, url: source.url, allowsCellular: self.allowsCellular)
                        self.set(.downloading(0), for: job.metadata.song.id)
                    }
                } catch {
                    guard self.sessionRevision == revision, self.jobs[job.id]?.cancelled == false,
                          !(error is CancellationError) else { return }
                    self.sessionScope.report(error, revision: revision, signedIn: true)
                    self.fail(job.id, message: error.localizedDescription)
                }
            }
        }
    }

    private func receive(_ event: NeteaseDownloadTransport.Event) {
        guard isRestored else { eventsBeforeRestore.append(event); return }
        switch event {
        case let .progress(id, progress):
            guard let job = jobs[id], !job.cancelled, job.stagedFilename == nil else { return }
            set(.downloading((progress * 100).rounded(.down) / 100), for: job.metadata.song.id)
        case let .waiting(id):
            guard let job = jobs[id], !job.cancelled, job.stagedFilename == nil else { return }
            set(.waiting, for: job.metadata.song.id)
        case let .completed(id, file):
            transferring.remove(id)
            guard let job = jobs[id], !job.cancelled else { try? FileManager.default.removeItem(at: file); return }
            jobs[id]?.stagedFilename = file.lastPathComponent
            let revision = sessionRevision
            let write = enqueuePersistence()
            workers[id] = sessionScope.task { [weak self] in
                guard let self else { return }
                defer { self.workers.removeValue(forKey: id); self.pump() }
                do { try await write.value }
                catch {
                    guard self.sessionScope.isCurrent(revision), self.jobs[id]?.cancelled == false else { return }
                    self.fail(id, message: error.localizedDescription)
                }
            }
        case let .failed(id, message, cancelled):
            transferring.remove(id)
            guard let job = jobs[id], !job.cancelled, !changingNetwork, !changingSession else { return }
            if cancelled {
                set(.queued, for: job.metadata.song.id); pump(); return
            }
            fail(id, message: message); pump()
        }
    }

    private func finish(_ job: NeteaseDownloadJob, file: URL, saved: NeteaseSavedSession, revision: UUID) async throws {
        try check(job.id, revision: revision)
        guard let type = job.type, let actual = job.actualQuality else { throw NeteaseDownloadError.invalidFile }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, job.expectedSize.map({ $0 == Int64(size) }) ?? true else { throw NeteaseDownloadError.invalidFile }
        set(.processing, for: job.metadata.song.id)
        let song = job.metadata.song
        async let cover = optionalArtwork(song.artworkURL)
        async let lyrics = optionalLyrics(song.id, credential: saved.credential, revision: revision)
        let (artwork, lyricText) = await (cover, lyrics)
        try check(job.id, revision: revision)
        let staging = directory.appending(path: "Processing/\(job.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tags = DownloadedAudioTags.Metadata(title: song.title, artist: song.artist, album: song.album,
            albumArtist: job.metadata.albumArtist, trackNumber: job.metadata.trackNumber, discNumber: job.metadata.discNumber,
            artwork: artwork, lyrics: lyricText)
        let prepared = try await process(file, type, tags, staging)
        try check(job.id, revision: revision)
        let folder = "网易云/\(Self.component(song.album, fallback: "未知专辑")) [\(song.albumID ?? 0)]"
        let filename = String(format: "%02d-%02d ", job.metadata.discNumber, job.metadata.trackNumber)
            + Self.component(song.title, fallback: "歌曲") + " [\(song.id)]." + prepared.pathExtension
        let relative = folder + "/" + filename
        let destination = try ownedFile(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resource(songID: song.id) != nil {
            jobs.removeValue(forKey: job.id)
            cleanupTransfer(job)
            if !availableFileIDs.contains(song.id) { availableFileIDs.insert(song.id) }
            set(.downloaded, for: song.id)
            return
        }
        let recoveringCommit = job.destinationRelativePath == relative && FileManager.default.fileExists(atPath: destination.path)
        if FileManager.default.fileExists(atPath: destination.path), !recoveringCommit { throw CocoaError(.fileWriteFileExists) }
        jobs[job.id]?.destinationRelativePath = relative
        try await persist()
        try check(job.id, revision: revision)
        if !recoveringCommit { try FileManager.default.moveItem(at: prepared, to: destination) }
        let lyricPath = lyricText.map { _ in String(relative.dropLast(prepared.pathExtension.count)) + "lrc" }
        let previousRecord = records[song.id]
        do {
            if let lyricPath, let lyricText { try lyricText.write(to: ownedFile(lyricPath), atomically: true, encoding: .utf8) }
            records[song.id] = .init(metadata: job.metadata, relativePath: relative, lyricsRelativePath: lyricPath,
                                     quality: actual, downloadedAt: Date(), ownerID: saved.profile.userID)
            committingJobs.insert(job.id)
            try await persist()
            committingJobs.remove(job.id)
            jobs.removeValue(forKey: job.id)
        } catch {
            committingJobs.remove(job.id)
            records[song.id] = previousRecord
            if jobs[job.id] == nil { jobs[job.id] = job }
            if !recoveringCommit { try? FileManager.default.removeItem(at: destination) }
            if let lyricPath { try? FileManager.default.removeItem(at: ownedFile(lyricPath)) }
            _ = enqueuePersistence()
            throw error
        }
        cleanupTransfer(job)
        if !availableFileIDs.contains(song.id) { availableFileIDs.insert(song.id) }
        set(.downloaded, for: song.id)
        if let onFileCommitted { onFileCommitted(relative) } else { onRecordsChanged?() }
    }

    private func optionalLyrics(_ id: Int64, credential: NeteaseCredential, revision: UUID) async -> String? {
        do {
            let lyrics = try await client.lyrics(id: id, credential: credential)
            guard !lyrics.original.isEmpty else { return nil }
            return LyricsDocument.storedText(original: lyrics.original, translation: lyrics.translation)
        } catch {
            sessionScope.report(error, revision: revision, signedIn: true)
            return nil
        }
    }
    private func optionalArtwork(_ url: URL?) async -> Data? {
        guard let url, let (data, response) = try? await artworkSession.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 20_000_000 else { return nil }
        return data
    }
    private func restartTransfersForNetworkPolicy() async {
        guard !changingNetwork, !changingSession else { return }
        changingNetwork = true
        let ids = transferring
        await transport.cancel(ids: ids)
        transferring.subtract(ids)
        changingNetwork = false; pump()
    }
    private func check(_ id: UUID, revision: UUID) throws {
        try Task.checkCancellation()
        guard revision == sessionRevision, jobs[id]?.cancelled == false, jobs[id]?.ownerID == userID else {
            throw NeteaseDownloadError.accountChanged
        }
    }
    private func fail(_ id: UUID, message: String) {
        guard let job = jobs[id] else { return }
        jobs[id]?.error = message
        set(.failed(message), for: job.metadata.song.id)
        let revision = sessionRevision
        let write = enqueuePersistence()
        Task { [weak self] in
            do { try await write.value }
            catch {
                if self?.sessionScope.isCurrent(revision) == true { self?.error = error.localizedDescription }
            }
        }
    }
    private func set(_ state: NeteaseDownloadState, for id: Int64) {
        guard states[id] != state else { return }
        states[id] = state
        switch state {
        case .downloading, .waiting:
            if let onProgressChanged { onProgressChanged(id) } else { onChange?() }
        default: onChange?()
        }
    }
    private func cleanupTransfer(_ job: NeteaseDownloadJob) {
        let path = transport.spool.appending(path: job.stagedFilename ?? job.id.uuidString + ".transfer")
        try? FileManager.default.removeItem(at: path)
    }
    private func persist() async throws {
        try await enqueuePersistence().value
    }
    private func enqueuePersistence() -> Task<Void, Error> {
        let value = Snapshot(records: Array(records.values), collections: Array(collections.values), jobs: jobs.values.filter { !committingJobs.contains($0.id) })
        let previous = persistenceTask, directory = directory, writeIndex = writeIndex
        let task = Task.detached {
            _ = await previous?.result
            try await writeIndex(AtomicJSONStore.encode(value), directory.appending(path: "index.json"))
        }
        persistenceTask = task
        return task
    }
    @concurrent static func writeIndexFile(_ data: Data, _ url: URL) async throws {
        try AtomicJSONStore.writeData(data, to: url)
    }
    private func ownedFile(_ path: String) throws -> URL {
        let root = musicDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return try Self.ownedFile(path, resolvedRoot: root)
    }
    nonisolated static func ownedFile(_ path: String, resolvedRoot root: URL) throws -> URL {
        let url = root.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
        guard path.hasPrefix("网易云/"), url.path.hasPrefix(root.path + "/"), !path.split(separator: "/").contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }
    nonisolated private static func component(_ value: String, fallback: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : String(cleaned.prefix(100))
    }
}
