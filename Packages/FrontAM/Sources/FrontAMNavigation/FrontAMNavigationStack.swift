import SwiftUI
import UIKit

@MainActor @Observable
public final class FrontAMNavigationStack<Route: Hashable, Preview>: NSObject, UINavigationControllerDelegate {
    public var depth: Int { max(0, (navigationController?.viewControllers.count ?? 1) - 1) }
    public var topRoute: Route? {
        (navigationController?.topViewController as? FrontAMNavigationPage<Route>)?.route
    }
    public private(set) var colorScheme: ColorScheme?
    public private(set) var displayedChrome: FrontAMNavigationChrome?
    @ObservationIgnored public private(set) weak var navigationController: UINavigationController?
    @ObservationIgnored private var environment = EnvironmentValues()
    @ObservationIgnored public private(set) var destination: ((Route) -> AnyView)?

    private let defaultRootTitle: String
    private let previewRoute: (Preview) -> Route
    private let initialChrome: (Route) -> (String, UINavigationItem.LargeTitleDisplayMode, ColorScheme?)
    private let preparePage: (FrontAMNavigationPage<Route>, Preview?, EnvironmentValues) -> Void
    private let decoratePage: (AnyView, EnvironmentValues, FrontAMNavigationStack, FrontAMNavigationPage<Route>, Preview?) -> AnyView
    private let zoomAlignment: (Route) -> ((UIView) -> CGRect?)?
    private let onNavigationCreated: (UINavigationController) -> Void
    private let onRouteEvent: (String, Route) -> Void
    private let onPageAppeared: () -> Void

    public init(
        rootTitle: String = "",
        previewRoute: @escaping (Preview) -> Route,
        initialChrome: @escaping (Route) -> (String, UINavigationItem.LargeTitleDisplayMode, ColorScheme?) = { _ in ("", .never, nil) },
        preparePage: @escaping (FrontAMNavigationPage<Route>, Preview?, EnvironmentValues) -> Void = { _, _, _ in },
        decoratePage: @escaping (AnyView, EnvironmentValues, FrontAMNavigationStack, FrontAMNavigationPage<Route>, Preview?) -> AnyView = { content, _, _, _, _ in content },
        zoomAlignment: @escaping (Route) -> ((UIView) -> CGRect?)? = { _ in nil },
        onNavigationCreated: @escaping (UINavigationController) -> Void = { _ in },
        onRouteEvent: @escaping (String, Route) -> Void = { _, _ in },
        onPageAppeared: @escaping () -> Void = {}
    ) {
        defaultRootTitle = rootTitle
        self.previewRoute = previewRoute
        self.initialChrome = initialChrome
        self.preparePage = preparePage
        self.decoratePage = decoratePage
        self.zoomAlignment = zoomAlignment
        self.onNavigationCreated = onNavigationCreated
        self.onRouteEvent = onRouteEvent
        self.onPageAppeared = onPageAppeared
    }

    public func configure(environment: EnvironmentValues, destination: @escaping (Route) -> AnyView) {
        self.environment = environment
        self.destination = destination
        let pages = navigationController?.viewControllers.compactMap { $0 as? FrontAMNavigationPage<Route> } ?? []
        let topPage = navigationController?.topViewController as? FrontAMNavigationPage<Route>
        for page in pages {
            if page === topPage || page.chrome.isActive {
                page.applyEnvironmentIfNeeded(environment)
            } else {
                page.pendingEnvironment = environment
            }
        }
    }

    public func makeNavigationController(root: AnyView, initialPath: [Route] = [], rootTitle: String? = nil, rootColorScheme: ColorScheme? = nil) -> UINavigationController {
        let page = makePage(root, route: nil)
        page.chrome.title = rootTitle ?? defaultRootTitle
        page.chrome.setColorScheme(rootColorScheme)
        let nav = UINavigationController(rootViewController: page)
        nav.navigationBar.prefersLargeTitles = true
        navigationController = nav
        displayedChrome = page.chrome
        nav.delegate = self
        onNavigationCreated(nav)
        for route in initialPath { open(route, animated: false) }
        return nav
    }

    public func makePage(_ content: AnyView, route: Route?, preview: Preview? = nil) -> FrontAMNavigationPage<Route> {
        let initial = route.map(initialChrome) ?? (defaultRootTitle, .inline, nil)
        let chrome = FrontAMNavigationChrome(isRoot: route == nil, title: initial.0, mode: initial.1)
        let page = FrontAMNavigationPage(chrome: chrome, route: route)
        chrome.onColorSchemeChange = { [weak self] in self?.updateColorScheme($0) }
        if let scheme = initial.2 { chrome.setColorScheme(scheme) }
        page.onPageAppeared = onPageAppeared
        page.updateEnvironment = { [weak self, weak page] environment in
            guard let self, let page else { return }
            page.rootView = AnyView(decoratePage(content, environment, self, page, preview)
                .environment(\.libraryNavigationChrome, chrome)
                .environment(\.libraryZoomNamespace, nil))
        }
        page.updateEnvironment?(environment)
        preparePage(page, preview, environment)
        return page
    }

