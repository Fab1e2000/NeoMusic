import FullScreenPlayer
import SwiftUI

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let catalog = LibraryCatalog()
    let songLibrary = SongLibrary(songs: [])
    let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, elapsed: 0)
    let playlistLibrary = PlaylistLibrary(playlists: [
        LibraryPlaylistItem(id: "favorites", title: "喜爱歌曲", artwork: .favorites,
                            isFavorite: true, isPinned: true, isSystem: true)
    ])
    let downloadedPlaylistView = PlaylistLibrary(playlists: [])
    let downloads = LibraryDownloads()
    let toasts = LibraryToastCenter()
    let pinnedAlbums = LibrarySelectionSet(ids: [], key: AppDefaultsKey.pinnedAlbums)
    let pinnedOrder = PinnedOrderStore()
    let favoriteAlbums = LibrarySelectionSet(ids: [], key: AppDefaultsKey.favoriteAlbums)
    let favoriteArtists = LibrarySelectionSet(ids: [], key: AppDefaultsKey.favoriteArtists)
    let artistPreferences = LibraryArtistPreferences()
    let deletedAlbums = LibrarySelectionSet(ids: [], key: AppDefaultsKey.deletedAlbums)
    var collectionDownloads = CollectionDownloadHandling()
    var prepareSongForLibraryAction: ((LibrarySongItem) -> LibrarySongItem?)?
    var playbackAccountID: String?

    private(set) lazy var runtime = LocalLibraryRuntime(
        songLibrary: songLibrary, playlistLibrary: playlistLibrary, player: player,
        favoriteAlbums: favoriteAlbums, pinnedAlbums: pinnedAlbums, deletedAlbums: deletedAlbums,
        onLocalSongsApplied: { [artistPreferences, downloads] in
            artistPreferences.registerLocalCredits(in: $0)
            downloads.setLocalSongs($0)
        })

    private(set) lazy var referencePlayer = PlayerState(model: player)
    private(set) lazy var referenceLibrary: PlayerLyricsController = {
        let root = runtime.root
        return PlayerLyricsController(reader: PlayerLyricsStoreAdapter(
            storageDirectory: AppStoragePaths.lyrics,
            root: root,
            resolveAudioURL: { id in
                let url = root.appending(path: id)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }))
    }()
}

// Legacy previews and tests share the same dependencies as the default app runtime.
@MainActor
enum LocalLibrary {
    private static var shared: AppContainer { .shared }

    static var runtime: LocalLibraryRuntime { shared.runtime }
    static var catalog: LibraryCatalog { shared.catalog }
    static var songLibrary: SongLibrary { shared.songLibrary }
    static var player: NowPlayingModel { shared.player }
    static var playlistLibrary: PlaylistLibrary { shared.playlistLibrary }
    static var downloads: LibraryDownloads { shared.downloads }
    static var toasts: LibraryToastCenter { shared.toasts }
    static var pinnedAlbums: LibrarySelectionSet { shared.pinnedAlbums }
    static var favoriteAlbums: LibrarySelectionSet { shared.favoriteAlbums }
    static var favoriteArtists: LibrarySelectionSet { shared.favoriteArtists }
    static var deletedAlbums: LibrarySelectionSet { shared.deletedAlbums }
    static var referenceLibrary: PlayerLyricsController { shared.referenceLibrary }
    static var referencePlayer: PlayerState { shared.referencePlayer }
    static var playbackAccountID: String? {
        get { shared.playbackAccountID }
        set { shared.playbackAccountID = newValue }
    }

    static var songs: [LibrarySongItem] { shared.songs }
    static var allSongs: [LibrarySongItem] { shared.allSongs }
    static var favorites: [LibrarySongItem] { shared.favorites }
    static var albums: [LibraryShelfItem] { shared.albums }
    static var artists: [LibraryArtistItem] { shared.artists }
    static var playlists: [LibraryPlaylistItem] { shared.playlists }
    static var pinned: [LibraryShelfItem] { shared.pinned }
    static var recentlyAdded: [LibraryShelfItem] { shared.recentlyAdded }
    static var menuActions: CollectionMenuActions { shared.menuActions }
    static var app: some View { shared.app }

    static func favoriteRows(online: [LibrarySongItem], favorites: [LibrarySongItem],
                             downloadedSongID: (String) -> Int64?) -> [LibrarySongItem] {
        AppContainer.favoriteRows(online: online, favorites: favorites, downloadedSongID: downloadedSongID)
    }

    static func albumDetail(_ id: String) -> CollectionDetail? { shared.albumDetail(id) }
    static func playlistDetail(_ id: String) -> CollectionDetail? { shared.playlistDetail(id) }
    static func songActions(for route: LibraryRoute) -> SongMenuActions { shared.songActions(for: route) }
    static func songAlbumPreview(_ song: LibrarySongItem, route: LibraryRoute) -> LibraryNavigationPreview? {
        shared.songAlbumPreview(song, route: route)
    }
}
