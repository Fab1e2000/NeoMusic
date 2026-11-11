import SwiftUI
import Observation

@MainActor @Observable final class HomeMusicIntegration {
    let model = HomeContentModel()
    let history: PlaybackCollectionHistory
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
    private var owner: String?
    private var pendingFeedPlayback: (songs: [NeteaseMusicSong], index: Int, title: String)?
    private(set) var pendingQuickAction: HomeQuickAction?
    @ObservationIgnored private var artworkSongs: [URL: [NeteaseMusicSong]] = [:]
    @ObservationIgnored private var retainedArtworkIDs: Set<String> = []
    @ObservationIgnored private var retainedArtworkSession: UUID?
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
        history = PlaybackCollectionHistory(url: URL.applicationSupportDirectory.appendingPathComponent("home-playback-history.json"))
    }
    func connect() {
        guard !connected else { return }
        connected = true
        model.login = { [weak self] in self?.showsLogin = true }
        model.retryFeatured = { [weak self] in Task { await self?.account.home?.refresh() } }
        model.retryRecommendations = model.retryFeatured
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
        player.replenishQueue = { [weak self] continuation, advance, ended in
            self?.replenishRoaming(continuation: continuation, shouldAdvance: advance, playbackEnded: ended)
        }
        player.onCollectionPlaybackStarted = { [weak self] reference in
            self?.history.record(reference)
            if reference.kind == .localPlaylist { LocalLibrary.playlistLibrary.markPlayed(reference.id) }
            if reference.kind == .onlinePlaylist, let owner = reference.ownerID {
                let id = reference.id.hasPrefix("netease-playlist:") ? reference.id : "netease-playlist:\(owner):\(reference.id)"
                LocalLibrary.playlistLibrary.markPlayed(id)
            }
        }
        account.home?.onChange = { [weak self] in self?.publish() }
        account.home?.onDetailChange = { [weak self] in self?.publishDetail($0) }
        account.home?.onArtworkChange = { [weak self] in self?.publishArtwork($0) }
        detailLibrary.loadOnlinePlaylist = { [weak self] id in
            guard let self else { return }
            do {
                let retry = self.detailLibrary.onlineErrors[id] != nil
                try await self.load(id, loadMore: retry && self.detailLibrary.onlineHasMore.contains(id), force: retry)
            } catch { /* load publishes the retry error. */ }
        }
        detailLibrary.loadMoreOnlinePlaylist = { [weak self] id in
            do { try await self?.load(id, loadMore: true) } catch { /* load preserves the visible page. */ }
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
    func restore() async { await history.restore() }
    func flushHistory() async { await history.flush() }
    func flushHistoryForBackground() {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "SavePlaybackHistory") {
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
        Task {
            await history.flush()
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = account.profile
            _ = account.validationState
            _ = account.music?.userID
            _ = account.music?.likedIDs
            _ = account.music?.likedAt
            _ = account.music?.playlists
            // likedSongRevision, not the song dictionary: another playlist's page must not rebuild this feed.
            _ = account.music?.likedSongRevision
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        publish()
        syncCollectedPlaylists()
        refreshOpenCollectionFavorites()
    }

    /// 喜欢状态变了之后，正在看的歌单曲目要换成爱心或删除、下载。
    private func refreshOpenCollectionFavorites() {
        guard owner != nil, account.music?.userID.map(String.init) == owner else { return }
        for (id, value) in loaded {
            updateDetail(id, item: value.0, songs: value.1)
        }
    }
    private func observeCurrentSong() {
        withObservationTracking {
            _ = player.current
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCurrentSong() }
        }
        publishQuickActions()
    }
    private func observeRecent() {
        withObservationTracking {
            _ = LocalLibrary.playlistLibrary.playlists
            _ = LocalLibrary.songLibrary.songs
            _ = history.recent(for: owner)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRecent() }
        }
        refreshRetainedArtwork()
        updateRecent()
        for (id, value) in loaded where id.hasPrefix("home:playlist:") {
            guard let owner, let number = id.split(separator: ":").last else { continue }
            let retained = LocalLibrary.playlistLibrary.playlist("netease-playlist:\(owner):\(number)")
            var item = value.0
            item.isFavorite = retained?.isFavorite ?? false
            item.isPinned = retained?.isPinned ?? false
            if item != value.0 {
                loaded[id]?.0 = item
                detailLibrary.setExternalCollection(item: item, songs: detailLibrary.songs(in: id), error: detailLibrary.onlineErrors[id])
            }
        }
    }
    private func artwork(_ remote: URL?, placeholder: ArtworkPlaceholder = .playlist) -> Artwork {
        guard let remote, let home = account.home else { return placeholder == .playlist ? .playlist : .missing }
        if let file = home.cachedArtworkURL(remote: remote) { return .file(file) }
        return .deferred(id: "home:\(home.sessionRevision.uuidString):\(remote.absoluteString)", placeholder: placeholder)
    }
    func requestArtwork(for id: String) {
        guard let home = account.home, home.userID == account.profile?.userID else { return }
        let prefix = "home:\(home.sessionRevision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return }
        home.requestArtwork([url])
    }
    func cachedArtworkFile(for id: String) async -> URL? {
        guard let home = account.home, home.userID == account.profile?.userID, !Task.isCancelled else { return nil }
        let revision = home.sessionRevision, owner = home.userID
        let prefix = "home:\(revision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return nil }
        let file = await home.cachedArtworkFile(url)
        guard revision == home.sessionRevision, home.userID == owner,
              account.profile?.userID == owner, !Task.isCancelled else { return nil }
        return file
    }
    private func publish() {
        let currentOwner = account.profile.map { String($0.userID) }
        if owner != currentOwner {
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
            owner = currentOwner
            for id in detailLibrary.playlists.map(\.id) where id.hasPrefix("home:") {
                var item = LibraryPlaylistItem(id: id, title: "播放列表", artwork: .playlist, sourceOwnerID: currentOwner)
                item.isReadOnlyContent = true
                detailLibrary.setExternalCollection(item: item, songs: [])
                detailLibrary.setOnlineHasMore(id, false)
            }
            loaded = [:]
            cachedSongs = []
            if currentOwner == nil { cancelPendingPlayback() }
        }
        if model.navigationOwnerID != currentOwner { model.navigationOwnerID = currentOwner }
        updateLikedSongs()
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
        var featured: [HomeContentItem] = [.init(id: "favorites", title: "喜爱歌曲", subtitle: "你喜欢的音乐，都在这里。", artwork: .favorites, style: .favorites, action: .navigate(.playlist("favorites")))]
        if let daily = account.home?.daily, let owner, account.home?.userID == account.profile?.userID {
            featured.append(.init(id: "daily", title: "每日推荐", subtitle: "每天为你挑选的音乐。", artwork: artwork(daily.songs.first?.artworkURL), action: .navigate(.playlist("home:daily:\(owner):\(daily.id)"))))
        }
        if model.featured != featured { model.featured = featured }
        if model.featuredError != account.home?.dailyError { model.featuredError = account.home?.dailyError }
        if model.recommendationsError != account.home?.recommendationsError { model.recommendationsError = account.home?.recommendationsError }
        let recommendations: [HomeContentItem] = (account.home?.userID == account.profile?.userID ? account.home?.recommendations ?? [] : []).map {
            .init(id: String($0.id), title: $0.title, subtitle: $0.creator, artwork: artwork($0.artworkURL), action: .navigate(.playlist("home:playlist:\($0.id)")))
        }
        if model.recommendations != recommendations { model.recommendations = recommendations }
        updateRecent()
        for (id, value) in loaded { updateDetail(id, item: value.0, songs: value.1) }
        let values = account.home?.userID == account.profile?.userID ? account.home?.cachedSongs ?? [] : []
        artworkSongs = Dictionary(grouping: values.filter { $0.artworkURL != nil }, by: { $0.artworkURL! })
        let songs = values.map(mapSong)
        if cachedSongs != songs { cachedSongs = songs }
        LocalLibrary.songLibrary.replaceExternalSongs(songs)
        refreshRetainedArtwork(contentChanged: true)
    }

    private func publishDetail(_ number: Int64) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }),
              let detail = home.cachedDetail(id: number) else { return }
        let route = "home:playlist:\(number)"
        if detailLibrary.playlist(route) != nil { applyDetail(detail, id: route, clearError: true) }
        let values = home.cachedSongs
        artworkSongs = Dictionary(grouping: values.filter { $0.artworkURL != nil }, by: { $0.artworkURL! })
        let songs = values.map(mapSong)
        if cachedSongs != songs { cachedSongs = songs }
        LocalLibrary.songLibrary.replaceExternalSongs(songs)
        refreshRetainedArtwork(contentChanged: true)
        updateRecent()
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

    private func updateRecent() {
        let recent: [HomeContentItem] = history.recent(for: owner).compactMap { reference in
            let route: LibraryRoute
            let cover: Artwork
            switch reference.kind {
            case .favorites: route = .playlist("favorites"); cover = .favorites
            case .localAlbum:
                route = .album(reference.id)
                guard let item = LocalLibrary.albums.first(where: { $0.id == reference.id }) else { return nil }
                cover = item.artwork
            case .localPlaylist:
                route = .playlist(reference.id)
                guard let item = LocalLibrary.playlistLibrary.playlist(reference.id) else { return nil }
                cover = item.artwork
            case .onlinePlaylist:
                let id = reference.id.split(separator: ":").last.map(String.init) ?? reference.id
                route = .playlist("home:playlist:\(id)")
                cover = Int64(id).flatMap { account.home?.cachedDetail(id: $0)?.playlist.artworkURL }.map { artwork($0) } ?? .playlist
            case .daily:
                guard let owner = reference.ownerID else { return nil }
                route = .playlist("home:daily:\(owner):\(reference.id)")
                cover = artwork(account.home?.dailySnapshot(id: reference.id)?.songs.first?.artworkURL)
            }
            return .init(id: "\(reference.kind.rawValue):\(reference.ownerID ?? "local"):\(reference.id)", title: reference.title, subtitle: "", artwork: cover, style: reference.kind == .favorites ? .favorites : .artwork, action: .navigate(route))
        }
        if model.recent != recent { model.recent = recent }
    }

    /// Feed and quick-action covers are the only home images that replace the visible sections.
    /// A song cover that is not on screen skips that rebuild.
    private func artworkAffectsVisibleHome(_ urls: Set<URL>) -> Bool {
        guard let home = account.home, home.userID == account.profile?.userID else { return false }
        if home.displayFeedBlocks.contains(where: { block in
            block.resources.contains { $0.artworkURL.map(urls.contains) == true }
        }) { return true }
        return NeteaseHomeQuickAction.allCases.contains { action in
            home.quickActionArtwork(action).map(urls.contains) == true
        }
    }

    private func publishArtwork(_ urls: Set<URL>) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }) else { return }
        let remoteByID = Dictionary(uniqueKeysWithValues: home.recommendations.map { (String($0.id), $0.artworkURL) })
        for index in model.recommendations.indices {
            if let remote = remoteByID[model.recommendations[index].id] ?? nil, urls.contains(remote) {
                let cover = artwork(remote)
                if model.recommendations[index].artwork != cover { model.recommendations[index].artwork = cover }
            }
        }
        if artworkAffectsVisibleHome(urls) { publishFeed() }
        var songs: [String: LibrarySongItem] = [:]
        for remote in urls {
            for value in artworkSongs[remote] ?? [] {
                let item = mapSong(value)
                songs[item.id] = item
            }
        }
        var covers: [String: Artwork] = [:]
        for (id, value) in loaded {
            if id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? ""),
               let remote = home.cachedDetail(id: number)?.playlist.artworkURL, urls.contains(remote) {
                let cover = artwork(remote)
                if value.0.artwork != cover { loaded[id]?.0.artwork = cover; covers[id] = cover }
            }
            if id.hasPrefix("home:daily:"), let remote = value.1.first?.artworkURL, urls.contains(remote) {
                let cover = artwork(remote)
                if value.0.artwork != cover { loaded[id]?.0.artwork = cover; covers[id] = cover }
            }
            for value in value.1 where value.artworkURL.map(urls.contains) == true {
                let item = mapSong(value)
                songs[item.id] = item
            }
        }
        detailLibrary.updateArtwork(songs: songs, playlists: covers)
        if let owner {
            Self.updateRetainedArtwork(in: LocalLibrary.playlistLibrary, home: home, owner: owner, urls: urls, songs: songs)
        }
        let updated = cachedSongs.map { item in songs[item.id].map { item.replacingArtwork(from: $0) } ?? item }
        if cachedSongs != updated { cachedSongs = updated }
        LocalLibrary.songLibrary.updateOnlineArtwork(songs, source: "home")
        player.updateArtwork(songs)
        updateRecent()
    }
    /// A retained Home collection keeps its stable library identity when its images arrive later.
    /// With no URL filter, replay cached files when either the Home cache or retained collections restore.
    static func updateRetainedArtwork(in library: PlaylistLibrary, home: NeteaseHomeStore, owner: String,
                                      urls: Set<URL>? = nil, songs: [String: LibrarySongItem] = [:]) {
        guard home.userID.map(String.init) == owner else { return }
        let prefix = "netease-playlist:\(owner):"
        var covers: [String: Artwork] = [:]
        var songImages = songs
        for item in library.playlists where item.sourceOwnerID == owner && item.id.hasPrefix(prefix) {
            guard let number = Int64(item.id.dropFirst(prefix.count)), let detail = home.cachedDetail(id: number) else { continue }
            let playlistMatches = detail.playlist.artworkURL.map { urls?.contains($0) != false } == true
            let songMatches = detail.songs.contains { $0.artworkURL.map { urls?.contains($0) != false } == true }
            guard playlistMatches || songMatches else { continue }
            if let remote = detail.playlist.artworkURL, urls?.contains(remote) != false {
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
        library.updateArtwork(songs: songImages, playlists: covers)
    }

    private func publishFeed() {
        let home = account.home
        let matches = home?.userID == account.profile?.userID
        let displayFeed = home.map { NeteaseHomeFeed(blocks: $0.displayFeedBlocks, hasMore: nil, cursor: nil) }
        let issues = matches ? Self.feedIssues(home) : []
        let sections = Self.feedSections(matches ? displayFeed : nil, issues: issues, artwork: { self.artwork($0) })
        if model.sections != sections { model.sections = sections }
        if model.feedIssues != issues { model.feedIssues = issues }
        publishQuickActions()
    }

    static func feedIssues(_ home: NeteaseHomeStore?) -> [HomeFeedIssue] {
        guard let home else { return [] }
        let sources: [(NeteaseHomeStore.RetrySource, String, String?, String?)] = [
            (.feed, "推荐内容", nil, home.feedError),
            (.recommendations, "推荐歌单", NeteaseHomeCategory.recommendedPlaylists.rawValue, home.recommendationsError),
            (.likedRecommendations, "喜欢歌曲推荐", NeteaseHomeCategory.likedSongs.rawValue, home.likedRecommendationsError),
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

    static func feedSections(_ feed: NeteaseHomeFeed?, issues: [HomeFeedIssue] = [], artwork: (URL?) -> Artwork) -> [HomeContentSection] {
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
                                     artwork: artwork(resource.artworkURL), action: .navigate(.playlist("home:playlist:\(id)")))
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
        home.updateLikedSongs(playlistID: playlist?.id, songs: music.songs.values.filter { music.likedIDs.contains($0.id) },
                              likedAt: music.likedAt, likedIDs: music.likedIDs,
                              orderedLikedIDs: playlist.flatMap { music.playlistTracks[$0.id] } ?? [])
    }

    static func currentOnlineSongID(_ song: LibrarySongItem, owner: String?) -> Int64? {
        guard let owner, song.onlineOwnerID == owner, song.unavailabilityReason == nil,
              let id = song.onlineSongID, id > 0 else { return nil }
        return id
    }

    private func publishQuickActions() {
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
        if model.quickActions != items { model.quickActions = items }
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
            } catch { /* The home store publishes each action's retry state. */ }
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
        item.subtitle = preview.subtitle
        item.artwork = preview.artwork
        item.sourceOwnerID = owner
        item.isReadOnlyContent = true
        detailLibrary.setExternalCollection(item: item, songs: detailLibrary.songs(in: id), error: detailLibrary.onlineErrors[id])
        if loaded[id] != nil { loaded[id]?.0 = item }
    }

    /// 私人漫游是持续的电台，不是一次返回的那几首。还剩一首时要下一批，队尾的下一首接着播。
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
        let id = owner.map { "netease:\($0):\(song.id)" } ?? "home-guest:\(song.id)"
        let url = song.artworkURL.flatMap { account.home?.cachedArtworkURL(remote: $0) }
        return LibrarySongItem(id: id, title: song.title, artist: song.artist, album: song.album, albumArtist: song.artist, trackNumber: song.trackNumber ?? 0,
                               artwork: artwork(song.artworkURL, placeholder: .missing), discNumber: song.discNumber ?? 1, artworkURL: url, duration: Int(song.duration),
                               isFavorite: account.music?.likedIDs.contains(song.id) == true,
                               favoriteAddedAt: account.music?.likedAt[song.id], unavailabilityReason: song.unavailable ? "暂无完整音源" : nil, onlineAlbumID: song.albumID,
                artistReferences: (song.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }
    private func updateDetail(_ id: String, item: LibraryPlaylistItem, songs: [NeteaseMusicSong], clearError: Bool = false) {
        var item = item
        if id.hasPrefix("home:playlist:"), let owner, let number = id.split(separator: ":").last {
            let retained = LocalLibrary.playlistLibrary.playlist("netease-playlist:\(owner):\(number)")
            item.isFavorite = retained?.isFavorite ?? false
            item.isPinned = retained?.isPinned ?? false
            item.isSubscribed = collected(number)
        }
        detailLibrary.setExternalCollection(item: item, songs: songs.map(mapSong), error: clearError ? nil : detailLibrary.onlineErrors[id])
    }
    private func applyDetail(_ detail: NeteasePlaylistDetail, id: String, clearError: Bool) {
        let existing = detailLibrary.playlist(id)
        let cover = detail.playlist.artworkURL == nil && existing?.sourceOwnerID == owner
            ? existing?.artwork ?? .playlist : artwork(detail.playlist.artworkURL)
        var item = LibraryPlaylistItem(id: id, title: detail.playlist.title, artwork: cover, sourceOwnerID: owner, subtitle: detail.playlist.creator)
        item.isReadOnlyContent = true
        loaded[id] = (item, detail.songs)
        detailLibrary.setOnlineHasMore(id, !detail.isComplete, totalCount: detail.orderedTrackIDs.count)
        updateDetail(id, item: item, songs: detail.songs, clearError: clearError)
    }
    private func restoreCachedDetail(_ id: String) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }),
              id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? ""),
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
            if id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? "") {
                let detail: NeteasePlaylistDetail
                if complete { detail = try await home.completeDetail(id: number) }
                else if loadMore { detail = try await home.loadMoreDetail(id: number) }
                else { detail = try await home.detail(id: number, force: force) }
                try Task.checkCancellation()
                guard home.userID == homeOwner, account.profile?.userID == profileOwner,
                      owner == profileOwner.map(String.init) else { throw CancellationError() }
                applyDetail(detail, id: id, clearError: true)
            } else if id.hasPrefix("home:daily:"), id.split(separator: ":").dropFirst(2).first.map(String.init) == owner,
                      let date = id.split(separator: ":").last.map(String.init), let snapshot = try await home.loadDailySnapshot(id: date) {
                let cover = snapshot.songs.first?.artworkURL.map { artwork($0) }
                    ?? detailLibrary.playlist(id)?.artwork ?? .playlist
                var item = LibraryPlaylistItem(id: id, title: "每日推荐", artwork: cover, sourceOwnerID: owner, subtitle: snapshot.date)
                item.isReadOnlyContent = true
                loaded[id] = (item, snapshot.songs)
                updateDetail(id, item: item, songs: snapshot.songs, clearError: true)
            } else { throw NeteaseAccountError.invalidResponse }
            cachedSongs = home.cachedSongs.map(mapSong)
            LocalLibrary.songLibrary.replaceExternalSongs(cachedSongs)
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
        guard case .playlist(let id) = route, id.hasPrefix("home:") else { return nil }
        var placeholder = LibraryPlaylistItem(id: id, title: id.hasPrefix("home:daily:") ? "每日推荐" : "播放列表", artwork: .playlist)
        placeholder.isReadOnlyContent = true
        if id.hasPrefix("home:playlist:"), let number = id.split(separator: ":").last {
            placeholder.isSubscribed = collected(number)
        }
        if detailLibrary.playlist(id) == nil { detailLibrary.setExternalCollection(item: placeholder, songs: []) }
        restoreCachedDetail(id)
        var actions = ExternalPlaylistActions(addSongs: { [weak self] in
            guard let self else { return }
            self.withCompleteCollection(id) { songs in
                LocalLibrary.playlistLibrary.pendingAddition = .init(songs: songs)
            }
        })
        if id.hasPrefix("home:playlist:") {
            actions.toggleFavorite = { [weak self] in self?.retain(id, action: .favorite) }
            actions.togglePin = { [weak self] in self?.retain(id, action: .pin) }
            actions.moveToFolder = { [weak self] in self?.retain(id, action: .folder) }
            actions.collect = { [weak self] in self?.changeCollection(id, subscribed: true) }
        }
        var collection = LocalLibrary.menuActions
        collection.play = { [weak self] _, shuffled in self?.requestPlayback(id, songID: nil, shuffled: shuffled) }
        collection.playNext = { [weak self] _ in self?.withCompleteCollection(id) { [weak self] in self?.player.insertNext($0) } }
        collection.playLater = { [weak self] _ in self?.withCompleteCollection(id) { [weak self] in self?.player.appendLater($0) } }
        var songs = SongMenuActions(downloads: LocalLibrary.downloads, notify: { LocalLibrary.toasts.show($0) })
        songs.play = { [weak self] list, index, _ in
            guard list.indices.contains(index), let songID = Int64(list[index].id.split(separator: ":").last ?? "") else { return }
            self?.requestPlayback(id, songID: songID, shuffled: false)
        }
        songs.playNext = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.insertNext([song]) }
        songs.playLater = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.appendLater([song]) }
        songs.addToPlaylist = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; LocalLibrary.playlistLibrary.pendingAddition = .init(songs: [song]) }
        songs.toggleFavorite = { [weak self] song in self?.setOnlineLiked(song, liked: !song.isFavorite) }
        songs.removeFromFavorites = { [weak self] song in self?.setOnlineLiked(song, liked: false) }
        return AnyView(HomeCollectionDetailView(playlistID: id, library: detailLibrary, actions: actions,
            onAppear: { [weak self] in self?.detailAppeared(id) },
            onDisappear: { [weak self] in self?.detailDisappeared(id) })
            .environment(\.collectionMenuActions, collection).environment(\.songMenuActions, songs))
    }

    private func setOnlineLiked(_ song: LibrarySongItem, liked: Bool) {
        guard let owner, let number = Int64(song.id.split(separator: ":").last ?? "") else { showsLogin = true; return }
        Task { [weak self] in
            guard let self, self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                  let music = self.account.music, music.userID.map(String.init) == owner,
                  song.id.hasPrefix("netease:\(owner):") else { return }
            do { try await music.setLiked(songID: number, liked: liked) }
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
    private func collected(_ number: Substring) -> Bool {
        guard let id = Int64(number), let owner, account.music?.userID.map(String.init) == owner else { return false }
        return account.music?.playlists.contains { $0.id == id && $0.isSubscribed == true } == true
    }

    private func syncCollectedPlaylists() {
        for (id, value) in loaded where id.hasPrefix("home:playlist:") {
            guard let number = id.split(separator: ":").last else { continue }
            var item = value.0
            item.isSubscribed = collected(number)
            guard item != value.0 else { continue }
            loaded[id]?.0 = item
            detailLibrary.setExternalCollection(item: item, songs: detailLibrary.songs(in: id), error: detailLibrary.onlineErrors[id])
        }
    }

    private func changeCollection(_ id: String, subscribed: Bool) {
        guard let owner, let number = Int64(id.split(separator: ":").last ?? ""),
              id.hasPrefix("home:playlist:") || id.hasPrefix("netease-playlist:") else { showsLogin = true; return }
        guard let music = account.music, music.userID.map(String.init) == owner,
              account.profile.map({ String($0.userID) }) == owner else { showsLogin = true; return }
        let revision = music.sessionRevision
        Task { [weak self] in
            do {
                try await music.setPlaylistSubscribed(id: number, subscribed: subscribed)
                guard let self, revision == music.sessionRevision, self.owner == owner,
                      music.userID.map(String.init) == owner else { return }
                if !subscribed, music.playlists.contains(where: { $0.id == number && $0.isSubscribed == true }) == false {
                    LocalLibrary.playlistLibrary.releaseRetainedOnlinePlaylist("netease-playlist:\(owner):\(number)")
                }
                self.syncCollectedPlaylists()
            } catch is CancellationError { }
            catch {
                guard revision == music.sessionRevision, self?.owner == owner else { return }
                LocalLibrary.toasts.show(.error(error.localizedDescription))
            }
        }
    }

    private enum RetainAction { case favorite, pin, folder }
    private func retain(_ id: String, action: RetainAction) {
        guard let owner, let number = id.split(separator: ":").last else { showsLogin = true; return }
        Task { [weak self] in
            guard let self, self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                  self.account.home?.userID.map(String.init) == owner, self.account.music?.userID.map(String.init) == owner else { return }
            do {
                try await self.load(id, complete: true)
                guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner, let detail = self.detailLibrary.playlist(id) else { return }
                let stableID = "netease-playlist:\(owner):\(number)"
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
                if let retained = LocalLibrary.playlistLibrary.playlist(stableID), var value = self.loaded[id] {
                    value.0.isFavorite = retained.isFavorite; value.0.isPinned = retained.isPinned
                    self.loaded[id] = value; self.updateDetail(id, item: value.0, songs: value.1)
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
                let daily = request.route.hasPrefix("home:daily:")
                let reference = PlaybackCollectionReference(kind: daily ? .daily : .onlinePlaylist, id: request.route.split(separator: ":").last.map(String.init) ?? request.route, ownerID: owner, title: self.detailLibrary.playlist(request.route)?.title ?? "播放列表")
                if let songID = request.songID {
                    guard let index = list.firstIndex(where: { Int64($0.id.split(separator: ":").last ?? "") == songID }) else { throw NeteaseAccountError.invalidResponse }
                    self.player.requestPlay(list, startingAt: index, from: reference.title, collection: reference)
                }
                else { self.player.requestPlay(list, from: reference.title, shuffled: request.shuffled, collection: reference) }
            } catch is CancellationError {} catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
    }
}
