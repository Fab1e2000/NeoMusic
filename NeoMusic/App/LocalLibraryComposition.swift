import FullScreenPlayer
import SwiftUI

@MainActor
struct CollectionDownloadHandling {
    var download: ((LibraryRoute) -> Bool)?
    var remove: ((LibraryRoute) -> Bool)?
    var downloadedState: ((LibraryRoute) -> Bool?)?
    var canDownload: ((LibraryRoute) -> Bool)?
    var canRemoveDownload: ((LibraryRoute) -> Bool)?
    var stop: ((LibraryRoute) -> Void)?
}

typealias AppLibrary = LocalLibrary

/// 应用级资料库、播放与现有页面的装配入口。
@MainActor
enum LocalLibrary {
    static let runtime = LocalLibraryRuntime(
        songLibrary: songLibrary, playlistLibrary: playlistLibrary, player: player,
        favoriteAlbums: favoriteAlbums, pinnedAlbums: pinnedAlbums, deletedAlbums: deletedAlbums,
        onLocalSongsApplied: { downloads.setLocalSongs($0) })
    static let catalog = LibraryCatalog()
    static let songLibrary = SongLibrary(songs: [])
    static var songs: [LibrarySongItem] { runtime.localSongs }
    static var allSongs: [LibrarySongItem] { runtime.allSongs }
    private static func song(id: String) -> LibrarySongItem? {
        guard let song = songLibrary.song(id: id), song.isOnline || !deletedAlbums.ids.contains(song.albumID) else { return nil }
        return song
    }
    static var favorites: [LibrarySongItem] {
        favoriteRows(online: songLibrary.onlineSongs, favorites: songLibrary.favoriteSongs,
                     downloadedSongID: { catalog.downloadedOnlineSongID?($0) })
            .filter { $0.isOnline || !deletedAlbums.ids.contains($0.albumID) }
    }

