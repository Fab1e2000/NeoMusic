import Foundation
import Observation

@MainActor @Observable final class NeteaseHomeStore {
    enum RetrySource: String, CaseIterable, Hashable, Sendable {
        case feed, recommendations, charts, followedReleases, newSongs
    }

    private(set) var userID: Int64?
    private(set) var recommendations: [NeteaseMusicPlaylist] = []
    private(set) var feed: NeteaseHomeFeed?
    private(set) var feedError: String?
    private(set) var charts: NeteaseHomeFeed.Block?
    private(set) var followedReleases: NeteaseHomeFeed.Block?
    private(set) var chartsError: String?
    private(set) var followedReleasesError: String?
    private(set) var newSongs: NeteaseHomeFeed.Block?
    private(set) var newSongsError: String?
    private(set) var refreshingSources: Set<RetrySource> = []
    private(set) var quickActionStates: [NeteaseHomeQuickAction: NeteaseHomeQuickActionState] = [:]
    var displayFeedBlocks: [NeteaseHomeFeed.Block] {
        let playlistFallback = Self.block(code: "NEOMUSIC_RECOMMENDED_PLAYLISTS", title: "推荐歌单", resources: recommendations.map {
            .init(type: "list", id: $0.id, title: $0.title, artist: $0.creator, image: $0.artworkURL?.absoluteString)
        })
        let candidates = (feed?.blocks ?? []) + [playlistFallback, charts, followedReleases, newSongs].compactMap { $0 }
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
    @ObservationIgnored private var sourceTasks: [RetrySource: Task<Void, Never>] = [:]
    @ObservationIgnored private var sourceTaskIDs: [RetrySource: UUID] = [:]
    private var likedPlaylistID: Int64?
    @ObservationIgnored private var likedSongIDs: Set<Int64> = []
    @ObservationIgnored private var likedSeedID: Int64?
    @ObservationIgnored private var likedSongs: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var quickActionTasks: [NeteaseHomeQuickAction: Task<NeteaseHomeQuickActionResult, Error>] = [:]
    @ObservationIgnored private var actionSongs: [NeteaseMusicSong] = []
    @ObservationIgnored private var referencedSongs: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var roamingTask: Task<RoamingCache, Error>?
    @ObservationIgnored private var continuationRequests: [UUID: Task<[NeteaseMusicSong], Error>] = [:]
    @ObservationIgnored private var roamingCache: RoamingCache?
    private struct RoamingCache: Codable, Sendable {
        let id: UUID
        let songs: [NeteaseMusicSong]
        let date: Date
        var consumed = false
    }
    @ObservationIgnored private var detailTasks: [Int64: Task<NeteasePlaylistDetail, Error>] = [:]
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
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        if !restored || userID != session?.profile.userID || credential != session?.credential {
            generation = UUID()
            let oldRefresh = refreshTask; refreshTask = nil; refreshID = nil; oldRefresh?.cancel()
            let oldSources = Array(sourceTasks.values); sourceTasks = [:]; sourceTaskIDs = [:]
            oldSources.forEach { $0.cancel() }; refreshingSources = []
            let oldActions = Array(quickActionTasks.values); quickActionTasks = [:]
            oldActions.forEach { $0.cancel() }
            let oldRoaming = roamingTask; roamingTask = nil; oldRoaming?.cancel(); roamingCache = nil
            let oldContinuations = Array(continuationRequests.values)
            continuationRequests.removeAll()
            oldContinuations.forEach { $0.cancel() }
            quickActionStates = [:]; likedPlaylistID = nil; likedSongIDs = []; likedSeedID = nil; likedSongs = [:]; actionSongs = []; referencedSongs = [:]
            let oldDetails = Array(detailTasks.values); detailTasks = [:]
            oldDetails.forEach { $0.cancel() }
            let oldArtwork = Array(artworkTasks.values); artworkTasks = [:]
            oldArtwork.forEach { $0.cancel() }
            let oldSaves = Array(saveTasks.values); saveTasks = [:]; saveIDs = [:]
            oldSaves.forEach { $0.cancel() }
            userID = nil; credential = nil; restored = false
            cache = Cache(); recommendations = []; daily = nil; songCatalog = []; feed = nil; feedError = nil
            charts = nil; followedReleases = nil; chartsError = nil; followedReleasesError = nil
            newSongs = nil; newSongsError = nil
            refreshedDetails = [:]; lastRefresh = nil
            recommendationsError = nil; dailyError = nil; onChange?()
            let revision = generation
            await oldRefresh?.value
            for task in oldSources { await task.value }
            for task in oldActions { _ = await task.result }
            _ = await oldRoaming?.result
            for task in oldContinuations { _ = await task.result }
            for task in oldDetails { _ = await task.result }
            for task in oldArtwork { await task.value }
            for task in oldSaves { await task.value }
            guard revision == generation, !Task.isCancelled else { return }
            userID = session?.profile.userID; credential = session?.credential
            let owner = scope, date = Self.day(), signedIn = userID != nil
            let loadedRecommendations = (try? await pageCache.load([NeteaseMusicPlaylist].self, scope: owner, key: "recommendations")) ?? []
            let today = signedIn ? try? await pageCache.load(NeteaseDailySnapshot.self, scope: owner, key: "daily:" + date) : nil
            guard revision == generation, !Task.isCancelled else { return }
            var snapshots: [String: NeteaseDailySnapshot] = [:]
            if signedIn, let today {
                snapshots[date] = today
                snapshots[today.id] = today
            }
            cache = Cache(recommendations: loadedRecommendations, snapshots: snapshots)
            restored = true
            let loadedFeed = try? await pageCache.load(NeteaseHomeFeed.self, scope: scope, key: "feed")
            guard revision == generation, !Task.isCancelled else { return }
            feed = loadedFeed
            let loadedCharts = try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-charts")
            let loadedFollowed = userID == nil ? nil : try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-followed")
            guard revision == generation, !Task.isCancelled else { return }
            charts = loadedCharts; followedReleases = loadedFollowed
            let loadedNewSongs = try? await pageCache.load(NeteaseHomeFeed.Block.self, scope: scope, key: "home-new-songs")
            let loadedRoaming = userID == nil ? nil : try? await pageCache.load(RoamingCache.self, scope: scope, key: "home-roaming")
            guard revision == generation, !Task.isCancelled else { return }
            newSongs = loadedNewSongs
            roamingCache = loadedRoaming
            rebuildSongCatalog()
            recommendations = cache.recommendations
            daily = userID == nil ? nil : cache.snapshots[Self.day()]
            for id in Set([hotChart?.numericID, radarPlaylist?.numericID].compactMap { $0 }) {
                _ = try? await restoreCachedDetail(id: id)
                guard revision == generation, !Task.isCancelled else { return }
            }
            onChange?()
            requestDisplayedArtwork()
            requestArtwork(daily?.songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL) ?? [])
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
            async let feed: Void = refreshSource(.feed, credential: credential, revision: revision, force: force)
            async let charts: Void = refreshSource(.charts, credential: credential, revision: revision, force: force)
            async let followed: Void = refreshSource(.followedReleases, credential: credential, revision: revision, force: force)
            async let roaming: Void = refreshRoaming(force: force)
            async let newSongs: Void = refreshSource(.newSongs, credential: credential, revision: revision, force: force)
            await feed
            async let recommendations: Void = refreshSource(.recommendations, credential: credential, revision: revision, force: force)
            await charts
            if revision == generation, !Task.isCancelled {
                await refreshQuickActionCovers(force: force)
            }
            _ = await (daily, newSongs, recommendations, followed, roaming)
            if revision == generation, refreshID == id {
                refreshTask = nil; refreshID = nil
                if !Task.isCancelled, recommendationsError == nil, dailyError == nil, feedError == nil,
                   chartsError == nil, followedReleasesError == nil, newSongsError == nil { lastRefresh = Date() }
            }
        }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func retry(_ source: RetrySource) async {
        guard !Task.isCancelled else { return }
        let revision = generation
        if let refreshTask, !refreshTask.isCancelled {
            await refreshTask.value
            return
        }
        await refreshSource(source, credential: credential, revision: revision, force: true)
    }

