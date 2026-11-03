import Foundation
import Observation
import Network

@MainActor @Observable
final class NeteaseMusicStore {
    private(set) var userID: Int64?
    private(set) var playlists: [NeteaseMusicPlaylist] = []
    private(set) var songs: [Int64: NeteaseMusicSong] = [:]
    private(set) var playlistTracks: [Int64: [Int64]] = [:]
    private(set) var likedIDs: Set<Int64> = []
    private(set) var likedAt: [Int64: Date] = [:]
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var loadingPlaylists: Set<Int64> = []
    private(set) var playlistErrors: [Int64: String] = [:]
    var wifiQuality: NeteaseMusicQuality = .lossless { didSet { defaults.set(wifiQuality.rawValue, forKey: "netease.quality.wifi"); onQualityChange?() } }
    var cellularQuality: NeteaseMusicQuality = .high { didSet { defaults.set(cellularQuality.rawValue, forKey: "netease.quality.cellular"); onQualityChange?() } }
    private(set) var isCellular = false
    @ObservationIgnored var onAuthenticationRequired: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onSessionInvalidated: (() -> Void)?
    @ObservationIgnored var onQualityChange: (() -> Void)?
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var detailTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lyricCache: [Int64: NeteaseMusicLyrics] = [:]
    @ObservationIgnored private var artworkFiles: [String: String] = [:]
    @ObservationIgnored private let artworkSession = URLSession(configuration: NeteaseAccountClient.sessionConfiguration())
    @ObservationIgnored private let cacheIO = MusicCacheIO()
    @ObservationIgnored private let monitor = NWPathMonitor()

    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.client = client; self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NeteaseMusic")
        wifiQuality = NeteaseMusicQuality(rawValue: defaults.string(forKey: "netease.quality.wifi") ?? "") ?? .lossless
        cellularQuality = NeteaseMusicQuality(rawValue: defaults.string(forKey: "netease.quality.cellular") ?? "") ?? .high
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                guard let self, self.isCellular != cellular else { return }
                self.isCellular = cellular; self.onQualityChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "NeoMusic.NetworkQuality"))
    }

    deinit { monitor.cancel() }

    func activate(_ session: NeteaseSavedSession, refresh: Bool = true) async {
        if userID != session.profile.userID || credential != session.credential {
            await invalidate()
            userID = session.profile.userID; credential = session.credential
            let revision = generation
            let cached = await cacheIO.load(cacheURL)
            guard revision == generation else { return }
            if let cached {
                playlists = cached.playlists; songs = cached.songs; playlistTracks = cached.tracks
                likedIDs = cached.liked; likedAt = cached.times; lyricCache = cached.lyrics; artworkFiles = cached.artwork ?? [:]
            }
            onChange?()
        }
        if refresh { await self.refresh() }
    }

    func invalidate() async {
        generation = UUID(); credential = nil; userID = nil
        onSessionInvalidated?()
        let pending = Array(tasks.values) + Array(detailTasks.values); pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        tasks.removeAll(); detailTasks.removeAll(); playlists = []; songs = [:]; playlistTracks = [:]; likedIDs = []; likedAt = [:]; lyricCache = [:]; artworkFiles = [:]
        isLoading = false; loadingPlaylists = []; playlistErrors = [:]; error = nil; onChange?()
    }

    private func run<T: Sendable>(_ operation: @escaping @MainActor (NeteaseCredential) async throws -> T) async throws -> T {
        guard let credential else { throw NeteaseAccountError.authenticationRequired }
        let revision = generation, id = UUID()
        let resultTask = Task { try await operation(credential) }
        tasks[id] = Task { await withTaskCancellationHandler { _ = await resultTask.result } onCancel: { resultTask.cancel() } }
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let value: T
            do { value = try await resultTask.value } catch {
                guard generation == revision else { throw CancellationError() }
                if error as? NeteaseAccountError == .authenticationRequired { onAuthenticationRequired?() }
                throw error
            }
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            return value
        } onCancel: { resultTask.cancel() }
    }

    func refresh() async {
        guard let userID, !isLoading else { return }
        isLoading = true; onChange?()
        let revision = generation
        defer { if generation == revision { isLoading = false; onChange?() } }
        do {
            let result = try await run { [client] credential in
                let playlists = try await client.playlists(userID: userID, credential: credential)
                let liked = try await client.likedIDs(userID: userID, credential: credential)
                return (playlists, liked)
            }
            playlists = result.0; likedIDs = Set(result.1); error = nil
            save(); onChange?()
            preloadArtwork(playlists.compactMap(\.artworkURL))
            if let favorites = playlists.first(where: \.isFavorites) { await loadPlaylist(id: favorites.id) }
        } catch is CancellationError {} catch { if generation == revision { self.error = error.localizedDescription; onChange?() } }
    }

    func loadPlaylist(id: Int64) async {
        if let existing = detailTasks[id] { await existing.value; return }
        let revision = generation
        let task = Task { [self] in await performLoadPlaylist(id: id) }
        detailTasks[id] = task
        await task.value
        if generation == revision { detailTasks.removeValue(forKey: id) }
    }

    private func performLoadPlaylist(id: Int64) async {
        loadingPlaylists.insert(id); playlistErrors[id] = nil; onChange?()
        let revision = generation
        defer { if generation == revision { loadingPlaylists.remove(id); onChange?() } }
        do {
            let detail = try await run { [client] in try await client.detail(id: id, credential: $0) }
            playlistTracks[id] = detail.songs.map(\.id)
            for song in detail.songs { songs[song.id] = song }
            if detail.playlist.isFavorites, detail.playlist.creatorID == userID { for (id, date) in detail.addedTimes { likedAt[id] = date } }
            error = nil; save(); onChange?()
            preloadArtwork(detail.songs.compactMap(\.artworkURL))
        } catch is CancellationError {} catch { if generation == revision { self.error = error.localizedDescription; playlistErrors[id] = error.localizedDescription; onChange?() } }
    }

    func setLiked(songID: Int64, liked: Bool) async throws {
        guard let userID else { throw NeteaseAccountError.authenticationRequired }
        let revision = generation
        do {
            try await run { [client] in try await client.setLiked(id: songID, liked: liked, credential: $0) }
        } catch {
            if error is CancellationError { throw error }
            guard generation == revision else { throw CancellationError() }
            let original = error
            let ids = try await run { [client] in try await client.likedIDs(userID: userID, credential: $0) }
            likedIDs = Set(ids); save(); onChange?()
            guard likedIDs.contains(songID) == liked else { throw original }
        }
        if liked { likedIDs.insert(songID); likedAt[songID] = Date() }
        else { likedIDs.remove(songID); likedAt.removeValue(forKey: songID) }
        save(); onChange?()
        if let favorites = playlists.first(where: \.isFavorites) { await loadPlaylist(id: favorites.id) }
    }

    func stream(songID: Int64) async throws -> NeteaseMusicStream {
        let quality = isCellular ? cellularQuality : wifiQuality
        return try await run { [client] in try await client.stream(id: songID, quality: quality, credential: $0) }
    }
    func lyrics(songID: Int64) async throws -> NeteaseMusicLyrics {
        if let cached = lyricCache[songID] { return cached }
        let lyrics = try await run { [client] in try await client.lyrics(id: songID, credential: $0) }
        lyricCache[songID] = lyrics; save(); return lyrics
    }
    private func preloadArtwork(_ urls: [URL]) {
        let id = UUID(), revision = generation
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            for url in Set(urls) {
                guard !Task.isCancelled, let self, self.generation == revision else { return }
                _ = try? await self.artwork(url)
            }
        }
    }
    func cachedArtworkURL(for remote: URL) -> URL? { cachedArtworkURL(remote) }
    func cachedArtworkURL(_ remote: URL) -> URL? {
        guard let name = artworkFiles[remote.absoluteString], let userID else { return nil }
        let file = directory.appendingPathComponent("\(userID)-\(name)")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func artwork(_ remote: URL) async throws -> URL {
        if let cached = cachedArtworkURL(remote) { return cached }
        guard remote.scheme == "https", let userID else { throw NeteaseAccountError.authenticationRequired }
        let data = try await run { [artworkSession] _ in
            let (data, response) = try await artworkSession.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { throw URLError(.badServerResponse) }
            return data
        }
        let name = UUID().uuidString + ".image"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(userID)-\(name)")
        try data.write(to: url, options: .atomic)
        artworkFiles[remote.absoluteString] = name; save(); onChange?()
        return url
    }
    private var cacheURL: URL { directory.appendingPathComponent("\(userID ?? 0).json") }
    struct Snapshot: Codable, Sendable {
        let playlists: [NeteaseMusicPlaylist]; let songs: [Int64: NeteaseMusicSong]; let tracks: [Int64: [Int64]]
        let liked: Set<Int64>; let times: [Int64: Date]; let lyrics: [Int64: NeteaseMusicLyrics]; let artwork: [String: String]?
    }
    private func save() {
        guard userID != nil else { return }
        let snapshot = Snapshot(playlists: playlists, songs: songs, tracks: playlistTracks, liked: likedIDs, times: likedAt, lyrics: lyricCache, artwork: artworkFiles)
        let url = cacheURL, revision = generation, id = UUID()
        tasks[id] = Task { [weak self, cacheIO] in
            defer { self?.tasks.removeValue(forKey: id) }
            do { try await cacheIO.save(snapshot, url: url) }
            catch is CancellationError {} catch {
                if self?.generation == revision { self?.error = "缓存保存失败：\(error.localizedDescription)"; self?.onChange?() }
            }
        }
    }
}

private actor MusicCacheIO {
    func load(_ url: URL) -> NeteaseMusicStore.Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NeteaseMusicStore.Snapshot.self, from: data)
    }
    func save(_ snapshot: NeteaseMusicStore.Snapshot, url: URL) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
