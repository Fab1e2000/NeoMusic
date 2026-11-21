import SwiftUI
import UIKit

@MainActor @Observable
final class LibraryDetailNavigation: NSObject, UINavigationControllerDelegate {
    var depth: Int { max(0, (navigationController?.viewControllers.count ?? 1) - 1) }
    var topRoute: LibraryRoute? {
        (navigationController?.topViewController as? LibraryDetailHostingController)?.chrome.route
    }
    private(set) var colorScheme: ColorScheme?
    private(set) var displayedChrome: LibraryNavigationChrome?
    @ObservationIgnored weak var navigationController: UINavigationController?
    @ObservationIgnored private var environment = EnvironmentValues()
    @ObservationIgnored private var destination: ((LibraryRoute) -> AnyView)?

    func configure(environment: EnvironmentValues, destination: @escaping (LibraryRoute) -> AnyView) {
        self.environment = environment
        self.destination = destination
        let pages = navigationController?.viewControllers.compactMap { $0 as? LibraryDetailHostingController } ?? []
        let topPage = navigationController?.topViewController as? LibraryDetailHostingController
        for page in pages {
            if page === topPage || page.chrome.isActive {
                page.applyEnvironmentIfNeeded(environment)
            } else {
                page.pendingEnvironment = environment
            }
        }
    }

    func makeNavigationController(root: AnyView, initialPath: [LibraryRoute] = [], rootTitle: String = "资料库", rootColorScheme: ColorScheme? = nil) -> UINavigationController {
        let page = makePage(root, route: nil)
        page.chrome.title = rootTitle
        page.chrome.setColorScheme(rootColorScheme)
        let nav = UINavigationController(rootViewController: page)
        nav.navigationBar.prefersLargeTitles = true
        navigationController = nav
        displayedChrome = page.chrome
        nav.delegate = self
        NavigationDiagnostics.recorder.attach(nav)
        for route in initialPath { open(route, animated: false) }
        return nav
    }

    func makePage(_ content: AnyView, route: LibraryRoute?, preview: LibraryNavigationPreview? = nil) -> LibraryDetailHostingController {
        let chrome = LibraryNavigationChrome(isRoot: route == nil, route: route)
        let page = LibraryDetailHostingController(chrome: chrome)
        if case .artist = route { chrome.setColorScheme(.dark) }
        page.updateEnvironment = { [weak self, weak page] environment in
            guard let page else { return }
            page.rootView = AnyView(
                LibraryNavigationPreviewScope(content: content, preview: preview,
                                              account: environment[NeteaseAccount.self])
                    .modifier(LibraryHostedPageEnvironment(
                        sourceEnvironment: environment,
                        chrome: chrome,
                        destination: self?.destination,
                        openAction: OpenLibraryRouteAction(
                            handler: { [weak self] in self?.open($0) },
                            previewHandler: { [weak self] in self?.open($0, preview: $1) },
                            sourceHandler: { [weak self] in self?.open($0, source: $1) },
                            sourceProviderHandler: { [weak self] in self?.open($0, sourceProvider: $1) },
                            previewSourceHandler: { [weak self] in self?.open($0, sourceProvider: $2, preview: $1) }
                        ),
                        closeAction: CloseLibraryDetailAction { [weak page] in
                            guard let page, let nav = page.navigationController, nav.topViewController === page else { return }
                            nav.popViewController(animated: true)
                        }
                    ))
            )
        }
        page.updateEnvironment?(environment)
        if case .artist = route {
            page.view.backgroundColor = .black
        } else if let preview, preview.route == route,
           preview.matches(owner: environment[NeteaseAccount.self]?.profile.map { String($0.userID) }),
           let backdrop = preview.albumBackdrop {
            page.chrome.setAlbumBackdrop(backdrop)
        }
        return page
    }

