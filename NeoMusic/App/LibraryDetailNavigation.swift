import FrontAMNavigation
import SwiftUI
import UIKit

typealias LibraryDetailNavigation = FrontAMNavigationStack<LibraryRoute, LibraryNavigationPreview>
typealias LibraryDetailHostingController = FrontAMNavigationPage<LibraryRoute>
typealias LibraryNavigationChrome = FrontAMNavigationChrome
typealias LibraryNavigationContainer<Root: View> = FrontAMNavigationContainer<LibraryRoute, LibraryNavigationPreview, Root>

extension FrontAMNavigationStack where Route == LibraryRoute, Preview == LibraryNavigationPreview {
    convenience init() {
        self.init(rootTitle: "资料库", previewRoute: \.route,
            initialChrome: { route in
                let initial = route.initialCategoryTitle
                return (initial?.title ?? "", initial?.mode == .large ? .always : .never, route.isArtist ? .dark : nil)
            },
            preparePage: { page, preview, environment in
                if page.route?.isArtist == true {
                    page.view.backgroundColor = .black
                } else if let preview, preview.route == page.route,
                          preview.matches(owner: environment[NeteaseAccount.self]?.profile.map { String($0.userID) }),
                          let backdrop = preview.albumBackdrop {
                    page.chrome.setAlbumBackdrop(backdrop)
                }
            },
            decoratePage: { content, environment, navigation, page, preview in
                AnyView(LibraryNavigationPreviewScope(content: content, preview: preview, account: environment[NeteaseAccount.self])
                    .modifier(LibraryHostedPageEnvironment(
                        sourceEnvironment: environment,
                        destination: navigation.destination,
                        openAction: OpenLibraryRouteAction(
                            handler: { [weak navigation] in navigation?.open($0) },
                            previewHandler: { [weak navigation] in navigation?.open($0, preview: $1) },
                            sourceHandler: { [weak navigation] in navigation?.open($0, source: $1) },
                            sourceProviderHandler: { [weak navigation] in navigation?.open($0, sourceProvider: $1) },
                            previewSourceHandler: { [weak navigation] in navigation?.open($0, sourceProvider: $2, preview: $1) }
                        ),
                        closeAction: CloseLibraryDetailAction { [weak page] in
                            guard let page, let nav = page.navigationController, nav.topViewController === page else { return }
                            nav.popViewController(animated: true)
                        }
                    )))
            },
            zoomAlignment: { route in
                switch route {
                case .album, .playlist: return { $0.libraryArtworkAlignmentRect() }
                default: return nil
                }
            },
            onNavigationCreated: { navigation in
                #if DEBUG
                if NavigationDiagnostics.isEnabled { NavigationDiagnostics.recorder.attach(navigation) }
                #endif
            },
            onRouteEvent: { event, route in
                #if DEBUG
                NavigationDiagnostics.event("UIKitLibrary.\(event)", page: route.diagnosticPage)
                #endif
            },
            onPageAppeared: { PerformanceDiagnostics.event("PageAppeared") })
    }
}

extension FrontAMNavigationChrome {
    convenience init(isRoot: Bool, route: LibraryRoute? = nil) {
        let initial = isRoot ? nil : route?.initialCategoryTitle
        self.init(isRoot: isRoot, title: initial?.title ?? (isRoot ? "资料库" : ""),
                  mode: isRoot ? .inline : initial?.mode == .large ? .always : .never)
    }

    func setAlbumBackdrop(_ backdrop: AlbumArtworkBackdrop?) {
        setBackdrop(color: backdrop?.uiColor, colorScheme: backdrop?.colorScheme)
    }

    func setSearchPage(_ model: SearchPageModel) {
        setSearchPage(model.navigationPresentation)
    }
}

extension View {
    func libraryHomeNavigation() -> some View { libraryHomeNavigation(title: "资料库") }
}

private struct LibraryNavigationPreviewScope: View {
    let content: AnyView
    let preview: LibraryNavigationPreview?
    let account: NeteaseAccount?
    var body: some View {
        content.environment(\.libraryNavigationPreview,
            preview?.matches(owner: account?.profile.map { String($0.userID) }) == true ? preview : nil)
    }
}

private struct LibraryHostedPageEnvironment: ViewModifier {
    let sourceEnvironment: EnvironmentValues
    let destination: ((LibraryRoute) -> AnyView)?
    let openAction: OpenLibraryRouteAction
    let closeAction: CloseLibraryDetailAction

    func body(content: Content) -> some View {
        content
            .environment(sourceEnvironment[NeteaseAccount.self])
            .environment(sourceEnvironment[PlaylistLibrary.self])
            .environment(\.collectionMenuActions, sourceEnvironment.collectionMenuActions)
            .environment(\.songMenuActions, sourceEnvironment.songMenuActions)
            .environment(\.songRowPlayback, sourceEnvironment.songRowPlayback)
            .environment(\.songPlaybackIndicatorsActive, sourceEnvironment.songPlaybackIndicatorsActive)
            .environment(\.libraryDownloads, sourceEnvironment.libraryDownloads)
            .environment(\.artworkLoadAction, sourceEnvironment.artworkLoadAction)
            .environment(\.frontAMPageToolbarAccessory, .init { AccountButton() })
            .environment(\.frontAMLinkedPlaylistProvider, "网易云")
            .environment(\.frontAMPlaylistEditorInitialText, sourceEnvironment.frontAMPlaylistEditorInitialText)
            .environment(\.frontAMViewEvent, .init { event, page in
                #if DEBUG
                NavigationDiagnostics.event(event, page: page)
                #endif
            })
            .environment(\.colorScheme, sourceEnvironment.colorScheme)
            .environment(\.locale, sourceEnvironment.locale)
            .environment(\.dynamicTypeSize, sourceEnvironment.dynamicTypeSize)
            .environment(\.libraryRouteDestination, LibraryRouteDestination(makePage: destination))
            .environment(\.nativeArtworkSurfaceEnabled, true)
            .environment(\.openLibraryRoute, openAction)
            .environment(\.closeLibraryDetail, closeAction)
    }
}

extension LibraryRoute {
    fileprivate var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }

    var initialCategoryTitle: (title: String, mode: NavigationBarItem.TitleDisplayMode)? {
        let category: LibraryCategory
        switch self {
        case .category(let value): category = value
        case .downloadedCategory(.downloaded): return nil
        case .downloadedCategory(let value): category = value
        case .album, .artist, .libraryArtist, .libraryArtistAlbum, .artistSection, .playlist, .playlistFolder, .searchCategory:
            return nil
        }
        switch category {
        case .playlists: return ("播放列表", .large)
        case .artists: return ("艺人", .large)
        case .albums: return ("专辑", .large)
        case .songs: return ("歌曲", .large)
        case .downloaded: return ("已下载", .inline)
        }
    }
}