    /// 已下载的网易云歌曲在喜爱歌曲里沿用在线条目：下载状态变化只更新行内标记，不替换行身份。
    static func favoriteRows(online: [LibrarySongItem],
                             favorites: [LibrarySongItem],
                             downloadedSongID: (String) -> Int64?) -> [LibrarySongItem] {
        var onlineBySongID: [Int64: LibrarySongItem] = [:]
        for song in online where song.isFavorite {
            guard let id = song.onlineSongID, onlineBySongID[id] == nil else { continue }
            onlineBySongID[id] = song
        }
        var seen: Set<String> = []
        var items: [LibrarySongItem] = []
        items.reserveCapacity(favorites.count + onlineBySongID.count)
        for song in favorites {
            let shown = song.isOnline ? song : downloadedSongID(song.id).flatMap { onlineBySongID[$0] } ?? song
            if seen.insert(shown.id).inserted { items.append(shown) }
        }
        // 下载完成到本地扫描回填之间，在线条目暂时不在 favoriteSongs 里，也要保留在列表原位。
        for song in online where song.isFavorite {
            if seen.insert(song.id).inserted { items.append(song) }
        }
        return SongLibrary.orderedFavorites(items)
    }
    static let pinnedAlbums = LibrarySelectionSet(ids: [], key: "pinnedAlbums")
    private static let pinnedOrder = PinnedOrderStore()
    static let favoriteAlbums = LibrarySelectionSet(ids: [], key: "favoriteAlbums")
    static let favoriteArtists = LibrarySelectionSet(ids: [], key: "favoriteArtists")
    static let deletedAlbums = LibrarySelectionSet(ids: [], key: "deletedAlbums")
    static let downloads = LibraryDownloads()
    static let toasts = LibraryToastCenter()
    static var collectionDownloads = CollectionDownloadHandling()
    static var collectionDownloadAction: ((LibraryRoute) -> Bool)? {
        get { collectionDownloads.download }
        set { collectionDownloads.download = newValue }
    }
    static var collectionRemovalAction: ((LibraryRoute) -> Bool)? {
        get { collectionDownloads.remove }
        set { collectionDownloads.remove = newValue }
    }
    static var collectionDownloadedState: ((LibraryRoute) -> Bool?)? {
        get { collectionDownloads.downloadedState }
        set { collectionDownloads.downloadedState = newValue }
    }
    static var collectionCanDownload: ((LibraryRoute) -> Bool)? {
        get { collectionDownloads.canDownload }
        set { collectionDownloads.canDownload = newValue }
    }
    static var collectionCanRemoveDownload: ((LibraryRoute) -> Bool)? {
        get { collectionDownloads.canRemoveDownload }
        set { collectionDownloads.canRemoveDownload = newValue }
    }
    static var collectionStopDownload: ((LibraryRoute) -> Void)? {
        get { collectionDownloads.stop }
        set { collectionDownloads.stop = newValue }
    }
    static var prepareSongForLibraryAction: ((LibrarySongItem) -> LibrarySongItem?)?
    private static func albumSongs(_ id: String) -> [LibrarySongItem] {
        guard !deletedAlbums.ids.contains(id) else { return [] }
        return songLibrary.albumIndex.songIDsByAlbum[id, default: []].compactMap { songLibrary.song(id: $0) }
    }
    static func isAlbumDownloaded(_ id: String) -> Bool { !albumSongs(id).isEmpty }
    static var albums: [LibraryShelfItem] {
        catalog.albums + songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
    }
    private static func albumItem(_ id: String) -> LibraryShelfItem? {
        guard !deletedAlbums.ids.contains(id), let item = songLibrary.albumIndex.itemsByID[id] else { return nil }
        return withPinState(item)
    }
    static var downloadedAlbumItems: [LibraryShelfItem] {
        let local = songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.albums.map { ($0.id, $0) })
        let netease = catalog.downloadedAlbums.map { catalogByID[$0.id] ?? $0 }
        return netease + local
    }

    /// 专辑的置顶、喜爱状态以 `pinnedAlbums`、`favoriteAlbums` 为准。
    private static func withPinState(_ album: LibraryShelfItem) -> LibraryShelfItem {
        var album = album
        album.isPinned = pinnedAlbums.ids.contains(album.id)
        album.isFavorite = favoriteAlbums.ids.contains(album.id)
        return album
    }

    /// 最近添加：播放列表、专辑，以及喜爱或加入播放列表的单曲。按加入时间从新到旧。
    static var allRecentlyAdded: [LibraryShelfItem] { recentAdditions() }
    static var recentlyAdded: [LibraryShelfItem] { recentAdditions(limit: 6) }

    private static func recentAdditions(limit: Int? = nil) -> [LibraryShelfItem] {
        let playlists = playlistLibrary.playlists.filter { !$0.isSystem }.map { playlist in
            var shown = playlist
            shown.artwork = playlistLibrary.displayArtwork(of: playlist)
            var item = shown.shelfItem
            if !playlist.isReadOnly { item.subtitle = "我" }
            return (item, playlist.addedAt)
        }
        let albumItems = albums.map { album in
            (album, LibraryRecentAdditions.date(forAddedOrder: album.addedOrder))
        }
        let added = playlistLibrary.recentlyAddedSongs()
        let hiddenAlbums = deletedAlbums.ids
        var songItems = songLibrary.favoriteSongs.compactMap { song -> (LibrarySongItem, Date?)? in
            guard added[song.id] == nil, song.isOnline || !hiddenAlbums.contains(song.albumID) else { return nil }
            return (song, song.favoriteAddedAt)
        }
        for (id, entry) in added {
            let visible = songLibrary.visibleSong(id: id).flatMap {
                $0.isOnline || !hiddenAlbums.contains($0.albumID) ? $0 : nil
            }
            let song = visible ?? entry.song
            songItems.append((song, song.favoriteAddedAt.map { max($0, entry.addedAt) } ?? entry.addedAt))
        }
        return LibraryRecentAdditions.ordered(collections: playlists + albumItems, songs: songItems, limit: limit)
    }

    static var musicPickerSource: MusicPickerSource {
        MusicPickerSource(
            songs: { allSongs },
            artists: { artists },
            albums: { albums.map(withPinState) },
            downloadedAlbums: { downloadedAlbumItems.map(withPinState) },
            recentlyAdded: { allRecentlyAdded },
            recentlyPlayed: { recentPlaybackFixture },
            playlistLibrary: playlistLibrary,
            albumSongs: { albumSongs($0) },
            loadAlbumSongs: { id in
                if CatalogRouteIdentity.isCatalogID(id), let load = catalog.loadAlbumSongs {
                    return try await load(id)
                }
                return albumSongs(id)
            },
            loadArtistDetail: { id in
                if CatalogRouteIdentity.isCatalogID(id), let load = catalog.loadArtistDetail {
                    return try await load(id)
                }
                return nil
            },
            songByID: { songForMenu($0) }
        )
    }

    static func playLibrarySong(_ id: String) {
        guard let song = songForMenu(id) else { return }
        playSongs([song], shuffled: false)
    }

    /// 最近添加单曲卡的菜单使用与播放相同的歌曲查找。
    static func songForMenu(_ id: String) -> LibrarySongItem? {
        song(id: id) ?? playlistLibrary.containedSong(id)
    }

    static var pinned: [LibraryShelfItem] {
        let items = playlistLibrary.playlists.filter(\.isPinned).map(\.shelfItem) + albums.map(withPinState).filter(\.isPinned)
        return pinnedOrder.ordered(items) { $0.route.flatMap(PinnedOrderID.init(route:)) }
    }

    /// Reorder only the currently visible pinned items; stale or incomplete requests fail without writing.
    @discardableResult
    static func reorderPinned(_ routes: [LibraryRoute]) -> Bool {
        let visible = pinned.compactMap { $0.route.flatMap(PinnedOrderID.init(route:)) }
        let requested = routes.compactMap(PinnedOrderID.init(route:))
        guard visible.count == pinned.count, requested.count == routes.count else { return false }
        return pinnedOrder.reorder(visible: visible, to: requested)
    }

    /// 尚未建立最近播放历史，不返回示例记录。
    static var recentPlaybackFixture: [LibrarySongItem] { [] }

    static let playlistLibrary = PlaylistLibrary(playlists: [
        LibraryPlaylistItem(id: "favorites", title: "喜爱歌曲", artwork: .favorites, isFavorite: true, isPinned: true, isSystem: true)
    ])
    private static let downloadedPlaylistView = PlaylistLibrary(playlists: [])
    static var downloadedPlaylists: PlaylistLibrary { downloadedPlaylistView }

    /// Download records own these snapshots; the editable playlist store never serializes them.
    static func refreshDownloadPresentation() {
        songLibrary.refreshDownloadPresentation()
        refreshDownloadedPlaylistsPresentation()
    }

    static func refreshDownloadedPlaylistsPresentation() {
        playlistLibrary.reconcileOfflineAvailability()
        let candidates = playlistLibrary.downloadedSnapshotItems + playlistLibrary.playlists.filter { !$0.isReadOnly }
        var items: [LibraryPlaylistItem] = []
        var contents: [String: [LibrarySongItem]] = [:]
        for var item in candidates {
            let available = playlistLibrary.songs(in: item.id).filter { downloads.state(of: $0.id) == .downloaded }
            guard !available.isEmpty else { continue }
            item.isReadOnlyContent = true
            items.append(item)
            contents[item.id] = available
        }
        downloadedPlaylistView.replaceDownloadedPlaylists(items: items, songs: contents)
    }
    static var playlists: [LibraryPlaylistItem] { playlistLibrary.playlists }
    static var artists: [LibraryArtistItem] { catalog.artists }
    static func albumDetail(_ id: String) -> CollectionDetail? {
        let orderedSongs = albumSongs(id)
        guard let album = albumItem(id) else { return nil }
        return CollectionDetail(kind: .album, title: album.title, subtitle: album.subtitle, caption: nil,
            artwork: album.artwork, tint: Color(.systemBackground), albumBackdrop: album.albumBackdrop, isFavorite: favoriteAlbums.ids.contains(id),
            isPinned: pinnedAlbums.ids.contains(id), songs: orderedSongs, route: .album(id))
    }
    static func playlistDetail(_ id: String) -> CollectionDetail? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        return CollectionDetail(kind: .playlist, title: playlist.title, subtitle: nil, caption: nil,
            artwork: playlist.artwork, tint: Color(.systemBackground), isFavorite: playlist.isFavorite,
            isPinned: playlist.isPinned, songs: id == "favorites" ? favorites : playlistLibrary.songs(in: id), route: .playlist(id))
    }
    static let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, elapsed: 0)

    static let referencePlayer = PlayerState(model: player)
    static let referenceLibrary = PlayerLyricsController(reader: PlayerLyricsStoreAdapter(
        storageDirectory: URL.applicationSupportDirectory.appending(path: "Lyrics", directoryHint: .isDirectory),
        root: runtime.root,
        resolveAudioURL: { id in
            let url = runtime.root.appending(path: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }))

    private static func playerActions(openRoute: @escaping (LibraryRoute) -> Void,
                                      openAudioQualitySettings: (() -> Void)?) -> PlayerActions {
        PlayerActions(
            isFavorite: { id in song(id: id)?.isFavorite == true },
            toggleFavorite: { songLibrary.toggleFavorite($0) },
            addToPlaylist: { id in
                guard let song = song(id: id) else { return }
                if let prepareSongForLibraryAction {
                    guard let prepared = prepareSongForLibraryAction(song) else { return }
                    playlistLibrary.pendingAddition = .init(songs: [prepared])
                } else { playlistLibrary.pendingAddition = .init(songs: [song]) }
            },
            openAlbum: { id in
                guard let song = song(id: id) else { return }
                if song.onlineAlbumID != nil { openRoute(.album(song.albumID)) }
                else if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(id) != nil { catalog.openSongAlbum?(id, openRoute) }
                else { openRoute(.album(song.albumID)) }
            },
            openArtist: { id in
                guard let song = song(id: id) else { return }
                if let ref = song.artistReferences.first { openRoute(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(id) != nil { catalog.openSongArtist?(id, nil, openRoute) }
            }, artistNames: { id in
                guard let song = song(id: id) else { return [] }
                let refs = song.artistReferences.map(\.name)
                if !refs.isEmpty { return refs }
                if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(id) != nil {
                    return song.artist.isEmpty ? [] : [song.artist]
                }
                return []
            }, openNamedArtist: { id, name in
                guard let song = song(id: id) else { return }
                if let ref = song.artistReferences.first(where: { $0.name == name }) { openRoute(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(id) != nil { catalog.openSongArtist?(id, name, openRoute) }
            }, feedback: { LibraryHaptics.success() }, notify: { toasts.show(LibraryToast($0)) }, completesFavoriteSynchronously: { id in
                guard let song = song(id: id) else { return false }
                return !song.isNeteaseCatalogSong && !downloads.canRemove(song)
            }, audioQuality: { id in
                guard player.hasCurrent, player.current.id == id else { return nil }
                if !player.current.isOnline {
                    return PlayerAudioQuality.localFile(runtime.root.appending(path: id))
                }
                guard let value = player.actualQuality,
                      let quality = NeteaseMusicQuality(rawValue: value) else { return nil }
                return PlayerAudioQuality(title: quality.title,
                    isLossless: quality == .lossless || quality == .hiRes)
            }, openAudioQualitySettings: openAudioQualitySettings)
    }

    /// 一个专辑或播放列表里的歌曲与名称。
    private static func collection(_ route: LibraryRoute) -> (title: String, songs: [LibrarySongItem])? {
        switch route {
        case .album(let id): albumDetail(id).map { ($0.title, $0.songs) }
        case .playlist(let id): playlistDetail(id).map { ($0.title, $0.songs) }
        case .artist(let id): (id, songs.filter { $0.albumArtist == id })
        default: nil
        }
    }

    static var playbackAccountID: String?

    static func playbackCollection(_ route: LibraryRoute) -> PlaybackCollectionReference? {
        switch route {
        case .album(let id):
            guard let detail = albumDetail(id) else { return nil }
            return .init(kind: .localAlbum, id: id, ownerID: nil, title: detail.title)
        case .playlist(let id):
            guard let item = playlistLibrary.playlist(id) else { return nil }
            if item.isSystem { return .init(kind: .favorites, id: id, ownerID: playbackAccountID, title: item.title) }
            return .init(kind: item.sourceOwnerID == nil ? .localPlaylist : .onlinePlaylist,
                         id: id, ownerID: item.sourceOwnerID, title: item.title)
        default: return nil
        }
    }

    /// Online menus resolve the complete collection before committing an action.
    private static func withCollection(_ route: LibraryRoute,
                                       perform: @escaping @MainActor ((title: String, songs: [LibrarySongItem])) -> Void) {
        guard case .playlist(let id) = route, let item = playlistLibrary.playlist(id) else {
            if let value = collection(route) { perform(value) }
            return
        }
        let owner = item.sourceOwnerID
        let accountID = playbackAccountID
        let needsOnline = owner != nil || playlistLibrary.onlineHasMore.contains(id)
            || (id == "favorites" && accountID != nil)
        guard needsOnline else {
            if let value = collection(route) { perform(value) }
            return
        }
        let complete = playlistLibrary.completeOnlinePlaylist
        let load = playlistLibrary.loadOnlinePlaylist
        guard complete != nil || load != nil else {
            toasts.show(.error("请登录网易云账号后重试"))
            return
        }
        Task {
            let completed: Bool
            if let complete { completed = await complete(id) }
            else {
                await load?(id)
                completed = playlistLibrary.loadedOnlinePlaylistIDs.contains(id)
            }
            guard !Task.isCancelled, playlistLibrary.playlist(id)?.sourceOwnerID == owner,
                  playbackAccountID == accountID else { return }
            if let error = playlistLibrary.onlineErrors[id] {
                toasts.show(.error(error))
                return
            }
            guard completed, !playlistLibrary.onlineHasMore.contains(id),
                  !playlistLibrary.loadingPlaylistIDs.contains(id), let value = collection(route) else {
                toasts.show(.error("播放列表尚未完整加载，请重试"))
                return
            }
            perform(value)
        }
    }

    /// 集合菜单操作接入播放队列与持久化资料库。
    static var menuActions: CollectionMenuActions {
        CollectionMenuActions(
            play: { route, shuffled in
                if catalog.handles(route) { catalog.actions.play(route, shuffled); return }
                withCollection(route) { collection in
                    guard !collection.songs.isEmpty else { return }
                    player.requestPlay(collection.songs, from: collection.title, shuffled: shuffled, collection: playbackCollection(route))
                }
            },
            playNext: { route in if catalog.handles(route) { catalog.actions.playNext(route); return }; withCollection(route) { player.insertNext($0.songs) } },
            playLater: { route in if catalog.handles(route) { catalog.actions.playLater(route); return }; withCollection(route) { player.appendLater($0.songs) } },
            toggleFavorite: { route in
                if catalog.handles(route) { catalog.actions.toggleFavorite(route); return }
                switch route {
                case .playlist(let id): playlistLibrary.toggleFavorite(id)
                case .album(let id): favoriteAlbums.toggle(id)
                case .artist(let id): favoriteArtists.toggle(id)
                default: break
                }
            },
            togglePin: { route in
                switch route {
                case .playlist(let id): playlistLibrary.togglePin(id)
                case .album(let id): pinnedAlbums.toggle(id)
                default: break
                }
            },
            addToPlaylist: { route in
                if catalog.handles(route) { catalog.actions.addToPlaylist(route); return }
                withCollection(route) { collection in
                    playlistLibrary.pendingAddition = .init(songs: collection.songs)
                }
            },
            playbackSource: { player.isPlaying ? player.sourceTitle : nil },
            requestMove: { playlistLibrary.pendingMove = playlistLibrary.playlist($0) },
            // 资料库里的所有专辑与用户播放列表都可以删除；系统播放列表不能。
            canDelete: { route in
                if catalog.handles(route) { return false }
                return switch route {
                case .playlist(let id): playlistLibrary.canDelete(id) || playlistLibrary.canUnsubscribe(id)
                case .album: true
                default: false
                }
            },
            isDownloaded: { route in
                if let value = collectionDownloadedState?(route) { return value }
                if case .album(let id) = route { return isAlbumDownloaded(id) }
                return false
            },
            edit: { route in
                guard case .playlist(let id) = route else { return }
                playlistLibrary.pendingEdit = playlistLibrary.playlist(id)
            },
            requestDelete: { route in
                guard case .playlist(let id) = route else { return }
                playlistLibrary.pendingDeletion = playlistLibrary.playlists.first { $0.id == id }
            },
            delete: { route in
                switch route {
                case .playlist(let id): playlistLibrary.deletePlaylist(id)
                case .album(let id):
                    let removed = albumSongs(id)
                    deletedAlbums.insert(id)
                    playlistLibrary.removeSongsEverywhere(Set(removed.map(\.id)))
                    pinnedAlbums.remove(id)
                default: break
                }
            },
            notify: { toasts.show($0) },
            removeDownload: { route in
                if collectionRemovalAction?(route) == true { return }
                if case .album(let id) = route { downloads.requestRemoval(albumSongs(id)) }
            },
            download: { route in
                if collectionDownloadAction?(route) == true { return }
                if case .album(let id) = route { downloads.download(albumSongs(id)) }
            },
            canDownload: { collectionCanDownload?($0) ?? false },
            canRemoveDownload: { collectionCanRemoveDownload?($0) ?? false },
            stopDownload: { collectionStopDownload?($0) },
            downloads: downloads
        )
    }

    /// 歌曲播放与持久化资料库操作。
    private static var songActions: SongMenuActions {
        SongMenuActions(
            downloads: downloads,
            play: { songs, index, source in player.requestPlay(songs, startingAt: index, from: source) },
            playNext: { player.insertNext([$0]) },
            toggleFavorite: { songLibrary.toggleFavorite($0.id) },
            removeFromFavorites: { songLibrary.setFavorite($0.id, false, playsSuccessHaptic: false) },
            togglePin: { songLibrary.togglePin($0.id) },
            addToPlaylist: { song in
                if let prepareSongForLibraryAction {
                    guard let prepared = prepareSongForLibraryAction(song) else { return }
                    playlistLibrary.pendingAddition = .init(songs: [prepared])
                } else { playlistLibrary.pendingAddition = .init(songs: [song]) }
            },
            playLater: { player.appendLater([$0]) },
            delete: { song in
                songLibrary.delete(song.id)
                playlistLibrary.removeSongsEverywhere([song.id])
            },
            // 对照 Apple Music：播放中显示“随后播放”与来源；暂停时为“添加到队列”。
            playbackSource: { player.isPlaying ? player.sourceTitle : nil },
            openAlbum: { song, open in
                if song.onlineAlbumID != nil { open(.album(song.albumID)) }
                else if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(song.id) != nil { catalog.openSongAlbum?(song.id, open) }
                else { open(.album(song.albumID)) }
            },
            openArtist: { song, open in
                if let ref = song.artistReferences.first { open(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || catalog.downloadedOnlineSongID?(song.id) != nil { catalog.openSongArtist?(song.id, nil, open) }
            },
            notify: { toasts.show($0) },
            isAsynchronousFavorite: { $0.isNeteaseCatalogSong || downloads.canRemove($0) }
        )
    }

    static func songActions(for route: LibraryRoute) -> SongMenuActions {
        var actions = songActions
        actions.play = { songs, index, source in
            player.requestPlay(songs, startingAt: index, from: source, collection: playbackCollection(route))
        }
        return actions
    }

    /// 应用装配：标签栏、迷你播放条与资料库各页。
    static var app: some View {
        AppShell(library: {
            LocalLibraryHome()
        }, detailDestination: { AnyView(LocalDestination(route: $0)) }, nowPlaying: player, playlistLibrary: playlistLibrary, toasts: toasts,
           referencePlayer: referencePlayer, referenceLibrary: referenceLibrary, makePlayerActions: playerActions, isInitialContentReady: runtime.isInitialPlaybackReady || (player.hasCurrent && !player.current.isOnline) || player.hasOfflineCurrentSong, libraryPath: launchPath, isPlayerPresented: ["nowplaying", "paused", "queue"].contains(launchPage))
        .playlistEditSheet(playlistLibrary, songs: { allSongs })
        .environment(\.libraryDownloads, downloads)
        .environment(\.collectionMenuActions, menuActions)
        .environment(\.songMenuActions, songActions)
        .environment(\.songRowPlayback, player)
        .environment(\.musicPickerSource, musicPickerSource)
    }

    static func playSongs(_ songs: [LibrarySongItem], shuffled: Bool) {
        player.requestPlay(songs, from: "歌曲", shuffled: shuffled)
    }

    static func playAlbums(_ ids: [String], shuffled: Bool) {
        if ids.contains(where: CatalogRouteIdentity.isCatalogID) {
            Task {
                do {
                    var songs: [LibrarySongItem] = []
                    for id in ids {
                        if CatalogRouteIdentity.isCatalogID(id), let load = catalog.loadAlbumSongs { songs += try await load(id) }
                        else { songs += albumDetail(id)?.songs ?? [] }
                    }
                    player.requestPlay(songs, from: "专辑", shuffled: shuffled)
                } catch is CancellationError { } catch { toasts.show(.error(error.localizedDescription)) }
            }
            return
        }
        let tracks = ids.flatMap { albumDetail($0)?.songs ?? [] }
        player.requestPlay(tracks, from: "专辑", shuffled: shuffled)
    }

    @ViewBuilder fileprivate static func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .category(.downloaded): DownloadedLibraryView(albums: downloadedAlbumItems.map(withPinState))
        case .downloadedCategory(.songs): SongsListView(songs: songs.filter { downloads.state(of: $0.id) == .downloaded }, playAll: playSongs)
        case .downloadedCategory(.albums): AlbumsGridView(albums: downloadedAlbumItems.map(withPinState), playAll: playAlbums)
        case .downloadedCategory(.artists):
            let downloadedArtistIDs = Set(songs.filter { downloads.state(of: $0.id) == .downloaded }
                .flatMap(\.artistReferences).map(\.id))
            ArtistsListView(artists: catalog.artists.filter { downloadedArtistIDs.contains($0.id) })
        case .downloadedCategory(.playlists): PlaylistsListView(library: downloadedPlaylists)
        case .downloadedCategory(.downloaded): EmptyView()
        case .category(.songs): SongsListView(songs: songs, playAll: playSongs)
        case .category(.albums): AlbumsGridView(albums: albums.map(withPinState), playAll: playAlbums)
        case .category(.artists): ArtistsListView(artists: artists)
        case .category(.playlists): PlaylistsListView(library: playlistLibrary)
        case .playlistFolder(let id): PlaylistsListView(library: playlistLibrary, folderID: id)
        case .album(let id): albumDetail(id).map { CollectionDetailView(detail: $0) }
        case .playlist(let id):
            if id == "favorites" { LocalFavoritesDetail() }
            else { PlaylistDetailView(playlistID: id, library: playlistLibrary, songs: [], availableSongs: { allSongs }, recentlyPlayedSongs: recentPlaybackFixture) }
        case .artist, .artistSection, .searchCategory: EmptyView()
        }
    }

    /// 启动参数 `-mockPage <页面>` 直接打开对应页面，便于截图核对。
    private static var launchPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mockPage"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var launchPath: [LibraryRoute] {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-catalogArtist"), args.indices.contains(index + 1), Int64(args[index + 1]) != nil { return [.artist(CatalogRouteIdentity.artistID(args[index + 1]))] }
        #endif
        guard let page = launchPage else { return [] }
        let pages: [String: [LibraryRoute]] = [
            "downloaded": [.category(.downloaded)],
            "songs": [.category(.songs)], "albums": [.category(.albums)], "artists": [.category(.artists)],
            "playlists": [.category(.playlists)], "album": [.category(.albums), .album("-斩断-")],
            "album-light": [.category(.albums), .album("月光入侵计划")],
            "album-night": [.category(.albums), .album("夜语花")],
            "playlist": [.category(.playlists), .playlist("test")],
            "favorites": [.category(.playlists), .playlist("favorites")],
            "folder": [.category(.playlists), .playlistFolder("111")],
        ]
        return pages[page] ?? []
    }


}

/// 在首页自己的 body 里读取置顶状态：置顶变化只刷新首页，不会让上层重建而重置首页的编辑状态。
struct LocalLibraryHome: View {
    var body: some View {
        let ready = LocalLibrary.runtime.isInitialLibraryReady
        let pinnedReady = ready && LocalLibrary.runtime.isInitialPresentationReady
        LibraryHomeView(pinned: pinnedReady ? LocalLibrary.pinned : [], recentlyAdded: ready ? LocalLibrary.recentlyAdded : [],
                        playlistLibrary: LocalLibrary.playlistLibrary,
                        isContentReady: ready,
                        isPinnedReady: pinnedReady,
                        reorderPinned: LocalLibrary.reorderPinned,
                        playSong: LocalLibrary.playLibrarySong,
                        songForMenu: LocalLibrary.songForMenu)
            .safeAreaInset(edge: .bottom) {
                if let status = LocalLibrary.runtime.status { LibraryStatusMessage(message: status) }
                if let error = LocalLibrary.playlistLibrary.persistenceError {
                    LibraryStatusMessage(message: error, title: "保存状态", isError: true)
                }
            }
    }
}

/// 在页面的 body 中生成目标页，资料库变化时随之刷新。
private struct LocalDestination: View {
    let route: LibraryRoute
    @Environment(\.libraryZoomNamespace) private var zoomNamespace

    @ViewBuilder var body: some View {
        switch route {
        case .album, .playlist:
            LocalLibrary.destination(route).environment(\.songMenuActions, LocalLibrary.songActions(for: route)).navigationDiagnostics(route.diagnosticPage).libraryZoomTransition(route, in: zoomNamespace)
        default:
            LocalLibrary.destination(route).navigationDiagnostics(route.diagnosticPage)
        }
    }
}

struct LocalFavoritesDetail: View {
    @Environment(NeteaseAccount.self) private var account

    private struct LoadRequest: Equatable {
        let revision: UUID
        let playlistID: Int64
    }

    private var loadRequest: LoadRequest? {
        guard account.hasRestored, let music = account.music, music.userID != nil,
              let favorites = music.playlists.first(where: \.isFavorites) else { return nil }
        return LoadRequest(revision: music.sessionRevision, playlistID: favorites.id)
    }

    var body: some View {
        if let detail = LocalLibrary.playlistDetail("favorites") {
            let hasMore = LocalLibrary.playlistLibrary.onlineHasMore.contains("favorites")
            let totalCount = LocalLibrary.playlistLibrary.onlineTrackCounts["favorites"]
            CollectionDetailView(
                detail: detail,
                hasMoreSongs: hasMore,
                totalSongCount: totalCount,
                onReachedEnd: {
                    guard LocalLibrary.playlistLibrary.onlineHasMore.contains("favorites"),
                          LocalLibrary.playlistLibrary.onlineErrors["favorites"] == nil else { return }
                    Task { await LocalLibrary.playlistLibrary.loadMoreOnlinePlaylist?("favorites") }
                },
                onPrepareCompleteCollection: {
                    _ = await LocalLibrary.playlistLibrary.prepareCompleteCollection("favorites")
                }
            )
                .task(id: loadRequest) {
                    guard loadRequest != nil else { return }
                    await loadFavorites()
                }
                .refreshable { await loadFavorites(force: true) }
        }
    }

    private func loadFavorites(force: Bool = false) async {
        guard let music = account.music else { return }
        let revision = music.sessionRevision
        await music.loadFavoritesPreview(force: force)
        guard revision == music.sessionRevision, !Task.isCancelled else { return }
        let playlistError = music.playlists.first(where: \.isFavorites).flatMap { music.playlistErrors[$0.id] }
        if let message = playlistError ?? music.error { LocalLibrary.toasts.show(.error(message)) }
    }
}

extension PinnedOrderID {
    init?(route: LibraryRoute) {
        switch route {
        case .playlist(let id): self.init(kind: .playlist, id: id)
        case .album(let id): self.init(kind: .album, id: id)
        default: return nil
        }
    }
}
