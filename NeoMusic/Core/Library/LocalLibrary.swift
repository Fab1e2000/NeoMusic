import SwiftUI

/// 本地资料库与现有页面的装配入口。
@MainActor
enum LocalLibrary {
    static let runtime = LocalLibraryRuntime()
    static let songLibrary = SongLibrary(songs: [])
    static var songs: [LibrarySongItem] { songLibrary.songs.filter { !deletedAlbums.ids.contains($0.albumID) } }
    static let pinnedAlbums = LibrarySelectionSet(ids: [], key: "pinnedAlbums")
    private static let pinnedOrder = PinnedOrderStore()
    static let favoriteAlbums = LibrarySelectionSet(ids: [], key: "favoriteAlbums")
    static let favoriteArtists = LibrarySelectionSet(ids: [], key: "favoriteArtists")
    static let deletedAlbums = LibrarySelectionSet(ids: [], key: "deletedAlbums")
    static let downloads = LibraryDownloads()
    static let toasts = LibraryToastCenter()
    private static func albumSongs(_ id: String) -> [LibrarySongItem] { songs.filter { $0.albumID == id } }
    static func isAlbumDownloaded(_ id: String) -> Bool { !albumSongs(id).isEmpty }
    static var albums: [LibraryShelfItem] {
        let grouped = Dictionary(grouping: songs, by: \.albumID)
        return grouped.keys.sorted().compactMap { id in
            albumItem(id, orderedSongs: grouped[id, default: []].sorted(by: LibrarySongItem.albumOrder))
        }
    }
    private static func albumItem(_ id: String, orderedSongs: [LibrarySongItem]) -> LibraryShelfItem? {
        guard let song = orderedSongs.first else { return nil }
        var credits: [String] = []
        for member in orderedSongs where !credits.contains(member.albumArtist) { credits.append(member.albumArtist) }
        return LibraryShelfItem(id: id, title: song.album, subtitle: credits.joined(separator: " / "), artwork: song.artwork,
            route: .album(id), isFavorite: favoriteAlbums.ids.contains(id), isPinned: pinnedAlbums.ids.contains(id),
            addedOrder: orderedSongs.map(\.addedOrder).max() ?? 0)
    }
    static var downloadedAlbumItems: [LibraryShelfItem] { albums }

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
            item.subtitle = "我"
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
    static var downloadedPlaylists: PlaylistLibrary { playlistLibrary }
    static var playlists: [LibraryPlaylistItem] { playlistLibrary.playlists }
    static var artists: [LibraryArtistItem] {
        Set(songs.map(\.albumArtist)).sorted().map { LibraryArtistItem(id: $0, name: $0, isFavorite: favoriteArtists.ids.contains($0)) }
    }
    static func albumDetail(_ id: String) -> CollectionDetail? {
        let orderedSongs = albumSongs(id).sorted(by: LibrarySongItem.albumOrder)
        guard let album = albumItem(id, orderedSongs: orderedSongs) else { return nil }
        return CollectionDetail(kind: .album, title: album.title, subtitle: album.subtitle, caption: nil,
            artwork: album.artwork, tint: Color(.systemBackground), albumBackdrop: orderedSongs.first?.artworkBackdrop, isFavorite: favoriteAlbums.ids.contains(id),
            isPinned: pinnedAlbums.ids.contains(id), songs: orderedSongs, route: .album(id))
    }
    static func playlistDetail(_ id: String) -> CollectionDetail? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        return CollectionDetail(kind: .playlist, title: playlist.title, subtitle: nil, caption: nil,
            artwork: playlist.artwork, tint: Color(.systemBackground), isFavorite: playlist.isFavorite,
            isPinned: playlist.isPinned, songs: id == "favorites" ? songs.filter(\.isFavorite) : playlistLibrary.songs(in: id), route: .playlist(id))
    }
    static func artistDetail(_ id: String) -> ArtistDetail? {
        let grouped = Dictionary(grouping: songs, by: \.albumID)
            .filter { $0.value.contains { $0.albumArtist == id } }
        guard !grouped.isEmpty else { return nil }
        let albums = grouped.keys.sorted().compactMap { albumID in
            albumItem(albumID, orderedSongs: grouped[albumID, default: []].sorted(by: LibrarySongItem.albumOrder))
        }
        return ArtistDetail(name: id, artwork: nil, isFavorite: favoriteArtists.ids.contains(id), albums: albums)
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
            isFavorite: { id in songs.first { $0.id == id }?.isFavorite == true },
            toggleFavorite: { songLibrary.toggleFavorite($0) },
            addToPlaylist: { id in
                guard let song = songs.first(where: { $0.id == id }) else { return }
                playlistLibrary.pendingAddition = .init(songs: [song])
            },
            openAlbum: { id in
                guard let song = songs.first(where: { $0.id == id }) else { return }
                openRoute(.album(song.albumID))
            },
            openArtist: { id in
                guard let song = songs.first(where: { $0.id == id }) else { return }
                openRoute(.artist(song.albumArtist))
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

    /// 集合菜单操作接入播放队列与持久化资料库。
    private static var menuActions: CollectionMenuActions {
        CollectionMenuActions(
            play: { route, shuffled in
                guard let collection = collection(route) else { return }
                player.requestPlay(collection.songs, from: collection.title, shuffled: shuffled)
            },
            playNext: { route in collection(route).map { player.insertNext($0.songs) } },
            playLater: { route in collection(route).map { player.appendLater($0.songs) } },
            toggleFavorite: { route in
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
                guard let collection = collection(route) else { return }
                playlistLibrary.pendingAddition = .init(songs: collection.songs)
            },
            playbackSource: { player.isPlaying ? player.sourceTitle : nil },
            requestMove: { playlistLibrary.pendingMove = playlistLibrary.playlist($0) },
            // 资料库里的所有专辑与用户播放列表都可以删除；系统播放列表不能。
            canDelete: { route in
                switch route {
                case .playlist(let id): playlistLibrary.canDelete(id)
                case .album: true
                default: false
                }
            },
            isDownloaded: { route in
                if case .album(let id) = route { isAlbumDownloaded(id) } else { false }
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
                if case .album(let id) = route { downloads.remove(albumSongs(id)) }
            },
            download: { route in
                if case .album(let id) = route { downloads.download(albumSongs(id)) }
            }
        )
    }

    /// 歌曲播放与持久化资料库操作。
    private static var songActions: SongMenuActions {
        SongMenuActions(
            play: { songs, index, source in player.requestPlay(songs, startingAt: index, from: source) },
            playNext: { player.insertNext([$0]) },
            toggleFavorite: { songLibrary.toggleFavorite($0.id) },
            removeFromFavorites: { songLibrary.setFavorite($0.id, false) },
            togglePin: { songLibrary.togglePin($0.id) },
            addToPlaylist: { playlistLibrary.pendingAddition = .init(songs: [$0]) },
            playLater: { player.appendLater([$0]) },
            delete: { song in
                songLibrary.delete(song.id)
                playlistLibrary.removeSongEverywhere(song.id)
            },
            // 对照 Apple Music：播放中显示“随后播放”与来源；暂停时为“添加到队列”。
            playbackSource: { player.isPlaying ? player.sourceTitle : nil }
        )
    }

    /// 应用装配：标签栏、迷你播放条与资料库各页。
    static var app: some View {
        AppShell(library: {
            LocalLibraryHome()
        }, detailDestination: { AnyView(LocalDestination(route: $0)) }, nowPlaying: player, playlistLibrary: playlistLibrary, toasts: toasts,
           referencePlayer: referencePlayer, referenceLibrary: referenceLibrary, makePlayerActions: playerActions, libraryPath: launchPath, isPlayerPresented: ["nowplaying", "paused", "queue"].contains(launchPage))
        .playlistEditSheet(playlistLibrary, songs: songs)
        .environment(\.libraryDownloads, downloads)
        .environment(\.collectionMenuActions, menuActions)
        .environment(\.songMenuActions, songActions)
        .environment(\.songRowPlayback, player)
    }

    static func playSongs(_ songs: [LibrarySongItem], shuffled: Bool) {
        player.requestPlay(songs, from: "歌曲", shuffled: shuffled)
    }

    static func playAlbums(_ ids: [String], shuffled: Bool) {
        let tracks = ids.flatMap { albumDetail($0)?.songs ?? [] }
        player.requestPlay(tracks, from: "专辑", shuffled: shuffled)
    }

    @ViewBuilder fileprivate static func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .category(.downloaded): DownloadedMockView(albums: downloadedAlbumItems.map(withPinState))
        case .downloadedCategory(.songs): SongsListView(songs: songs.filter { downloads.state(of: $0.id) == .downloaded }, playAll: playSongs)
        case .downloadedCategory(.albums): AlbumsGridView(albums: downloadedAlbumItems.map(withPinState), playAll: playAlbums)
        case .downloadedCategory(.artists): ArtistsListView(artists: artists)
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
            else { PlaylistDetailView(playlistID: id, library: playlistLibrary, songs: songs, recentlyPlayedSongs: recentPlaybackFixture) }
        case .artist(let id): artistDetail(id).map(ArtistDetailView.init)
        }
    }

    /// 启动参数 `-mockPage <页面>` 直接打开对应页面，便于截图核对。
    private static var launchPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mockPage"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var launchPath: [LibraryRoute] {
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
        LibraryHomeView(pinned: LocalLibrary.pinned, recentlyAdded: LocalLibrary.recentlyAdded,
                        playlistLibrary: LocalLibrary.playlistLibrary,
                        reorderPinned: LocalLibrary.reorderPinned)
            .refreshable { await LocalLibrary.runtime.refresh() }
            .safeAreaInset(edge: .bottom) {
                if LocalLibrary.songs.isEmpty {
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
            LocalLibrary.destination(route).navigationDiagnostics(route.diagnosticPage).libraryZoomTransition(route, in: zoomNamespace)
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

/// 共享歌曲记录与持久化喜爱状态。
@MainActor @Observable
final class SongLibrary {
    private(set) var songs: [LibrarySongItem]
    init(songs: [LibrarySongItem]) { self.songs = songs }

    func replace(_ songs: [LibrarySongItem]) { self.songs = songs }

    func setFavorite(_ id: String, _ value: Bool) {
        guard let index = songs.firstIndex(where: { $0.id == id }), songs[index].isFavorite != value else { return }
        songs[index].isFavorite = value
        LocalLibraryRuntime.setFlag(id, value: value, key: "favoriteSongs")
    }

    func toggleFavorite(_ id: String) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
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