    private func refreshSource(_ source: RetrySource, credential: NeteaseCredential?, revision: UUID, force: Bool) async {
        while let pending = sourceTasks[source] {
            await pending.value
            if !pending.isCancelled || Task.isCancelled || generation != revision { return }
        }
        guard generation == revision, !Task.isCancelled else { return }
        let id = UUID()
        sourceTaskIDs[source] = id
        refreshingSources.insert(source)
        let task = Task { [self] in
            defer {
                if generation == revision, sourceTaskIDs[source] == id {
                    sourceTasks[source] = nil; sourceTaskIDs[source] = nil
                    refreshingSources.remove(source)
                    onChange?()
                }
            }
            guard generation == revision, !Task.isCancelled else { return }
            switch source {
            case .feed: await refreshFeed(credential: credential, revision: revision, force: force)
            case .recommendations: await refreshRecommendations(credential: credential, revision: revision)
            case .charts: await refreshCharts(credential: credential, revision: revision)
            case .followedReleases: await refreshFollowed(credential: credential, revision: revision)
            case .newSongs: await refreshNewSongs(credential: credential, revision: revision)
            }
        }
        sourceTasks[source] = task
        onChange?()
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func updateLikedSongs(playlistID: Int64?, songs: [NeteaseMusicSong], likedAt: [Int64: Date], likedIDs: Set<Int64>, orderedLikedIDs: [Int64] = []) {
        guard userID != nil else { return }
        likedPlaylistID = playlistID
        likedSongs = Dictionary(songs.filter { $0.id > 0 && !$0.unavailable }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unavailable = Set(songs.filter(\.unavailable).map(\.id))
        let availableIDs = likedIDs.filter { $0 > 0 && !unavailable.contains($0) }
        let datedSeed = likedAt.filter { availableIDs.contains($0.key) }.max { $0.value < $1.value }?.key
        likedSongIDs = availableIDs
        likedSeedID = datedSeed ?? orderedLikedIDs.first(where: { availableIDs.contains($0) })
            ?? likedSeedID.flatMap { availableIDs.contains($0) ? $0 : nil }
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
            newSongs = value; newSongsError = nil; save(value, key: "home-new-songs"); rebuildSongCatalog(); onChange?(); requestDisplayedArtwork()
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
                    let replacement = Dictionary(first.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    return NeteasePlaylistDetail(playlist: first.playlist,
                        songs: previous.songs.map { replacement[$0.id] ?? $0 }, addedTimes: first.addedTimes,
                        trackIDs: first.orderedTrackIDs, loadedTrackCount: previous.nextOffset)
                }
            }
            try Task.checkCancellation()
            guard revision == generation else { return }
            onChange?()
            requestDisplayedArtwork()
        } catch {}
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
                requestDisplayedArtwork()
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

    var canRequestHeartRecommendations: Bool {
        userID != nil && credential != nil && (likedPlaylistID ?? 0) > 0
    }

    func heartRecommendations(seedID: Int64) async throws -> [NeteaseMusicSong] {
        guard let credential, let playlistID = likedPlaylistID, playlistID > 0, seedID > 0 else {
            throw NeteaseHomeActionError.noFavoritePlaylist
        }
        let songs = try await continuationBatch { [client] in
            try await client.intelligenceModeSongs(playlistID: playlistID, seedSongID: seedID, credential: credential)
        }
        guard likedPlaylistID == playlistID else { throw CancellationError() }
        actionSongs = songs
        rebuildSongCatalog()
        return songs
    }

    func nextRoamingSongs() async throws -> [NeteaseMusicSong] {
        guard restored, let credential else { throw NeteaseHomeActionError.loginRequired }
        return try await continuationBatch { [client] in
            try await client.personalFM(credential: credential, mode: "EXPLORE", limit: 30)
        }
    }

    private func continuationBatch(_ fetch: @escaping @Sendable () async throws -> [NeteaseMusicSong]) async throws -> [NeteaseMusicSong] {
        try Task.checkCancellation()
        let revision = generation, id = UUID()
        let task = Task { try await fetch() }
        continuationRequests[id] = task
        defer { continuationRequests[id] = nil }
        let songs = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        var seen = Set<Int64>()
        return songs.filter { $0.id > 0 && !$0.unavailable && seen.insert($0.id).inserted }
    }

    @discardableResult
    func retainReferencedSongs(ids: Set<Int64>, adding songs: [NeteaseMusicSong] = []) -> Bool {
        guard userID != nil else { return false }
        var retained = Dictionary(songCatalog.filter { ids.contains($0.id) }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        for song in songs where ids.contains(song.id) { retained[song.id] = song }
        guard referencedSongs != retained else { return false }
        referencedSongs = retained
        rebuildSongCatalog()
        return true
    }

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

    private func refreshCharts(credential: NeteaseCredential?, revision: UUID) async {
        do {
            let value = try await client.homeCharts(credential: credential)
            try Task.checkCancellation()
            guard generation == revision else { return }
            charts = value; chartsError = nil; save(value, key: "home-charts"); onChange?(); requestDisplayedArtwork()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { chartsError = error.localizedDescription; onChange?() }
        }
    }
    private func refreshFollowed(credential: NeteaseCredential?, revision: UUID) async {
        guard let credential else { return }
        do {
            let value = try await client.followedArtistReleases(credential: credential, cached: followedReleases)
            try Task.checkCancellation()
            guard generation == revision else { return }
            followedReleases = value; followedReleasesError = nil; save(value, key: "home-followed"); onChange?(); requestDisplayedArtwork()
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled {
                followedReleasesError = error.localizedDescription; onChange?()
            }
        }
    }

    private func refreshFeed(credential: NeteaseCredential?, revision: UUID, force: Bool) async {
        do {
            var value = try await client.homeFeed(credential: credential, refresh: force)
            try Task.checkCancellation()
            guard generation == revision else { return }
            if feed == nil, value.hasMore == true, !value.blocks.isEmpty {
                publishFeed(value)
            }
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
            save(value, key: "feed")
            publishFeed(value)
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled { feedError = error.localizedDescription; onChange?() }
        }
    }

    private func publishFeed(_ value: NeteaseHomeFeed) {
        feed = value; feedError = nil
        rebuildSongCatalog()
        onChange?()
        requestDisplayedArtwork()
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
            requestDisplayedArtwork()
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
            try await cacheIO.save(snapshot, to: dailyArchiveURL(snapshot.id))
            try Task.checkCancellation()
            guard generation == revision else { return }
            cache.snapshots[snapshot.id] = snapshot
            daily = snapshot; cache.snapshots[date] = snapshot; dailyError = nil
            rebuildSongCatalog()
            save(snapshot, key: "daily:" + snapshot.id)
            save(snapshot, key: "daily:" + date)
            PerformanceDiagnostics.event("NetworkContentReady"); onChange?()
            requestDisplayedArtwork()
            requestArtwork(songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL))
        } catch is CancellationError {} catch { if generation == revision, !Task.isCancelled { dailyError = error.localizedDescription; onChange?() } }
    }
    var cachedSongs: [NeteaseMusicSong] { userID == nil ? [] : songCatalog }
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
            + Array(referencedSongs.values)
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

