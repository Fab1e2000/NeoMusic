#if DEBUG
import SwiftUI

/// Uses the production chrome and playlist rows with an isolated, unsaved library.
struct OnlineLibraryShellPreview: View {
    @State private var library: PlaylistLibrary
    @State private var player: NowPlayingModel
    @State private var toasts = LibraryToastCenter()
    private let initialPage: String
    private let lyrics: ReferenceLibrary

    init(initialPage: String = "playlists") {
        self.initialPage = initialPage
        let library = PlaylistLibrary(playlists: [
            .init(id: "preview-favorites", title: "喜爱歌曲", artwork: .favorites, isFavorite: true, isSystem: true),
            .init(id: "preview-two", title: "2", artwork: .playlist, addedOrder: 2),
            .init(id: "preview-three", title: "111", artwork: Self.cover, addedOrder: 3),
            .init(id: "preview-child", title: "夜晚散步", artwork: .playlist, addedOrder: 4)
        ], folders: [.init(id: "preview-folder", name: "test", addedOrder: 1)])
        library.move(playlistID: "preview-child", to: "preview-folder")
        _library = State(initialValue: library)
        let song = LibrarySongItem(id: "preview-track", title: "物語りのワルツ", artist: "Isekaijoucho",
                                  album: "", albumArtist: "Isekaijoucho", trackNumber: 1,
                                  artwork: .image(Image("AlbumSample17")), duration: 240)
        _player = State(initialValue: NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false, elapsed: 0))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeoMusicOnlinePreview", isDirectory: true)
        lyrics = ReferenceLibrary(reader: ReferenceLyricsReader(storageDirectory: root, root: root, resolveAudioURL: { _ in nil }))
    }

    private static var cover: Artwork {
        let renderer = ImageRenderer(content:
            LinearGradient(colors: [Color(red: 0.96, green: 0.86, blue: 0.6), .orange, Color(red: 0.3, green: 0.02, blue: 0.01)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topLeading) { Text("111").font(.system(size: 9)).foregroundStyle(.black).padding(5) }
                .frame(width: 64, height: 64))
        renderer.scale = 3
        return renderer.uiImage.map { .image(Image(uiImage: $0)) } ?? .playlist
    }

    private var initialPath: [LibraryRoute] {
        switch initialPage {
        case "favorites": [.category(.playlists), .playlist("preview-favorites")]
        case "detail": [.category(.playlists), .playlist("preview-three")]
        default: [.category(.playlists)]
        }
    }

    var body: some View {
        AppShell(library: {
            LibraryHomeView(pinned: [], recentlyAdded: [], playlistLibrary: library)
        }, detailDestination: { route in
            switch route {
            case .category(.playlists): AnyView(PlaylistsListView(library: library))
            case .playlistFolder(let id): AnyView(PlaylistsListView(library: library, folderID: id))
            case .playlist(let id): AnyView(PlaylistDetailView(playlistID: id, library: library, songs: []))
            default: AnyView(PlaylistsListView(library: library))
            }
        }, nowPlaying: player, playlistLibrary: library, toasts: toasts,
           referencePlayer: ReferencePlayerState(model: player), referenceLibrary: lyrics,
           makePlayerActions: { _ in
               ReferencePlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                                      addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in })
           }, libraryPath: initialPath, isPlayerPresented: initialPage == "queue")
    }
}
#endif
