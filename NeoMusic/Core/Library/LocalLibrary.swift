import SwiftUI

/// 本地资料库与现有页面的装配入口。
@MainActor
enum LocalLibrary {
    static let runtime = LocalLibraryRuntime()
    static let catalog = LibraryCatalog()
    static let songLibrary = SongLibrary(songs: [])
    static var songs: [LibrarySongItem] { songLibrary.songs.filter { !deletedAlbums.ids.contains($0.albumID) } }
    static var allSongs: [LibrarySongItem] { songLibrary.allSongs.filter { $0.isOnline || !deletedAlbums.ids.contains($0.albumID) } }
    private static func song(id: String) -> LibrarySongItem? {
        guard let song = songLibrary.song(id: id), song.isOnline || !deletedAlbums.ids.contains(song.albumID) else { return nil }
        return song
    }
    static var favorites: [LibrarySongItem] { SongLibrary.orderedFavorites(allSongs) }
    static let pinnedAlbums = LibrarySelectionSet(ids: [], key: "pinnedAlbums")
    private static let pinnedOrder = PinnedOrderStore()
    static let favoriteAlbums = LibrarySelectionSet(ids: [], key: "favoriteAlbums")
    static let favoriteArtists = LibrarySelectionSet(ids: [], key: "favoriteArtists")
    static let deletedAlbums = LibrarySelectionSet(ids: [], key: "deletedAlbums")
    static let downloads = LibraryDownloads()
    static let toasts = LibraryToastCenter()
    static var collectionDownloadAction: ((LibraryRoute) -> Bool)?
    static var collectionRemovalAction: ((LibraryRoute) -> Bool)?
    static var collectionDownloadedState: ((LibraryRoute) -> Bool?)?
    static var collectionCanDownload: ((LibraryRoute) -> Bool)?
    static var collectionCanRemoveDownload: ((LibraryRoute) -> Bool)?
    static var collectionStopDownload: ((LibraryRoute) -> Void)?
    static var downloadedAlbumID: ((String) -> String?)?
    static var prepareSongForLibraryAction: ((LibrarySongItem) -> LibrarySongItem?)?
    private static func albumSongs(_ id: String) -> [LibrarySongItem] {
        guard !deletedAlbums.ids.contains(id) else { return [] }
        return songLibrary.albumIndex.songIDsByAlbum[id, default: []].compactMap { songLibrary.song(id: $0) }
    }
    static func isAlbumDownloaded(_ id: String) -> Bool { !albumSongs(id).isEmpty }
    static var albums: [LibraryShelfItem] {
        catalog.albums.filter { downloadedAlbumID?($0.id) == nil } + songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
    }
    private static func albumItem(_ id: String) -> LibraryShelfItem? {
        guard !deletedAlbums.ids.contains(id), let item = songLibrary.albumIndex.itemsByID[id] else { return nil }
        return withPinState(item)
    }
    static var downloadedAlbumItems: [LibraryShelfItem] { albums.filter { !$0.id.hasPrefix("catalog:") } }

    /// 专辑的置顶、喜爱状态以 `pinnedAlbums`、`favoriteAlbums` 为准。
    private static func withPinState(_ album: LibraryShelfItem) -> LibraryShelfItem {
        var album = album
        album.isPinned = pinnedAlbums.ids.contains(album.id)
        album.isFavorite = favoriteAlbums.ids.contains(album.id)
        return album
    }