    func restoreCachedDetail(id: Int64, publish: Bool = true) async throws -> NeteasePlaylistDetail? {
        try Task.checkCancellation()
        if let cached = cache.details[id] { return cached }
        let revision = generation, owner = scope
        let detail = try? await pageCache.load(NeteasePlaylistDetail.self, scope: owner, key: "playlist:\(id)")
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        if let cached = cache.details[id] { return cached }
        guard let detail else { return nil }
        cache.details[id] = detail
        rebuildSongCatalog()
        if publish { onDetailChange?(id) }
        return detail
    }

    func playlistArtworkFile(id: Int64) async throws -> URL? {
        let revision = generation
        _ = try await restoreCachedDetail(id: id, publish: false)
        _ = try await joinDetail(id)
        let detail: NeteasePlaylistDetail
        if let cached = cache.details[id], cached.orderedTrackIDs.isEmpty || cached.nextOffset > 0 { detail = cached }
        else {
            let credential = credential
            detail = try await fetchDetail(id: id, preloadArtwork: false, publish: false) { [client] in
                try await client.detail(id: id, credential: credential, trackLimit: 1)
            }
        }
        try Task.checkCancellation()
        guard generation == revision, let remote = detail.displayArtworkURL(ownerID: userID) else { return nil }
        let file = try await artworkCache.imageURL(for: remote, scope: scope)
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        return file
    }

