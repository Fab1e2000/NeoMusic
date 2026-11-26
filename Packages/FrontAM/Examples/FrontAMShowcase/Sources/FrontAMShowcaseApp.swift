import FrontAM
import SwiftUI
import UIKit

@main
struct FrontAMShowcaseApp: App {
    var body: some Scene {
        WindowGroup { ShowcaseRoot() }
    }
}

private enum ShowcaseTab: String, CaseIterable, Sendable {
    case home, library, search

    var title: String {
        switch self { case .home: "主页"; case .library: "资料库"; case .search: "搜索" }
    }

    var symbol: String {
        switch self { case .home: "house"; case .library: "music.note.list"; case .search: "magnifyingglass" }
    }
}

private struct ShowcaseRoot: View {
    @State private var library = ShowcaseLibrary()
    @State private var selectedTab = ShowcaseTab.home
    @State private var playerPresented = false
    @State private var tabEditorPresented = false
    @State private var navigations = FrontAMTabNavigations<ShowcaseTab, LibraryRoute, LibraryNavigationPreview>(
        initialTabs: ShowcaseTab.allCases, makeNavigation: { makeNavigation() }
    )

    private static let tabStorage = FrontAMTabStorage(orderKey: "showcase.tabOrder", hiddenKey: "showcase.tabHidden")
    private static let tabOrder = FrontAMTabOrder(fixed: [.search], reorderable: [.home, .library], fallback: ShowcaseTab.home,
                                                  decode: ShowcaseTab.init(rawValue:), encode: { $0.rawValue })
    @AppStorage("showcase.tabOrder") private var storedOrder = ""

    var body: some View {
        let navigation = navigations.navigation(for: selectedTab)
        let anchor = library.playback.timelineAnchor
        FrontAMShell(isPlayerPresented: $playerPresented, currentRoute: { navigation.topRoute },
                     openInCurrentTab: { navigation.open($0, preview: $1) }) { open, popupClosed in
            let services = library.playerServices { route in open(route, library.preview(for: route)) }
            FrontAMTabs(selection: $selectedTab, colorScheme: navigation.colorScheme, orderStore: Self.tabStorage,
                        order: { Self.tabOrder.displayed(order: Self.tabStorage.order ?? "", hidden: nil) },
                        items: tabs)
                .modifier(FrontAMPlayerPopup(isPresented: $playerPresented, artwork: services.artwork,
                                             barColorScheme: navigation.colorScheme, onClose: popupClosed,
                                             missingArtwork: { ArtworkView(artwork: .missing) }) { active, dismiss in
                    FullScreenPlayerView(player: library.player, services: services, isActive: active,
                                         onDismiss: dismiss, artworkTransition: FrontAMPopupArtworkTransition())
                })
        }
        .environment(library.player)
        .environment(\.songRowPlayback, library.playback)
        .environment(\.songMenuActions, library.songActions)
        .environment(\.collectionMenuActions, library.collectionActions)
        .environment(\.libraryToastCenter, library.toasts)
        .environment(\.frontAMPageToolbarAccessory, .init { showcaseMenu })
        .addToPlaylistSheet(library.playlists, toasts: library.toasts)
        .moveToFolderSheet(library.playlists)
        .playlistEditSheet(library.playlists, songs: { library.songs })
        .libraryToastFeedback(library.toasts)
        .onChange(of: library.playlists.pendingAddition != nil) { _, isPending in
            if isPending { playerPresented = false }
        }
        .sheet(isPresented: $tabEditorPresented) { tabEditor }
        .task(id: anchor) { await library.playback.advanceWhenFinished(anchor: anchor) }
    }

    private var showcaseMenu: some View {
        Menu {
            Button("排列标签", systemImage: "arrow.up.arrow.down") { tabEditorPresented = true }
            Button("清空队列", systemImage: "trash", role: .destructive) {
                playerPresented = false
                library.playback.clearQueue()
            }
            .disabled(library.playback.currentTrack == nil)
        } label: {
            Label("演示选项", systemImage: "slider.horizontal.3")
        }
    }