    /// 最近添加：先是用户自己的播放列表（副标题为作者），后接专辑，对照 Apple Music。
    static var recentlyAdded: [LibraryShelfItem] {
        let playlists = playlistLibrary.playlists.filter { !$0.isSystem }.sorted { $0.addedOrder > $1.addedOrder }.map { playlist in
            var shown = playlist
            shown.artwork = playlistLibrary.displayArtwork(of: playlist)
            var item = shown.shelfItem
            if !playlist.isReadOnly { item.subtitle = "我" }
            return item
        }
        return playlists + albums.sorted { $0.addedOrder > $1.addedOrder }.prefix(6).map(withPinState)
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
    static var artists: [LibraryArtistItem] {
        catalog.artists + Set(songs.map(\.albumArtist)).sorted().map { LibraryArtistItem(id: $0, name: $0, isFavorite: favoriteArtists.ids.contains($0)) }
    }
    static func albumDetail(_ id: String) -> CollectionDetail? {
        let orderedSongs = albumSongs(id)
        guard let album = albumItem(id) else { return nil }
        return CollectionDetail(kind: .album, title: album.title, subtitle: album.subtitle, caption: nil,
            artwork: album.artwork, tint: Color(.systemBackground), albumBackdrop: orderedSongs.first?.artworkBackdrop, isFavorite: favoriteAlbums.ids.contains(id),
            isPinned: pinnedAlbums.ids.contains(id), songs: orderedSongs, route: .album(id))
    }
    static func playlistDetail(_ id: String) -> CollectionDetail? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        return CollectionDetail(kind: .playlist, title: playlist.title, subtitle: nil, caption: nil,
            artwork: playlist.artwork, tint: Color(.systemBackground), isFavorite: playlist.isFavorite,
            isPinned: playlist.isPinned, songs: id == "favorites" ? favorites : playlistLibrary.songs(in: id), route: .playlist(id))
    }
    static func artistDetail(_ id: String) -> ArtistDetail? {
        let albums = songLibrary.albumIndex.albumIDsByArtist[id, default: []].compactMap(albumItem)
        guard !albums.isEmpty else { return nil }
        return ArtistDetail(name: id, artwork: albums.first?.artwork, isFavorite: favoriteArtists.ids.contains(id), albums: albums, id: id, songs: songs.filter { $0.albumArtist == id })
    }
    static let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, elapsed: 0)

    static let referencePlayer = ReferencePlayerState(model: player)
    static let referenceLibrary = ReferenceLibrary(reader: ReferenceLyricsReader(
        storageDirectory: URL.applicationSupportDirectory.appending(path: "Lyrics", directoryHint: .isDirectory),
        root: runtime.root,
        resolveAudioURL: { id in
            let url = runtime.root.appending(path: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }))

    private static func playerActions(openRoute: @escaping (LibraryRoute) -> Void) -> ReferencePlayerActions {
        ReferencePlayerActions(
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
                if song.isOnline { catalog.openSongAlbum?(id, openRoute) }
                else { openRoute(.album(song.albumID)) }
            },
            openArtist: { id in
                guard let song = song(id: id) else { return }
                if song.isOnline { catalog.openSongArtist?(id, nil, openRoute) }
                else { openRoute(.artist(song.albumArtist)) }
            }, artistNames: { id in
                let refs = song(id: id)?.artistReferences ?? []
                return refs.map(\.name)
            }, openNamedArtist: { id, name in
                guard let song = song(id: id) else { return }
                if song.isOnline { catalog.openSongArtist?(id, name, openRoute) }
                else { openRoute(.artist(song.albumArtist)) }
            })
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
                case .playlist(let id): playlistLibrary.canDelete(id)
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
                    for song in removed { playlistLibrary.removeSongEverywhere(song.id) }
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
            removeFromFavorites: { songLibrary.setFavorite($0.id, false) },
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
                playlistLibrary.removeSongEverywhere(song.id)
            },
            // 对照 Apple Music：播放中显示“随后播放”与来源；暂停时为“添加到队列”。
            playbackSource: { player.isPlaying ? player.sourceTitle : nil }
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
    }

    static func playSongs(_ songs: [LibrarySongItem], shuffled: Bool) {
        player.requestPlay(songs, from: "歌曲", shuffled: shuffled)
    }

    static func playAlbums(_ ids: [String], shuffled: Bool) {
        if ids.contains(where: { $0.hasPrefix("catalog:") }) {
            Task {
                do {
                    var songs: [LibrarySongItem] = []
                    for id in ids {
                        if id.hasPrefix("catalog:"), let load = catalog.loadAlbumSongs { songs += try await load(id) }
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
        case .category(.downloaded): DownloadedMockView(albums: downloadedAlbumItems.map(withPinState))
        case .downloadedCategory(.songs): SongsListView(songs: songs.filter { downloads.state(of: $0.id) == .downloaded }, playAll: playSongs)
        case .downloadedCategory(.albums): AlbumsGridView(albums: downloadedAlbumItems.map(withPinState), playAll: playAlbums)
        case .downloadedCategory(.artists): ArtistsListView(artists: artists.filter { !$0.id.hasPrefix("catalog:") })
        case .downloadedCategory(.playlists): PlaylistsListView(library: downloadedPlaylists)
        case .downloadedCategory(.downloaded): EmptyView()
        case .category(.songs): SongsListView(songs: songs, playAll: playSongs)
        case .category(.albums): AlbumsGridView(albums: albums.map(withPinState), playAll: playAlbums)
        case .category(.artists): ArtistsListView(artists: artists)
        case .category(.playlists): PlaylistsListView(library: playlistLibrary)
        case .playlistFolder(let id): PlaylistsListView(library: playlistLibrary, folderID: id)
        case .album(let id): albumDetail(id).map(CollectionDetailView.init)
        case .playlist(let id):
            if id == "favorites" { LocalFavoritesDetail() }
            else { PlaylistDetailView(playlistID: id, library: playlistLibrary, songs: [], availableSongs: { allSongs }, recentlyPlayedSongs: recentPlaybackFixture) }
        case .artist(let id): artistDetail(id).map { ArtistDetailView(detail: $0) }
        case .artistSection(let id, let section): artistDetail(id).map { ArtistSectionView(detail: $0, section: section) }
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
        if let index = args.firstIndex(of: "-catalogArtist"), args.indices.contains(index + 1), Int64(args[index + 1]) != nil { return [.artist("catalog:artist:" + args[index + 1])] }
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
            "artist": [.category(.artists), .artist("磁带君")],
            "folder": [.category(.playlists), .playlistFolder("111")],
        ]
        return pages[page] ?? []
    }


}

/// 在首页自己的 body 里读取置顶状态：置顶变化只刷新首页，不会让上层重建而重置首页的编辑状态。
struct LocalLibraryHome: View {
    var body: some View {
        let ready = LocalLibrary.runtime.isInitialPresentationReady && LocalLibrary.runtime.isInitialLibraryReady
        LibraryHomeView(pinned: ready ? LocalLibrary.pinned : [], recentlyAdded: ready ? LocalLibrary.recentlyAdded : [],
                        playlistLibrary: LocalLibrary.playlistLibrary,
                        isContentReady: ready,
                        reorderPinned: LocalLibrary.reorderPinned)
            .safeAreaInset(edge: .bottom) {
                if ready, !LocalLibrary.runtime.isScanning, LocalLibrary.songs.isEmpty {
                    VStack(spacing: 8) {
                        Text("将音乐放入“文件 → 我的 iPhone → NeoMusic → 音乐”").font(.callout)
                        Text("支持 MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF，可包含子文件夹。").font(.caption).foregroundStyle(.secondary)
                        Button("在文件中打开") {
                            var components = URLComponents(url: LocalLibrary.runtime.root, resolvingAgainstBaseURL: false)
                            components?.scheme = "shareddocuments"
                            if let url = components?.url { UIApplication.shared.open(url) }
                        }
                    }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                if let status = LocalLibrary.runtime.status { Text(status).font(.caption).padding() }
                if let error = LocalLibrary.player.errorMessage { Text(error).font(.caption).foregroundStyle(.red).padding() }
                if let error = LocalLibrary.playlistLibrary.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding() }
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

/// A typed identity prevents a playlist and an album with the same ID from colliding.
struct PinnedOrderID: Hashable, Codable {
    enum Kind: String, Codable { case playlist, album }
    let kind: Kind
    let id: String

    init(kind: Kind, id: String) { self.kind = kind; self.id = id }

    init?(route: LibraryRoute) {
        switch route {
        case .playlist(let id): self.init(kind: .playlist, id: id)
        case .album(let id): self.init(kind: .album, id: id)
        default: return nil
        }
    }
}

/// Pin flags remain authoritative. The order is independent, so partial loading,
/// a missing file, or a cancelled scan cannot erase a user's saved positions.
@MainActor @Observable
final class PinnedOrderStore {
    private(set) var order: [PinnedOrderID]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let canWrite: Bool

    init(defaults: UserDefaults = .standard, key: String = "pinnedShelfOrder.v1") {
        self.defaults = defaults
        self.key = key
        if let stored = defaults.object(forKey: key) {
            if let data = stored as? Data, let decoded = try? JSONDecoder().decode([PinnedOrderID].self, from: data) {
                var seen = Set<PinnedOrderID>()
                order = decoded.filter { seen.insert($0).inserted }
                canWrite = true
            } else {
                // A future version or damaged value must never be silently overwritten.
                order = []
                canWrite = false
            }
        } else {
            order = []
            canWrite = true
        }
    }

    /// Unseen pins append in the existing library order; unavailable pins retain their stored positions.
    func ordered<T>(_ items: [T], id: (T) -> PinnedOrderID?) -> [T] {
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted { lhs, rhs in
            let left = id(lhs.element).flatMap { ranks[$0] } ?? Int.max
            let right = id(rhs.element).flatMap { ranks[$0] } ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Rearrange only a complete permutation of current pins. Hidden/unloaded IDs keep their slots.
    @discardableResult
    func reorder(visible: [PinnedOrderID], to requested: [PinnedOrderID]) -> Bool {
        let visibleSet = Set(visible)
        guard canWrite, visible.count == visibleSet.count, requested.count == visible.count,
              Set(requested) == visibleSet else { return false }
        let saved = Set(order)
        let all = order + visible.filter { !saved.contains($0) }
        var next = 0
        let updated = all.map { id in
            guard visibleSet.contains(id) else { return id }
            defer { next += 1 }
            return requested[next]
        }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: key)
        order = updated
        return true
    }
}

/// 持久化选择集合。
@MainActor @Observable
final class LibrarySelectionSet {
    private(set) var ids: Set<String> { didSet { if let key { UserDefaults.standard.set(Array(ids), forKey: key) } } }
    private let key: String?
    init(ids: Set<String>, key: String? = nil) {
        self.key = key
        self.ids = key.flatMap { UserDefaults.standard.stringArray(forKey: $0) }.map(Set.init) ?? ids
    }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func insert(_ id: String) { ids.insert(id) }
    func remove(_ id: String) { ids.remove(id) }
}

/// Album ordering and cover selection change with local metadata, independently of favorites and pins.
@MainActor
final class LocalAlbumIndex {
    let items: [LibraryShelfItem]
    let itemsByID: [String: LibraryShelfItem]
    let songIDsByAlbum: [String: [String]]
    let albumIDsByArtist: [String: [String]]

    init(songs: [LibrarySongItem]) {
        let groups = Dictionary(grouping: songs, by: \.albumID)
        var items: [LibraryShelfItem] = []
        var songIDs: [String: [String]] = [:]
        var artistAlbums: [String: [String]] = [:]
        for id in groups.keys.sorted() {
            let members = groups[id, default: []].sorted(by: LibrarySongItem.albumOrder)
            guard let first = members.first else { continue }
            var credits: [String] = []
            for member in members where !credits.contains(member.albumArtist) { credits.append(member.albumArtist) }
            items.append(LibraryShelfItem(id: id, title: first.album, subtitle: credits.joined(separator: " / "),
                                          artwork: first.artwork, route: .album(id),
                                          addedOrder: members.map(\.addedOrder).max() ?? 0))
            songIDs[id] = members.map(\.id)
            for artist in credits { artistAlbums[artist, default: []].append(id) }
        }
        self.items = items
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        songIDsByAlbum = songIDs
        albumIDsByArtist = artistAlbums
    }

    /// Called on mutation only; reads reuse the prepared index without inspecting the song array.
    static func hasSameMetadata(_ lhs: [LibrarySongItem], _ rhs: [LibrarySongItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.albumID == b.albumID && a.album == b.album && a.albumArtist == b.albumArtist
                && a.trackNumber == b.trackNumber && a.discNumber == b.discNumber
                && a.artwork == b.artwork && a.addedOrder == b.addedOrder
        }
    }
}

/// 共享歌曲记录与持久化喜爱状态。
@MainActor @Observable
final class SongLibrary {
    private(set) var songs: [LibrarySongItem] {
        didSet {
            rebuildCatalog()
            if !LocalAlbumIndex.hasSameMetadata(oldValue, songs) { albumIndex = LocalAlbumIndex(songs: songs) }
        }
    }
    private(set) var albumIndex = LocalAlbumIndex(songs: [])
    private(set) var onlineSongs: [LibrarySongItem] = [] { didSet { rebuildCatalog() } }
    private(set) var externalSongs: [LibrarySongItem] = [] { didSet { rebuildCatalog() } }
    private var externalSources: [String: [LibrarySongItem]] = [:]
    private(set) var allSongs: [LibrarySongItem] = []
    private var songsByID: [String: LibrarySongItem] = [:]
    @ObservationIgnored var downloadedFileID: (@MainActor (String) -> String?)?
    @ObservationIgnored var downloadedFavoriteAction: (@MainActor (LibrarySongItem, Bool) -> Bool)?

    func refreshDownloadPresentation() { rebuildCatalog() }

    func updateLocalMetadata(_ replacements: [String: LibrarySongItem]) {
        let updated = songs.map { replacements[$0.id] ?? $0 }
        if songs != updated { songs = updated }
    }

    func song(id: String) -> LibrarySongItem? { songsByID[id] }

    private func rebuildCatalog() {
        let existing = Set((songs + onlineSongs).map(\.id))
        let candidates = songs + onlineSongs + externalSongs.filter { !existing.contains($0.id) }
        var visibleFileIDs = Set(songs.map(\.id))
        let updated = candidates.filter { song in
            guard song.isOnline, let localID = downloadedFileID?(song.id) else { return true }
            return visibleFileIDs.insert(localID).inserted
        }
        if allSongs != updated { allSongs = updated }
        // Detail routes and old queue entries keep their original online identity.
        songsByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    func replaceExternalSongs(_ values: [LibrarySongItem], source: String = "home") {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard externalSources[source] != values else { return }
            externalSources[source] = values
            var seen = Set<String>()
            let updated = externalSources.keys.sorted().flatMap { externalSources[$0] ?? [] }.filter { $0.isOnline && seen.insert($0.id).inserted }
            if externalSongs != updated { externalSongs = updated }
        }
    }
    @ObservationIgnored var onlineFavoriteAction: (@MainActor (String, Bool) -> Void)?
    private let defaults: UserDefaults
    init(songs: [LibrarySongItem], defaults: UserDefaults = .standard) {
        self.songs = []
        self.defaults = defaults
        replace(songs)
    }

    func replace(_ songs: [LibrarySongItem]) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let dates = defaults.dictionary(forKey: "favoriteSongDates") as? [String: Double] ?? [:]
            let updated = songs.map { song in
                var song = song
                if song.isFavorite { song.favoriteAddedAt = dates[song.id].map(Date.init(timeIntervalSince1970:)) }
                return song
            }
            if self.songs != updated { self.songs = updated }
        }
    }

    @discardableResult
    func replaceOnline(_ songs: [LibrarySongItem]) -> Bool {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction) {
            var seen: Set<String> = []
            let updated = songs.filter { $0.isOnline && seen.insert($0.id).inserted }
            guard onlineSongs != updated else { return false }
            onlineSongs = updated
            return true
        }
    }

    /// Image arrivals update their owning catalog without reloading playback availability.
    func updateOnlineArtwork(_ replacements: [String: LibrarySongItem], source: String? = nil) {
        guard !replacements.isEmpty else { return }
        if let source {
            let existing = externalSources[source] ?? []
            replaceExternalSongs(existing.map { item in replacements[item.id].map { item.replacingArtwork(from: $0) } ?? item }, source: source)
        } else {
            let updated = onlineSongs.map { item in replacements[item.id].map { item.replacingArtwork(from: $0) } ?? item }
            if onlineSongs != updated { onlineSongs = updated }
        }
    }

    static func orderedFavorites(_ songs: [LibrarySongItem]) -> [LibrarySongItem] {
        songs.enumerated().filter { $0.element.isFavorite }.sorted { lhs, rhs in
            switch (lhs.element.favoriteAddedAt, rhs.element.favoriteAddedAt) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func setFavorite(_ id: String, _ value: Bool) {
        if let song = song(id: id), downloadedFavoriteAction?(song, value) == true { return }
        if let song = song(id: id), song.isOnline {
            if song.isFavorite != value { onlineFavoriteAction?(id, value) }
            return
        }
        guard let index = songs.firstIndex(where: { $0.id == id }), songs[index].isFavorite != value else { return }
        var updated = songs[index]
        updated.isFavorite = value
        var ids = Set(defaults.stringArray(forKey: "favoriteSongs") ?? [])
        if value { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: "favoriteSongs")
        var dates = defaults.dictionary(forKey: "favoriteSongDates") as? [String: Double] ?? [:]
        let date = value ? Date() : nil
        dates[id] = date?.timeIntervalSince1970
        defaults.set(dates, forKey: "favoriteSongDates")
        updated.favoriteAddedAt = date
        songs[index] = updated
    }

    func toggleFavorite(_ id: String) {
        guard let song = song(id: id) else { return }
        setFavorite(id, !song.isFavorite)
    }

    func togglePin(_ id: String) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].isPinned.toggle()
        LocalLibraryRuntime.setFlag(id, value: songs[index].isPinned, key: "pinnedSongs")
    }

    func delete(_ id: String) { LocalLibraryRuntime.setFlag(id, value: true, key: "hiddenSongs"); songs.removeAll { $0.id == id } }
}

private struct LocalFavoritesDetail: View {
    var body: some View {
        if let detail = LocalLibrary.playlistDetail("favorites") { CollectionDetailView(detail: detail) }
    }
}
