import SwiftUI
import Observation

@MainActor struct HomeFeedPlaylistCovers {
    let session: UUID?
    private var cards: [Int64: [ArtworkResourceState<Artwork>]] = [:]
    private var remoteByPlaylist: [Int64: URL] = [:]

    init(session: UUID?) { self.session = session }

    mutating func register(_ card: ArtworkResourceState<Artwork>, playlist: Int64, remote: URL?) {
        cards[playlist, default: []].append(card)
        remoteByPlaylist[playlist] = remote
    }

    mutating func update(playlist: Int64, remote: URL?, session: UUID, cover: @autoclosure () -> Artwork) {
        guard self.session == session, let targets = cards[playlist] else { return }
        remoteByPlaylist[playlist] = remote
        let replacement = cover()
        for card in targets { card.update(replacement) }
    }

    func publish(filesFor urls: Set<URL>, session: UUID, artwork: (URL) -> Artwork) {
        guard self.session == session else { return }
        for (id, remote) in remoteByPlaylist where urls.contains(remote) {
            let cover = artwork(remote)
            for card in cards[id] ?? [] { card.update(cover) }
        }
    }
}

@MainActor @Observable final class HomeMusicIntegration {
    let model = HomeContentModel()
    let detailLibrary = PlaylistLibrary(playlists: [], folders: [])
    var showsLogin = false
    private(set) var cachedSongs: [LibrarySongItem] = []
    private let account: NeteaseAccount
    private let player: NowPlayingModel
    private var connected = false
    private var completingLogin = false
    private var activeRoute: String?
    private(set) var pending: Pending?
    private var playbackTask: Task<Void, Never>?
    private var playbackRevision = UUID()
    private var loaded: [String: (LibraryPlaylistItem, [NeteaseMusicSong])] = [:]
    @ObservationIgnored private var favoriteOwner: String?
    @ObservationIgnored private var publishedLikedIDs: Set<Int64> = []
    @ObservationIgnored private var publishedLikedAt: [Int64: Date] = [:]
    private var owner: String?
    private var pendingFeedPlayback: (songs: [NeteaseMusicSong], index: Int, title: String)?
    private(set) var pendingQuickAction: HomeQuickAction?
    @ObservationIgnored private var queueArtworkBindings: (revision: UInt64, songs: [String: [LibrarySongItem]])?
    @ObservationIgnored private var artworkSongs: [URL: [NeteaseMusicSong]] = [:]
    @ObservationIgnored private var feedPlaylistCovers = HomeFeedPlaylistCovers(session: nil)
    @ObservationIgnored private var feedArtwork: [URL: [ArtworkResourceState<Artwork>]] = [:]
    @ObservationIgnored private var retainedArtworkIDs: Set<String> = []
    @ObservationIgnored private var retainedArtworkSession: UUID?
    @ObservationIgnored private var cachedSongsPublishTask: Task<Void, Never>?
    @ObservationIgnored private var cachedSongsGeneration = 0
    private struct CatalogVersion: Equatable {
        let session: UUID?
        let revision: UInt64?
    }
    @ObservationIgnored private var projectedCatalog: CatalogVersion?
    @ObservationIgnored private var projectedLikedIDs: Set<Int64> = []
    @ObservationIgnored private var projectedLikedAt: [Int64: Date] = [:]
    @ObservationIgnored private var cachedSongIndices: [String: Int] = [:]
    @ObservationIgnored private var artworkBatchSession: UUID?
    @ObservationIgnored private var pendingArtworkURLs: Set<URL> = []
    @ObservationIgnored private(set) var artworkPublishTask: Task<Void, Never>?
    @ObservationIgnored private var hasConnectedPublish = false
    @ObservationIgnored private let projectionCache = OnlineSongProjectionCache()
    @ObservationIgnored private var roamingFill: Task<Void, Never>?
    @ObservationIgnored private var roamingGeneration = UUID()
    @ObservationIgnored private var roamingAdvance = false
    @ObservationIgnored private var roamingPlaybackEnded = false
    struct Pending {
        let route: String
        let songID: Int64?
        let shuffled: Bool
    }
    init(account: NeteaseAccount, player: NowPlayingModel = LocalLibrary.player) {
        self.account = account
        self.player = player
    }
    func connect() {
        guard !connected else { return }
        connected = true
        model.login = { [weak self] in self?.showsLogin = true }
        model.refresh = { [weak self] in
            guard let self else { return }
            self.model.isLoading = true
            await self.account.home?.refresh()
            self.model.isLoading = false
        }
        model.retryIssue = { [weak self] id in
            guard let self, let source = NeteaseHomeStore.RetrySource(rawValue: id),
                  let home = self.account.home, home.userID == self.account.profile?.userID else { return }
            await home.retry(source)
        }
        model.play = { [weak self] section, item in self?.playFeed(section: section, item: item) }
        model.performQuickAction = { [weak self] action in self?.requestQuickAction(action) }
        model.prepareNavigation = { [weak self] in self?.prepareNavigation($0) }
        player.recommendationOwner = { [weak self] song in
            guard let self, let home = account.home, let user = account.profile?.userID,
                  self.owner == String(user), !account.isLoggingOut, home.userID == user, home.canRequestHeartRecommendations,
                  Self.currentOnlineSongID(song, owner: String(user)) != nil else { return nil }
            return String(user)
        }
        player.fetchRecommendations = { [weak self] song in
            guard let self, let home = account.home, let owner = player.recommendationOwner?(song),
                  let seed = Self.currentOnlineSongID(song, owner: owner) else { throw CancellationError() }
            let revision = home.sessionRevision
            let songs = try await home.heartRecommendations(seedID: seed)
            try Task.checkCancellation()
            guard account.home === home, revision == home.sessionRevision, player.recommendationOwner?(song) == owner else {
                throw CancellationError()
            }
            return songs.map(mapSong)
        }
        player.onRecommendationsQueued = { [weak self] songs in
            guard let self else { return }
            publish()
            for id in Set(songs.compactMap({ $0.artwork.loadID })) {
                requestArtwork(for: id)
            }
        }
        player.replenishQueue = { [weak self] continuation, advance, ended in
            self?.replenishRoaming(continuation: continuation, shouldAdvance: advance, playbackEnded: ended)
        }
        player.onCollectionPlaybackStarted = { reference in
            if reference.kind == .localPlaylist { LocalLibrary.playlistLibrary.markPlayed(reference.id) }
            if reference.kind == .onlinePlaylist, let owner = reference.ownerID {
                let id = reference.id.hasPrefix("netease-playlist:") ? reference.id : "netease-playlist:\(owner):\(reference.id)"
                LocalLibrary.playlistLibrary.markPlayed(id)
            }
        }
        account.home?.onChange = { [weak self] in self?.publish() }
        account.home?.onDetailChange = { [weak self] in self?.publishDetail($0) }
        account.home?.onArtworkChange = { [weak self] in self?.scheduleArtworkPublish($0) }
        detailLibrary.loadOnlinePlaylist = { [weak self] id in
            guard let self else { return }
            do {
                let retry = self.detailLibrary.onlineErrors[id] != nil
                try await self.load(id, loadMore: retry && self.detailLibrary.onlineHasMore.contains(id), force: retry)
            } catch {}
        }
        detailLibrary.loadMoreOnlinePlaylist = { [weak self] id in
            do { try await self?.load(id, loadMore: true) } catch {}
        }
        detailLibrary.completeOnlinePlaylist = { [weak self] id in
            guard let self else { return false }
            do { try await self.load(id, complete: true); return true } catch { return false }
        }
        detailLibrary.unsubscribeOnlinePlaylist = { [weak self] id in self?.changeCollection(id, subscribed: false) }
        observe()
        observeCurrentSong()
        observeRecent()
    }