    private var tabEditor: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.tabOrder.resolve(storedOrder), id: \.self) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                    }
                    .onMove { indices, destination in
                        var order = Self.tabOrder.resolve(storedOrder)
                        order.move(fromOffsets: indices, toOffset: destination)
                        storedOrder = Self.tabOrder.raw(order)
                    }
                }
                Section { Label(ShowcaseTab.search.title, systemImage: ShowcaseTab.search.symbol) }
            }
            .navigationTitle("排列标签")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { tabEditorPresented = false }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }

    private func tabs(_ environment: EnvironmentValues) -> [FrontAMTabItem<ShowcaseTab>] {
        let library = library
        return ShowcaseTab.allCases.map { tab in
            let navigation = navigations.navigation(for: tab)
            navigation.configure(environment: environment) { route in
                AnyView(ShowcaseDestination(route: route, library: library).libraryToasts(library.toasts))
            }
            return .init(id: tab, identifier: tab.rawValue, title: tab.title,
                         image: UIImage(systemName: tab.symbol), isSearch: tab == .search,
                         makeController: {
                             navigation.makeNavigationController(root: AnyView(tabRoot(tab).libraryToasts(library.toasts)),
                                                                 rootTitle: tab.title)
                         },
                         updateNavigationAppearance: { style in
                             navigation.navigationController?.navigationBar.overrideUserInterfaceStyle =
                                 navigation.colorScheme.map { $0 == .dark ? .dark : .light } ?? style
                         })
        }
    }

    @ViewBuilder private func tabRoot(_ tab: ShowcaseTab) -> some View {
        switch tab {
        case .home: HomeFeedView(model: library.home)
        case .library: ShowcaseLibraryRoot(library: library)
        case .search: SearchPageView(model: library.search)
        }
    }

    private static func makeNavigation() -> FrontAMNavigationStack<LibraryRoute, LibraryNavigationPreview> {
        .init(previewRoute: \.route, initialChrome: { route in
            if case .artist = route { return ("", .never, .dark) }
            return ("", .never, nil)
        }, preparePage: { page, preview, _ in
            if let backdrop = preview?.albumBackdrop {
                page.chrome.setBackdrop(color: backdrop.uiColor, colorScheme: backdrop.colorScheme)
            }
        }, decoratePage: { content, environment, navigation, page, preview in
            let open = OpenLibraryRouteAction(
                handler: { [weak navigation] in navigation?.open($0) },
                previewHandler: { [weak navigation] in navigation?.open($0, preview: $1) },
                sourceHandler: { [weak navigation] in navigation?.open($0, source: $1) },
                sourceProviderHandler: { [weak navigation] in navigation?.open($0, sourceProvider: $1) },
                previewSourceHandler: { [weak navigation] in navigation?.open($0, sourceProvider: $2, preview: $1) }
            )
            return AnyView(content
                .environment(\.frontAMPageToolbarAccessory, environment.frontAMPageToolbarAccessory)
                .environment(\.collectionMenuActions, environment.collectionMenuActions)
                .environment(\.songMenuActions, environment.songMenuActions)
                .environment(\.songRowPlayback, environment.songRowPlayback)
                .environment(\.libraryToastCenter, environment.libraryToastCenter)
                .environment(\.artworkLoadAction, environment.artworkLoadAction)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.nativeArtworkSurfaceEnabled, true)
                .environment(\.libraryRouteDestination, .init(makePage: navigation.destination))
                .environment(\.libraryNavigationPreview, preview)
                .environment(\.openLibraryRoute, open)
                .environment(\.closeLibraryDetail, .init { [weak page] in
                    guard let page, let controller = page.navigationController, controller.topViewController === page else { return }
                    controller.popViewController(animated: true)
                }))
        }, zoomAlignment: { route in
            switch route {
            case .album, .playlist, .libraryArtistAlbum:
                return { $0.libraryArtworkAlignmentRect() }
            case .artist, .libraryArtist:
                return { $0.bounds }
            default:
                return nil
            }
        })
    }
}

private struct ShowcaseLibraryRoot: View {
    let library: ShowcaseLibrary

    var body: some View {
        LibraryHomeView(pinned: library.pinned, recentlyAdded: library.recentlyAdded,
                        playlistLibrary: library.playlists, reorderPinned: library.reorderPinned,
                        playSong: { id in
                            if let song = library.songs.first(where: { $0.id == id }) { library.playSong(song) }
                        }, songForMenu: { id in library.songs.first { $0.id == id } })
    }
}

private struct ShowcaseDestination: View {
    let route: LibraryRoute
    let library: ShowcaseLibrary

    var body: some View {
        switch route {
        case .category(.songs):
            songList(library.songs)
        case .category(.albums):
            AlbumsGridView(albums: library.albums) { ids, shuffled in
                let tracks = ids.flatMap { library.tracks(in: .album($0)) }
                library.play(tracks, source: "专辑", shuffled: shuffled)
            }
        case .category(.artists):
            ArtistsListView(artists: library.artists)
        case .category(.playlists):
            PlaylistsListView(library: library.playlists)
        case .category(.downloaded):
            DownloadedLibraryView(albums: [])
        case .downloadedCategory:
            ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle")
        case .album, .libraryArtistAlbum:
            if let item = library.item(for: route) {
                CollectionDetailView(detail: .init(kind: .album, title: item.title, subtitle: item.subtitle,
                    artwork: item.artwork, tint: .purple, albumBackdrop: item.albumBackdrop,
                    isFavorite: item.isFavorite, isPinned: item.isPinned, songs: library.tracks(in: route), route: route))
            }
        case .playlist(let id):
            PlaylistDetailView(playlistID: id, library: library.playlists, songs: library.songs,
                               availableSongs: { library.songs })
        case .playlistFolder(let id):
            PlaylistsListView(library: library.playlists, folderID: id)
        case .artist(let id):
            if let item = library.item(for: route) {
                ArtistDetailView(detail: .init(name: item.title, artwork: item.artwork,
                    isFavorite: item.isFavorite, albums: library.albums(for: id), id: id,
                    biography: "在不曾存在的城市采集声音，把折线、光点与虚构的站名写成歌。",
                    songs: library.tracks(in: route)), playSong: library.playSong,
                    toggleFavorite: { library.toggleCollectionFavorite(route) })
            }
        case .libraryArtist(let id):
            if let artist = library.artists.first(where: { $0.id == id }) {
                LibraryArtistDetailView(artist: artist,
                    play: { library.playCollection(route, shuffled: $0) })
            }
        case .artistSection(let id, let section):
            if section == .albums {
                AlbumsGridView(albums: library.albums(for: id)) { ids, shuffled in
                    library.play(ids.flatMap { library.tracks(in: .album($0)) }, source: "专辑", shuffled: shuffled)
                }
            } else {
                songList(library.tracks(in: route))
            }
        case .searchCategory(let id):
            SearchCategoryPage(model: library.search, category: id)
                .onAppear { library.showCategory(id) }
        }
    }

    private func songList(_ songs: [LibrarySongItem]) -> some View {
        SongsListView(songs: songs) { tracks, shuffled in
            library.play(tracks, source: library.item(for: route)?.title ?? "歌曲", shuffled: shuffled)
        }
    }
}