    public func open(_ route: Route, source: UIView? = nil, animated: Bool = true,
              sourceProvider: (() -> UIView?)? = nil, preview: Preview? = nil) {
        onRouteEvent("openRequested", route)
        guard let nav = navigationController, let destination else { return }
        let page = makePage(destination(route), route: route, preview: preview.flatMap { previewRoute($0) == route ? $0 : nil })
        if let alignment = zoomAlignment(route), sourceProvider != nil || source != nil {
            let options = UIViewController.Transition.ZoomOptions()
            options.alignmentRectProvider = { context in
                let view = context.zoomedViewController.view!
                view.layoutIfNeeded()
                return alignment(view)
            }
            page.preferredTransition = .zoom(options: options) { [weak source] _ in
                let current = sourceProvider.map { $0() } ?? source
                guard let current, current.window != nil else { return nil }
                return current
            }
        }
        onRouteEvent("push", route)
        nav.pushViewController(page, animated: animated)
    }

    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        updateColorScheme((viewController as? FrontAMNavigationPage<Route>)?.chrome.colorScheme)
    }

    public func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        updateColorScheme((viewController as? FrontAMNavigationPage<Route>)?.chrome.colorScheme)
        // An interrupted zoom can finish its incoming transition while UIKit is starting the pop.
        // Resolve the displayed page after this navigation callback has unwound.
        Task { @MainActor [weak self, weak navigationController, weak viewController] in
            guard let navigationController, let page = viewController as? FrontAMNavigationPage<Route>,
                  navigationController.topViewController === page else { return }
            if let destination = navigationController.transitionCoordinator?.viewController(forKey: .to),
               destination !== page { return }
            self?.displayedChrome = page.chrome
        }
        for case let page as FrontAMNavigationPage<Route> in navigationController.viewControllers {
            page.chrome.isActive = page === viewController
        }
    }

    private func updateColorScheme(_ scheme: ColorScheme?) {
        navigationController?.navigationBar.overrideUserInterfaceStyle = scheme.map { UIUserInterfaceStyle($0) } ?? .unspecified
        if colorScheme != scheme { colorScheme = scheme }
    }
}

public final class FrontAMNavigationPage<Route: Hashable>: UIHostingController<AnyView> {
    public let chrome: FrontAMNavigationChrome
    public let route: Route?
    var onPageAppeared: () -> Void = {}
    var updateEnvironment: ((EnvironmentValues) -> Void)?
    var pendingEnvironment: EnvironmentValues?
    private weak var registeredScroll: UIScrollView?
    public init(chrome: FrontAMNavigationChrome, route: Route? = nil) {
        self.chrome = chrome
        self.route = route
        super.init(rootView: AnyView(EmptyView()))
        chrome.controller = self
        navigationItem.backButtonDisplayMode = .default
        chrome.apply()
    }
    @MainActor public required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyEnvironmentIfNeeded(_ environment: EnvironmentValues) {
        pendingEnvironment = nil
        updateEnvironment?(environment)
    }
    public override func viewDidLayoutSubviews() {
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
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        chrome.isActive = true
        if let pending = pendingEnvironment {
            pendingEnvironment = nil
            updateEnvironment?(pending)
        }
        chrome.apply()
    }
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome.isActive = false
    }
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        chrome.isActive = true
        chrome.hasAppeared = true
        chrome.activateSearchPageIfNeeded()
        onPageAppeared()
    }
}

public struct FrontAMNavigationContainer<Route: Hashable, Preview, Root: View>: View {
    let navigation: FrontAMNavigationStack<Route, Preview>
    let root: Root
    let destination: (Route) -> AnyView
    let initialPath: [Route]

    public init(navigation: FrontAMNavigationStack<Route, Preview>, root: Root,
                destination: @escaping (Route) -> AnyView, initialPath: [Route] = []) {
        self.navigation = navigation
        self.root = root
        self.destination = destination
        self.initialPath = initialPath
    }

    public var body: some View {
        FrontAMNavigationControllerHost(navigation: navigation, root: root,
            destination: destination, initialPath: initialPath)
            .ignoresSafeArea()
    }
}

private struct FrontAMNavigationControllerHost<Route: Hashable, Preview, Root: View>: UIViewControllerRepresentable {
    let navigation: FrontAMNavigationStack<Route, Preview>
    let root: Root
    let destination: (Route) -> AnyView
    var initialPath: [Route] = []

    func makeUIViewController(context: Context) -> UINavigationController {
        navigation.configure(environment: context.environment, destination: destination)
        return navigation.makeNavigationController(root: AnyView(root), initialPath: initialPath)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        navigation.configure(environment: context.environment, destination: destination)
    }
}
