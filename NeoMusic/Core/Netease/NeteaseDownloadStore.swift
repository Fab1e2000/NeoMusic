import Foundation
import Observation

@MainActor @Observable
final class NeteaseDownloadStore {
    typealias Processor = @Sendable (URL, String, DownloadedAudioTags.Metadata, URL) async throws -> URL
    private(set) var states: [Int64: NeteaseDownloadState] = [:]
    private(set) var records: [Int64: NeteaseDownloadRecord] = [:]
    private(set) var collections: [String: NeteaseDownloadCollection] = [:]
    private(set) var isRestored = false
    private(set) var error: String?
    private(set) var userID: Int64?
    private(set) var sessionRevision = UUID()
    var quality: NeteaseMusicQuality {
        didSet { defaults.set(quality.rawValue, forKey: "netease.download.quality") }
    }
    var allowsCellular: Bool {
        didSet {
            defaults.set(allowsCellular, forKey: "netease.download.cellular")
            if oldValue != allowsCellular { Task { await restartTransfersForNetworkPolicy() } }
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onRecordsChanged: (() -> Void)?
    let musicDirectory: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: NeteaseDownloadTransport
    @ObservationIgnored private let process: Processor
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
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var records: [NeteaseDownloadRecord]
        var collections: [NeteaseDownloadCollection]
        var jobs: [NeteaseDownloadJob]
    }

    init(client: NeteaseMusicClient = NeteaseMusicClient(),
         directory: URL = URL.applicationSupportDirectory.appending(path: "NeteaseDownloads", directoryHint: .isDirectory),
         musicDirectory: URL = URL.documentsDirectory.appending(path: "音乐", directoryHint: .isDirectory),
         defaults: UserDefaults = .standard, transport: NeteaseDownloadTransport? = nil,
         process: @escaping Processor = NeteaseDownloadStore.prepare) {
        self.client = client; self.directory = directory; self.musicDirectory = musicDirectory; self.defaults = defaults
        self.quality = defaults.string(forKey: "netease.download.quality").flatMap(NeteaseMusicQuality.init(rawValue:)) ?? .lossless
        self.allowsCellular = defaults.object(forKey: "netease.download.cellular") as? Bool ?? true
        self.transport = transport ?? NeteaseDownloadTransport(spool: directory.appending(path: "Transfers"))
        self.process = process
        self.transport.onEvent = { [weak self] in self?.receive($0) }
        self.transport.onFinishedEvents = { [weak self] in
            guard let self else { return }
            for work in self.workers.values { await work.value }
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = directory.appending(path: "index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: index))
                records = Dictionary(snapshot.records.map { ($0.songID, $0) }, uniquingKeysWith: { _, last in last })
                collections = Dictionary(snapshot.collections.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
                jobs = Dictionary(snapshot.jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            }
            transferring = await transport.activeIDs()
            for job in jobs.values {
                if job.cancelled { continue }
                states[job.metadata.song.id] = job.error.map(NeteaseDownloadState.failed) ?? .queued
            }
            for id in records.keys where resource(songID: id) != nil { states[id] = .downloaded }
            // A download delegate may have moved its file just before the process exited.
            for id in jobs.keys where jobs[id]?.stagedFilename == nil {
                let file = transport.spool.appending(path: id.uuidString + ".transfer")
                if FileManager.default.fileExists(atPath: file.path) { jobs[id]?.stagedFilename = file.lastPathComponent }
            }
            isRestored = true
            let buffered = eventsBeforeRestore; eventsBeforeRestore = []
            for event in buffered { receive(event) }
            await reconcileFiles()
            onRecordsChanged?(); onChange?()
        } catch { self.error = "读取下载记录失败：\(error.localizedDescription)" }
    }

    func activate(_ saved: NeteaseSavedSession?) async {
        await restore()
        guard isRestored else { return }
        if hasActivated, session == saved { pump(); return }
        changingSession = true
        sessionRevision = UUID()
        let previousSession = session
        session = saved; userID = saved?.profile.userID
        let obsolete = Set(jobs.values.filter {
            $0.ownerID != saved?.profile.userID || (hasActivated && previousSession != saved)
        }.map(\.id))
        for id in obsolete { jobs[id]?.cancelled = true }
        for plan in plans.values { plan.task.cancel() }
        for task in workers.values { task.cancel() }
        await transport.cancel(ids: obsolete.union(transferring.filter { jobs[$0] == nil }))
        for plan in plans.values { _ = await plan.task.result }
        for task in workers.values { await task.value }
        plans = [:]; workers = [:]
        transferring.subtract(obsolete)
        for id in obsolete {
            guard let job = jobs[id] else { continue }
            cleanupTransfer(job)
            if resource(songID: job.metadata.song.id) == nil { states.removeValue(forKey: job.metadata.song.id) }
        }
        jobs = jobs.filter { !obsolete.contains($0.key) }
        hasActivated = true; changingSession = false
        do { try persist() } catch { self.error = error.localizedDescription }
        onChange?(); pump()
    }

    func enqueue(songIDs: [Int64]) async throws {
        let ids = Array(Set(songIDs)).sorted()
        try await plan(key: "songs:" + ids.map(String.init).joined(separator: ",")) { saved in
            let values = try await self.client.downloadSongs(ids: ids, credential: saved.credential)
            return (values, nil)
        }
    }

    #if DEBUG
    /// Diagnostics use the active business-layer credential and leave account and playback state untouched.
    func readProbeCandidate(progress: (Int) -> Void) async throws -> (id: Int64, attempts: Int, declaredType: String) {
        guard let saved = session else { throw NeteaseAccountError.authenticationRequired }
        let revision = sessionRevision
        let daily = try await client.dailyRecommendations(credential: saved.credential)
        let candidates = daily.filter { !$0.unavailable && resource(songID: $0.id) == nil }.prefix(3)
        var attempts = 0
        for song in candidates {
            attempts += 1; progress(attempts)
            do {
                let source = try await client.downloadSource(id: song.id, quality: .lossless, credential: saved.credential)
                try Task.checkCancellation()
                guard revision == sessionRevision else { throw NeteaseDownloadError.accountChanged }
                return (song.id, attempts, source.type)
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard revision == sessionRevision else { throw NeteaseDownloadError.accountChanged }
            }
        }
        throw NeteaseDownloadError.unavailable
    }
    #endif

    func enqueueAlbum(id: Int64) async throws {
        try await plan(key: "album:\(id)") { saved in
            let detail = try await self.client.albumDetail(id: id, credential: saved.credential)
            var values = try await self.client.downloadSongs(ids: detail.songs.map(\.id), credential: saved.credential)
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
            let values = try await self.client.downloadSongs(ids: detail.orderedTrackIDs, credential: saved.credential)
            return (values, .init(kind: .playlist, id: id, ownerID: saved.profile.userID,
                                 title: detail.playlist.title, artist: detail.playlist.creator, orderedSongIDs: detail.orderedTrackIDs))
        }
    }

    private func plan(key: String, build: @escaping @MainActor (NeteaseSavedSession) async throws -> ([NeteaseDownloadSong], NeteaseDownloadCollection?)) async throws {
        if let plan = plans[key] { return try await plan.task.value }
        guard let saved = session, !changingSession else { throw NeteaseAccountError.authenticationRequired }
        let revision = sessionRevision, selectedQuality = quality, planID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let (songs, collection) = try await build(saved)
            try Task.checkCancellation()
            guard self.sessionRevision == revision else { throw NeteaseDownloadError.accountChanged }
            guard !songs.isEmpty else { throw NeteaseDownloadError.unavailable }
            let oldCollections = self.collections, oldJobs = self.jobs, oldStates = self.states
            if let collection { self.collections[collection.key] = collection }
            for metadata in songs {
                let songID = metadata.song.id
                if self.resource(songID: songID) != nil { self.states[songID] = .downloaded; continue }
                if self.jobs.values.contains(where: { $0.metadata.song.id == songID && !$0.cancelled && $0.error == nil }) { continue }
                self.jobs = self.jobs.filter { $0.value.metadata.song.id != songID }
                let job = NeteaseDownloadJob(id: UUID(), ownerID: saved.profile.userID, metadata: metadata,
                                            requestedQuality: selectedQuality)
                self.jobs[job.id] = job
                self.states[songID] = .queued
            }
            do { try self.persist() }
            catch {
                self.collections = oldCollections; self.jobs = oldJobs; self.states = oldStates
                throw error
            }
            for (id, previous) in oldJobs where self.jobs[id] == nil { self.cleanupTransfer(previous) }
            self.error = nil; self.onRecordsChanged?(); self.onChange?(); self.pump()
        }
        plans[key] = PlanningTask(id: planID, task: task)
        defer { if plans[key]?.id == planID { plans.removeValue(forKey: key) } }
        do { try await task.value }
        catch {
            if task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            self.error = error.localizedDescription
            throw error
        }
    }

    func stopCollection(key: String) async {
        if let plan = plans[key] {
            plan.task.cancel()
            _ = await plan.task.result
            if plans[key]?.id == plan.id { plans.removeValue(forKey: key) }
        }
        if let collection = collections[key] { await stop(songIDs: collection.orderedSongIDs) }
    }

    func stop(songIDs: [Int64]) async {
        let songs = Set(songIDs), ids = Set(jobs.values.filter { songs.contains($0.metadata.song.id) }.map(\.id))
        for id in ids { jobs[id]?.cancelled = true; workers[id]?.cancel() }
        await transport.cancel(ids: ids)
        for id in ids { await workers[id]?.value; if let job = jobs[id] { cleanupTransfer(job) }; jobs.removeValue(forKey: id) }
        transferring.subtract(ids)
        for id in songs where resource(songID: id) == nil { states.removeValue(forKey: id) }
        do { try persist() } catch { self.error = error.localizedDescription }
        onChange?(); pump()
    }

    func remove(songIDs: [Int64]) async throws {
        await stop(songIDs: songIDs)
        defer {
            for id in Set(songIDs) where resource(songID: id) == nil { states.removeValue(forKey: id) }
            onRecordsChanged?(); onChange?()
        }
        for id in Set(songIDs) {
            guard let record = records[id] else { continue }
            for path in [record.relativePath, record.lyricsRelativePath].compactMap({ $0 }) {
                let url = try ownedFile(path)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            // Retain source identity and collection references for online fallback and future downloads.
            states.removeValue(forKey: id)
        }
        try persist()
    }

    func resource(songID: Int64) -> URL? {
        guard let record = records[songID], let url = try? ownedFile(record.relativePath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Used by background-event completion and deterministic integration tests.
    func waitForProcessing() async {
        while !workers.isEmpty { for task in workers.values { await task.value } }
    }
    func lyricsURL(songID: Int64) -> URL? {
        guard let path = records[songID]?.lyricsRelativePath else { return nil }
        return try? ownedFile(path)
    }

    func reconcileFiles() async {
        let missing = records.keys.filter { states[$0] == .downloaded && resource(songID: $0) == nil }
        guard !missing.isEmpty else { return }
        for id in missing { states.removeValue(forKey: id) }
        onRecordsChanged?(); onChange?()
    }

    private func pump() {
        guard isRestored, let saved = session, !changingSession, !changingNetwork else { return }
        for job in jobs.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard workers.count + transferring.count < 3 else { return }
            guard !job.cancelled, job.error == nil, job.ownerID == saved.profile.userID,
                  workers[job.id] == nil, !transferring.contains(job.id) else { continue }
            let revision = sessionRevision
            workers[job.id] = Task { [weak self] in
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
                        try self.persist()
                        self.transferring.insert(job.id)
                        self.transport.start(id: job.id, url: source.url, allowsCellular: self.allowsCellular)
                        self.set(.downloading(0), for: job.metadata.song.id)
                    }
                } catch {
                    guard self.sessionRevision == revision, self.jobs[job.id]?.cancelled == false,
                          !(error is CancellationError) else { return }
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
            // Whole percent updates keep long lists independent of network packet frequency.
            set(.downloading((progress * 100).rounded(.down) / 100), for: job.metadata.song.id)
        case let .waiting(id):
            guard let job = jobs[id], !job.cancelled, job.stagedFilename == nil else { return }
            set(.waiting, for: job.metadata.song.id)
        case let .completed(id, file):
            transferring.remove(id)
            guard let job = jobs[id], !job.cancelled else { try? FileManager.default.removeItem(at: file); return }
            jobs[id]?.stagedFilename = file.lastPathComponent
            do { try persist() } catch { fail(id, message: error.localizedDescription); return }
            pump()
        case let .failed(id, message, cancelled):
            transferring.remove(id)
            guard let job = jobs[id], !job.cancelled, !changingNetwork, !changingSession else { return }
            if cancelled {
                // User stops are persisted above. System cancellation after force-quit keeps the request resumable.
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
        async let lyrics = optionalLyrics(song.id, credential: saved.credential)
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
        // Repeated requests reuse a committed file; only a fully prepared file can replace an orphan.
        if resource(songID: song.id) != nil { jobs.removeValue(forKey: job.id); cleanupTransfer(job); return }
        let recoveringCommit = job.destinationRelativePath == relative && FileManager.default.fileExists(atPath: destination.path)
        if FileManager.default.fileExists(atPath: destination.path), !recoveringCommit { throw CocoaError(.fileWriteFileExists) }
        // Persist ownership before the move so a process exit between file and index commits is recoverable.
        jobs[job.id]?.destinationRelativePath = relative
        try persist()
        if !recoveringCommit { try FileManager.default.moveItem(at: prepared, to: destination) }
        let lyricPath = lyricText.map { _ in String(relative.dropLast(prepared.pathExtension.count)) + "lrc" }
        let previousRecord = records[song.id]
        do {
            if let lyricPath, let lyricText { try lyricText.write(to: ownedFile(lyricPath), atomically: true, encoding: .utf8) }
            records[song.id] = .init(metadata: job.metadata, relativePath: relative, lyricsRelativePath: lyricPath,
                                     quality: actual, downloadedAt: Date(), ownerID: saved.profile.userID)
            jobs.removeValue(forKey: job.id)
            try persist()
        } catch {
            records[song.id] = previousRecord; jobs[job.id] = job
            if !recoveringCommit { try? FileManager.default.removeItem(at: destination) }
            if let lyricPath { try? FileManager.default.removeItem(at: ownedFile(lyricPath)) }
            throw error
        }
        cleanupTransfer(job); set(.downloaded, for: song.id); onRecordsChanged?()
    }

    private func optionalLyrics(_ id: Int64, credential: NeteaseCredential) async -> String? {
        guard let lyrics = try? await client.lyrics(id: id, credential: credential), !lyrics.original.isEmpty else { return nil }
        return lyrics.translation.isEmpty ? lyrics.original : lyrics.original + "\n" + lyrics.translation
    }
    private func optionalArtwork(_ url: URL?) async -> Data? {
        guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
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
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    private func set(_ state: NeteaseDownloadState, for id: Int64) {
        guard states[id] != state else { return }
        states[id] = state; onChange?()
    }
    private func cleanupTransfer(_ job: NeteaseDownloadJob) {
        let path = transport.spool.appending(path: job.stagedFilename ?? job.id.uuidString + ".transfer")
        try? FileManager.default.removeItem(at: path)
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = Snapshot(records: Array(records.values), collections: Array(collections.values), jobs: Array(jobs.values))
        try JSONEncoder().encode(value).write(to: directory.appending(path: "index.json"), options: .atomic)
    }
    private func ownedFile(_ path: String) throws -> URL {
        let root = musicDirectory.standardizedFileURL.resolvingSymlinksInPath()
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
