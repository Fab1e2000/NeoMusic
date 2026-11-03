import Foundation
import Observation

@MainActor @Observable final class NeteaseHomeStore {
    private(set) var userID: Int64?
    private(set) var recommendations: [NeteaseMusicPlaylist] = []
    private(set) var daily: NeteaseDailySnapshot?
    private(set) var recommendationsError: String?
    private(set) var dailyError: String?
    var onChange: (() -> Void)?
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTasks: [Int64: Task<NeteasePlaylistDetail, Error>] = [:]
    @ObservationIgnored private var artworkTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let artworkSession = URLSession(configuration: NeteaseAccountClient.sessionConfiguration())
    @ObservationIgnored private var cache = Cache()
    @ObservationIgnored private var restored = false
    private struct Cache: Codable {
        var recommendations: [NeteaseMusicPlaylist] = []
        var snapshots: [String: NeteaseDailySnapshot] = [:]
        var details: [Int64: NeteasePlaylistDetail] = [:]
        var artworkFiles: [String: String]? = nil
    }
    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL = URL.applicationSupportDirectory.appendingPathComponent("NeteaseHome")) {
        self.client = client; self.directory = directory
    }
    static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private var cacheURL: URL { directory.appendingPathComponent(userID.map(String.init) ?? "public").appendingPathExtension("json") }
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        if !restored || userID != session?.profile.userID || credential != session?.credential {
            generation = UUID()
            let oldRefresh = refreshTask; refreshTask = nil; oldRefresh?.cancel()
            let oldDetails = Array(detailTasks.values); detailTasks = [:]
            oldDetails.forEach { $0.cancel() }
            let oldArtwork = Array(artworkTasks.values); artworkTasks = [:]
            oldArtwork.forEach { $0.cancel() }
            userID = session?.profile.userID; credential = session?.credential
            cache = Cache(); recommendations = []; daily = nil
            recommendationsError = nil; dailyError = nil; onChange?()
            let revision = generation
            await oldRefresh?.value
            for task in oldDetails { _ = await task.result }
            for task in oldArtwork { await task.value }
            guard revision == generation else { return }
            let url = cacheURL
            let loaded = await Task.detached { try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: url)) }.value
            guard revision == generation else { return }
            cache = loaded ?? Cache(); restored = true
            recommendations = cache.recommendations
            daily = userID == nil ? nil : cache.snapshots[Self.day()]
            onChange?()
            preloadArtwork(recommendations.compactMap(\.artworkURL) + (daily?.songs.compactMap(\.artworkURL) ?? []))
        }
        if refresh { await self.refresh() }
    }
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let revision = generation
        let task = Task { [self] in
            do {
                let items = try await client.homeRecommendations(credential: credential)
                try Task.checkCancellation()
                guard generation == revision else { return }
                recommendations = items; cache.recommendations = items; recommendationsError = nil; save(); onChange?()
                preloadArtwork(items.compactMap(\.artworkURL))
            } catch is CancellationError {} catch { if generation == revision { recommendationsError = error.localizedDescription; onChange?() } }
            if let credential, generation == revision, !Task.isCancelled {
                do {
                    let date = Self.day()
                    let songs = try await client.dailyRecommendations(credential: credential)
                    try Task.checkCancellation()
                    guard generation == revision else { return }
                    let previous = cache.snapshots[date]
                    let snapshot = NeteaseDailySnapshot(date: date, songs: songs, id: previous?.songs.map(\.id) == songs.map(\.id) ? previous!.id : UUID().uuidString)
                    cache.snapshots[snapshot.id] = snapshot
                    daily = snapshot; cache.snapshots[date] = snapshot; dailyError = nil; save(); onChange?()
                    preloadArtwork(songs.compactMap(\.artworkURL))
                } catch is CancellationError {} catch { if generation == revision { dailyError = error.localizedDescription; onChange?() } }
            }
            if revision == generation { refreshTask = nil }
        }
        refreshTask = task
        await task.value
    }
    var cachedSongs: [NeteaseMusicSong] {
        guard userID != nil else { return [] }
        let songs = cache.details.values.flatMap(\.songs) + cache.snapshots.values.flatMap(\.songs)
        return Array(Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }
    func dailySnapshot(id: String) -> NeteaseDailySnapshot? { cache.snapshots[id] }
    func dailySnapshot(date: String) -> NeteaseDailySnapshot? { cache.snapshots[date] }
    func cachedDetail(id: Int64) -> NeteasePlaylistDetail? { cache.details[id] }
    func detail(id: Int64) async throws -> NeteasePlaylistDetail {
        if let task = detailTasks[id] {
            let revision = generation
            let value = try await task.value
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            return value
        }
        let revision = generation
        let credential = credential
        let task = Task { [client] in try await client.detail(id: id, credential: credential) }
        detailTasks[id] = task
        defer { if generation == revision { detailTasks[id] = nil } }
        do {
            let value = try await task.value
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            cache.details[id] = value; save(); onChange?()
            preloadArtwork([value.playlist.artworkURL].compactMap { $0 } + value.songs.compactMap(\.artworkURL))
            return value
        } catch {
            guard generation == revision, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }
    private var artworkDirectory: URL { directory.appendingPathComponent(userID.map(String.init) ?? "public", isDirectory: true) }
    func cachedArtworkURL(remote: URL) -> URL? {
        guard let filename = cache.artworkFiles?[remote.absoluteString] else { return nil }
        let url = artworkDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private func preloadArtwork(_ urls: [URL]) {
        let revision = generation
        let destination = artworkDirectory
        for remote in Set(urls) where remote.scheme == "https" && cachedArtworkURL(remote: remote) == nil && artworkTasks[remote] == nil {
            artworkTasks[remote] = Task { [self] in
                defer { if generation == revision { artworkTasks[remote] = nil } }
                do {
                    let (data, response) = try await artworkSession.data(from: remote)
                    try Task.checkCancellation()
                    guard generation == revision, let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode), !data.isEmpty else { return }
                    let filename = UUID().uuidString
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try data.write(to: destination.appendingPathComponent(filename), options: .atomic)
                    if cache.artworkFiles == nil { cache.artworkFiles = [:] }
                    cache.artworkFiles?[remote.absoluteString] = filename
                    save(); onChange?()
                } catch { }
            }
        }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch { /* Cached content remains available for this session. */ }
    }
}
