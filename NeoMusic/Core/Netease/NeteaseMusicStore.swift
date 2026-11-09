import Foundation
import Observation
import Network

@MainActor @Observable
final class NeteaseMusicStore {
    private(set) var userID: Int64?
    private(set) var playlists: [NeteaseMusicPlaylist] = []
    private(set) var songs: [Int64: NeteaseMusicSong] = [:]
    private(set) var playlistTracks: [Int64: [Int64]] = [:]
    /// Changes only when a favorites playlist or an already-liked song record changes.
    /// Home observes this instead of the whole song table, so loading another playlist does not republish the feed.
    private(set) var likedSongRevision = 0
    private(set) var likedIDs: Set<Int64> = []
    private(set) var likedAt: [Int64: Date] = [:]
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var loadingPlaylists: Set<Int64> = []
    private(set) var playlistErrors: [Int64: String] = [:]
    private(set) var morePlaylistIDs: Set<Int64> = []
    var wifiQuality: NeteaseMusicQuality = .lossless { didSet { defaults.set(wifiQuality.rawValue, forKey: "netease.quality.wifi"); onQualityChange?() } }
    var cellularQuality: NeteaseMusicQuality = .high { didSet { defaults.set(cellularQuality.rawValue, forKey: "netease.quality.cellular"); onQualityChange?() } }
    private(set) var isCellular = false
    @ObservationIgnored var onAuthenticationRequired: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onLibraryChange: (() -> Void)?
    @ObservationIgnored var onArtworkChange: ((Set<URL>) -> Void)?
    var sessionRevision: UUID { generation }
    @ObservationIgnored var onSessionInvalidated: (() -> Void)?
    @ObservationIgnored var onQualityChange: (() -> Void)?
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let pages: NeteasePageCache
    @ObservationIgnored private let artworkCache: NeteaseArtworkCache
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var details: [Int64: NeteasePlaylistDetail] = [:]
    @ObservationIgnored private var restoredPlaylists: Set<Int64> = []
    @ObservationIgnored private var detailDates: [Int64: Date] = [:]
    @ObservationIgnored private var failedLoads: [Int64: LoadMode] = [:]
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var detailTasks: [Int64: Task<Bool, Never>] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lyricCache: [Int64: NeteaseMusicLyrics] = [:]
    @ObservationIgnored private var legacyArtworkFiles: [String: String] = [:]
    @ObservationIgnored private let cacheIO = NeteaseCacheIO()
    @ObservationIgnored private var artworkTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveIDs: [String: UUID] = [:]
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var artworkObserver: (any NSObjectProtocol)?

    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL? = nil, defaults: UserDefaults = .standard,
         artworkSession: URLSession? = nil, artworkCache: NeteaseArtworkCache? = nil) {
        self.client = client; self.defaults = defaults
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NeteaseMusic")
        self.directory = directory
        pages = NeteasePageCache(directory: directory)
        self.artworkCache = artworkCache ?? artworkSession.map { NeteaseArtworkCache(directory: directory.appendingPathComponent("Artwork"), session: $0) } ?? .shared
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
        artworkObserver = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork,
            object: self.artworkCache, queue: .main) { [weak self] notification in
                guard let event = NeteaseArtworkCache.eviction(in: notification) else { return }
                MainActor.assumeIsolated {
                    guard let self, self.restored, let userID = self.userID,
                          event.scope == String(userID), !event.urls.isEmpty else { return }
                    self.onArtworkChange?(event.urls)
                }
            }
    }

    isolated deinit {
        monitor.cancel()
        if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) }
    }

    func activate(_ session: NeteaseSavedSession, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        if !restored || userID != session.profile.userID || credential != session.credential {
            await invalidate()
            guard !Task.isCancelled else { return }
            userID = session.profile.userID; credential = session.credential
            let revision = generation, scope = String(session.profile.userID)
            let summary = try? await pages.load(Summary.self, scope: scope, key: "library")
            let legacy = summary == nil ? await cacheIO.load(Snapshot.self, from: cacheURL) : nil
            let files = summary?.legacyArtwork ?? legacy?.artwork ?? [:]
            let existing = await cacheIO.existingFiles(files.values.map { directory.appendingPathComponent("\(scope)-\($0)") })
            guard revision == generation, !Task.isCancelled else { return }
            restored = true
            legacyArtworkFiles = files.filter { existing.contains(directory.appendingPathComponent("\(scope)-\($0.value)")) }
            if let summary {
                playlists = summary.playlists; likedIDs = summary.liked; likedAt = summary.times
                if let favorites = playlists.first(where: \.isFavorites) {
                    var preview = summary.favoritesPreview
                    if preview == nil {
                        preview = try? await pages.load(NeteasePlaylistDetail.self, scope: scope, key: "playlist:\(favorites.id)")
                    }
                    guard revision == generation, !Task.isCancelled else { return }
                    if let preview, preview.playlist.id == favorites.id { apply(firstPage(preview), persist: false) }
                    if summary.favoritesPreview == nil { saveSummary() }
                }
            } else if let legacy {
                playlists = legacy.playlists; likedIDs = legacy.liked; likedAt = legacy.times
                var importedDetails: [NeteasePlaylistDetail] = []
                for playlist in legacy.playlists {
                    guard let ids = legacy.tracks[playlist.id] else { continue }
                    let resolved = ids.compactMap { legacy.songs[$0] }.filter { !$0.unavailable }
                    let detail = NeteasePlaylistDetail(playlist: playlist, songs: resolved, addedTimes: legacy.times,
                        trackIDs: ids, loadedTrackCount: ids.count)
                    if playlist.isFavorites { apply(firstPage(detail), persist: false) }
                    importedDetails.append(detail)
                }
                let imported = importedDetails
                let summary = summarySnapshot()
                let legacyURL = cacheURL
                _ = try? await run { [pages, cacheIO] _ in
                    for detail in imported { try await pages.save(detail, scope: scope, key: "playlist:\(detail.playlist.id)") }
                    for (id, lyrics) in legacy.lyrics { try await pages.save(lyrics, scope: scope, key: "lyrics:\(id)") }
                    try await pages.save(summary, scope: scope, key: "library")
                    try await cacheIO.remove(legacyURL)
                }
            }
            guard generation == revision, !Task.isCancelled else { return }
            onChange?()
        }
        if refresh { await self.refresh() }
    }

    func invalidate() async {
        let hadSession = restored || userID != nil
        generation = UUID(); credential = nil; userID = nil; restored = false
        if hadSession { onSessionInvalidated?() }
        let pending = Array(tasks.values) + Array(artworkTasks.values) + Array(saveTasks.values)
        let pendingDetails = Array(detailTasks.values)
        pending.forEach { $0.cancel() }; pendingDetails.forEach { $0.cancel() }
        for task in pending { await task.value }
        for task in pendingDetails { _ = await task.value }
        tasks.removeAll(); detailTasks.removeAll(); artworkTasks.removeAll(); saveTasks.removeAll(); saveIDs.removeAll()
        playlists = []; songs = [:]; playlistTracks = [:]; likedIDs = []; likedAt = [:]; lyricCache = [:]; legacyArtworkFiles = [:]
        details = [:]; restoredPlaylists = []; detailDates = [:]; failedLoads = [:]; refreshedAt = nil; morePlaylistIDs = []
        isLoading = false; loadingPlaylists = []; playlistErrors = [:]; error = nil; onChange?()
    }

    private func run<T: Sendable>(_ operation: @escaping @MainActor (NeteaseCredential) async throws -> T) async throws -> T {
        try Task.checkCancellation()
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

    func refresh(force: Bool = false) async {
        guard let userID, !isLoading, !Task.isCancelled else { return }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 300 { return }
        let interval = PerformanceDiagnostics.begin("MusicRefresh")
        defer { PerformanceDiagnostics.end("MusicRefresh", interval) }
        isLoading = true; error = nil; onChange?()
        let revision = generation
        defer { if generation == revision { isLoading = false; onChange?() } }
        async let listsReady = refreshPlaylists(userID: userID, revision: revision)
        async let likesReady = refreshLikes(userID: userID, revision: revision)
        let success = await (listsReady, likesReady)
        guard generation == revision, !Task.isCancelled else { return }
        if success.0 && success.1 { refreshedAt = Date() }
        if let favorites = playlists.first(where: \.isFavorites) { await loadPlaylist(id: favorites.id, force: force) }
    }

    private func refreshPlaylists(userID: Int64, revision: UUID) async -> Bool {
        do {
            let value = try await run { [client] in try await client.playlists(userID: userID, credential: $0) }
            let changed = playlists != value
            playlists = value; saveSummary(); onChange?()
            if changed { onLibraryChange?() }
            requestArtwork(value.prefix(6).compactMap(\.artworkURL))
            PerformanceDiagnostics.event("NetworkContentReady")
            return true
        } catch is CancellationError { return false }
        catch { if generation == revision { self.error = error.localizedDescription; onChange?() }; return false }
    }

    private func refreshLikes(userID: Int64, revision: UUID) async -> Bool {
        do {
            let value = try await run { [client] in try await client.likedIDs(userID: userID, credential: $0) }
            let changed = likedIDs != value
            likedIDs = value; saveSummary(); onChange?()
            if changed { onLibraryChange?() }
            return true
        } catch is CancellationError { return false }
        catch { if generation == revision { self.error = error.localizedDescription; onChange?() }; return false }
    }

    func hasMorePlaylist(id: Int64) -> Bool {
        if let detail = details[id] { return !detail.isComplete }
        return playlists.first(where: { $0.id == id }).map { $0.trackCount > 0 } ?? false
    }
    func playlistTotalCount(id: Int64) -> Int {
        details[id]?.orderedTrackIDs.count ?? playlists.first(where: { $0.id == id })?.trackCount ?? 0
    }

    func loadPlaylist(id: Int64, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        if let existing = detailTasks[id] { _ = await existing.value; return }
        if !force, let failed = failedLoads[id] { _ = await load(id: id, mode: failed); return }
        if !force, details[id] != nil, let date = detailDates[id], Date().timeIntervalSince(date) < 300 { return }
        _ = await load(id: id, mode: .refresh)
    }

    func loadMorePlaylist(id: Int64) async {
        let revision = generation, offset = details[id]?.nextOffset
        if let existing = detailTasks[id] {
            _ = await existing.value
            guard revision == generation, !Task.isCancelled else { return }
            if details[id]?.nextOffset != offset { return }
        }
        guard !Task.isCancelled else { return }
        guard details[id]?.isComplete == false else { return }
        _ = await load(id: id, mode: .more)
    }

    @discardableResult
    func completePlaylist(id: Int64) async -> Bool {
        let revision = generation
        guard !Task.isCancelled else { return false }
        if details[id]?.isComplete == true { return true }
        if let existing = detailTasks[id] { _ = await existing.value }
        guard revision == generation, !Task.isCancelled else { return false }
        if details[id]?.isComplete == true { return true }
        let completed = await load(id: id, mode: .complete)
        return completed && revision == generation && !Task.isCancelled
    }

    func adoptCachedPlaylist(_ detail: NeteasePlaylistDetail, ownerID: Int64, revision: UUID) {
        guard ownerID == userID, revision == generation, !Task.isCancelled,
              details[detail.playlist.id] == nil, detailTasks[detail.playlist.id] == nil else { return }
        restoredPlaylists.insert(detail.playlist.id)
        apply(detail, persist: false)
        onChange?()
    }

    func restoreCachedSongs(ids: Set<Int64>) async -> [NeteaseMusicSong] {
        guard let userID, !Task.isCancelled else { return [] }
        let available = ids.sorted().compactMap { songs[$0] }
        let missing = ids.subtracting(available.map(\.id))
        guard !missing.isEmpty else { return available }
        let scope = String(userID)
        do {
            let restored = try await run { [pages] _ in
                try await Self.findCachedSongs(ids: missing, pages: pages, scope: scope)
            }
            return available + restored
        } catch { return [] }
    }

    @concurrent private static func findCachedSongs(ids: Set<Int64>, pages: NeteasePageCache, scope: String) async throws -> [NeteaseMusicSong] {
        let details = try await pages.entries(NeteasePlaylistDetail.self, scope: scope, prefix: "playlist:")
        var found: [Int64: NeteaseMusicSong] = [:]
        for detail in details.values {
            try Task.checkCancellation()
            for song in detail.songs where ids.contains(song.id) { found[song.id] = song }
            if found.count == ids.count { break }
        }
        return ids.sorted().compactMap { found[$0] }
    }

    private enum LoadMode { case refresh, more, complete }

    private func load(id: Int64, mode: LoadMode) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let existing = detailTasks[id] { return await existing.value }
        let revision = generation
        let task = Task { [self] in
            defer { if generation == revision { detailTasks.removeValue(forKey: id) } }
            return await performLoadPlaylist(id: id, mode: mode)
        }
        detailTasks[id] = task
        // The store owns this shared request; individual view tasks may leave
        // while another consumer still needs the same page or complete queue.
        return await task.value
    }

    private func performLoadPlaylist(id: Int64, mode: LoadMode) async -> Bool {
        loadingPlaylists.insert(id); playlistErrors[id] = nil; failedLoads[id] = nil; onChange?()
        let revision = generation
        defer { if generation == revision { loadingPlaylists.remove(id); onChange?() } }
        do {
            try await restorePlaylist(id: id)
            let existing = details[id]
            if mode != .refresh, existing?.isComplete == true { return true }
            let detail = try await run { [client] credential in
                switch mode {
                case .refresh:
                    return try await client.detail(id: id, credential: credential, trackLimit: max(100, existing?.nextOffset ?? 0), prefetched: existing?.songs ?? [])
                case .more:
                    guard let existing else { throw NeteaseAccountError.invalidResponse }
                    return try await client.loadMore(existing, credential: credential)
                case .complete:
                    guard let existing else { return try await client.detail(id: id, credential: credential) }
                    return try await client.complete(existing, credential: credential)
                }
            }
            apply(detail)
            if mode == .refresh { detailDates[id] = Date() }
            PerformanceDiagnostics.event("NetworkContentReady"); onChange?()
            requestArtwork([detail.playlist.artworkURL].compactMap { $0 } + detail.songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL))
            return true
        } catch is CancellationError { return false }
        catch { if generation == revision { playlistErrors[id] = error.localizedDescription; failedLoads[id] = mode; onChange?() }; return false }
    }

    private func restorePlaylist(id: Int64) async throws {
        try Task.checkCancellation()
        guard !restoredPlaylists.contains(id), let userID else { return }
        let scope = String(userID)
        let cached = try await run { [pages] _ in
            try? await pages.load(NeteasePlaylistDetail.self, scope: scope, key: "playlist:\(id)")
        }
        restoredPlaylists.insert(id)
        if let cached {
            apply(cached, persist: false)
            onChange?()
        }
    }

    private func firstPage(_ detail: NeteasePlaylistDetail) -> NeteasePlaylistDetail {
        let count = min(100, detail.nextOffset)
        let ids = Set(detail.orderedTrackIDs.prefix(count))
        return .init(playlist: detail.playlist, songs: Array(detail.songs.prefix(count)),
                     addedTimes: detail.addedTimes.filter { ids.contains($0.key) },
                     trackIDs: detail.orderedTrackIDs, loadedTrackCount: count)
    }

    private func apply(_ detail: NeteasePlaylistDetail, persist: Bool = true) {
        let id = detail.playlist.id
        let trackIDs = detail.songs.map(\.id)
        let favorites = detail.playlist.isFavorites && detail.playlist.creatorID == userID
        let likedContentChanged = (favorites && playlistTracks[id] != trackIDs) || detail.songs.contains { song in
            (favorites || likedIDs.contains(song.id)) && songs[song.id] != song
        }
        details[id] = detail
        playlistTracks[id] = trackIDs
        for song in detail.songs {
            // 喜欢操作不知道曲目详情时，不能用「不可用」占位盖住正在播放的歌曲。
            if song.unavailable, songs[song.id]?.unavailable == false { continue }
            songs[song.id] = song
        }
        if likedContentChanged { likedSongRevision &+= 1 }
        if detail.isComplete { morePlaylistIDs.remove(id) } else { morePlaylistIDs.insert(id) }
        if detail.playlist.isFavorites, detail.playlist.creatorID == userID {
            for (id, date) in detail.addedTimes { likedAt[id] = date }
        }
        if persist {
            restoredPlaylists.insert(id)
            save(detail, key: "playlist:\(id)")
            if detail.playlist.isFavorites { saveSummary() }
        }
    }

    func setPlaylistSubscribed(id: Int64, subscribed: Bool) async throws {
        guard let userID else { throw NeteaseAccountError.authenticationRequired }
        let revision = generation
        var failure: Error?
        do {
            try await run { [client] in try await client.setPlaylistSubscribed(id: id, subscribed: subscribed, credential: $0) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard generation == revision else { throw CancellationError() }
            failure = error
        }
        let value = try await run { [client] in try await client.playlists(userID: userID, credential: $0) }
        guard generation == revision, !Task.isCancelled else { throw CancellationError() }
        playlists = value
        saveSummary(); onChange?(); onLibraryChange?()
        let collected = value.contains { $0.id == id && $0.isSubscribed == true }
        guard collected == subscribed else { throw failure ?? NeteaseAccountError.invalidResponse }
    }

    func setLiked(songID: Int64, liked: Bool) async throws {
        guard let userID else { throw NeteaseAccountError.authenticationRequired }
        let revision = generation
        let previous = LikedMembership(ids: likedIDs, times: likedAt, detail: playlists.first(where: \.isFavorites).flatMap { details[$0.id] })
        // 和 MeloX 的 setLocalSong 一样：先改喜欢列表，请求失败再放回去。
        reviseLiked(songID, liked: liked, persist: false)
        onChange?()
        do {
            if let favorites = playlists.first(where: \.isFavorites) { try await restorePlaylist(id: favorites.id) }
            guard revision == generation, !Task.isCancelled else { throw CancellationError() }
            reviseLiked(songID, liked: liked, persist: false)
            try await run { [client] in try await client.setLiked(id: songID, liked: liked, credential: $0) }
            guard revision == generation, !Task.isCancelled else { throw CancellationError() }
        } catch {
            guard generation == revision else { throw CancellationError() }
            if await confirmedLiked(songID, liked: liked, userID: userID, revision: revision) { return }
            restoreLiked(previous)
            onChange?()
            throw error
        }
        guard let favorites = playlists.first(where: \.isFavorites) else { saveSummary(); onLibraryChange?(); return }
        if liked, songs[songID]?.unavailable != false {
            let single = NeteasePlaylistDetail(playlist: favorites, songs: [], addedTimes: [:], trackIDs: [songID], loadedTrackCount: 0)
            if let resolved = try? await run({ [client] in try await client.complete(single, credential: $0) }),
               revision == generation {
                var changed = false
                for song in resolved.songs where !song.unavailable && songs[song.id] != song {
                    songs[song.id] = song
                    changed = true
                }
                if changed { likedSongRevision &+= 1 }
            }
        }
        guard revision == generation, !Task.isCancelled else { return }
        reviseLiked(songID, liked: liked, persist: true)
        onLibraryChange?()
        onChange?()
    }

    private struct LikedMembership {
        let ids: Set<Int64>
        let times: [Int64: Date]
        let detail: NeteasePlaylistDetail?
    }

    /// 喜欢歌曲的名单和「我喜欢的音乐」曲目一起改。已在目标状态时不改加入时间。
    private func reviseLiked(_ songID: Int64, liked: Bool, persist: Bool) {
        if liked {
            if likedIDs.insert(songID).inserted { likedAt[songID] = Date() }
        } else {
            likedIDs.remove(songID)
            likedAt.removeValue(forKey: songID)
        }
        guard let favorites = playlists.first(where: \.isFavorites), let existing = details[favorites.id] else {
            if persist { saveSummary() }
            return
        }
        var ids = existing.orderedTrackIDs
        var loadedIDs = Array(ids.prefix(existing.nextOffset))
        if let index = ids.firstIndex(of: songID) {
            ids.remove(at: index)
            loadedIDs.removeAll { $0 == songID }
        }
        if liked {
            ids.insert(songID, at: 0)
            // 只有已经拿到曲目时才放进喜欢列表。缺详情不能记成「暂无完整音源」。
            if songs[songID] != nil { loadedIDs.insert(songID, at: 0) }
        }
        let loaded = loadedIDs.compactMap { songs[$0] }
        apply(.init(playlist: favorites, songs: loaded, addedTimes: likedAt, trackIDs: ids, loadedTrackCount: loaded.count), persist: persist)
    }

    private func restoreLiked(_ previous: LikedMembership) {
        likedIDs = previous.ids
        likedAt = previous.times
        if let detail = previous.detail { apply(detail, persist: false) }
        likedIDs = previous.ids
        likedAt = previous.times
    }

    /// 写请求失败时，以服务器上的喜欢名单为准。已经达到目标就不再报失败。
    private func confirmedLiked(_ songID: Int64, liked: Bool, userID: Int64, revision: UUID) async -> Bool {
        guard let ids = try? await run({ [client] in try await client.likedIDs(userID: userID, credential: $0) }),
              revision == generation, ids.contains(songID) == liked else { return false }
        likedIDs = ids
        reviseLiked(songID, liked: liked, persist: true)
        onLibraryChange?()
        onChange?()
        return true
    }

    func stream(songID: Int64) async throws -> NeteaseMusicStream {
        let quality = isCellular ? cellularQuality : wifiQuality
        return try await run { [client] in try await client.stream(id: songID, quality: quality, credential: $0) }
    }
    func lyrics(songID: Int64) async throws -> NeteaseMusicLyrics {
        try Task.checkCancellation()
        guard let userID else { throw NeteaseAccountError.authenticationRequired }
        if let cached = lyricCache[songID] { return cached }
        let scope = String(userID), key = "lyrics:\(songID)"
        let (lyrics, needsSave) = try await run { [pages, client] credential in
            if let cached = try? await pages.load(NeteaseMusicLyrics.self, scope: scope, key: key) {
                try Task.checkCancellation()
                return (cached, false)
            }
            try Task.checkCancellation()
            return (try await client.lyrics(id: songID, credential: credential), true)
        }
        lyricCache[songID] = lyrics
        if needsSave { save(lyrics, key: key) }
        return lyrics
    }
    func requestArtwork(_ urls: [URL]) {
        guard restored, userID != nil, !Task.isCancelled else { return }
        let revision = generation
        let cached = Set(urls.filter { cachedArtworkURL($0) != nil })
        if !cached.isEmpty { onArtworkChange?(cached) }
        var seen = Set<URL>()
        for remote in urls where seen.insert(remote).inserted && remote.scheme == "https" && cachedArtworkURL(remote) == nil && artworkTasks[remote] == nil {
            artworkTasks[remote] = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == revision { self.artworkTasks[remote] = nil } }
                _ = try? await self.artwork(remote)
            }
        }
    }
    func cachedArtworkURL(for remote: URL) -> URL? { cachedArtworkURL(remote) }
    func cachedArtworkURL(_ remote: URL) -> URL? {
        guard let userID else { return nil }
        if let file = artworkCache.cachedURL(for: remote, scope: String(userID)) { return file }
        return legacyArtworkFiles[remote.absoluteString].map { directory.appendingPathComponent("\(userID)-\($0)") }
    }
    func cachedArtworkFile(_ remote: URL) async -> URL? {
        guard restored, let userID, !Task.isCancelled else { return nil }
        if let cached = cachedArtworkURL(remote) { return cached }
        let revision = generation, scope = String(userID)
        let file = await artworkCache.cachedFileURL(for: remote, scope: scope)
        guard restored, generation == revision, self.userID == userID, !Task.isCancelled else { return nil }
        return file
    }
    func artwork(_ remote: URL) async throws -> URL {
        if let cached = cachedArtworkURL(remote) { return cached }
        guard remote.scheme == "https", let userID else { throw NeteaseAccountError.authenticationRequired }
        let revision = generation
        let file = try await run { [artworkCache] _ in
            try await artworkCache.imageURL(for: remote, scope: String(userID))
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        PerformanceDiagnostics.event("ArtworkReady"); onArtworkChange?([remote])
        return file
    }

    private var cacheURL: URL { directory.appendingPathComponent("\(userID ?? 0).json") }
    struct Snapshot: Codable, Sendable {
        let playlists: [NeteaseMusicPlaylist]; let songs: [Int64: NeteaseMusicSong]; let tracks: [Int64: [Int64]]
        let liked: Set<Int64>; let times: [Int64: Date]; let lyrics: [Int64: NeteaseMusicLyrics]; let artwork: [String: String]?
    }
    private struct Summary: Codable, Sendable {
        let playlists: [NeteaseMusicPlaylist]
        let liked: Set<Int64>
        let times: [Int64: Date]
        let legacyArtwork: [String: String]
        let favoritesPreview: NeteasePlaylistDetail?
    }
    private func summarySnapshot() -> Summary {
        let favorites = playlists.first(where: \.isFavorites).flatMap { details[$0.id] }.map(firstPage)
        return Summary(playlists: playlists, liked: likedIDs, times: likedAt,
                       legacyArtwork: legacyArtworkFiles, favoritesPreview: favorites)
    }
    private func saveSummary() {
        save(summarySnapshot(), key: "library")
    }
    private func save<Value: Encodable & Sendable>(_ value: Value, key: String) {
        guard let userID else { return }
        let scope = String(userID), revision = generation, previous = saveTasks[key], id = UUID()
        previous?.cancel()
        saveIDs[key] = id
        saveTasks[key] = Task { [weak self, pages] in
            defer {
                if self?.generation == revision, self?.saveIDs[key] == id {
                    self?.saveTasks[key] = nil; self?.saveIDs[key] = nil
                }
            }
            await previous?.value
            guard !Task.isCancelled else { return }
            do { try await pages.save(value, scope: scope, key: key) }
            catch is CancellationError {} catch {
                if self?.generation == revision { self?.error = "缓存保存失败：\(error.localizedDescription)"; self?.onChange?() }
            }
        }
    }

    func waitForCacheWrites() async {
        for task in saveTasks.values { await task.value }
    }
}

/// File work for the three account-owned content caches stays off the UI executor.
actor NeteaseCacheIO {
    func load<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) -> Value? {
        guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func existingFiles(_ urls: [URL]) -> Set<URL> {
        Set(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    func remove(_ url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: url)
    }
    func save<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        try writeArtwork(data, to: url)
    }
    func writeArtwork(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