    func open(_ route: LibraryRoute, source: UIView? = nil, animated: Bool = true,
              sourceProvider: (() -> UIView?)? = nil, preview: LibraryNavigationPreview? = nil) {
        NavigationDiagnostics.event("UIKitLibrary.openRequested", page: route.diagnosticPage)
        guard let nav = navigationController, let destination else { return }
        let page = makePage(destination(route), route: route, preview: preview?.route == route ? preview : nil)
        switch route {
        case .album, .playlist:
            if sourceProvider != nil || source != nil {
                let options = UIViewController.Transition.ZoomOptions()
                options.alignmentRectProvider = { context in
                    let view = context.zoomedViewController.view!
                    view.layoutIfNeeded()
                    return view.libraryArtworkAlignmentRect()
                }
                page.preferredTransition = .zoom(options: options) { [weak source] _ in
                    let current = sourceProvider.map { $0() } ?? source
                    guard let current, current.window != nil else { return nil }
                    return current
                }
            }
        default: break
        }
        NavigationDiagnostics.event("UIKitLibrary.push", page: route.diagnosticPage)
        nav.pushViewController(page, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        updateColorScheme((viewController as? LibraryDetailHostingController)?.chrome.colorScheme)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        updateColorScheme((viewController as? LibraryDetailHostingController)?.chrome.colorScheme)
        // An interrupted zoom can finish its incoming transition while UIKit is starting the pop.
        // Resolve the displayed page after this navigation callback has unwound.
        Task { @MainActor [weak self, weak navigationController, weak viewController] in
            guard let navigationController, let page = viewController as? LibraryDetailHostingController,
                  navigationController.topViewController === page else { return }
            if let destination = navigationController.transitionCoordinator?.viewController(forKey: .to),
               destination !== page { return }
            self?.displayedChrome = page.chrome
        }
        for case let page as LibraryDetailHostingController in navigationController.viewControllers {
            page.chrome.isActive = page === viewController
        }
    }

    fileprivate func updateColorScheme(_ scheme: ColorScheme?) {
        navigationController?.navigationBar.overrideUserInterfaceStyle = scheme.map { UIUserInterfaceStyle($0) } ?? .unspecified
        if colorScheme != scheme { colorScheme = scheme }
    }
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
    let chrome: LibraryNavigationChrome
    let destination: ((LibraryRoute) -> AnyView)?
    let openAction: OpenLibraryRouteAction
    let closeAction: CloseLibraryDetailAction

    func body(content: Content) -> some View {
        content
            .environment(sourceEnvironment[NeteaseAccount.self])
            .environment(\.collectionMenuActions, sourceEnvironment.collectionMenuActions)
            .environment(\.songMenuActions, sourceEnvironment.songMenuActions)
            .environment(\.songRowPlayback, sourceEnvironment.songRowPlayback)
            .environment(\.songPlaybackIndicatorsActive, sourceEnvironment.songPlaybackIndicatorsActive)
            .environment(\.libraryDownloads, sourceEnvironment.libraryDownloads)
            .environment(\.artworkLoadAction, sourceEnvironment.artworkLoadAction)
            .environment(\.colorScheme, sourceEnvironment.colorScheme)
            .environment(\.locale, sourceEnvironment.locale)
            .environment(\.dynamicTypeSize, sourceEnvironment.dynamicTypeSize)
            .environment(\.libraryNavigationChrome, chrome)
            .environment(\.libraryRouteDestination, LibraryRouteDestination(makePage: destination))
            .environment(\.libraryZoomNamespace, nil)
            .environment(\.nativeArtworkSurfaceEnabled, true)
            .environment(\.openLibraryRoute, openAction)
            .environment(\.closeLibraryDetail, closeAction)
    }
}

struct LibraryNavigationContainer<Root: View>: View {
    let navigation: LibraryDetailNavigation
    let root: Root
    let destination: (LibraryRoute) -> AnyView
    var initialPath: [LibraryRoute] = []
    var body: some View {
        LibraryNavigationControllerHost(navigation: navigation, root: root,
            destination: destination, initialPath: initialPath)
            .ignoresSafeArea()
    }
}

private struct LibraryNavigationControllerHost<Root: View>: UIViewControllerRepresentable {
    let navigation: LibraryDetailNavigation
    let root: Root
    let destination: (LibraryRoute) -> AnyView
    var initialPath: [LibraryRoute] = []