    private func observe() {
        withObservationTracking {
            _ = account.profile
            _ = account.isLoggingOut
            _ = account.validationState
            _ = account.music?.userID
            _ = account.music?.likedIDs
            _ = account.music?.likedAt
            _ = account.music?.playlists
            _ = account.music?.likedSongRevision
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        publish()
        syncCollectedPlaylists()
        refreshOpenCollectionFavorites()
    }

    private func refreshOpenCollectionFavorites() {
        guard owner != nil, account.music?.userID.map(String.init) == owner else { return }
        let liked = account.music?.likedIDs ?? []
        let times = account.music?.likedAt ?? [:]
        let changed = publishedLikedIDs.symmetricDifference(liked).union(
            Set(publishedLikedAt.keys).union(times.keys).filter { publishedLikedAt[$0] != times[$0] })
        let ownerChanged = favoriteOwner != owner
        favoriteOwner = owner; publishedLikedIDs = liked; publishedLikedAt = times
        for (id, value) in loaded where ownerChanged || value.1.contains(where: { changed.contains($0.id) }) {
            updateDetail(id, item: value.0, songs: value.1)
        }
    }
    private func observeCurrentSong() {
        withObservationTracking {
            _ = player.current
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCurrentSong() }
        }
        if retainReferencedSongs() { publish() }
        else { publishQuickActions() }
    }

