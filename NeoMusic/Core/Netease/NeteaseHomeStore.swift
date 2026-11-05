import Foundation
import Observation

@MainActor @Observable final class NeteaseHomeStore {
    private(set) var userID: Int64?
    private(set) var recommendations: [NeteaseMusicPlaylist] = []
    private(set) var feed: NeteaseHomeFeed?
    private(set) var feedError: String?
    private(set) var charts: NeteaseHomeFeed.Block?
    private(set) var followedReleases: NeteaseHomeFeed.Block?
    private(set) var chartsError: String?
    private(set) var followedReleasesError: String?
    private(set) var likedRecommendations: NeteaseHomeFeed.Block?
    private(set) var newSongs: NeteaseHomeFeed.Block?
    private(set) var likedRecommendationsError: String?
    private(set) var newSongsError: String?
    private(set) var quickActionStates: [NeteaseHomeQuickAction: NeteaseHomeQuickActionState] = [:]
    var displayFeedBlocks: [NeteaseHomeFeed.Block] {
        let playlistFallback = Self.block(code: "NEOMUSIC_RECOMMENDED_PLAYLISTS", title: "推荐歌单", resources: recommendations.map {
            .init(type: "list", id: $0.id, title: $0.title, artist: $0.creator, image: $0.artworkURL?.absoluteString)
        })
        let candidates = (feed?.blocks ?? []) + [likedRecommendations, playlistFallback, charts, followedReleases, newSongs].compactMap { $0 }
        var categories: [NeteaseHomeCategory: NeteaseHomeFeed.Block] = [:]
        for block in candidates where block.hasDisplayableResources {
            guard let category = block.category, categories[category] == nil else { continue }
            categories[category] = block
        }
        return NeteaseHomeCategory.allCases.compactMap { categories[$0] }
    }
    private(set) var daily: NeteaseDailySnapshot?
    private(set) var recommendationsError: String?
    private(set) var dailyError: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onDetailChange: ((Int64) -> Void)?
    @ObservationIgnored var onArtworkChange: ((Set<URL>) -> Void)?
    var sessionRevision: UUID { generation }
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var refreshIsForced = false
    @ObservationIgnored private var likedTask: Task<Void, Never>?
    @ObservationIgnored private var likedTaskID: UUID?
    @ObservationIgnored private var likedTaskSeedID: Int64?
    @ObservationIgnored private var likedPlaylistID: Int64?
    @ObservationIgnored private var likedSongIDs: Set<Int64> = []
    @ObservationIgnored private var likedContextReceived = false
    @ObservationIgnored private var likedSeedID: Int64?
    @ObservationIgnored private var likedSongs: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var likedCache: LikedCache?
    @ObservationIgnored private var quickActionTasks: [NeteaseHomeQuickAction: Task<NeteaseHomeQuickActionResult, Error>] = [:]
    @ObservationIgnored private var actionSongs: [NeteaseMusicSong] = []
    @ObservationIgnored private var roamingTask: Task<RoamingCache, Error>?
    @ObservationIgnored private var roamingCache: RoamingCache?
    private struct RoamingCache: Codable, Sendable {
        let id: UUID
        let songs: [NeteaseMusicSong]
        let date: Date
        var consumed = false
    }
    private struct LikedCache: Codable, Sendable {
        let seedID: Int64
        let block: NeteaseHomeFeed.Block
    }
    @ObservationIgnored private var detailTasks: [Int64: Task<NeteasePlaylistDetail, Error>] = [:]
    @ObservationIgnored private var legacyMigration: Task<Cache?, Never>?
    @ObservationIgnored private var legacyMigrationChecked = false
    @ObservationIgnored private var artworkTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var artworkEvictionObserver: NSObjectProtocol?
    @ObservationIgnored private let artworkCache: NeteaseArtworkCache
    @ObservationIgnored private let pageCache: NeteasePageCache
    @ObservationIgnored private var cache = Cache()
    @ObservationIgnored private var restored = false
    @ObservationIgnored private let cacheIO = NeteaseCacheIO()
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveIDs: [String: UUID] = [:]
    @ObservationIgnored private var refreshedDetails: [Int64: Date] = [:]
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var songCatalog: [NeteaseMusicSong] = []
    private struct Cache: Codable, Sendable {
        var recommendations: [NeteaseMusicPlaylist] = []
        var snapshots: [String: NeteaseDailySnapshot] = [:]
        var details: [Int64: NeteasePlaylistDetail] = [:]
        var artworkFiles: [String: String]? = nil
    }
    private struct StartupCache: Decodable, Sendable {
        let recommendations: [NeteaseMusicPlaylist]
        let daily: NeteaseDailySnapshot?
        let artworkFiles: [String: String]?
        private enum CodingKeys: String, CodingKey { case recommendations, snapshots, artworkFiles }
        private struct SnapshotKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            recommendations = try values.decodeIfPresent([NeteaseMusicPlaylist].self, forKey: .recommendations) ?? []
            artworkFiles = try values.decodeIfPresent([String: String].self, forKey: .artworkFiles)
            let snapshots = try values.nestedContainer(keyedBy: SnapshotKey.self, forKey: .snapshots)
            daily = try snapshots.decodeIfPresent(NeteaseDailySnapshot.self, forKey: SnapshotKey(stringValue: NeteaseHomeStore.day()))
        }
    }
    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL = URL.applicationSupportDirectory.appendingPathComponent("NeteaseHome"),
         artworkSession: URLSession? = nil, artworkCache: NeteaseArtworkCache? = nil) {
        self.client = client; self.directory = directory
        pageCache = NeteasePageCache(directory: directory)
        self.artworkCache = artworkCache ?? artworkSession.map { NeteaseArtworkCache(directory: directory.appendingPathComponent("Artwork"), session: $0) } ?? .shared
        artworkEvictionObserver = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork, object: self.artworkCache, queue: .main) { [weak self] note in
            guard let event = NeteaseArtworkCache.eviction(in: note) else { return }
            MainActor.assumeIsolated {
                guard let self, self.restored, event.scope == self.scope else { return }
                if !event.urls.isEmpty { self.onArtworkChange?(event.urls) }
            }
        }
    }
    isolated deinit {
        if let artworkEvictionObserver { NotificationCenter.default.removeObserver(artworkEvictionObserver) }
    }
    nonisolated static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private var scope: String { userID.map(String.init) ?? "public" }
    private var cacheURL: URL { directory.appendingPathComponent(userID.map(String.init) ?? "public").appendingPathExtension("json") }
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        if !restored || userID != session?.profile.userID || credential != session?.credential {
            generation = UUID()
            let oldRefresh = refreshTask; refreshTask = nil; refreshID = nil; oldRefresh?.cancel()
            let oldLiked = likedTask; likedTask = nil; likedTaskID = nil; likedTaskSeedID = nil; oldLiked?.cancel()
            let oldActions = Array(quickActionTasks.values); quickActionTasks = [:]
            oldActions.forEach { $0.cancel() }
            let oldRoaming = roamingTask; roamingTask = nil; oldRoaming?.cancel(); roamingCache = nil
            quickActionStates = [:]; likedContextReceived = false; likedPlaylistID = nil; likedSongIDs = []; likedSeedID = nil; likedSongs = [:]; likedCache = nil; actionSongs = []
            let oldDetails = Array(detailTasks.values); detailTasks = [:]
            oldDetails.forEach { $0.cancel() }
            let oldMigration = legacyMigration; legacyMigration = nil; oldMigration?.cancel()
            legacyMigrationChecked = false
            let oldArtwork = Array(artworkTasks.values); artworkTasks = [:]
            oldArtwork.forEach { $0.cancel() }
            let oldSaves = Array(saveTasks.values); saveTasks = [:]; saveIDs = [:]
            oldSaves.forEach { $0.cancel() }
            userID = nil; credential = nil; restored = false
            cache = Cache(); recommendations = []; daily = nil; songCatalog = []; feed = nil; feedError = nil
            charts = nil; followedReleases = nil; chartsError = nil; followedReleasesError = nil
            likedRecommendations = nil; newSongs = nil; likedRecommendationsError = nil; newSongsError = nil
            refreshedDetails = [:]; lastRefresh = nil
            recommendationsError = nil; dailyError = nil; onChange?()
            let revision = generation
            await oldRefresh?.value
            await oldLiked?.value
            for task in oldActions { _ = await task.result }
            _ = await oldRoaming?.result
            for task in oldDetails { _ = await task.result }
            _ = await oldMigration?.value
            for task in oldArtwork { await task.value }
            for task in oldSaves { await task.value }
            guard revision == generation, !Task.isCancelled else { return }
            userID = session?.profile.userID; credential = session?.credential
            let loaded = await restoreStartupCache()
            guard revision == generation, !Task.isCancelled else { return }
            cache = loaded; restored = true
            let loadedFeed = try? await pageCache.load(NeteaseHomeFeed.self, scope: scope, key: "feed")
            guard revision == generation, !Task.isCancelled else { return }
            feed = loadedFeed
            let loadedCharts = try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-charts")
            let loadedFollowed = userID == nil ? nil : try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-followed")
            guard revision == generation, !Task.isCancelled else { return }
            charts = loadedCharts; followedReleases = loadedFollowed
            let loadedLiked = userID == nil ? nil : try? await pageCache.load(LikedCache.self, scope: scope, key: "home-liked")
            let loadedNewSongs = try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-new-songs")
            let loadedRoaming = userID == nil ? nil : try? await pageCache.load(RoamingCache.self, scope: scope, key: "home-roaming")
            guard revision == generation, !Task.isCancelled else { return }
            likedCache = loadedLiked; likedRecommendations = loadedLiked?.block; newSongs = loadedNewSongs
            roamingCache = loadedRoaming
            rebuildSongCatalog()
            recommendations = cache.recommendations
            daily = userID == nil ? nil : cache.snapshots[Self.day()]
            for id in Set([hotChart?.numericID, radarPlaylist?.numericID].compactMap { $0 }) {
                _ = try? await restoreCachedDetail(id: id)
                guard revision == generation, !Task.isCancelled else { return }
            }
            onChange?()
            requestArtwork(recommendations.prefix(6).compactMap(\.artworkURL) + (daily?.songs.prefix(8).compactMap(\.artworkURL) ?? []))
        }
        if refresh { await self.refresh(force: false) }
    }
    func refresh(force: Bool = true) async {
        let interval = PerformanceDiagnostics.begin("HomeRefresh")
        defer { PerformanceDiagnostics.end("HomeRefresh", interval) }
        guard !Task.isCancelled else { return }
        let revision = generation
        if let pending = refreshTask {
            if !force || refreshIsForced {
                await pending.value
                return
            }
            pending.cancel()
            await pending.value
            guard generation == revision, !Task.isCancelled else { return }
            if let replacement = refreshTask { await replacement.value; return }
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300, userID == nil || daily?.date == Self.day() { return }
        let credential = credential, id = UUID()
        refreshID = id; refreshIsForced = force
        let task = Task { [self] in
            async let daily: Void = refreshDaily(credential: credential, revision: revision)
            async let feed: Void = refreshFeed(credential: credential, revision: revision, force: force)
            async let supplemental: Void = refreshSupplemental(credential: credential, revision: revision)
            async let roaming: Void = refreshRoaming(force: force)
            _ = await (daily, feed, supplemental, roaming)
            guard revision == generation, !Task.isCancelled else {
                if refreshID == id { refreshTask = nil; refreshID = nil }
                return
            }
            async let recommendations: Void = refreshRecommendations(credential: credential, revision: revision)
            async let newSongs: Void = refreshNewSongs(credential: credential, revision: revision)
            async let covers: Void = refreshQuickActionCovers(force: force)
            let liked = scheduleLikedRecommendations(force: true)
            await withTaskCancellationHandler { await liked?.value } onCancel: { liked?.cancel() }
            _ = await (newSongs, recommendations, covers)
            if revision == generation, refreshID == id {
                refreshTask = nil; refreshID = nil
                if !Task.isCancelled, recommendationsError == nil, dailyError == nil, feedError == nil,
                   chartsError == nil, followedReleasesError == nil, likedRecommendationsError == nil, newSongsError == nil { lastRefresh = Date() }
            }
        }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func updateLikedSongs(playlistID: Int64?, songs: [NeteaseMusicSong], likedAt: [Int64: Date], likedIDs: Set<Int64>, orderedLikedIDs: [Int64] = []) {
        guard userID != nil else { return }
        likedPlaylistID = playlistID
        likedSongs = Dictionary(songs.filter { $0.id > 0 && !$0.unavailable }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unavailable = Set(songs.filter(\.unavailable).map(\.id))
        let availableIDs = likedIDs.filter { $0 > 0 && !unavailable.contains($0) }
        let datedSeed = likedAt.filter { availableIDs.contains($0.key) }.max { $0.value < $1.value }?.key
        let seedID = datedSeed ?? orderedLikedIDs.first(where: { availableIDs.contains($0) })
            ?? likedSeedID.flatMap { availableIDs.contains($0) ? $0 : nil }
        let changed = !likedContextReceived || seedID != likedSeedID || likedSongIDs != availableIDs
        likedSongIDs = availableIDs
        guard changed else { return }
        likedContextReceived = true; likedSeedID = seedID
        likedTask?.cancel()
        if likedCache?.seedID != seedID { likedRecommendations = nil; likedRecommendationsError = nil }
        _ = scheduleLikedRecommendations(force: false)
    }

    @discardableResult private func scheduleLikedRecommendations(force: Bool) -> Task<Void, Never>? {
        guard !Task.isCancelled, let credential, !likedSongIDs.isEmpty else {
            likedTask?.cancel()
            if likedContextReceived, likedSongIDs.isEmpty {
                likedRecommendations = nil; likedCache = nil; likedRecommendationsError = nil
                removeCachedPage(key: "home-liked"); rebuildSongCatalog(); onChange?()
            }
            return nil
        }
        guard !(feed?.blocks.contains { $0.category == .likedSongs && $0.hasDisplayableResources } ?? false) else {
            likedRecommendationsError = nil
            return nil
        }
        let requestedSeed = likedSeedID
        if let likedTask, !likedTask.isCancelled, likedTaskSeedID == requestedSeed { return likedTask }
        if !force, likedCache?.seedID == requestedSeed, likedRecommendations != nil { return nil }
        let previous = likedTask
        previous?.cancel()
        let revision = generation, id = UUID()
        likedTaskID = id; likedTaskSeedID = requestedSeed
        let task = Task { [self] in
            await previous?.value
            defer { if likedTaskID == id { likedTask = nil; likedTaskID = nil; likedTaskSeedID = nil } }
            do {
                try Task.checkCancellation()
                let seed = try await loadLikedSeed(credential: credential)
                try Task.checkCancellation()
                guard generation == revision, likedTaskID == id, likedSongIDs.contains(seed.id) else { return }
                likedSeedID = seed.id; likedSongs[seed.id] = seed; likedTaskSeedID = seed.id
                let songs = try await client.similarSongs(id: seed.id, credential: credential)
                try Task.checkCancellation()
                guard generation == revision, likedSeedID == seed.id, likedTaskID == id else { return }
                let block = Self.block(code: "NEOMUSIC_LIKED_SONGS", title: "根据你喜欢的《\(seed.title)》推荐",
                                       resources: songs.filter { $0.id > 0 && !$0.unavailable }.map { .init(song: $0) })
                let value = LikedCache(seedID: seed.id, block: block)
                likedCache = value; likedRecommendations = block; likedRecommendationsError = nil
                save(value, key: "home-liked"); rebuildSongCatalog(); onChange?()
            } catch is CancellationError {} catch {
                if generation == revision, likedTaskID == id, !Task.isCancelled {
                    likedRecommendationsError = error.localizedDescription; onChange?()
                }
            }
        }
        likedTask = task
        return task
    }

    private func loadLikedSeed(credential: NeteaseCredential) async throws -> NeteaseMusicSong {
        var seedID = likedSeedID
        if seedID == nil {
            guard !likedSongIDs.isEmpty else { throw NeteaseHomeActionError.noLikedSongs }
            guard let playlistID = likedPlaylistID else { throw NeteaseHomeActionError.noFavoritePlaylist }
            let detail = try await client.detail(id: playlistID, credential: credential, trackLimit: 1)
            seedID = detail.addedTimes.filter { likedSongIDs.contains($0.key) }.max { $0.value < $1.value }?.key
                ?? detail.orderedTrackIDs.first(where: { likedSongIDs.contains($0) })
            if let seed = detail.songs.first(where: { $0.id == seedID && !$0.unavailable }) { return seed }
        }
        guard let seedID else { throw NeteaseHomeActionError.noLikedSongs }
        if let cached = likedSongs[seedID] { return cached }
        guard let seed = try await client.songs(ids: [seedID], credential: credential).first(where: { $0.id == seedID && !$0.unavailable }) else {
            throw NeteaseHomeActionError.noLikedSongs
        }
        return seed
    }

    private func refreshNewSongs(credential: NeteaseCredential?, revision: UUID) async {
        guard !(feed?.blocks.contains { $0.category == .newSongs && $0.hasDisplayableResources } ?? false) else {
            newSongsError = nil
            return
        }
        do {
            let songs = try await client.newSongs(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            let value = Self.block(code: "NEOMUSIC_NEW_SONGS", title: "新歌速递", resources: songs.filter { $0.id > 0 && !$0.unavailable }.map { .init(song: $0) })
            newSongs = value; newSongsError = nil; save(value, key: "home-new-songs"); rebuildSongCatalog(); onChange?()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { newSongsError = error.localizedDescription; onChange?() }
        }
    }

    private static func block(code: String, title: String, resources: [NeteaseHomeFeed.Resource]) -> NeteaseHomeFeed.Block {
        .init(blockCode: code, uiElement: .init(mainTitle: nil, subTitle: .init(title: title), image: nil),
              creatives: [.init(creativeId: code, creativeType: nil, uiElement: nil, resources: resources)])
    }

    private var hotChart: NeteaseHomeFeed.Resource? {
        (charts?.resources ?? []).first { ["热歌榜", "云音乐热歌榜"].contains($0.title) && ["list", "playlist"].contains($0.resourceType?.lowercased() ?? "") }
    }
    private var radarPlaylist: NeteaseHomeFeed.Resource? {
        displayFeedBlocks.first { $0.category == .radarPlaylists }?.resources.first { $0.isDisplayable && ["list", "playlist"].contains($0.resourceType?.lowercased() ?? "") }
    }
    func quickActionArtwork(_ action: NeteaseHomeQuickAction) -> URL? {
        switch action {
        case .dailySongs: daily?.songs.first?.artworkURL
        case .hotSongs: hotChart?.numericID.flatMap(firstTrackArtwork)
        case .heartMode: likedSeedID.flatMap { likedSongs[$0]?.artworkURL }
        case .privateRadar: radarPlaylist?.numericID.flatMap(firstTrackArtwork)
        case .privateRoaming: roamingCache?.songs.first?.artworkURL
        case .similarSongs: nil
        }
    }

    private func firstTrackArtwork(_ id: Int64) -> URL? {
        guard let detail = cache.details[id], let firstID = detail.orderedTrackIDs.first else { return nil }
        return detail.songs.first(where: { $0.id == firstID })?.artworkURL
    }

    private func refreshQuickActionCovers(force: Bool) async {
        let hotID = hotChart?.numericID, radarID = radarPlaylist?.numericID
        async let hot: Void = refreshFirstTrackCover(id: hotID, force: force)
        async let radar: Void = refreshFirstTrackCover(id: radarID == hotID ? nil : radarID, force: force)
        _ = await (hot, radar)
    }

    private func refreshFirstTrackCover(id: Int64?, force: Bool) async {
        guard let id else { return }
        let revision = generation, credential = credential
        do {
            _ = try await restoreCachedDetail(id: id)
            if try await joinDetail(id) == nil {
                if !force, cache.details[id] != nil, let date = refreshedDetails[id], Date().timeIntervalSince(date) < 300 { return }
                let previous = cache.details[id]
                _ = try await fetchDetail(id: id, refresh: true, preloadArtwork: false) { [client] in
                    let first = try await client.detail(id: id, credential: credential, trackLimit: 1)
                    guard let previous, previous.orderedTrackIDs == first.orderedTrackIDs, previous.nextOffset > first.nextOffset else { return first }
                    // The cover refresh must not discard pages already loaded for this playlist.
                    let replacement = Dictionary(first.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    return NeteasePlaylistDetail(playlist: first.playlist,
                        songs: previous.songs.map { replacement[$0.id] ?? $0 }, addedTimes: first.addedTimes,
                        trackIDs: first.orderedTrackIDs, loadedTrackCount: previous.nextOffset)
                }
            }
            try Task.checkCancellation()
            guard revision == generation else { return }
            onChange?()
            requestArtwork([firstTrackArtwork(id)].compactMap { $0 })
        } catch { /* Existing first-track artwork survives a failed refresh of the same playlist. */ }
    }

    private func refreshRoaming(force: Bool) async {
        guard credential != nil else { return }
        if !force, let roamingCache, Date().timeIntervalSince(roamingCache.date) < 300 { return }
        _ = try? await prepareRoaming(refresh: true)
    }

    private func prepareRoaming(refresh: Bool = false) async throws -> RoamingCache {
        try Task.checkCancellation()
        if let roamingTask {
            let value = try await roamingTask.value
            try Task.checkCancellation()
            return value
        }
        if !refresh, let roamingCache, !roamingCache.consumed { return roamingCache }
        guard let credential else { throw NeteaseHomeActionError.loginRequired }
        let revision = generation
        quickActionStates[.privateRoaming] = .loading; onChange?()
        let task = Task<RoamingCache, Error> { [self] in
            defer { if generation == revision { roamingTask = nil } }
            do {
                let songs = try await client.personalFM(credential: credential, mode: "EXPLORE", limit: 30)
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                var seen = Set<Int64>()
                let valid = songs.filter { $0.id > 0 && !$0.unavailable && seen.insert($0.id).inserted }
                guard !valid.isEmpty else { throw NeteaseHomeActionError.emptySongs }
                let value = RoamingCache(id: UUID(), songs: valid, date: Date())
                roamingCache = value
                save(value, key: "home-roaming")
                rebuildSongCatalog()
                quickActionStates[.privateRoaming] = nil; onChange?()
                requestArtwork([valid.first?.artworkURL].compactMap { $0 })
                return value
            } catch {
                if generation == revision {
                    quickActionStates[.privateRoaming] = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
                    onChange?()
                }
                throw error
            }
        }
        roamingTask = task
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    /// A cancelled queue-replacement confirmation leaves this batch available.
    func consumeRoamingBatch(id: UUID) {
        guard var value = roamingCache, value.id == id, !value.consumed else { return }
        value.consumed = true
        roamingCache = value
        save(value, key: "home-roaming")
    }
    func performQuickAction(_ action: NeteaseHomeQuickAction, currentSongID: Int64? = nil) async throws -> NeteaseHomeQuickActionResult {
        try Task.checkCancellation()
        if let task = quickActionTasks[action] { return try await task.value }
        let revision = generation, credential = credential
        quickActionStates[action] = .loading; onChange?()
        let task = Task<NeteaseHomeQuickActionResult, Error> { [self] in
            defer { if generation == revision { quickActionTasks[action] = nil } }
            do {
                if action != .hotSongs, credential == nil { throw NeteaseHomeActionError.loginRequired }
                let result: NeteaseHomeQuickActionResult
                switch action {
                case .dailySongs:
                    if daily?.date != Self.day() || daily?.songs.isEmpty != false {
                        await refreshDaily(credential: credential, revision: revision)
                    }
                    try Task.checkCancellation()
                    guard let daily, !daily.songs.isEmpty else {
                        if let dailyError { throw NeteaseHomeActionError.requestFailed(dailyError) }
                        throw NeteaseHomeActionError.emptySongs
                    }
                    result = .daily(daily)
                case .hotSongs:
                    if hotChart == nil {
                        let value = try await client.homeCharts(credential: credential)
                        try Task.checkCancellation()
                        guard generation == revision else { throw CancellationError() }
                        charts = value; chartsError = nil; save(value, key: "home-charts")
                    }
                    guard let resource = hotChart else { throw NeteaseHomeActionError.noHotChart }
                    result = .playlist(Self.playlist(resource))
                case .privateRadar:
                    if radarPlaylist == nil { await refresh(force: true) }
                    try Task.checkCancellation()
                    guard let resource = radarPlaylist else {
                        if let feedError { throw NeteaseHomeActionError.requestFailed(feedError) }
                        throw NeteaseHomeActionError.noRadar
                    }
                    result = .playlist(Self.playlist(resource))
                case .heartMode:
                    guard let playlistID = likedPlaylistID, playlistID > 0 else { throw NeteaseHomeActionError.noFavoritePlaylist }
                    let seed = try await loadLikedSeed(credential: credential!)
                    try Task.checkCancellation()
                    guard generation == revision else { throw CancellationError() }
                    likedSeedID = seed.id; likedSongs[seed.id] = seed
                    result = .songs(try await client.intelligenceModeSongs(playlistID: playlistID, seedSongID: seed.id, credential: credential!))
                case .privateRoaming:
                    let batch = try await prepareRoaming()
                    result = .roaming(id: batch.id, songs: batch.songs)
                case .similarSongs:
                    guard let currentSongID, currentSongID > 0 else { throw NeteaseHomeActionError.noCurrentOnlineSong }
                    result = .songs(try await client.similarSongs(id: currentSongID, credential: credential))
                }
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                let playable: NeteaseHomeQuickActionResult
                if case let .songs(songs) = result {
                    var seen = Set<Int64>()
                    let valid = songs.filter { $0.id > 0 && !$0.unavailable && seen.insert($0.id).inserted }
                    guard !valid.isEmpty else { throw NeteaseHomeActionError.emptySongs }
                    actionSongs = valid; rebuildSongCatalog(); playable = .songs(valid)
                } else { playable = result }
                quickActionStates[action] = nil; onChange?()
                return playable
            } catch {
                if generation == revision {
                    quickActionStates[action] = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
                    onChange?()
                }
                throw error
            }
        }
        quickActionTasks[action] = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func playlist(_ resource: NeteaseHomeFeed.Resource) -> NeteaseMusicPlaylist {
        .init(id: resource.numericID!, title: resource.title, creator: resource.uiElement?.subTitle?.title ?? "",
              creatorID: 0, artworkURL: resource.artworkURL, trackCount: 0, isFavorites: false)
    }

    private func refreshSupplemental(credential: NeteaseCredential?, revision: UUID) async {
        async let charts: Void = refreshCharts(credential: credential, revision: revision)
        async let followed: Void = refreshFollowed(credential: credential, revision: revision)
        _ = await (charts, followed)
    }
    private func refreshCharts(credential: NeteaseCredential?, revision: UUID) async {
        do {
            let value = try await client.homeCharts(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            charts = value; chartsError = nil; save(value, key: "home-charts"); onChange?()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { chartsError = error.localizedDescription; onChange?() }
        }
    }
    private func refreshFollowed(credential: NeteaseCredential?, revision: UUID) async {
        guard let credential else { return }
        do {
            let value = try await client.followedArtistReleases(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            followedReleases = value; followedReleasesError = nil; save(value, key: "home-followed"); onChange?()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { followedReleasesError = error.localizedDescription; onChange?() }
        }
    }

    private func refreshFeed(credential: NeteaseCredential?, revision: UUID, force: Bool) async {
        do {
            var value = try await client.homeFeed(credential: credential, refresh: force)
            var cursors = Set<String>()
            var resources = Set(value.blocks.flatMap { $0.resources.map(\.id) })
            while value.hasMore == true, let cursor = value.cursor, !cursor.isEmpty, cursors.insert(cursor).inserted {
                try Task.checkCancellation()
                let page = try await client.homeFeed(credential: credential, cursor: cursor)
                try Task.checkCancellation()
                let additional = Set(page.blocks.flatMap { $0.resources.map(\.id) }).subtracting(resources)
                value = value.merging(page)
                if additional.isEmpty { break }
                resources.formUnion(additional)
            }
            try Task.checkCancellation()
            guard generation == revision else { return }
            value = .init(blocks: value.blocks, hasMore: false, cursor: nil)
            feed = value; feedError = nil
            rebuildSongCatalog()
            save(value, key: "feed")
            onChange?()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { feedError = error.localizedDescription; onChange?() }
        }
    }

    private func refreshRecommendations(credential: NeteaseCredential?, revision: UUID) async {
        guard !(feed?.blocks.contains { $0.category == .recommendedPlaylists && $0.hasDisplayableResources } ?? false) else {
            recommendationsError = nil
            return
        }
        do {
            try Task.checkCancellation()
            let items = try await client.homeRecommendations(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            recommendations = items; cache.recommendations = items; recommendationsError = nil; save(items, key: "recommendations")
            PerformanceDiagnostics.event("NetworkContentReady"); onChange?()
            requestArtwork(items.prefix(6).compactMap(\.artworkURL))
        } catch is CancellationError {} catch { if generation == revision, !Task.isCancelled { recommendationsError = error.localizedDescription; onChange?() } }
    }
    private func refreshDaily(credential: NeteaseCredential?, revision: UUID) async {
        guard let credential else { return }
        do {
            try Task.checkCancellation()
            let date = Self.day()
            let songs = try await client.dailyRecommendations(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            let previous = cache.snapshots[date]
            let snapshot = NeteaseDailySnapshot(date: date, songs: songs, id: previous?.songs.map(\.id) == songs.map(\.id) ? previous!.id : UUID().uuidString)
            // History references this immutable ID after the bounded page cache is evicted.
            try await cacheIO.save(snapshot, to: dailyArchiveURL(snapshot.id))
            try Task.checkCancellation()
            guard generation == revision else { return }
            cache.snapshots[snapshot.id] = snapshot
            daily = snapshot; cache.snapshots[date] = snapshot; dailyError = nil
            rebuildSongCatalog()
            save(snapshot, key: "daily:" + snapshot.id)
            save(snapshot, key: "daily:" + date)
            PerformanceDiagnostics.event("NetworkContentReady"); onChange?()
            requestArtwork(songs.prefix(8).compactMap(\.artworkURL))
        } catch is CancellationError {} catch { if generation == revision, !Task.isCancelled { dailyError = error.localizedDescription; onChange?() } }
    }
    var cachedSongs: [NeteaseMusicSong] { userID == nil ? [] : songCatalog }
    /// Older saved queues contain only IDs. Their missing metadata is recovered after the first screen.
    func restoreCachedSongs(ids: Set<Int64>) async -> [NeteaseMusicSong] {
        guard userID != nil, !ids.isEmpty, !Task.isCancelled else { return [] }
        let revision = generation, owner = scope
        let loaded = cachedSongs.filter { ids.contains($0.id) }
        let missing = ids.subtracting(loaded.map(\.id))
        guard !missing.isEmpty else { return loaded }
        let recovered = (try? await Self.readCachedSongs(ids: missing, scope: owner, directory: directory,
                                                       pageCache: pageCache, cacheIO: cacheIO)) ?? []
        guard revision == generation, !Task.isCancelled else { return [] }
        return loaded + recovered
    }
    @concurrent private static func readCachedSongs(ids: Set<Int64>, scope: String, directory: URL,
                                                   pageCache: NeteasePageCache, cacheIO: NeteaseCacheIO) async throws -> [NeteaseMusicSong] {
        var missing = ids
        var found: [NeteaseMusicSong] = []
        func collect(_ songs: [NeteaseMusicSong]) {
            for song in songs where missing.remove(song.id) != nil { found.append(song) }
        }
        let playlists = (try? await pageCache.entries(NeteasePlaylistDetail.self, scope: scope, prefix: "playlist:")) ?? [:]
        for detail in playlists.values {
            try Task.checkCancellation()
            collect(detail.songs)
            if missing.isEmpty { return found }
        }
        let snapshots = (try? await pageCache.entries(NeteaseDailySnapshot.self, scope: scope, prefix: "daily:")) ?? [:]
        for snapshot in snapshots.values {
            try Task.checkCancellation()
            collect(snapshot.songs)
            if missing.isEmpty { return found }
        }
        if let legacy = await cacheIO.load(Cache.self, from: directory.appendingPathComponent(scope).appendingPathExtension("json")) {
            for detail in legacy.details.values {
                try Task.checkCancellation()
                collect(detail.songs)
                if missing.isEmpty { return found }
            }
            for snapshot in legacy.snapshots.values {
                try Task.checkCancellation()
                collect(snapshot.songs)
                if missing.isEmpty { return found }
            }
        }
        let history = directory.appendingPathComponent("DailyHistory", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == "json" {
            try Task.checkCancellation()
            if let snapshot = await cacheIO.load(NeteaseDailySnapshot.self, from: file) { collect(snapshot.songs) }
            if missing.isEmpty { return found }
        }
        return found
    }
    private func rebuildSongCatalog() {
        let songs = cache.details.values.flatMap(\.songs) + cache.snapshots.values.flatMap(\.songs)
            + displayFeedBlocks.flatMap { $0.resources.compactMap(\.song) } + actionSongs + (roamingCache?.songs ?? [])
        songCatalog = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
    }
    func dailySnapshot(id: String) -> NeteaseDailySnapshot? { cache.snapshots[id] }
    func dailySnapshot(date: String) -> NeteaseDailySnapshot? { cache.snapshots[date] }
    func cachedDetail(id: Int64) -> NeteasePlaylistDetail? { cache.details[id] }
    private func dailyArchiveURL(_ id: String) -> URL {
        directory.appendingPathComponent("DailyHistory", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true).appendingPathComponent(id).appendingPathExtension("json")
    }
    func loadDailySnapshot(id: String) async throws -> NeteaseDailySnapshot? {
        try Task.checkCancellation()
        if let cached = cache.snapshots[id] { return cached }
        let revision = generation, owner = scope, archiveURL = dailyArchiveURL(id)
        var snapshot = try? await pageCache.load(NeteaseDailySnapshot.self, scope: owner, key: "daily:" + id)
        if snapshot == nil { snapshot = await cacheIO.load(NeteaseDailySnapshot.self, from: archiveURL) }
        if snapshot == nil {
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            let legacy = await migrateLegacyCache()
            snapshot = legacy?.snapshots[id]
            if snapshot == nil { snapshot = try? await pageCache.load(NeteaseDailySnapshot.self, scope: owner, key: "daily:" + id) }
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        if let cached = cache.snapshots[id] { return cached }
        guard let snapshot else { return nil }
        cache.snapshots[id] = snapshot
        cache.snapshots[snapshot.id] = snapshot
        rebuildSongCatalog()
        save(snapshot, key: "daily:" + id)
        onChange?()
        return snapshot
    }

    func restoreCachedDetail(id: Int64) async throws -> NeteasePlaylistDetail? {
        try Task.checkCancellation()
        if let cached = cache.details[id] { return cached }
        let revision = generation, owner = scope
        var detail = try? await pageCache.load(NeteasePlaylistDetail.self, scope: owner, key: "playlist:\(id)")
        if detail == nil {
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            let legacy = await migrateLegacyCache()
            detail = legacy?.details[id]
            if detail == nil { detail = try? await pageCache.load(NeteasePlaylistDetail.self, scope: owner, key: "playlist:\(id)") }
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        if let cached = cache.details[id] { return cached }
        guard let detail else { return nil }
        cache.details[id] = detail
        rebuildSongCatalog()
        onDetailChange?(id)
        return detail
    }

    /// Browsing refreshes the displayed page; playback consumes the selected snapshot.
    func detail(id: Int64, force: Bool = false) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        _ = try await restoreCachedDetail(id: id)
        let joined = try await joinDetail(id)
        if let cached = cache.details[id], joined != nil || (!force && refreshedDetails[id].map { Date().timeIntervalSince($0) < 300 } == true) {
            let firstPageCount = min(100, cached.orderedTrackIDs.count)
            if cached.nextOffset >= firstPageCount { return cached }
            let credential = credential
            return try await fetchDetail(id: id, refresh: true) { [client] in
                try await client.loadMore(cached, credential: credential, limit: firstPageCount - cached.nextOffset)
            }
        }
        let limit = max(100, cache.details[id]?.nextOffset ?? 0)
        let credential = credential
        return try await fetchDetail(id: id, refresh: true) { [client] in
            try await client.detail(id: id, credential: credential, trackLimit: limit)
        }
    }

    func loadMoreDetail(id: Int64) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        _ = try await restoreCachedDetail(id: id)
        let previousOffset = cache.details[id]?.nextOffset ?? 0
        if let value = try await joinDetail(id), value.isComplete || value.nextOffset > previousOffset { return value }
        guard let cached = cache.details[id] else { return try await detail(id: id) }
        guard !cached.isComplete else { return cached }
        let credential = credential
        return try await fetchDetail(id: id) { [client] in
            try await client.loadMore(cached, credential: credential)
        }
    }

    func completeDetail(id: Int64) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        _ = try await restoreCachedDetail(id: id)
        if let cached = cache.details[id], cached.isComplete { return cached }
        let revision = generation
        _ = try await joinDetail(id)
        let detail: NeteasePlaylistDetail
        if let cached = cache.details[id] { detail = cached }
        else { detail = try await self.detail(id: id) }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        if detail.isComplete { return detail }
        let credential = credential
        if detailTasks[id] != nil {
            _ = try await joinDetail(id)
            return try await completeDetail(id: id)
        }
        return try await fetchDetail(id: id) { [client] in
            try await client.complete(detail, credential: credential)
        }
    }

    /// Shared requests belong to this session; a disappearing view only cancels its own wait.
    private func joinDetail(_ id: Int64) async throws -> NeteasePlaylistDetail? {
        guard let task = detailTasks[id] else { return nil }
        let revision = generation
        do { return try await existing(task) }
        catch is CancellationError {
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            return nil
        }
    }

    private func existing(_ task: Task<NeteasePlaylistDetail, Error>) async throws -> NeteasePlaylistDetail {
        let revision = generation
        let value = try await task.value
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        return value
    }

    private func fetchDetail(id: Int64, refresh: Bool = false, preloadArtwork: Bool = true,
                             operation: @escaping @MainActor () async throws -> NeteasePlaylistDetail) async throws -> NeteasePlaylistDetail {
        let revision = generation
        let task = Task { [self] in
            defer { if generation == revision { detailTasks[id] = nil } }
            let value: NeteasePlaylistDetail
            do { value = try await operation() }
            catch {
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            cache.details[id] = value
            if refresh { refreshedDetails[id] = Date() }
            rebuildSongCatalog()
            save(value, key: "playlist:\(id)")
            onDetailChange?(id)
            if preloadArtwork { requestArtwork([value.playlist.artworkURL].compactMap { $0 } + value.songs.prefix(8).compactMap(\.artworkURL)) }
            return value
        }
        detailTasks[id] = task
        return try await existing(task)
    }
    private var artworkDirectory: URL { directory.appendingPathComponent(userID.map(String.init) ?? "public", isDirectory: true) }
    func cachedArtworkURL(remote: URL) -> URL? {
        if let file = artworkCache.cachedURL(for: remote, scope: scope) { return file }
        guard let filename = cache.artworkFiles?[remote.absoluteString] else { return nil }
        let url = artworkDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func cachedArtworkFile(_ remote: URL) async -> URL? {
        guard restored, !Task.isCancelled else { return nil }
        if let cached = cachedArtworkURL(remote: remote) { return cached }
        let revision = generation, owner = scope
        let file = await artworkCache.cachedFileURL(for: remote, scope: owner)
        guard restored, generation == revision, scope == owner, !Task.isCancelled else { return nil }
        return file
    }
    func requestArtwork(_ urls: [URL]) {
        guard restored, !Task.isCancelled else { return }
        let revision = generation
        let owner = scope
        var seen = Set<URL>()
        var cached = Set<URL>()
        for remote in urls where seen.insert(remote).inserted && remote.scheme == "https" {
            if cachedArtworkURL(remote: remote) != nil { cached.insert(remote); continue }
            guard artworkTasks[remote] == nil else { continue }
            artworkTasks[remote] = Task { [self] in
                defer {
                    if generation == revision {
                        artworkTasks[remote] = nil
                    }
                }
                do {
                    _ = try await artworkCache.imageURL(for: remote, scope: owner)
                    try Task.checkCancellation()
                    guard generation == revision else { return }
                    PerformanceDiagnostics.event("ArtworkReady")
                    onArtworkChange?([remote])
                } catch { }
            }
        }
        if !cached.isEmpty { onArtworkChange?(cached) }
    }
    func flush() async {
        for task in Array(saveTasks.values) { await task.value }
    }

    private func save<Value: Encodable & Sendable>(_ value: Value, key: String) {
        let owner = scope, revision = generation, previous = saveTasks[key], id = UUID()
        previous?.cancel()
        saveIDs[key] = id
        saveTasks[key] = Task { [weak self, pageCache] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == revision else { return }
            try? await pageCache.save(value, scope: owner, key: key)
            if self?.saveIDs[key] == id { self?.saveTasks[key] = nil; self?.saveIDs[key] = nil }
        }
    }

    private func removeCachedPage(key: String) {
        let owner = scope, revision = generation, previous = saveTasks[key], id = UUID()
        previous?.cancel()
        saveIDs[key] = id
        saveTasks[key] = Task { [weak self, pageCache] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == revision else { return }
            try? await pageCache.remove(scope: owner, key: key)
            if self?.saveIDs[key] == id { self?.saveTasks[key] = nil; self?.saveIDs[key] = nil }
        }
    }

    private func restoreStartupCache() async -> Cache {
        let owner = scope, date = Self.day(), legacyURL = cacheURL, signedIn = userID != nil
        let recommendations = try? await pageCache.load([NeteaseMusicPlaylist].self, scope: owner, key: "recommendations")
        let today = signedIn ? try? await pageCache.load(NeteaseDailySnapshot.self, scope: owner, key: "daily:" + date) : nil
        let artwork = try? await pageCache.load([String: String].self, scope: owner, key: "legacy-artwork")
        let legacy: StartupCache?
        if recommendations == nil || today == nil || artwork == nil {
            legacy = await cacheIO.load(StartupCache.self, from: legacyURL)
        } else { legacy = nil }
        var snapshots: [String: NeteaseDailySnapshot] = [:]
        if signedIn, let snapshot = today ?? legacy?.daily {
            snapshots[date] = snapshot
            snapshots[snapshot.id] = snapshot
        }
        return Cache(recommendations: recommendations ?? legacy?.recommendations ?? [],
                     snapshots: snapshots, artworkFiles: artwork ?? legacy?.artworkFiles)
    }

    /// The former whole-account file is migrated only when a requested page needs it.
    private func migrateLegacyCache() async -> Cache? {
        if let legacyMigration { return await legacyMigration.value }
        guard !legacyMigrationChecked, !Task.isCancelled else { return nil }
        let owner = scope, revision = generation, legacyURL = cacheURL
        let history = directory.appendingPathComponent("DailyHistory", isDirectory: true).appendingPathComponent(owner, isDirectory: true)
        let task = Task<Cache?, Never> { [self] in
            defer { if generation == revision { legacyMigration = nil } }
            let legacy = await cacheIO.load(Cache.self, from: legacyURL)
            guard generation == revision, !Task.isCancelled else { return nil }
            guard let legacy else { legacyMigrationChecked = true; return nil }
            do {
                let snapshots = Dictionary(legacy.snapshots.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for snapshot in snapshots.values {
                    try await cacheIO.save(snapshot, to: history.appendingPathComponent(snapshot.id).appendingPathExtension("json"))
                }
                for (key, snapshot) in legacy.snapshots {
                    if try await pageCache.load(NeteaseDailySnapshot.self, scope: owner, key: "daily:" + key) == nil {
                        try await pageCache.save(snapshot, scope: owner, key: "daily:" + key)
                    }
                }
                for (id, detail) in legacy.details {
                    if try await pageCache.load(NeteasePlaylistDetail.self, scope: owner, key: "playlist:\(id)") == nil {
                        try await pageCache.save(detail, scope: owner, key: "playlist:\(id)")
                    }
                }
                if try await pageCache.load([NeteaseMusicPlaylist].self, scope: owner, key: "recommendations") == nil {
                    try await pageCache.save(legacy.recommendations, scope: owner, key: "recommendations")
                }
                if let artwork = legacy.artworkFiles, !artwork.isEmpty {
                    try await pageCache.save(artwork, scope: owner, key: "legacy-artwork")
                }
                try Task.checkCancellation()
                guard generation == revision else { return nil }
                try await cacheIO.remove(legacyURL)
                guard generation == revision, !Task.isCancelled else { return nil }
                legacyMigrationChecked = true
            } catch { }
            guard generation == revision, !Task.isCancelled else { return nil }
            return legacy
        }
        legacyMigration = task
        return await task.value
    }
}