    func makeUIViewController(context: Context) -> UINavigationController {
        navigation.configure(environment: context.environment, destination: destination)
        return navigation.makeNavigationController(root: AnyView(root), initialPath: initialPath)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        navigation.configure(environment: context.environment, destination: destination)
    }
}

final class LibraryDetailHostingController: UIHostingController<AnyView> {
    let chrome: LibraryNavigationChrome
    var updateEnvironment: ((EnvironmentValues) -> Void)?
    var pendingEnvironment: EnvironmentValues?
    private weak var registeredScroll: UIScrollView?
    init(chrome: LibraryNavigationChrome) {
        self.chrome = chrome
        super.init(rootView: AnyView(EmptyView()))
        chrome.controller = self
        navigationItem.backButtonDisplayMode = .default
        chrome.apply()
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyEnvironmentIfNeeded(_ environment: EnvironmentValues) {
        pendingEnvironment = nil
        updateEnvironment?(environment)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard registeredScroll?.isDescendant(of: view) != true else { return }
        if let scroll = firstScroll(in: view), scroll !== registeredScroll {
            registeredScroll = scroll
            setContentScrollView(scroll, for: .top)
        }
    }
    private func firstScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let scroll = firstScroll(in: child) { return scroll } }
        return nil
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        chrome.isActive = true
        if let pending = pendingEnvironment {
            pendingEnvironment = nil
            updateEnvironment?(pending)
        }
        chrome.apply()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome.isActive = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        chrome.isActive = true
        chrome.hasAppeared = true
        chrome.activateSearchPageIfNeeded()
        PerformanceDiagnostics.event("PageAppeared")
    }
}