    @discardableResult
    private func retainReferencedSongs(adding songs: [NeteaseMusicSong] = []) -> Bool {
        guard let home = account.home, let owner, home.userID.map(String.init) == owner,
              account.profile?.userID == home.userID else { return false }
        let playlistSongs = LocalLibrary.playlistLibrary.playlists.filter { !$0.isReadOnly && !$0.isSystem }
            .flatMap { LocalLibrary.playlistLibrary.songs(in: $0.id) }
        let ids = Set((player.queue + playlistSongs).filter { $0.onlineOwnerID == owner }.compactMap(\.onlineSongID))
        return home.retainReferencedSongs(ids: ids.union(songs.map(\.id)), adding: songs)
    }
    private func observeRecent() {
        withObservationTracking {
            _ = LocalLibrary.playlistLibrary.playlists
            _ = LocalLibrary.songLibrary.songs
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRecent() }
        }
        if retainReferencedSongs() { publish() }
        refreshRetainedArtwork()
        syncOpenCollectionStates()
    }
    static func playlistArtwork(id: Int64, home: NeteaseHomeStore?) -> Artwork {
        guard let home else { return .playlist }
        if let detail = home.cachedDetail(id: id),
           let remote = detail.displayArtworkURL(ownerID: home.userID),
           let file = home.cachedArtworkURL(remote: remote) { return .file(file) }
        return .deferred(id: DeferredArtworkKey(domain: .homePlaylist, session: home.sessionRevision, playlistID: id).rawValue, placeholder: .playlist)
    }

    private func artwork(_ remote: URL?, placeholder: ArtworkPlaceholder = .playlist,
                         cachedCovers: [URL: URL]? = nil) -> Artwork {
        guard let remote, let home = account.home else { return placeholder == .playlist ? .playlist : .missing }
        if let file = cachedCovers?[remote] ?? home.cachedArtworkURL(remote: remote) { return .file(file) }
        return .deferred(id: DeferredArtworkKey(domain: .home, session: home.sessionRevision, url: remote).rawValue, placeholder: placeholder)
    }
    func requestArtwork(for id: String) {
        guard let home = account.home, home.userID == account.sessionOwnerID,
              let key = DeferredArtworkKey(rawValue: id),
              key.matches(domain: .home, session: home.sessionRevision),
              let url = key.remoteURL else { return }
        home.requestArtwork([url])
    }
    func cachedArtworkFile(for id: String) async -> URL? {
        guard let home = account.home, home.userID == account.sessionOwnerID, !Task.isCancelled else { return nil }
        let revision = home.sessionRevision, owner = home.userID
        guard let key = DeferredArtworkKey(rawValue: id), key.session == revision.uuidString else { return nil }
        if key.domain == .homePlaylist, let number = key.playlistID {
            let file = try? await home.playlistArtworkFile(id: number)
            guard revision == home.sessionRevision, account.sessionOwnerID == owner, !Task.isCancelled else { return nil }
            return file
        }
        guard key.domain == .home, let url = key.remoteURL else { return nil }
        let file = await home.cachedArtworkFile(url)
        guard revision == home.sessionRevision, home.userID == owner,
              account.sessionOwnerID == owner, !Task.isCancelled else { return nil }
        return file
    }
    private func publish() {
        let currentOwner = account.profile.map { String($0.userID) }
        if owner != currentOwner {
            if player.continuation?.ownerID != currentOwner { player.stopAutomaticContinuation() }
            roamingGeneration = UUID()
            roamingFill?.cancel()
            roamingFill = nil
            roamingAdvance = false
            roamingPlaybackEnded = false
            if owner != nil {
                cancelPendingPlayback(); pendingFeedPlayback = nil; pendingQuickAction = nil
            }
            model.quickActionRoute = nil
            model.quickActionPreview = nil
            queueArtworkBindings = nil
            owner = currentOwner
            for id in detailLibrary.playlists.map(\.id) where id.hasPrefix("home:") {
                var item = LibraryPlaylistItem(id: id, title: "播放列表", artwork: .playlist, sourceOwnerID: currentOwner)
                item.isReadOnlyContent = true
                detailLibrary.setExternalCollection(item: item, songs: [])
                detailLibrary.setPlaylistDetailReceived(false, for: id)
                detailLibrary.setOnlineHasMore(id, false)
            }
            loaded = [:]
            cachedSongs = []
            projectionCache.removeAll()
            projectedCatalog = nil
            cachedSongIndices.removeAll()
            artworkPublishTask?.cancel()
            artworkPublishTask = nil
            pendingArtworkURLs.removeAll()
            cachedSongsPublishTask?.cancel()
            cachedSongsPublishTask = nil
            cachedSongsGeneration &+= 1
            if currentOwner == nil { cancelPendingPlayback() }
        }
        if model.navigationOwnerID != currentOwner { model.navigationOwnerID = currentOwner }
        updateLikedSongs()
        if player.isAutomaticContinuationEnabled {
            let lostPlaylist = account.home?.userID == account.music?.userID
                && account.home?.userID != nil && account.home?.canRequestHeartRecommendations == false
            if account.isLoggingOut || lostPlaylist { player.stopAutomaticContinuation() }
        }
        publishFeed()
        resumePendingPlayback()
        if LocalLibrary.playbackAccountID != currentOwner { LocalLibrary.playbackAccountID = currentOwner }
        resumePendingQuickAction()
        if let pendingFeedPlayback, let userID = account.profile?.userID,
           account.validationState == .valid, account.home?.userID == userID, account.music?.userID == userID {
            self.pendingFeedPlayback = nil
            completingLogin = showsLogin
            showsLogin = false
            player.requestPlay(pendingFeedPlayback.songs.map(mapSong), startingAt: pendingFeedPlayback.index, from: pendingFeedPlayback.title)
        }

        if model.isGuest != (currentOwner == nil) { model.isGuest = currentOwner == nil }
        for (id, value) in loaded { updateDetail(id, item: value.0, songs: value.1) }
        retainReferencedSongs()
        let values = account.home?.userID == account.profile?.userID ? account.home?.cachedSongs ?? [] : []
        let allowAsync = hasConnectedPublish && account.home?.userID != nil
        hasConnectedPublish = true
        syncCachedSongs(values, home: account.home?.userID == account.profile?.userID ? account.home : nil, preferAsync: allowAsync)
        refreshRetainedArtwork(contentChanged: true)
    }

    private func publishDetail(_ number: Int64) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }),
              let detail = home.cachedDetail(id: number) else { return }
        feedPlaylistCovers.update(playlist: number, remote: detail.displayArtworkURL(ownerID: home.userID),
                                  session: home.sessionRevision, cover: feedPlaylistArtwork(id: number, home: home))
        let route = "home:playlist:\(number)"
        if detailLibrary.playlist(route) != nil { applyDetail(detail, id: route, clearError: detail.hasInitialPage) }
        retainReferencedSongs()
        syncCachedSongs(home.cachedSongs, home: home, preferAsync: home.cachedSongs.count > 120)
        refreshRetainedArtwork(contentChanged: true)
    }

    private func syncCachedSongs(_ values: [NeteaseMusicSong], home: NeteaseHomeStore?, preferAsync: Bool) {
        let session = home?.sessionRevision
        let currentOwner = owner
        let likedIDs = account.music?.likedIDs ?? []
        let likedAt = account.music?.likedAt ?? [:]
        let version = CatalogVersion(session: session, revision: home?.songCatalogRevision)
        if projectedCatalog == version, preferAsync || cachedSongsPublishTask == nil {
            // A pending group commits with the latest favorites.
            guard cachedSongsPublishTask == nil,
                  projectedLikedIDs != likedIDs || projectedLikedAt != likedAt else { return }
            commitCachedSongs(values, artworkByURL: artworkSongs, uniqueURLs: Array(artworkSongs.keys),
                              home: home, likedIDs: likedIDs, likedAt: likedAt)
            return
        }
        projectedCatalog = version
        if values.count > 120, preferAsync, let home, home.userID == account.profile?.userID {
            cachedSongsPublishTask?.cancel()
            cachedSongsGeneration &+= 1
            let generation = cachedSongsGeneration
            cachedSongsPublishTask = Task { @MainActor [weak self] in
                guard let prepared = try? await OnlineSongProjector.groupArtworkInBackground(values) else { return }
                guard let self, !Task.isCancelled, self.cachedSongsGeneration == generation,
                      let currentHome = self.account.home, currentHome.sessionRevision == session,
                      currentHome.userID == self.account.profile?.userID,
                      self.owner == currentOwner else { return }
                self.cachedSongsPublishTask = nil
                self.commitCachedSongs(values, artworkByURL: prepared.byURL,
                                       uniqueURLs: prepared.uniqueURLs, home: currentHome,
                                       likedIDs: self.account.music?.likedIDs ?? [],
                                       likedAt: self.account.music?.likedAt ?? [:])
            }
            return
        }
        cachedSongsPublishTask?.cancel()
        cachedSongsPublishTask = nil
        cachedSongsGeneration &+= 1
        let grouped = OnlineSongProjector.groupByArtworkURL(values)
        commitCachedSongs(values, artworkByURL: grouped.byURL, uniqueURLs: grouped.uniqueURLs,
                          home: home, likedIDs: likedIDs, likedAt: likedAt)
    }

    private func commitCachedSongs(_ values: [NeteaseMusicSong],
                                   artworkByURL: [URL: [NeteaseMusicSong]],
                                   uniqueURLs: [URL],
                                   home: NeteaseHomeStore?,
                                   likedIDs: Set<Int64>,
                                   likedAt: [Int64: Date]) {
        projectedLikedIDs = likedIDs
        projectedLikedAt = likedAt
        artworkSongs = artworkByURL
        let revision = home?.sessionRevision
        let cachedCovers: [URL: URL]
        if let home {
            var resolved: [URL: URL] = [:]
            resolved.reserveCapacity(uniqueURLs.count)
            for remote in uniqueURLs {
                if let file = home.cachedArtworkURL(remote: remote) { resolved[remote] = file }
            }
            cachedCovers = resolved
        } else {
            cachedCovers = [:]
        }
        var songs: [LibrarySongItem] = []
        songs.reserveCapacity(values.count)
        var liveIDs = Set<Int64>()
        liveIDs.reserveCapacity(values.count)
        for value in values {
            liveIDs.insert(value.id)
            let isLiked = likedIDs.contains(value.id)
            let likedDate = likedAt[value.id]
            let coverURL = value.artworkURL.flatMap { cachedCovers[$0] }
            let item = projectionCache.project(
                value,
                owner: owner,
                revision: revision,
                isFavorite: isLiked,
                favoriteAddedAt: likedDate,
                cachedArtworkURL: coverURL
            ) {
                mapSong(value, cachedCovers: cachedCovers)
            }
            songs.append(item)
        }
        projectionCache.prune(keeping: liveIDs)
        if cachedSongs != songs {
            cachedSongs = songs
            cachedSongIndices = Dictionary(uniqueKeysWithValues: songs.indices.map { (songs[$0].id, $0) })
        }
        LocalLibrary.songLibrary.replaceExternalSongs(songs)
    }

    private func refreshRetainedArtwork(contentChanged: Bool = false) {
        guard let home = account.home, let owner, home.userID == account.profile?.userID else {
            retainedArtworkIDs = []; retainedArtworkSession = nil
            return
        }
        let ids = Set(LocalLibrary.playlistLibrary.playlists.filter { $0.sourceOwnerID == owner }.map(\.id))
        guard contentChanged || retainedArtworkSession != home.sessionRevision || retainedArtworkIDs != ids else { return }
        retainedArtworkIDs = ids
        retainedArtworkSession = home.sessionRevision
        Self.updateRetainedArtwork(in: LocalLibrary.playlistLibrary, home: home, owner: owner)
    }

    private func scheduleArtworkPublish(_ urls: Set<URL>) {
        guard !urls.isEmpty, let home = account.home, home.userID == account.profile?.userID else { return }
        let session = home.sessionRevision
        if artworkBatchSession != session {
            artworkPublishTask?.cancel()
            artworkPublishTask = nil
            pendingArtworkURLs.removeAll()
            artworkBatchSession = session
        }
        pendingArtworkURLs.formUnion(urls)
        guard artworkPublishTask == nil else { return }
        artworkPublishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            let batch = pendingArtworkURLs
            pendingArtworkURLs.removeAll(keepingCapacity: true)
            artworkPublishTask = nil
            guard account.home === home, home.sessionRevision == session else { return }
            publishArtwork(batch)
        }
    }

    private func publishArtwork(_ urls: Set<URL>) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }) else { return }
        var songs: [String: LibrarySongItem] = [:]
        for remote in urls {
            for value in artworkSongs[remote] ?? [] {
                let item = makeSong(value)
                songs[item.id] = item
            }
        }
        var covers: [String: Artwork] = [:]
        for (id, value) in loaded {
            if id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? ""),
               let remote = home.cachedDetail(id: number)?.displayArtworkURL(ownerID: home.userID), urls.contains(remote) {
                let cover = artwork(remote)
                if value.0.artwork != cover { loaded[id]?.0.artwork = cover; covers[id] = cover }
            }
            if id.hasPrefix("home:daily:"), let remote = value.1.first?.artworkURL, urls.contains(remote) {
                let cover = artwork(remote)
                if value.0.artwork != cover { loaded[id]?.0.artwork = cover; covers[id] = cover }
            }
            for value in value.1 where value.artworkURL.map(urls.contains) == true {
                let item = makeSong(value)
                songs[item.id] = item
            }
        }
        // A download can finish before the asynchronous catalog index is published.
        if queueArtworkBindings?.revision != player.queueRevision {
            var bindings: [String: [LibrarySongItem]] = [:]
            for queued in player.queue {
                if let id = queued.artwork.loadID { bindings[id, default: []].append(queued) }
            }
            queueArtworkBindings = (player.queueRevision, bindings)
        }
        for remote in urls {
            let id = DeferredArtworkKey(domain: .home, session: home.sessionRevision, url: remote).rawValue
            guard let matches = queueArtworkBindings?.songs[id],
                  let file = home.cachedArtworkURL(remote: remote) else { continue }
            for queued in matches where queued.onlineOwnerID == owner && queued.artwork.loadID == id {
                var replacement = queued
                replacement.artwork = .file(file)
                replacement.artworkURL = file
                songs[queued.id] = replacement
            }
        }
        player.updateArtwork(songs)
        feedPlaylistCovers.publish(filesFor: urls, session: home.sessionRevision) { self.artwork($0) }
        for url in urls {
            for resource in feedArtwork[url] ?? [] { resource.update(artwork(url)) }
        }
        for item in model.quickActions {
            let action = NeteaseHomeQuickAction(rawValue: item.action.rawValue)!
            if item.action == .similarSongs, Self.currentOnlineSongID(player.current, owner: owner) != nil {
                item.$artwork.update(player.current.artwork)
            } else if let url = home.quickActionArtwork(action), urls.contains(url) {
                item.$artwork.update(artwork(url))
            }
        }
        detailLibrary.updateArtwork(songs: songs, playlists: covers)
        if let owner {
            Self.updateRetainedArtwork(in: LocalLibrary.playlistLibrary, home: home, owner: owner, urls: urls, songs: songs)
        }
        for (id, replacement) in songs {
            if let index = cachedSongIndices[id] { cachedSongs[index].publishArtwork(from: replacement) }
        }
        LocalLibrary.songLibrary.updateOnlineArtwork(songs, source: "home")
    }
    static func updateRetainedArtwork(in library: PlaylistLibrary, home: NeteaseHomeStore, owner: String,
                                      urls: Set<URL>? = nil, songs: [String: LibrarySongItem] = [:]) {
        guard home.userID.map(String.init) == owner else { return }
        let prefix = "netease-playlist:\(owner):"
        var covers: [String: Artwork] = [:]
        var songImages = songs
        for item in library.playlists where item.sourceOwnerID == owner && item.id.hasPrefix(prefix) {
            guard let number = Int64(item.id.dropFirst(prefix.count)), let detail = home.cachedDetail(id: number) else { continue }
            let playlistMatches = detail.displayArtworkURL(ownerID: home.userID).map { urls?.contains($0) != false } == true
            let songMatches = detail.songs.contains { $0.artworkURL.map { urls?.contains($0) != false } == true }
            guard playlistMatches || songMatches else { continue }
            if let remote = detail.displayArtworkURL(ownerID: home.userID), urls?.contains(remote) != false {
                if let file = home.cachedArtworkURL(remote: remote) { covers[item.id] = .file(file) }
                else if urls?.contains(remote) == true {
                    covers[item.id] = .deferred(id: "home:\(home.sessionRevision.uuidString):\(remote.absoluteString)", placeholder: .playlist)
                }
            }
            let current = Dictionary(library.songs(in: item.id).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in detail.songs {
                guard let remote = value.artworkURL, urls?.contains(remote) != false,
                      var song = current["netease:\(owner):\(value.id)"] else { continue }
                let file = home.cachedArtworkURL(remote: remote)
                guard file != nil || urls?.contains(remote) == true else { continue }
                song.artwork = file.map(Artwork.file) ?? .deferred(id: "home:\(home.sessionRevision.uuidString):\(remote.absoluteString)", placeholder: .missing)
                song.artworkURL = file
                song.artworkData = nil; song.artworkBackdrop = nil
                songImages[song.id] = song
            }
        }
        if !songImages.isEmpty || !covers.isEmpty {
            library.updateArtwork(songs: songImages, playlists: covers)
        }
    }

    private func feedPlaylistArtwork(id: Int64, home: NeteaseHomeStore?) -> Artwork {
        if let home, let detail = home.cachedDetail(id: id),
           detail.playlist.creatorID == home.userID || detail.orderedTrackIDs.isEmpty || detail.nextOffset > 0 {
            return artwork(detail.displayArtworkURL(ownerID: home.userID))
        }
        return Self.playlistArtwork(id: id, home: home)
    }

    private func publishFeed() {
        let home = account.home
        let matches = home?.userID == account.profile?.userID
        let displayFeed = home.map { NeteaseHomeFeed(blocks: $0.displayFeedBlocks, hasMore: nil, cursor: nil) }
        let issues = matches ? Self.feedIssues(home) : []
        let sections = Self.feedSections(matches ? displayFeed : nil, issues: issues, artwork: { self.artwork($0) }, playlistArtwork: { self.feedPlaylistArtwork(id: $0, home: home) })
        let session = matches ? home?.sessionRevision : nil
        if feedPlaylistCovers.session != session || model.sections != sections { model.sections = sections }
        feedPlaylistCovers = HomeFeedPlaylistCovers(session: session)
        feedArtwork = [:]
        if matches, let home {
            for block in home.displayFeedBlocks {
                guard let section = model.sections.first(where: { $0.id == block.id }) else { continue }
                for resource in block.resources {
                    guard let item = section.items.first(where: { $0.id == resource.id }) else { continue }
                    if case .navigate(.playlist) = item.action, let id = resource.numericID {
                        let remote = home.cachedDetail(id: id)?.displayArtworkURL(ownerID: home.userID)
                        feedPlaylistCovers.register(item.$artwork, playlist: id, remote: remote)
                    } else if let remote = resource.artworkURL {
                        feedArtwork[remote, default: []].append(item.$artwork)
                    }
                }
            }
        }
        if model.feedIssues != issues { model.feedIssues = issues }
        publishQuickActions()
    }

    static func feedIssues(_ home: NeteaseHomeStore?) -> [HomeFeedIssue] {
        guard let home else { return [] }
        let sources: [(NeteaseHomeStore.RetrySource, String, String?, String?)] = [
            (.feed, "推荐内容", nil, home.feedError),
            (.recommendations, "推荐歌单", NeteaseHomeCategory.recommendedPlaylists.rawValue, home.recommendationsError),
            (.charts, "排行榜", NeteaseHomeCategory.charts.rawValue, home.chartsError),
            (.followedReleases, "艺人新动向", NeteaseHomeCategory.followedArtists.rawValue, home.followedReleasesError),
            (.newSongs, "新歌速递", NeteaseHomeCategory.newSongs.rawValue, home.newSongsError)
        ]
        return sources.compactMap { source, title, sectionID, message in
            guard let message else { return nil }
            return HomeFeedIssue(id: source.rawValue, title: title, message: message, sectionID: sectionID,
                                 isRetrying: home.refreshingSources.contains(source))
        }
    }

    static func feedSections(_ feed: NeteaseHomeFeed?, issues: [HomeFeedIssue] = [], artwork: (URL?) -> Artwork, playlistArtwork: ((Int64) -> Artwork)? = nil) -> [HomeContentSection] {
        let sections: [HomeContentSection] = (feed?.blocks ?? []).compactMap { block in
            guard let category = block.category, !block.title.isEmpty else { return nil }
            var seen = Set<String>()
            let items: [HomeContentItem] = (block.creatives ?? []).flatMap { creative in
                let resources = creative.resources ?? []
                let group = creative.creativeId ?? resources.first?.id
                return resources.compactMap { resource -> HomeContentItem? in
                    guard resource.isSupportedMusicResource, !seen.contains(resource.id),
                          let id = resource.numericID, !resource.title.isEmpty else { return nil }
                    if [.likedSongs, .songRecommendations].contains(category) {
                        guard let song = resource.song, resource.resourceType == "song" else { return nil }
                        seen.insert(resource.id)
                        return .init(id: resource.id, title: song.title, subtitle: song.artist,
                                     artwork: artwork(resource.artworkURL), groupID: group, action: .playSong)
                    }
                    switch resource.resourceType {
                    case "song":
                        guard let song = resource.song, category == .newSongs else { return nil }
                        seen.insert(resource.id)
                        return .init(id: resource.id, title: song.title, subtitle: song.artist,
                                     artwork: artwork(resource.artworkURL), groupID: group, action: .playSong)
                    case "album":
                        seen.insert(resource.id)
                        return .init(id: resource.id, title: resource.title, subtitle: resource.uiElement?.subTitle?.title ?? "",
                                     artwork: artwork(resource.artworkURL), action: .navigate(.album("catalog:album:\(id)")))
                    case "artist":
                        seen.insert(resource.id)
                        return .init(id: resource.id, title: resource.title, subtitle: resource.uiElement?.subTitle?.title ?? "",
                                     artwork: artwork(resource.artworkURL), action: .navigate(.artist("catalog:artist:\(id)")))
                    case "list", "playlist":
                        seen.insert(resource.id)
                        return .init(id: resource.id, title: resource.title, subtitle: "",
                                     artwork: playlistArtwork?(id) ?? artwork(resource.artworkURL), action: .navigate(.playlist("home:playlist:\(id)")))
                    default: return nil
                    }
                }
            }
            guard !items.isEmpty else { return nil }
            return .init(id: block.id, title: block.title,
                         kind: [.likedSongs, .songRecommendations].contains(category) ? .songs : .covers, items: items)
        }
        return NeteaseHomeCategory.allCases.compactMap { category in
            if let section = sections.first(where: { $0.id == category.rawValue }) { return section }
            guard let issue = issues.first(where: { $0.sectionID == category.rawValue }) else { return nil }
            return .init(id: category.rawValue, title: issue.title, kind: .covers, items: [])
        }
    }

    static func feedPlayback(_ feed: NeteaseHomeFeed?, section: String, item: String) -> (songs: [NeteaseMusicSong], index: Int, title: String)? {
        guard let block = feed?.blocks.first(where: { $0.id == section }),
              let category = block.category, [.likedSongs, .songRecommendations, .newSongs].contains(category),
              let group = block.creatives?.first(where: { ($0.resources ?? []).contains { $0.id == item } }),
              let target = group.resources?.first(where: { $0.id == item })?.song else { return nil }
        var seen = Set<Int64>()
        let songs = (group.resources ?? []).filter(\.isSupportedMusicResource).compactMap(\.song).filter { seen.insert($0.id).inserted }
        guard let index = songs.firstIndex(where: { $0.id == target.id }) else { return nil }
        return (songs, index, block.title)
    }

    private func playFeed(section: String, item: String) {
        let feed = account.home.map { NeteaseHomeFeed(blocks: $0.displayFeedBlocks, hasMore: nil, cursor: nil) }
        guard let selection = Self.feedPlayback(feed, section: section, item: item) else { return }
        cancelPendingPlayback()
        pendingQuickAction = nil
        guard let userID = account.profile?.userID, account.validationState == .valid,
              account.home?.userID == userID, account.music?.userID == userID else {
            pendingFeedPlayback = selection
            showsLogin = true
            return
        }
        player.requestPlay(selection.songs.map(mapSong), startingAt: selection.index, from: selection.title)
    }

    private func updateLikedSongs() {
        guard let userID = account.profile?.userID, let home = account.home, let music = account.music,
              home.userID == userID, music.userID == userID else { return }
        let playlist = music.playlists.first { $0.isFavorites && $0.creatorID == userID }
        home.updateLikedSongs(playlistID: playlist?.id, songs: music.likedIDs.compactMap { music.songs[$0] },
                              likedAt: music.likedAt, likedIDs: music.likedIDs,
                              orderedLikedIDs: playlist.flatMap { music.playlistTracks[$0.id] } ?? [])
    }

    static func currentOnlineSongID(_ song: LibrarySongItem, owner: String?) -> Int64? {
        guard let owner, song.onlineOwnerID == owner, song.unavailabilityReason == nil,
              let id = song.onlineSongID, id > 0 else { return nil }
        return id
    }

    private func publishQuickActions(artworkOnly: Bool = false) {
        let home = account.home
        let matches = home?.userID == account.profile?.userID
        let items = HomeQuickAction.allCases.map { action -> HomeQuickActionItem in
            let businessAction = NeteaseHomeQuickAction(rawValue: action.rawValue)!
            var cover = matches ? home?.quickActionArtwork(businessAction).map { artwork($0) } : nil
            let subtitle: String
            switch action {
            case .dailySongs: subtitle = "每天为你挑选的音乐"
            case .hotSongs: subtitle = "网易云音乐热歌榜"
            case .heartMode: subtitle = "从你喜欢的音乐开始"
            case .privateRadar: subtitle = "发现与你合拍的歌单"
            case .privateRoaming: subtitle = "听听接下来会遇见什么"
            case .similarSongs:
                if Self.currentOnlineSongID(player.current, owner: owner) != nil {
                    subtitle = "根据《\(player.current.title)》推荐"
                    cover = player.current.artwork
                } else { subtitle = "从当前播放的网易云歌曲出发" }
            }
            return .init(action: action, artwork: cover, subtitle: subtitle)
        }
        if artworkOnly {
            for item in model.quickActions {
                if let replacement = items.first(where: { $0.id == item.id }) { item.$artwork.update(replacement.artwork) }
            }
        } else if model.quickActions != items { model.quickActions = items }
        let states: [HomeQuickAction: HomeQuickActionState] = Dictionary(uniqueKeysWithValues:
            (matches ? home?.quickActionStates ?? [:] : [:]).compactMap { key, value in
                guard let action = HomeQuickAction(rawValue: key.rawValue) else { return nil }
                let state: HomeQuickActionState
                switch value {
                case .loading: state = .loading
                case .failed(let message): state = .failed(message)
                }
                return (action, state)
            })
        if model.quickActionStates != states { model.quickActionStates = states }
    }

    func requestQuickAction(_ action: HomeQuickAction) {
        cancelPendingPlayback()
        pendingFeedPlayback = nil
        pendingQuickAction = nil
        model.quickActionRoute = nil
        model.quickActionPreview = nil
        let ready = (account.profile?.userID).map { userID in
            account.validationState == .valid && account.home?.userID == userID && account.music?.userID == userID
        } ?? false
        if action != .hotSongs && !ready {
            pendingQuickAction = action
            showsLogin = true
            return
        }
        if !action.opensDetail { LibraryHaptics.impact() }
        runQuickAction(action)
    }

    private func resumePendingQuickAction() {
        guard let action = pendingQuickAction, let userID = account.profile?.userID,
              account.validationState == .valid, account.home?.userID == userID, account.music?.userID == userID else { return }
        pendingQuickAction = nil
        completingLogin = showsLogin
        showsLogin = false
        runQuickAction(action)
    }

    private func runQuickAction(_ action: HomeQuickAction) {
        guard let home = account.home, home.userID == account.profile?.userID else { return }
        let revision = home.sessionRevision, userID = account.profile?.userID
        let playbackID = playbackRevision
        let currentSongID = Self.currentOnlineSongID(player.current, owner: userID.map(String.init))
        let businessAction = NeteaseHomeQuickAction(rawValue: action.rawValue)!
        let displayedArtwork = model.quickActions.first(where: { $0.action == action })?.artwork
        playbackTask = Task { [weak self] in
            defer {
                if let self, self.playbackRevision == playbackID { self.playbackTask = nil }
            }
            do {
                try Task.checkCancellation()
                let result = try await home.performQuickAction(businessAction, currentSongID: currentSongID)
                guard let self, !Task.isCancelled, self.playbackRevision == playbackID, home.sessionRevision == revision,
                      self.account.profile?.userID == userID, home.userID == userID else { return }
                switch result {
                case .daily(let snapshot):
                    guard let userID else { return }
                    let route = LibraryRoute.playlist("home:daily:\(userID):\(snapshot.id)")
                    let cover = displayedArtwork ?? self.artwork(snapshot.songs.first?.artworkURL)
                    self.publishNavigation(.init(route: route, ownerID: String(userID), title: "每日推荐", subtitle: snapshot.date, artwork: cover))
                case .playlist(let playlist):
                    let preview = LibraryNavigationPreview(route: .playlist("home:playlist:\(playlist.id)"), ownerID: userID.map(String.init),
                        title: playlist.title, subtitle: playlist.creator,
                        artwork: self.model.quickActions.first(where: { $0.action == action })?.artwork ?? self.artwork(playlist.artworkURL))
                    self.publishNavigation(preview)
                case .songs(let songs):
                    guard !songs.isEmpty, userID != nil else { return }
                    self.player.requestPlay(songs.map(self.mapSong), from: action.title, shuffled: false)
                case .roaming(let id, let songs):
                    guard !songs.isEmpty, let userID else { return }
                    let continuation = PlaybackQueueContinuation(ownerID: String(userID))
                    self.player.requestPlay(songs.map(self.mapSong), from: action.title, shuffled: false, continuation: continuation, onStarted: { [weak self, weak selectedHome = home] in
                        guard let self, let selectedHome, selectedHome.sessionRevision == revision else { return }
                        selectedHome.consumeRoamingBatch(id: id)
                        self.beginRoamingContinuation(continuation)
                    })
                }
            } catch {}
        }
    }

    private func publishNavigation(_ preview: LibraryNavigationPreview) {
        prepareNavigation(preview)
        model.quickActionPreview = preview
        model.quickActionRoute = preview.route
    }

    func prepareNavigation(_ preview: LibraryNavigationPreview) {
        guard preview.ownerID == owner, case .playlist(let id) = preview.route, id.hasPrefix("home:") else { return }
        var item = detailLibrary.playlist(id) ?? LibraryPlaylistItem(id: id, title: preview.title, artwork: preview.artwork)
        item.title = preview.title
        if let subtitle = preview.subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.subtitle = subtitle }
        item.artwork = preview.artwork
        item.sourceOwnerID = owner
        item.isReadOnlyContent = true
        detailLibrary.setExternalCollection(item: item, songs: detailLibrary.songs(in: id), error: detailLibrary.onlineErrors[id])
        if loaded[id] != nil { loaded[id]?.0 = item }
    }

    private func beginRoamingContinuation(_ continuation: PlaybackQueueContinuation) {
        guard player.continuation == continuation else { return }
        roamingGeneration = UUID()
        roamingFill?.cancel()
        roamingFill = nil
        roamingAdvance = false
        roamingPlaybackEnded = false
        replenishRoaming(continuation: continuation, shouldAdvance: false, playbackEnded: false)
    }

    private func replenishRoaming(continuation: PlaybackQueueContinuation, shouldAdvance: Bool, playbackEnded: Bool) {
        guard player.continuation == continuation, continuation.ownerID == owner,
              let home = account.home, home.userID.map(String.init) == continuation.ownerID else { return }
        let remaining = max(0, player.queue.count - player.currentIndex - 1)
        guard remaining <= 1 else { return }
        if shouldAdvance && remaining == 0 {
            roamingAdvance = true
            roamingPlaybackEnded = roamingPlaybackEnded || playbackEnded
        }
        guard roamingFill == nil else { return }
        let generation = roamingGeneration
        roamingFill = Task { [weak self] in await self?.fillRoaming(continuation: continuation, generation: generation) }
    }

    private func fillRoaming(continuation: PlaybackQueueContinuation, generation: UUID) async {
        var scheduleNext = false
        defer {
            if roamingGeneration == generation { roamingFill = nil }
            if scheduleNext, roamingGeneration == generation {
                roamingFill = Task { [weak self] in await self?.fillRoaming(continuation: continuation, generation: generation) }
            }
        }
        guard let home = account.home, player.continuation == continuation,
              continuation.ownerID == owner else { roamingAdvance = false; return }
        let known = Set(player.queue.map(\.id))
        let revision = home.sessionRevision
        do {
            let songs = try await home.nextRoamingSongs()
            try Task.checkCancellation()
            guard roamingGeneration == generation else { return }
            guard player.continuation == continuation, account.home === home, home.sessionRevision == revision,
                  account.profile?.userID == home.userID else {
                roamingAdvance = false
                roamingPlaybackEnded = false
                return
            }
            let mapped = songs.map(mapSong).filter { !known.contains($0.id) }
            let advance = roamingAdvance && player.next == nil
            let ended = roamingPlaybackEnded
            roamingAdvance = false
            roamingPlaybackEnded = false
            guard !mapped.isEmpty else {
                if advance && ended { player.isPlaying = false }
                return
            }
            let index = player.currentIndex
            player.appendContinuing(mapped)
            retainReferencedSongs(adding: songs)
            publish()
            if advance, player.currentIndex == index, player.queue.indices.contains(index + 1) {
                player.select(index + 1)
            }
            let remaining = player.queue.count - player.currentIndex - 1
            scheduleNext = remaining <= 1 && player.continuation == continuation
        } catch {
            let advance = roamingAdvance && player.next == nil && roamingGeneration == generation
                && player.continuation == continuation
            let ended = roamingPlaybackEnded
            if roamingGeneration == generation {
                roamingAdvance = false
                roamingPlaybackEnded = false
            }
            if advance && ended { player.isPlaying = false }
        }
    }

    private func mapSong(_ song: NeteaseMusicSong) -> LibrarySongItem {
        mapSong(song, cachedCovers: nil)
    }

    private func mapSong(_ song: NeteaseMusicSong, cachedCovers: [URL: URL]?) -> LibrarySongItem {
        let item = makeSong(song, cachedCovers: cachedCovers)
        return item.retainingArtwork(from: LocalLibrary.songLibrary.song(id: item.id))
    }

    private func makeSong(_ song: NeteaseMusicSong, cachedCovers: [URL: URL]? = nil) -> LibrarySongItem {
        let id = OnlineSongIdentity.format(ownerID: owner, guestPrefix: "home-guest", song: song.id)
        let url = song.artworkURL.flatMap { cachedCovers?[$0] ?? account.home?.cachedArtworkURL(remote: $0) }
        return OnlineSongProjector.makeSong(
            song,
            id: id,
            artwork: artwork(song.artworkURL, placeholder: .missing, cachedCovers: cachedCovers),
            artworkURL: url,
            isFavorite: account.music?.likedIDs.contains(song.id) == true,
            favoriteAddedAt: account.music?.likedAt[song.id]
        )
    }
    private func syncedPlaylistMetadata(for id: String, item: LibraryPlaylistItem) -> LibraryPlaylistItem {
        guard case .homePlaylist(let number) = PlaylistRouteIdentity(id) else { return item }
        var item = item
        if let owner {
            let retained = LocalLibrary.playlistLibrary.playlist(PlaylistRouteIdentity.accountID(owner: owner, playlistID: number))
            item.isFavorite = retained?.isFavorite ?? false
            item.isPinned = retained?.isPinned ?? false
        }
        item.isSubscribed = isPlaylistSubscribed(number)
        return item
    }
    private func syncOpenCollectionStates() {
        for (id, value) in loaded {
            let updated = syncedPlaylistMetadata(for: id, item: value.0)
            guard updated != value.0 else { continue }
            loaded[id]?.0 = updated
            detailLibrary.setExternalCollection(item: updated, songs: detailLibrary.songs(in: id), error: detailLibrary.onlineErrors[id])
        }
    }
    private func updateDetail(_ id: String, item: LibraryPlaylistItem, songs: [NeteaseMusicSong], clearError: Bool = false) {
        let item = syncedPlaylistMetadata(for: id, item: item)
        detailLibrary.setExternalCollection(item: item, songs: songs.map(mapSong), error: clearError ? nil : detailLibrary.onlineErrors[id])
    }
    private func applyDetail(_ detail: NeteasePlaylistDetail, id: String, clearError: Bool) {
        let cover = Self.playlistArtwork(id: detail.playlist.id, home: account.home)
        var item = LibraryPlaylistItem(id: id, title: detail.playlist.title, artwork: cover, sourceOwnerID: owner, subtitle: detail.playlist.creator)
        item.isReadOnlyContent = true
        loaded[id] = (item, detail.songs)
        detailLibrary.setPlaylistDetailReceived(detail.hasInitialPage, for: id)
        detailLibrary.setOnlineHasMore(id, !detail.isComplete, totalCount: detail.orderedTrackIDs.count)
        updateDetail(id, item: item, songs: detail.songs, clearError: clearError)
    }
    private func restoreCachedDetail(_ id: String) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }),
              case .homePlaylist(let number) = PlaylistRouteIdentity(id),
              let detail = home.cachedDetail(id: number) else { return }
        applyDetail(detail, id: id, clearError: false)
    }
    private func load(_ id: String, complete: Bool = false, loadMore: Bool = false, force: Bool = false) async throws {
        guard let home = account.home else { throw NeteaseAccountError.invalidResponse }
        let homeOwner = home.userID
        let profileOwner = account.profile?.userID
        guard homeOwner == profileOwner, owner == profileOwner.map(String.init) else { throw CancellationError() }
        restoreCachedDetail(id)
        do {
            switch PlaylistRouteIdentity(id) {
            case .homePlaylist(let number):
                let detail: NeteasePlaylistDetail
                if complete { detail = try await home.completeDetail(id: number) }
                else if loadMore { detail = try await home.loadMoreDetail(id: number) }
                else { detail = try await home.detail(id: number, force: force) }
                try Task.checkCancellation()
                guard home.userID == homeOwner, account.profile?.userID == profileOwner,
                      owner == profileOwner.map(String.init) else { throw CancellationError() }
                applyDetail(detail, id: id, clearError: true)
            case .daily(let dailyOwner, let date) where dailyOwner == owner:
                guard let snapshot = try await home.loadDailySnapshot(id: date) else {
                    throw NeteaseAccountError.invalidResponse
                }
                let cover = snapshot.songs.first?.artworkURL.map { artwork($0) }
                    ?? detailLibrary.playlist(id)?.artwork ?? .playlist
                var item = LibraryPlaylistItem(id: id, title: "每日推荐", artwork: cover, sourceOwnerID: owner, subtitle: snapshot.date)
                item.isReadOnlyContent = true
                detailLibrary.setPlaylistDetailReceived(true, for: id)
                loaded[id] = (item, snapshot.songs)
                updateDetail(id, item: item, songs: snapshot.songs, clearError: true)
            default:
                throw NeteaseAccountError.invalidResponse
            }
            syncCachedSongs(home.cachedSongs, home: home, preferAsync: false)
        } catch {
            guard !Task.isCancelled, home.userID == homeOwner, account.profile?.userID == profileOwner,
                  owner == profileOwner.map(String.init) else { throw CancellationError() }
            if !(error is CancellationError), let item = detailLibrary.playlist(id) {
                detailLibrary.setExternalCollection(item: item, songs: detailLibrary.songs(in: id), error: error.localizedDescription)
            }
            throw error
        }
    }
    func destination(for route: LibraryRoute) -> AnyView? {
        guard case .playlist(let id) = route else { return nil }
        let routeIdentity = PlaylistRouteIdentity(id)
        guard routeIdentity.isHomeRoute else { return nil }
        var placeholder = LibraryPlaylistItem(id: id, title: {
            if case .daily = routeIdentity { return "每日推荐" }
            return "播放列表"
        }(), artwork: .playlist)
        placeholder.isReadOnlyContent = true
        if case .homePlaylist(let number) = routeIdentity {
            placeholder.isSubscribed = isPlaylistSubscribed(number)
        }
        if detailLibrary.playlist(id) == nil { detailLibrary.setExternalCollection(item: placeholder, songs: []) }
        restoreCachedDetail(id)
        detailLibrary.unsubscribeOnlinePlaylist = { [weak self] targetID in
            self?.changeCollection(targetID, subscribed: false)
        }
        var actions = ExternalPlaylistActions(addSongs: { [weak self] in
            guard let self else { return }
            self.withCompleteCollection(id) { songs in
                LocalLibrary.playlistLibrary.pendingAddition = .init(songs: songs)
            }
        })
        if case .homePlaylist = routeIdentity {
            actions.toggleFavorite = { [weak self] in self?.retain(id, action: .favorite) }
            actions.togglePin = { [weak self] in self?.retain(id, action: .pin) }
            actions.moveToFolder = { [weak self] in self?.retain(id, action: .folder) }
            actions.collect = { [weak self] in self?.changeCollection(id, subscribed: true) }
        }
        var collection = LocalLibrary.menuActions
        collection.defersQueueNotice = true
        collection.play = { [weak self] _, shuffled in self?.requestPlayback(id, songID: nil, shuffled: shuffled) }
        collection.playNext = { [weak self] _ in self?.withCompleteCollection(id) { [weak self] in self?.player.insertNext($0); LocalLibrary.toasts.show(.playingNext) } }
        collection.playLater = { [weak self] _ in self?.withCompleteCollection(id) { [weak self] in self?.player.appendLater($0); LocalLibrary.toasts.show(.addedToQueue) } }
        var songs = LocalLibrary.songActions(for: route)
        songs.defersQueueNotice = true
        songs.play = { [weak self] list, index, _ in
            guard list.indices.contains(index) else { return }
            let target = list[index]
            guard let songID = target.onlineSongID ?? LocalLibrary.catalog.downloadedOnlineSongID?(target.id) else { return }
            self?.requestPlayback(id, songID: songID, shuffled: false)
        }
        songs.playNext = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.insertNext([song]); LocalLibrary.toasts.show(.playingNext) }
        songs.playLater = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.appendLater([song]); LocalLibrary.toasts.show(.addedToQueue) }
        songs.addToPlaylist = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; LocalLibrary.playlistLibrary.pendingAddition = .init(songs: [song]) }
        songs.toggleFavorite = { [weak self] song in self?.setOnlineLiked(song, liked: !song.isFavorite, playsSuccessHaptic: !song.isFavorite) }
        songs.removeFromFavorites = { [weak self] song in self?.setOnlineLiked(song, liked: false, playsSuccessHaptic: false) }
        return AnyView(HomeCollectionDetailView(playlistID: id, library: detailLibrary, actions: actions,
            onAppear: { [weak self] in self?.detailAppeared(id) },
            onDisappear: { [weak self] in self?.detailDisappeared(id) })
            .environment(\.collectionMenuActions, collection).environment(\.songMenuActions, songs))
    }

    private func setOnlineLiked(_ song: LibrarySongItem, liked: Bool, playsSuccessHaptic: Bool) {
        guard let owner,
              let number = song.onlineSongID ?? LocalLibrary.catalog.downloadedOnlineSongID?(song.id) else {
            showsLogin = true
            return
        }
        Task { [weak self] in
            guard let self, self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                  let music = self.account.music, music.userID.map(String.init) == owner else { return }
            let revision = music.sessionRevision
            do {
                try await music.setLiked(songID: number, liked: liked)
                guard revision == music.sessionRevision, self.owner == owner,
                      self.account.profile.map({ String($0.userID) }) == owner else { return }
                if playsSuccessHaptic { LibraryHaptics.success() }
                LocalLibrary.toasts.show(liked ? .favorited : .unfavorited)
            }
            catch is CancellationError {} catch {
                guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner else { return }
                LocalLibrary.toasts.show(.error(error.localizedDescription))
            }
        }
    }

    private func withCompleteCollection(_ id: String, action: @escaping @MainActor ([LibrarySongItem]) -> Void) {
        guard let owner else { showsLogin = true; return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.load(id, complete: true)
                guard !Task.isCancelled, self.owner == owner,
                      self.account.profile.map({ String($0.userID) }) == owner else { return }
                action(self.detailLibrary.songs(in: id))
            } catch is CancellationError {} catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
    }
    private func isPlaylistSubscribed(_ id: Int64) -> Bool {
        guard let owner, account.music?.userID.map(String.init) == owner else { return false }
        return account.music?.playlists.contains { $0.id == id && $0.isSubscribed == true } == true
    }

    private func syncCollectedPlaylists() {
        syncOpenCollectionStates()
    }

    private func changeCollection(_ id: String, subscribed: Bool) {
        guard owner != nil,
              OnlineLibraryIntegration.changePlaylistSubscription(
                  id,
                  subscribed: subscribed,
                  account: account,
                  onSubscribedChanged: { [weak self] in self?.syncCollectedPlaylists() }
              ) else {
            showsLogin = true
            return
        }
    }

    private enum RetainAction { case favorite, pin, folder }
    private func retain(_ id: String, action: RetainAction) {
        guard let owner, case .homePlaylist(let number) = PlaylistRouteIdentity(id) else { showsLogin = true; return }
        Task { [weak self] in
            guard let self, self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                  self.account.home?.userID.map(String.init) == owner, self.account.music?.userID.map(String.init) == owner else { return }
            do {
                try await self.load(id, complete: true)
                guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner, let detail = self.detailLibrary.playlist(id) else { return }
                let stableID = PlaylistRouteIdentity.accountID(owner: owner, playlistID: number)
                var item = LocalLibrary.playlistLibrary.playlist(stableID) ?? LibraryPlaylistItem(id: stableID, title: detail.title, artwork: detail.artwork, sourceOwnerID: owner, subtitle: detail.subtitle)
                item.sourceOwnerID = owner
                LocalLibrary.playlistLibrary.retainOnlinePlaylist(item, songs: self.detailLibrary.songs(in: id))
                withAnimation {
                    switch action {
                    case .favorite: LocalLibrary.playlistLibrary.toggleFavorite(stableID)
                    case .pin: LocalLibrary.playlistLibrary.togglePin(stableID)
                    case .folder: LocalLibrary.playlistLibrary.pendingMove = LocalLibrary.playlistLibrary.playlist(stableID)
                    }
                }
                if let retained = LocalLibrary.playlistLibrary.playlist(stableID) {
                    if var value = self.loaded[id] {
                        value.0.isFavorite = retained.isFavorite; value.0.isPinned = retained.isPinned
                        self.loaded[id] = value; self.updateDetail(id, item: value.0, songs: value.1)
                    }
                    switch action {
                    case .favorite:
                        LibraryHaptics.success()
                        LocalLibrary.toasts.show(retained.isFavorite ? .favorited : .unfavorited)
                    case .pin:
                        LibraryHaptics.success()
                        LocalLibrary.toasts.show(retained.isPinned ? .pinned : .unpinned)
                    case .folder: break
                    }
                }
            } catch is CancellationError {} catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
    }

    func detailAppeared(_ id: String) {
        if let activeRoute, activeRoute != id { cancelPendingPlayback() }
        activeRoute = id
    }
    func detailDisappeared(_ id: String) {
        guard activeRoute == id, !showsLogin else { return }
        activeRoute = nil
        cancelPendingPlayback()
    }
    func loginDismissed() {
        pendingFeedPlayback = nil
        if completingLogin { completingLogin = false; return }
        pendingQuickAction = nil
        cancelPendingPlayback()
    }
    func requestPlayback(_ id: String, songID: Int64?, shuffled: Bool) {
        cancelPendingPlayback()
        pendingQuickAction = nil
        pendingFeedPlayback = nil
        pending = Pending(route: id, songID: songID, shuffled: shuffled)
        if owner == nil { showsLogin = true } else { resumePendingPlayback() }
    }
    func cancelPendingPlayback() {
        playbackRevision = UUID(); playbackTask?.cancel(); playbackTask = nil; pending = nil
    }
    func resumePendingPlayback() {
        guard let request = pending, let userID = account.profile?.userID,
              account.validationState == .valid, account.home?.userID == userID, account.music?.userID == userID,
              activeRoute == request.route else { return }
        let owner = String(userID)
        pending = nil
        completingLogin = showsLogin
        showsLogin = false
        let revision = playbackRevision
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.load(request.route, complete: true)
                guard !Task.isCancelled, revision == self.playbackRevision, self.account.profile.map({ String($0.userID) }) == owner, self.activeRoute == request.route,
                      self.account.home?.userID == userID, self.account.music?.userID == userID else { return }
                let list = self.detailLibrary.songs(in: request.route)
                let routeIdentity = PlaylistRouteIdentity(request.route)
                let daily: Bool
                let referenceID: String
                switch routeIdentity {
                case .daily(_, let date):
                    daily = true
                    referenceID = date
                case .homePlaylist(let id):
                    daily = false
                    referenceID = String(id)
                default:
                    daily = false
                    referenceID = request.route.split(separator: ":").last.map(String.init) ?? request.route
                }
                let reference = PlaybackCollectionReference(kind: daily ? .daily : .onlinePlaylist, id: referenceID, ownerID: owner, title: self.detailLibrary.playlist(request.route)?.title ?? "播放列表")
                if let songID = request.songID {
                    guard let index = list.firstIndex(where: { $0.onlineSongID == songID }) else { throw NeteaseAccountError.invalidResponse }
                    self.player.requestPlay(list, startingAt: index, from: reference.title, collection: reference)
                }
                else { self.player.requestPlay(list, from: reference.title, shuffled: request.shuffled, collection: reference) }
            } catch is CancellationError {} catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
    }
}