    func detail(id: Int64, force: Bool = false) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        _ = try await restoreCachedDetail(id: id)
        let joined = try await joinDetail(id)
        if let cached = cache.details[id], joined != nil || (!force && refreshedDetails[id].map { Date().timeIntervalSince($0) < 300 } == true) {
            if cached.hasInitialPage { return cached }
            let credential = credential
            return try await fetchDetail(id: id, refresh: true) { [client] in
                try await client.loadMore(cached, credential: credential, limit: cached.initialPageCount - cached.nextOffset)
            }
        }
        let limit = max(NeteasePlaylistDetail.initialPageSize, cache.details[id]?.nextOffset ?? 0)
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

    private func fetchDetail(id: Int64, refresh: Bool = false, preloadArtwork: Bool = true, publish: Bool = true,
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
            if publish { onDetailChange?(id) }
            if preloadArtwork { requestArtwork([value.playlist.artworkURL].compactMap { $0 } + value.songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL)) }
            return value
        }
        detailTasks[id] = task
        return try await existing(task)
    }
    func cachedArtworkURL(remote: URL) -> URL? {
        artworkCache.cachedURL(for: remote, scope: scope)
    }
    func cachedArtworkFile(_ remote: URL) async -> URL? {
        guard restored, !Task.isCancelled else { return nil }
        if let cached = cachedArtworkURL(remote: remote) { return cached }
        let revision = generation, owner = scope
        let file = await artworkCache.cachedFileURL(for: remote, scope: owner)
        guard restored, generation == revision, scope == owner, !Task.isCancelled else { return nil }
        return file
    }
    private func requestDisplayedArtwork() {
        let urls = displayFeedBlocks.flatMap { $0.resources.compactMap(\.artworkURL) }
            + NeteaseHomeQuickAction.allCases.compactMap { quickActionArtwork($0) }
        requestArtwork(urls)
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
}
