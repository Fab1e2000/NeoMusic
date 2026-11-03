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
        player.onCollectionPlaybackStarted = { [weak self] reference in
            self?.history.record(reference)
            if reference.kind == .localPlaylist { LocalLibrary.playlistLibrary.markPlayed(reference.id) }
            if reference.kind == .onlinePlaylist, let owner = reference.ownerID {
                let id = reference.id.hasPrefix("netease-playlist:") ? reference.id : "netease-playlist:\(owner):\(reference.id)"
                LocalLibrary.playlistLibrary.markPlayed(id)
            }
        }
        account.home?.onChange = { [weak self] in self?.publish() }
        detailLibrary.loadOnlinePlaylist = { [weak self] id in
            do { try await self?.load(id) } catch { /* load publishes the retry error. */ }
        }
        observe()
    }
    private func observe() {
        withObservationTracking {
            _ = account.profile
            _ = account.validationState
            _ = account.home?.userID
            _ = account.music?.userID
            _ = account.home?.daily
            _ = account.home?.recommendations
            _ = account.home?.dailyError
            _ = account.home?.recommendationsError
            _ = account.music?.likedIDs
            _ = account.music?.likedAt
            _ = LocalLibrary.playlistLibrary.playlists
            _ = LocalLibrary.songLibrary.songs
            _ = history.recent(for: owner)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        publish()
    }
    private func artwork(_ remote: URL?) -> Artwork {
        remote.flatMap { account.home?.cachedArtworkURL(remote: $0) }.map(Artwork.file) ?? .playlist
    }
    private func publish() {
        let currentOwner = account.profile.map { String($0.userID) }
        if owner != currentOwner {
            if owner != nil { cancelPendingPlayback() }
            owner = currentOwner
            for (id, _) in loaded {
                var item = LibraryPlaylistItem(id: id, title: "播放列表", artwork: .playlist)
                item.isReadOnlyContent = true
                detailLibrary.setExternalCollection(item: item, songs: [])
            }
            loaded = [:]
            cachedSongs = []
            if currentOwner == nil { cancelPendingPlayback() }
        }
        resumePendingPlayback()
        LocalLibrary.playbackAccountID = currentOwner
        model.isGuest = currentOwner == nil
        model.featured = [.init(id: "favorites", title: "喜爱歌曲", subtitle: "你喜欢的音乐，都在这里。", artwork: .favorites, route: .playlist("favorites"), style: .favorites)]
        if let daily = account.home?.daily, let owner, account.home?.userID == account.profile?.userID {
            model.featured.append(.init(id: "daily", title: "每日推荐", subtitle: "每天为你挑选的音乐。", artwork: .playlist, route: .playlist("home:daily:\(owner):\(daily.id)"), style: .daily))
        }
        model.featuredError = account.home?.dailyError
        model.recommendationsError = account.home?.recommendationsError
        model.recommendations = (account.home?.userID == account.profile?.userID ? account.home?.recommendations ?? [] : []).map {
            .init(id: String($0.id), title: $0.title, subtitle: $0.creator, artwork: artwork($0.artworkURL), route: .playlist("home:playlist:\($0.id)"))
        }
        model.recent = history.recent(for: owner).compactMap { reference in
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
                route = .playlist("home:daily:\(owner):\(reference.id)"); cover = .playlist
            }
            return .init(id: "\(reference.kind.rawValue):\(reference.ownerID ?? "local"):\(reference.id)", title: reference.title, subtitle: "", artwork: cover, route: route, style: reference.kind == .daily ? .daily : reference.kind == .favorites ? .favorites : .artwork)
        }
        for (id, value) in loaded { updateDetail(id, item: value.0, songs: value.1) }
        cachedSongs = (account.home?.userID == account.profile?.userID ? account.home?.cachedSongs ?? [] : []).map(mapSong)
        LocalLibrary.songLibrary.replaceExternalSongs(cachedSongs)
    }
    private func mapSong(_ song: NeteaseMusicSong) -> LibrarySongItem {
        let id = owner.map { "netease:\($0):\(song.id)" } ?? "home-guest:\(song.id)"
        let url = song.artworkURL.flatMap { account.home?.cachedArtworkURL(remote: $0) }
        return LibrarySongItem(id: id, title: song.title, artist: song.artist, album: song.album, albumArtist: song.artist, trackNumber: 0,
                               artwork: url.map(Artwork.file) ?? .missing, artworkURL: url, duration: Int(song.duration),
                               isFavorite: account.music?.likedIDs.contains(song.id) == true,
                               favoriteAddedAt: account.music?.likedAt[song.id], unavailabilityReason: song.unavailable ? "暂无完整音源" : nil)
    }
    private func updateDetail(_ id: String, item: LibraryPlaylistItem, songs: [NeteaseMusicSong], clearError: Bool = false) {
        var item = item
        if id.hasPrefix("home:playlist:"), let owner, let number = id.split(separator: ":").last {
            let retained = LocalLibrary.playlistLibrary.playlist("netease-playlist:\(owner):\(number)")
            item.isFavorite = retained?.isFavorite ?? false
            item.isPinned = retained?.isPinned ?? false
        }
        detailLibrary.setExternalCollection(item: item, songs: songs.map(mapSong), error: clearError ? nil : detailLibrary.onlineErrors[id])
    }
    private func applyDetail(_ detail: NeteasePlaylistDetail, id: String, clearError: Bool) {
        var item = LibraryPlaylistItem(id: id, title: detail.playlist.title, artwork: artwork(detail.playlist.artworkURL), subtitle: detail.playlist.creator)
        item.isReadOnlyContent = true
        loaded[id] = (item, detail.songs)
        updateDetail(id, item: item, songs: detail.songs, clearError: clearError)
    }
    private func restoreCachedDetail(_ id: String) {
        guard let home = account.home, home.userID == account.profile?.userID,
              owner == account.profile.map({ String($0.userID) }),
              id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? ""),
              let detail = home.cachedDetail(id: number) else { return }
        applyDetail(detail, id: id, clearError: false)
    }
    private func load(_ id: String) async throws {
        guard let home = account.home else { throw NeteaseAccountError.invalidResponse }
        let homeOwner = home.userID
        let profileOwner = account.profile?.userID
        guard homeOwner == profileOwner, owner == profileOwner.map(String.init) else { throw CancellationError() }
        restoreCachedDetail(id)
        do {
            if id.hasPrefix("home:playlist:"), let number = Int64(id.split(separator: ":").last ?? "") {
                let detail = try await home.detail(id: number)
                try Task.checkCancellation()
                guard home.userID == homeOwner, account.profile?.userID == profileOwner,
                      owner == profileOwner.map(String.init) else { throw CancellationError() }
                applyDetail(detail, id: id, clearError: true)
            } else if id.hasPrefix("home:daily:"), id.split(separator: ":").dropFirst(2).first.map(String.init) == owner,
                      let date = id.split(separator: ":").last.map(String.init), let snapshot = home.dailySnapshot(id: date) {
                var item = LibraryPlaylistItem(id: id, title: "每日推荐", artwork: .playlist, subtitle: snapshot.date)
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
        if detailLibrary.playlist(id) == nil { detailLibrary.setExternalCollection(item: placeholder, songs: []) }
        restoreCachedDetail(id)
        var actions = ExternalPlaylistActions(addSongs: { [weak self] in
            guard let self else { return }
            if self.owner == nil { self.showsLogin = true; return }
            LocalLibrary.playlistLibrary.pendingAddition = .init(songs: self.detailLibrary.songs(in: id))
        })
        if id.hasPrefix("home:playlist:") {
            actions.toggleFavorite = { [weak self] in self?.retain(id, action: .favorite) }
            actions.togglePin = { [weak self] in self?.retain(id, action: .pin) }
            actions.moveToFolder = { [weak self] in self?.retain(id, action: .folder) }
        }
        var collection = CollectionMenuActions()
        collection.play = { [weak self] _, shuffled in self?.requestPlayback(id, songID: nil, shuffled: shuffled) }
        collection.playNext = { [weak self] _ in if let self, self.owner != nil { self.player.insertNext(self.detailLibrary.songs(in: id)) } }
        collection.playLater = { [weak self] _ in if let self, self.owner != nil { self.player.appendLater(self.detailLibrary.songs(in: id)) } }
        var songs = SongMenuActions()
        songs.play = { [weak self] list, index, _ in
            guard list.indices.contains(index), let songID = Int64(list[index].id.split(separator: ":").last ?? "") else { return }
            self?.requestPlayback(id, songID: songID, shuffled: false)
        }
        songs.playNext = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.insertNext([song]) }
        songs.playLater = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; self?.player.appendLater([song]) }
        songs.addToPlaylist = { [weak self] song in guard self?.owner != nil else { self?.showsLogin = true; return }; LocalLibrary.playlistLibrary.pendingAddition = .init(songs: [song]) }
        songs.toggleFavorite = { [weak self] song in
            guard let self else { return }
            guard let owner = self.owner, let number = Int64(song.id.split(separator: ":").last ?? "") else { self.showsLogin = true; return }
            Task {
                guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                      let music = self.account.music, music.userID.map(String.init) == owner,
                      song.id.hasPrefix("netease:\(owner):") else { return }
                do { try await music.setLiked(songID: number, liked: !song.isFavorite) }
                catch is CancellationError {} catch {
                    guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner else { return }
                    LocalLibrary.toasts.show(.error(error.localizedDescription))
                }
            }
        }
        return AnyView(HomeCollectionDetailView(playlistID: id, library: detailLibrary, actions: actions,
            artwork: id.hasPrefix("home:daily:") ? AnyView(HomeDailyArtwork()) : nil,
            onAppear: { [weak self] in self?.detailAppeared(id) },
            onDisappear: { [weak self] in self?.detailDisappeared(id) })
            .environment(\.collectionMenuActions, collection).environment(\.songMenuActions, songs)
            .task { [weak self] in
                do { try await self?.load(id) }
                catch { /* load owns visible errors and cancellation isolation. */ }
            })
    }
    private enum RetainAction { case favorite, pin, folder }
    private func retain(_ id: String, action: RetainAction) {
        guard let owner, let number = id.split(separator: ":").last else { showsLogin = true; return }
        Task { [weak self] in
            guard let self, self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner,
                  self.account.home?.userID.map(String.init) == owner, self.account.music?.userID.map(String.init) == owner else { return }
            do {
                try await self.load(id)
                guard self.owner == owner, self.account.profile.map({ String($0.userID) }) == owner, let detail = self.detailLibrary.playlist(id) else { return }
                let stableID = "netease-playlist:\(owner):\(number)"
                var item = LocalLibrary.playlistLibrary.playlist(stableID) ?? LibraryPlaylistItem(id: stableID, title: detail.title, artwork: detail.artwork, sourceOwnerID: owner, subtitle: detail.subtitle)
                item.sourceOwnerID = owner
                LocalLibrary.playlistLibrary.retainOnlinePlaylist(item, songs: self.detailLibrary.songs(in: id))
                switch action {
                case .favorite: LocalLibrary.playlistLibrary.toggleFavorite(stableID)
                case .pin: LocalLibrary.playlistLibrary.togglePin(stableID)
                case .folder: LocalLibrary.playlistLibrary.pendingMove = LocalLibrary.playlistLibrary.playlist(stableID)
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
        if completingLogin { completingLogin = false; return }
        cancelPendingPlayback()
    }
    func requestPlayback(_ id: String, songID: Int64?, shuffled: Bool) {
        cancelPendingPlayback()
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
                try await self.load(request.route)
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