extension LibraryRoute {
    var initialCategoryTitle: (title: String, mode: NavigationBarItem.TitleDisplayMode)? {
        let category: LibraryCategory
        switch self {
        case .category(let value): category = value
        case .downloadedCategory(.downloaded): return nil
        case .downloadedCategory(let value): category = value
        case .album, .artist, .artistSection, .playlist, .playlistFolder, .searchCategory: return nil
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

@MainActor @Observable
final class LibraryNavigationChrome: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UISearchControllerDelegate {
    var isActive = false
    var hasAppeared = false
    @ObservationIgnored weak var controller: UIViewController?
    @ObservationIgnored let route: LibraryRoute?
    @ObservationIgnored var title = ""
    @ObservationIgnored var mode: UINavigationItem.LargeTitleDisplayMode
    @ObservationIgnored let isRoot: Bool
    private(set) var colorScheme: ColorScheme?
    @ObservationIgnored private var search: UISearchController?
    @ObservationIgnored private var query: Binding<String>?
    @ObservationIgnored private var searchPrompt = ""
    @ObservationIgnored private var searchPage: SearchPageModel?

    init(isRoot: Bool, route: LibraryRoute? = nil) {
        self.isRoot = isRoot
        self.route = route
        if !isRoot, let initial = route?.initialCategoryTitle {
            title = initial.title
            mode = initial.mode == .large ? .always : .never
        } else {
            mode = isRoot ? .inline : .never
            title = isRoot ? "资料库" : ""
        }
    }
    func apply() {
        guard let item = controller?.navigationItem else { return }
        if item.title != title { item.title = title }
        if item.largeTitleDisplayMode != mode { item.largeTitleDisplayMode = mode }
        item.navigationBarMinimization.minimizationBehavior = isRoot ? .onScrollDown : .never
        item.navigationBarMinimization.restorationBehavior = isRoot ? .atScrollEdge : .automatic
        item.navigationBarMinimization.safeAreaAdjustment = .disabled
    }
    func setColorScheme(_ scheme: ColorScheme?) {
        colorScheme = scheme
        controller?.overrideUserInterfaceStyle = scheme.map { UIUserInterfaceStyle($0) } ?? .unspecified
        guard let controller, let navigation = controller.navigationController,
              navigation.topViewController === controller else { return }
        (navigation.delegate as? LibraryDetailNavigation)?.updateColorScheme(scheme)
    }
    func setAlbumBackdrop(_ backdrop: AlbumArtworkBackdrop?) {
        controller?.view.backgroundColor = backdrop?.uiColor ?? .systemBackground
        setColorScheme(backdrop?.colorScheme)
    }
    func attach(_ controller: UIViewController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        apply()
        setSearch(query, prompt: searchPrompt)
    }
    func setSearch(_ binding: Binding<String>?, prompt: String) {
        query = binding
        searchPrompt = prompt
        guard let controller else { return }
        guard let binding else {
            search?.isActive = false
            controller.navigationItem.searchController = nil
            search = nil
            return
        }
        if search == nil {
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            self.search = search
        }
        if controller.navigationItem.searchController !== search {
            controller.navigationItem.searchController = search
            controller.navigationItem.hidesSearchBarWhenScrolling = true
            controller.definesPresentationContext = true
        }
        search?.searchBar.placeholder = prompt
        if search?.searchBar.text != binding.wrappedValue { search?.searchBar.text = binding.wrappedValue }
    }
    func updateSearchResults(for searchController: UISearchController) {
        if let searchPage {
            guard searchPage.isSearching else { return }
            guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
            searchPage.input(searchController.searchBar.text ?? "")
            return
        }
        let text = searchController.searchBar.text ?? ""
        if query?.wrappedValue != text { query?.wrappedValue = text }
    }

    func setSearchPage(_ model: SearchPageModel) {
        searchPage = model
        let prompt = "网易云音乐中的歌曲、艺人、专辑及歌单"
        setSearch(Binding(get: { model.query }, set: { model.input($0) }), prompt: prompt)
        guard let search else { return }
        search.delegate = self
        search.searchBar.delegate = self
        controller?.navigationItem.preferredSearchBarPlacement = .stacked
        controller?.navigationItem.hidesSearchBarWhenScrolling = false
    }
    func activateSearchPageIfNeeded() {
        guard hasAppeared, searchPage?.isSearching == true, search?.isActive == false else { return }
        search?.isActive = true
    }
    func willPresentSearchController(_ searchController: UISearchController) {
        guard searchController === search else { return }
        searchPage?.isSearching = true
    }
    func didPresentSearchController(_ searchController: UISearchController) {
        guard searchController === search, searchPage?.isSearching == true, searchPage?.submitted == false else { return }
        searchController.searchBar.becomeFirstResponder()
    }
    func willDismissSearchController(_ searchController: UISearchController) {
        guard searchController === search else { return }
        searchPage?.cancel()
    }
    func completeSearchSubmission() {
        guard searchPage?.submitted == true, let search,
              search.searchBar.searchTextField.isFirstResponder else { return }
        search.searchBar.resignFirstResponder()
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchPage?.submit()
        completeSearchSubmission()
    }
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        guard searchPage?.isSearching == true else { return }
        searchPage?.resumeEditing()
    }
}

extension EnvironmentValues {
    @Entry var libraryNavigationChrome: LibraryNavigationChrome?
}

extension View {
    func libraryNavigationTitle(_ title: String) -> some View { modifier(LibraryTitle(title: title)) }
    func libraryTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { modifier(LibraryTitleMode(mode: mode)) }
    func libraryHomeNavigation(title: String = "资料库") -> some View { modifier(LibraryHomeChrome(title: title)) }
    func librarySearchable(text: Binding<String>, prompt: String, enabled: Bool = true) -> some View {
        modifier(LibrarySearch(query: text, prompt: prompt, enabled: enabled))
    }
    func librarySearchPage(_ model: SearchPageModel) -> some View { modifier(LibrarySearchPage(model: model)) }
}

private struct LibrarySearchPage: ViewModifier {
    let model: SearchPageModel
    @Environment(\.libraryNavigationChrome) private var chrome
    func body(content: Content) -> some View {
        content.background { LibraryChromeUpdate {
            chrome?.setSearchPage(model)
        }.frame(width: 0, height: 0) }
        .onChange(of: model.submitted) { _, submitted in
            if submitted { chrome?.completeSearchSubmission() }
        }
    }
}

private struct LibraryChromeUpdate: UIViewRepresentable {
    let update: () -> Void
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: UIView, context: Context) { update() }
}
private struct LibraryTitle: ViewModifier {
    let title: String
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome { content.background { LibraryChromeUpdate { chrome.title = title; chrome.apply() }.frame(width: 0, height: 0) } }
        else { content.navigationTitle(title) }
    }
}
private struct LibraryTitleMode: ViewModifier {
    let mode: NavigationBarItem.TitleDisplayMode
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome {
            content.background { LibraryChromeUpdate {
                chrome.mode = mode == .large ? .always : .never
                chrome.apply()
            }.frame(width: 0, height: 0) }
        } else { content.navigationBarTitleDisplayMode(mode) }
    }
}
private struct LibraryHomeChrome: ViewModifier {
    let title: String
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if chrome != nil {
            content
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
                .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
        else {
            content.navigationTitle(title).toolbarTitleDisplayMode(.inlineLarge)
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
                .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
    }
}
private struct LibrarySearch: ViewModifier {
    @Binding var query: String
    let prompt: String
    let enabled: Bool
    @Environment(\.libraryNavigationChrome) private var chrome
    @ViewBuilder func body(content: Content) -> some View {
        if let chrome {
            content.background { LibraryChromeUpdate { chrome.setSearch(enabled ? $query : nil, prompt: prompt) }.frame(width: 0, height: 0) }
        } else if enabled { content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(prompt)) }
        else { content }
    }
}
