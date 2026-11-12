import XCTest
import SwiftUI
import LNPopupController
import Synchronization
@testable import NeoMusic

@MainActor @Observable
private final class StartupLibraryProbe {
    var isReady = false
    var pinCount = 4
    let library = PlaylistLibrary(playlists: [])
}

@MainActor
private final class NavigationAccountStorage {
    var session: NeteaseSavedSession?
}

private struct StartupLibraryProbeView: View {
    let probe: StartupLibraryProbe
    var body: some View {
        let pins: [LibraryShelfItem] = [
            .init(id: "first", title: "专辑一", artwork: .missing, route: .album("first")),
            .init(id: "second", title: "专辑二", artwork: .missing, route: .album("second")),
            .init(id: "third", title: "专辑三", artwork: .missing, route: .album("third")),
            .init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites"))
        ]
        LibraryHomeView(pinned: probe.isReady ? Array(pins.prefix(probe.pinCount)) : [], recentlyAdded: probe.isReady ? [
            .init(id: "recent-first", title: "最近专辑一", artwork: .missing, route: .album("recent-first")),
            .init(id: "recent-second", title: "最近专辑二", artwork: .missing, route: .album("recent-second"))
        ] : [],
                        playlistLibrary: probe.library, isContentReady: probe.isReady)
    }
}

@MainActor
private final class NativeDisplayFrameSampler: NSObject {
    private let sample: (CADisplayLink) -> Void
    private var displayLink: CADisplayLink?

    init(sample: @escaping (CADisplayLink) -> Void) { self.sample = sample }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(displayFrame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayFrame(_ link: CADisplayLink) { sample(link) }
}

@MainActor
final class LibraryDetailNavigationTests: XCTestCase {
    private lazy var account: NeteaseAccount = {
        let storage = NavigationAccountStorage()
        return NeteaseAccount(readSession: { storage.session },
                              saveSession: { storage.session = $0 },
                              deleteSession: { storage.session = nil },
                              validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
                              cachedAvatar: { _ in nil },
                              loadAvatar: { _ in throw URLError(.badURL) },
                              clearAvatarCache: { })
    }()

    private func settle() async throws { try await Task.sleep(for: .milliseconds(1400)) }

    func testListProjectionReusesInputsAndImmediatelyReflectsDataAndControls() {
        let cache = LibraryListProjection<SongsListView.ProjectionInput, SongsListView.Projection>()
        var calculations = 0
        let source = [
            LibrarySongItem(id: "zhou", title: "周杰伦", artist: "艺人", album: "专辑", albumArtist: "艺人",
                            trackNumber: 1, artwork: .missing, addedOrder: 2),
            LibrarySongItem(id: "chen", title: "陈奕迅", artist: "艺人", album: "专辑", albumArtist: "艺人",
                            trackNumber: 2, artwork: .missing, addedOrder: 1, isFavorite: true)
        ]
        func project(_ songs: [LibrarySongItem], query: String = "", filter: LibraryFilter = .all,
                     sort: SongSort = .name) -> SongsListView.Projection {
            let input = SongsListView.ProjectionInput(songs: songs, query: query, filter: filter, sort: sort)
            return cache.value(for: input) { calculations += 1; return input.calculate() }
        }
        let initial = project(source)
        XCTAssertEqual(initial.sections.map(\.letter), ["C", "Z"])
        XCTAssertEqual(initial.ordered.map(\.id), ["chen", "zhou"])
        XCTAssertEqual(project(source).ordered.map(\.id), ["chen", "zhou"])
        XCTAssertEqual(calculations, 1, "Presentation-only updates reuse the last result")

        let updated = source + [LibrarySongItem(id: "ashin", title: "阿信", artist: "艺人", album: "专辑", albumArtist: "艺人",
                                               trackNumber: 3, artwork: .missing, addedOrder: 3, isFavorite: true)]
        XCTAssertEqual(project(updated).ordered.map(\.id), ["ashin", "chen", "zhou"])
        XCTAssertEqual(calculations, 2)
        XCTAssertEqual(project(updated, query: "周").ordered.map(\.id), ["zhou"])
        XCTAssertEqual(calculations, 3)
        XCTAssertTrue(project(updated, query: "周", filter: .favorites).ordered.isEmpty)
        XCTAssertEqual(calculations, 4)
        XCTAssertTrue(project(updated, query: "周", filter: .favorites, sort: .addedDate).ordered.isEmpty)
        XCTAssertEqual(calculations, 5)
        XCTAssertEqual(project(updated, filter: .favorites, sort: .addedDate).ordered.map(\.id), ["ashin", "chen"])
        XCTAssertEqual(calculations, 6)
        XCTAssertEqual(project(updated, filter: .favorites, sort: .addedDate).ordered.map(\.id), ["ashin", "chen"])
        XCTAssertEqual(calculations, 6)
    }

    func testArtworkDemandStartsOnlyForVisibleLazyRows() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        var requested = Set<String>()
        let first = expectation(description: "Visible cover requests its image")
        let content = ScrollView {
            LazyVStack {
                ForEach(0..<100, id: \.self) { index in
                    ArtworkView(artwork: .deferred(id: "cover:\(index)", placeholder: .missing))
                        .frame(width: 72, height: 72)
                }
            }
        }.environment(\.artworkLoadAction, ArtworkLoadAction { id in
            if requested.insert(id).inserted, id == "cover:0" { first.fulfill() }
        })
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        await fulfillment(of: [first], timeout: 3)
        try await settle()
        XCTAssertTrue(requested.contains("cover:0"))
        XCTAssertLessThan(requested.count, 100, "Off-screen rows must not start the entire artwork catalog")
    }

    private func mount(_ bridge: LibraryDetailNavigation, sourceContainer: UIView? = nil) async throws -> UIWindow {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            LibraryNavigationContainer(navigation: bridge, root: TestRoot(sourceContainer: sourceContainer),
                destination: { route in AnyView(TestDetail(route: route)) }))
        window.makeKeyAndVisible()
        return window
    }

    func testFavoritesPageClearsItsTitle() async throws {
        let bridge = LibraryDetailNavigation()
        var environment = EnvironmentValues()
        environment[NeteaseAccount.self] = account
        bridge.configure(environment: environment, destination: { _ in AnyView(EmptyView()) })
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let detail = CollectionDetail(kind: .playlist, title: "喜爱歌曲", artwork: .favorites,
            tint: Color(.systemBackground), songs: [], route: .playlist("favorites"))
        window.rootViewController = bridge.makeNavigationController(
            root: AnyView(CollectionDetailView(detail: detail)), rootTitle: "喜爱歌曲")
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle()
        let page = try XCTUnwrap(bridge.navigationController?.topViewController)
        XCTAssertEqual(page.navigationItem.title, "")
    }

    func testOwnsNativeStackAndRetainsOriginalToolbarGroups() async throws {
        let bridge = LibraryDetailNavigation()
        let window = try await mount(bridge)
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        XCTAssertTrue(type(of: nav) == UINavigationController.self)
        let root = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        XCTAssertEqual(root.navigationItem.title, "资料库")
        XCTAssertEqual(root.navigationItem.largeTitleDisplayMode, .inline)
        XCTAssertEqual(root.navigationItem.trailingItemGroups.flatMap(\.barButtonItems).count, 2)
        XCTAssertTrue(root.chrome.isActive)
        bridge.open(.category(.albums))
        try await settle()
        let category = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertFalse(root.chrome.isActive)
        XCTAssertEqual(category.navigationItem.title, "专辑")
        XCTAssertNotNil(category.navigationItem.searchController)
        XCTAssertEqual(category.navigationItem.trailingItemGroups.flatMap(\.barButtonItems).count, 1)
        bridge.open(.album("first"))
        try await settle()
        XCTAssertEqual(nav.viewControllers.count, 3)
        nav.popToRootViewController(animated: true)
        try await settle()
        XCTAssertTrue(nav.topViewController === root)
        XCTAssertTrue(root.chrome.isActive)
        XCTAssertEqual(bridge.depth, 0)
        XCTAssertEqual(root.navigationItem.title, "资料库")
        XCTAssertEqual(root.navigationItem.trailingItemGroups.flatMap(\.barButtonItems).count, 2)
    }

    func testAlbumAppearanceIsRestoredOnReturn() async throws {
        let bridge = LibraryDetailNavigation()
        let window = try await mount(bridge)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .light)
        let root = try XCTUnwrap(nav.topViewController)
        bridge.open(.album("color"), animated: false)
        try await settle()
        let page = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        page.chrome.setColorScheme(.dark)
        try await settle()
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .dark)
        bridge.navigationController(nav, willShow: root, animated: true)
        try await settle()
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .light)
        bridge.navigationController(nav, didShow: page, animated: true)
        try await settle()
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .dark, "A cancelled return must restore the visible album style")
        nav.popViewController(animated: false)
        try await settle()
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .light)
        page.chrome.setColorScheme(.dark)
        try await settle()
        XCTAssertEqual(nav.navigationBar.traitCollection.userInterfaceStyle, .light, "A disappeared page must not change the active bar")
        XCTAssertEqual(nav.navigationBar.overrideUserInterfaceStyle, .unspecified)
    }

    func testAppShellBarsChangeDuringZoomAndRestoreOnTabChange() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let player = PlayerTestFixtures.state(tracks: [ReferenceTrack(id: "appearance", title: "Track",
            artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60)])
        window.rootViewController = UIHostingController(rootView: AppShell(
            library: { TestRoot(showsArtwork: true) }, detailDestination: { AnyView(TestDetail(route: $0)) }, nowPlaying: nil,
            playlistLibrary: PlaylistLibrary(playlists: []), toasts: LibraryToastCenter(),
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(),
            makePlayerActions: { _, _ in PlayerTestFixtures.actions() }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        func tabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { tabs(in: $0) }.first
        }
        let tabs = try XCTUnwrap(tabs(in: window.rootViewController!))
        let nav = try XCTUnwrap(tabs.selectedViewController as? UINavigationController)
        let bridge = try XCTUnwrap(nav.delegate as? LibraryDetailNavigation)
        let mini = try XCTUnwrap(descendants(of: LNPopupBar.self, in: tabs.view).first)
        let libraryTab = try XCTUnwrap(tabs.selectedTab)
        let homeTab = try XCTUnwrap(tabs.tabs.first { $0.identifier == AppTab.home.rawValue })
        func assertAppearance(_ style: UIUserInterfaceStyle, file: StaticString = #filePath, line: UInt = #line) {
            for bar in [nav.navigationBar, tabs.tabBar, mini] as [UIView] {
                XCTAssertEqual(bar.traitCollection.userInterfaceStyle, style, "\(type(of: bar))", file: file, line: line)
            }
        }
        func select(_ tab: UITab) {
            let previous = tabs.selectedTab
            tabs.selectedTab = tab
            tabs.delegate?.tabBarController?(tabs, didSelectTab: tab, previousTab: previous)
        }
        assertAppearance(.light)
        let root = try XCTUnwrap(nav.topViewController)
        let source = try XCTUnwrap(nav.topViewController?.view.libraryArtworkSource())
        let navigationChanged = expectation(description: "Navigation bar changes during zoom")
        let tabChanged = expectation(description: "Tab bar changes during zoom")
        let miniChanged = expectation(description: "Mini player changes during zoom")
        let navigationRegistration = nav.navigationBar.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: UINavigationBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .dark else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Navigation buttons must not wait for zoom completion")
            navigationChanged.fulfill()
        }
        let tabRegistration = tabs.tabBar.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: UITabBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .dark else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Tab appearance must not wait for zoom completion")
            tabChanged.fulfill()
        }
        let miniRegistration = mini.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: LNPopupBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .dark else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Mini player must change during the same transition")
            miniChanged.fulfill()
        }
        bridge.open(.album("appearance"), source: source)
        XCTAssertNotNil(nav.transitionCoordinator)
        var page = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        page.chrome.setColorScheme(.dark)
        await fulfillment(of: [navigationChanged, tabChanged, miniChanged], timeout: 3)
        nav.navigationBar.unregisterForTraitChanges(navigationRegistration)
        tabs.tabBar.unregisterForTraitChanges(tabRegistration)
        mini.unregisterForTraitChanges(miniRegistration)
        try await settle()
        assertAppearance(.dark)
        XCTAssertEqual(root.traitCollection.userInterfaceStyle, .light, "Detail appearance must not recolor the library behind zoom")
        XCTAssertEqual(tabs.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(page.traitCollection.userInterfaceStyle, .dark)
        // UIKit reports the original page again when an interactive return is cancelled.
        bridge.navigationController(nav, willShow: root, animated: true)
        try await settle()
        assertAppearance(.light)
        bridge.navigationController(nav, didShow: page, animated: true)
        try await settle()
        assertAppearance(.dark)
        let navigationReturned = expectation(description: "Navigation bar restores during zoom-out")
        let tabReturned = expectation(description: "Tab bar restores during zoom-out")
        let miniReturned = expectation(description: "Mini player restores during zoom-out")
        let navigationReturnRegistration = nav.navigationBar.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: UINavigationBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .light else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Navigation buttons must restore during zoom-out")
            navigationReturned.fulfill()
        }
        let tabReturnRegistration = tabs.tabBar.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: UITabBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .light else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Restoring inherited appearance must not wait for zoom-out completion")
            tabReturned.fulfill()
        }
        let miniReturnRegistration = mini.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: LNPopupBar, _) in
            guard bar.traitCollection.userInterfaceStyle == .light else { return }
            XCTAssertNotNil(nav.transitionCoordinator, "Mini player must restore during zoom-out")
            miniReturned.fulfill()
        }
        nav.popViewController(animated: true)
        XCTAssertNotNil(nav.transitionCoordinator)
        await fulfillment(of: [navigationReturned, tabReturned, miniReturned], timeout: 3)
        nav.navigationBar.unregisterForTraitChanges(navigationReturnRegistration)
        tabs.tabBar.unregisterForTraitChanges(tabReturnRegistration)
        mini.unregisterForTraitChanges(miniReturnRegistration)
        try await settle()
        assertAppearance(.light)

        bridge.open(.album("appearance"), animated: false)
        try await settle()
        page = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        page.chrome.setColorScheme(.dark)
        try await settle()
        assertAppearance(.dark)
        select(homeTab)
        try await settle()
        XCTAssertEqual(tabs.tabBar.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(mini.traitCollection.userInterfaceStyle, .light)
        page.chrome.setColorScheme(.light)
        page.chrome.setColorScheme(.dark)
        try await settle()
        XCTAssertEqual(mini.traitCollection.userInterfaceStyle, .light, "A hidden tab must not restyle the shell")
        select(libraryTab)
        try await settle()
        assertAppearance(.dark)
        page.chrome.setColorScheme(.light)
        window.overrideUserInterfaceStyle = .dark
        try await settle()
        assertAppearance(.light)
        XCTAssertEqual(root.overrideUserInterfaceStyle, .unspecified, "The source library must not acquire a detail appearance override")
        XCTAssertEqual(tabs.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(page.traitCollection.userInterfaceStyle, .light)
        nav.popViewController(animated: false)
        try await settle()
        assertAppearance(.dark)
        // Offscreen controllers inherit updated traits when UIKit restores their view hierarchy.
        XCTAssertTrue(root.view.window === window)
        XCTAssertEqual(root.traitCollection.userInterfaceStyle, .dark, "The restored library follows the current system appearance")
        page.chrome.setColorScheme(.light)
        try await settle()
        assertAppearance(.dark)
        window.overrideUserInterfaceStyle = .light
        try await settle()
        assertAppearance(.light)
    }

    func testMiniPlayerPlacementUpdatesStayInsideBarContent() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let tracks = (0..<3).map { ReferenceTrack(id: "mini-\($0)", title: "Track \($0)",
            artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60) }
        let player = PlayerTestFixtures.state(tracks: tracks)
        window.rootViewController = UIHostingController(rootView: AppShell(
            library: { TestRoot() }, detailDestination: { AnyView(TestDetail(route: $0)) },
            nowPlaying: nil, playlistLibrary: PlaylistLibrary(playlists: []), toasts: LibraryToastCenter(),
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(),
            makePlayerActions: { _, _ in PlayerTestFixtures.actions() })
            .environment(account)
            .environment(\.scenePhase, .active)
            .dynamicTypeSize(.large))
        window.makeKeyAndVisible()
        try await settle()
        func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { findTabs(in: $0) }.first
        }
        let tabs = try XCTUnwrap(findTabs(in: window.rootViewController!))
        let content = try XCTUnwrap(tabs.popupContent)
        let item = try XCTUnwrap(tabs.popupBar.popupItem)
        XCTAssertEqual(item.accessibilityLabel, "Track 0，Artist，迷你播放器")
        XCTAssertEqual(item.accessibilityHint, "打开正在播放")
        let pager = try XCTUnwrap(descendants(of: UIScrollView.self, in: tabs.popupBar).first {
            $0.panGestureRecognizer.name == "NeoDizzy.NowPlayingTrackSwipe"
        })
        // Finish the initial native display before measuring placement-only updates.
        XCTAssertTrue(pager.window === window)
        let initialBar = UIGraphicsImageRenderer(bounds: tabs.popupBar.bounds).image { _ in
            XCTAssertTrue(tabs.popupBar.drawHierarchy(in: tabs.popupBar.bounds, afterScreenUpdates: true))
        }
        let initialAppearance = XCTAttachment(image: initialBar)
        initialAppearance.name = "mini-player-before-placement-changes"
        initialAppearance.lifetime = .keepAlways
        add(initialAppearance)
        let updates = Mutex((phase: "initial", events: [String]()))
        // LNPopupUI writes userInfo whenever it resubmits a PopupItem, even for the same song.
        let observation = item.observe(\.userInfo, options: [.new]) { _, _ in
            updates.withLock { $0.events.append("\($0.phase) at \(ProcessInfo.processInfo.systemUptime)") }
        }
        defer { observation.invalidate() }
        for cycle in 0..<3 {
            for placement in [LNPopupBar.Environment.inline, .regular] {
                updates.withLock { $0.phase = "cycle=\(cycle), placement=\(placement)" }
                // These are the two native trait updates made by LN's minimization callback.
                content.traitOverrides[LNPopupBar.EnvironmentTrait.self] = placement
                tabs.popupBar.traitOverrides[LNPopupBar.EnvironmentTrait.self] = placement
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertTrue(tabs.popupContent === content)
                XCTAssertTrue(tabs.popupBar.popupItem === item)
                XCTAssertEqual(item.accessibilityLabel, "Track 0，Artist，迷你播放器")
                XCTAssertEqual(item.accessibilityHint, "打开正在播放")
                XCTAssertEqual(pager.bounds.height, placement == .inline ? 18 : 36, accuracy: 1)
            }
        }
        let updateEvents = updates.withLock { $0.events }
        let itemUpdates = updateEvents.count
        let evidence = XCTAttachment(string: "placementChanges=6, popupItemResubmissions=\(itemUpdates)\n\(updateEvents.joined(separator: "\n"))")
        evidence.name = "mini-player-placement-updates"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(itemUpdates, 0, "Bar placement must not resubmit artwork, controls and fullscreen content")
        XCTAssertEqual(tabs.tabBarMinimizeBehavior, .onScrollDown)
        XCTAssertTrue(tabs.popupBar.inheritsBottomBarMetrics)
        player.next()
        try await settle()
        XCTAssertEqual(tabs.popupBar.popupItem?.accessibilityLabel, "Track 1，Artist，迷你播放器")
        XCTAssertEqual(tabs.popupBar.popupItem?.accessibilityHint, "打开正在播放")
    }

    func testPlayerTransitionGlassRetainsAlbumAppearanceAcrossRepeatedCloses() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let player = PlayerTestFixtures.state(tracks: [ReferenceTrack(id: "appearance", title: "Track",
            artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60)])
        window.rootViewController = UIHostingController(rootView: AppShell(
            library: { TestRoot(showsArtwork: true) }, detailDestination: { route in
                let dark = route == .album("dark")
                return AnyView(CollectionDetailView(detail: CollectionDetail(kind: .album,
                    title: dark ? "Dark Album" : "Light Album", artwork: .missing, tint: .clear,
                    albumBackdrop: AlbumArtworkBackdrop(red: dark ? 0 : 1, green: dark ? 0 : 1,
                                                       blue: dark ? 0 : 1), songs: [], route: route)))
            }, nowPlaying: nil, playlistLibrary: PlaylistLibrary(playlists: []), toasts: LibraryToastCenter(),
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(),
            makePlayerActions: { _, _ in PlayerTestFixtures.actions() }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { findTabs(in: $0) }.first
        }
        let tabs = try XCTUnwrap(findTabs(in: window.rootViewController!))
        let nav = try XCTUnwrap(tabs.selectedViewController as? UINavigationController)
        let bridge = try XCTUnwrap(nav.delegate as? LibraryDetailNavigation)
        let root = try XCTUnwrap(nav.topViewController)
        for style in [UIUserInterfaceStyle.dark, .light] {
            window.overrideUserInterfaceStyle = style == .dark ? .light : .dark
            bridge.open(.album(style == .dark ? "dark" : "light"), animated: false)
            try await settle()
            XCTAssertEqual(tabs.popupBar.traitCollection.userInterfaceStyle, style)
            for cycle in 1...2 {
                for opens in [true, false] {
                    var sampledFrames = 0
                    var mismatchedFrames = 0
                    let sampler = NativeDisplayFrameSampler { _ in
                        // Inspect the actual mounted sibling, not the configured bar endpoint.
                        guard let wrapper = tabs.popupContentView.value(forKey: "transitionView") as? UIView,
                              wrapper.window === window else { return }
                        sampledFrames += 1
                        let effects = self.descendants(of: UIVisualEffectView.self, in: wrapper)
                        if wrapper.traitCollection.userInterfaceStyle != style || effects.isEmpty ||
                            effects.contains(where: { $0.traitCollection.userInterfaceStyle != style }) {
                            mismatchedFrames += 1
                        }
                    }
                    sampler.start()
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        if opens { tabs.openPopup(animated: true) { continuation.resume() } }
                        else { tabs.closePopup(animated: true) { continuation.resume() } }
                    }
                    sampler.stop()
                    XCTAssertGreaterThan(sampledFrames, 0, "The native glass transition must be sampled")
                    XCTAssertEqual(mismatchedFrames, 0, "style=\(style.rawValue), cycle=\(cycle), opening=\(opens)")
                    let evidence = XCTAttachment(string: "style=\(style.rawValue), cycle=\(cycle), opening=\(opens), frames=\(sampledFrames), mismatches=\(mismatchedFrames)")
                    evidence.lifetime = .keepAlways
                    add(evidence)
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let frame = XCTAttachment(image: image)
                frame.name = "mini-player-style-\(style.rawValue)-close-\(cycle)"
                frame.lifetime = .keepAlways
                add(frame)
            }
            nav.popViewController(animated: false)
            try await settle()
            XCTAssertEqual(root.traitCollection.userInterfaceStyle, window.traitCollection.userInterfaceStyle)
        }
    }

    func testAlbumScrollContentExtendsBehindBarsWithNativeTopEffect() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let songs = (1...24).map { index in
            LibrarySongItem(id: "edge-\(index)", title: "滚动内容 · 曲目 \(index)", artist: "测试艺人",
                album: "专辑", albumArtist: "测试艺人", trackNumber: index, artwork: .missing)
        }
        let player = PlayerTestFixtures.state(tracks: [.init(id: "edge", title: "正在播放", artists: "测试艺人",
            albumTitle: "专辑", coverURL: nil, duration: 60)])
        window.rootViewController = UIHostingController(rootView: AppShell(
            library: { TestRoot(showsArtwork: true) }, detailDestination: { route in
                let light = route == .album("light")
                return AnyView(CollectionDetailView(detail: CollectionDetail(kind: .album, title: "滚动边缘检查",
                    artwork: .image(Image(uiImage: PlayerTestFixtures.artwork())), tint: .blue,
                    albumBackdrop: light ? .init(red: 0.88, green: 0.92, blue: 0.98) : .init(red: 0.04, green: 0.07, blue: 0.12),
                    songs: songs, route: route)))
            }, nowPlaying: nil, playlistLibrary: PlaylistLibrary(playlists: []), toasts: LibraryToastCenter(),
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(), makePlayerActions: { _, _ in PlayerTestFixtures.actions() }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        func findNavigation(in controller: UIViewController) -> UINavigationController? {
            if let tabs = controller as? UITabBarController {
                return tabs.selectedViewController.flatMap(findNavigation)
            }
            if let nav = controller as? UINavigationController { return nav }
            for child in controller.children { if let nav = findNavigation(in: child) { return nav } }
            return nil
        }
        let nav = try XCTUnwrap(findNavigation(in: window.rootViewController!))
        let bridge = try XCTUnwrap(nav.delegate as? LibraryDetailNavigation)
        for theme in ["dark", "light"] {
            bridge.open(.album(theme), animated: false)
            try await settle()
            let page = try XCTUnwrap(nav.topViewController)
            let list = try XCTUnwrap(descendants(of: UICollectionView.self, in: page.view).first)
            let frame = list.convert(list.bounds, to: window)
            let details = XCTAttachment(string: "frame=\(frame), insets=\(list.adjustedContentInset), topEffectHidden=\(list.topEdgeEffect.isHidden)")
            details.name = "\(theme)-scroll-geometry"; details.lifetime = .keepAlways; add(details)
            XCTAssertEqual(frame.minY, window.bounds.minY, accuracy: 1)
            XCTAssertEqual(frame.maxY, window.bounds.maxY, accuracy: 1)
            XCTAssertGreaterThan(list.adjustedContentInset.top, 0)
            XCTAssertGreaterThan(list.adjustedContentInset.bottom, 0)
            XCTAssertTrue(page.contentScrollView(for: .top) === list)
            XCTAssertFalse(list.topEdgeEffect.isHidden, "UIKit must retain the native top gradient")
            for (position, offset) in [("cover", CGFloat(100)), ("tracks", CGFloat(620))] {
                list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                try await Task.sleep(for: .milliseconds(200))
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let image = XCTAttachment(image: rendered)
                image.name = "\(theme)-\(position)-behind-bars"; image.lifetime = .keepAlways; add(image)
            }
            let lastSong = IndexPath(item: songs.count, section: 0) // Header is the first list item.
            list.scrollToItem(at: lastSong, at: .bottom, animated: false)
            list.layoutIfNeeded()
            let attributes = try XCTUnwrap(list.layoutAttributesForItem(at: lastSong))
            let lastRow = list.convert(attributes.frame, to: window)
            XCTAssertLessThanOrEqual(lastRow.maxY, frame.maxY - list.adjustedContentInset.bottom + 1,
                "Automatic insets must keep the final row reachable above the bottom controls")
            nav.popViewController(animated: false)
            try await settle()
        }
    }

    func testRapidNativeZoomReturnAllowsOpeningAgain() async throws {
        let bridge = LibraryDetailNavigation()
        let sourceContainer = UIView()
        let window = try await mount(bridge, sourceContainer: sourceContainer)
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 140, height: 140))
        source.backgroundColor = .systemBlue
        sourceContainer.addSubview(source)
        XCTAssertTrue(source.isDescendant(of: root.view))
        for index in 0..<5 {
            bridge.open(.album("rapid-\(index)"), source: source)
            XCTAssertNotNil(nav.topViewController?.preferredTransition)
            try await Task.sleep(for: .milliseconds(100))
            nav.popViewController(animated: true)
            try await settle()
            XCTAssertTrue(nav.topViewController === root)
            XCTAssertEqual(bridge.depth, 0)
        }
        bridge.open(.album("second"), source: source)
        try await settle()
        XCTAssertTrue(nav.topViewController is LibraryDetailHostingController)
        XCTAssertEqual(bridge.depth, 1)
    }

    func testNavigationGeometryMatchesOriginalSwiftUIContainer() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: TabView {
            Tab("资料库", systemImage: "music.note.square.stack.fill") {
                NavigationStack { TestRoot() }
            }
        })
        window.makeKeyAndVisible()
        try await settle()
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let nav = controller as? UINavigationController { return nav }
            for child in controller.children { if let nav = navigation(in: child) { return nav } }
            return nil
        }
        let original = try XCTUnwrap(navigation(in: window.rootViewController!))
        let originalBar = original.navigationBar.convert(original.navigationBar.bounds, to: window)
        let originalBounds = original.view.convert(original.view.bounds, to: window)
        let originalBackMode = original.topViewController?.navigationItem.backButtonDisplayMode
        let bridge = LibraryDetailNavigation()
        window.rootViewController = UIHostingController(rootView:
            LibraryAppTabs(selection: .constant(.library), navigation: bridge,
                library: TestRoot(), destination: { _ in AnyView(EmptyView()) })
                .environment(account).ignoresSafeArea())
        try await settle()
        let native = try XCTUnwrap(bridge.navigationController)
        let nativeBar = native.navigationBar.convert(native.navigationBar.bounds, to: window)
        let nativeBounds = native.view.convert(native.view.bounds, to: window)
        XCTAssertEqual(native.topViewController?.navigationItem.backButtonDisplayMode.rawValue, originalBackMode?.rawValue)
        XCTAssertEqual(nativeBar.minY, originalBar.minY, accuracy: 1)
        XCTAssertEqual(nativeBar.height, originalBar.height, accuracy: 1)
        XCTAssertEqual(nativeBounds.minY, originalBounds.minY, accuracy: 1)
        XCTAssertEqual(nativeBounds.maxY, originalBounds.maxY, accuracy: 1)
    }

    func testStartupShowsNativeChromeBeforeContentWithoutReplacingNavigation() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let probe = StartupLibraryProbe()
        window.rootViewController = UIHostingController(rootView: LibraryAppTabs(
            selection: .constant(.library), navigation: bridge,
            library: StartupLibraryProbeView(probe: probe), destination: { _ in AnyView(EmptyView()) }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let page = try XCTUnwrap(nav.topViewController)
        let tabs = try XCTUnwrap(nav.tabBarController)
        XCTAssertEqual(page.navigationItem.title, "资料库")
        try assertNativeToolbar(in: nav)
        XCTAssertEqual(tabs.tabs.map(\.title), ["主页", "资料库", "搜索"])
        XCTAssertFalse(tabs.tabBar.isHidden)
        XCTAssertFalse(descendants(of: UICollectionView.self, in: page.view)
            .contains { $0.delegate is PinnedCollectionView.Coordinator },
                       "The shelf must occupy no row before its content is ready")
        let list = try XCTUnwrap(descendants(of: UICollectionView.self, in: page.view).first)
        func firstCategoryCell() -> UICollectionViewCell? {
            list.visibleCells.filter { cell in
                !descendants(of: UICollectionView.self, in: cell)
                    .contains { $0.delegate is PinnedCollectionView.Coordinator }
            }.min { $0.frame.minY < $1.frame.minY }
        }
        let initialCategoryY = try XCTUnwrap(firstCategoryCell()).frame.minY
        // The recently-added grid hosts SwiftUI cards without a native artwork
        // surface, matching the pinned shelf, so probe its widest visible card.
        func recentCoverFrame(presentation: Bool) -> CGRect? {
            let hostedGrids = descendants(of: UICollectionView.self, in: page.view).filter { grid in
                grid !== list && !(grid.delegate is PinnedCollectionView.Coordinator)
                    && list.visibleCells.contains { row in grid.isDescendant(of: row) }
            }
            guard let grid = hostedGrids.min(by: { $0.frame.minY < $1.frame.minY }),
                  let card = grid.visibleCells.max(by: { $0.bounds.width < $1.bounds.width }),
                  let row = list.visibleCells.first(where: { grid.isDescendant(of: $0) }) else { return nil }
            if presentation, let cardLayer = card.layer.presentation(), let rowLayer = row.layer.presentation() {
                return cardLayer.convert(cardLayer.bounds, to: rowLayer)
            }
            return card.convert(card.bounds, to: row)
        }
        let frame = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let emptyFrame = XCTAttachment(image: frame)
        emptyFrame.name = "startup-native-chrome-before-library-content"
        emptyFrame.lifetime = .keepAlways
        add(emptyFrame)

        probe.isReady = true
        var categoryPositions: [CGFloat] = []
        var recentCoverFrames: [CGRect] = []
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(16))
            if let cell = firstCategoryCell() {
                categoryPositions.append(cell.layer.presentation()?.frame.minY ?? cell.frame.minY)
            }
            if let frame = recentCoverFrame(presentation: true) { recentCoverFrames.append(frame) }
        }
        try await settle()
        let restoredFrame = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        restoredFrame.name = "pinned-content-after-restoration"
        restoredFrame.lifetime = .keepAlways
        add(restoredFrame)
        XCTAssertTrue(bridge.navigationController === nav)
        XCTAssertTrue(nav.topViewController === page)
        XCTAssertTrue(nav.tabBarController === tabs)
        let pinned = try XCTUnwrap(descendants(of: UICollectionView.self, in: page.view)
            .first { $0.delegate is PinnedCollectionView.Coordinator })
        XCTAssertEqual(pinned.numberOfItems(inSection: 0), 4)
        let finalCategoryY = try XCTUnwrap(firstCategoryCell()).frame.minY
        XCTAssertGreaterThan(finalCategoryY - initialCategoryY, 250, "Two rows of pins must push the categories down")
        XCTAssertFalse(categoryPositions.contains { $0 > initialCategoryY + 1 && $0 < finalCategoryY - 1 },
                       "Restored content must take its final layout without an insertion animation")
        let finalCoverFrame = try XCTUnwrap(recentCoverFrame(presentation: false))
        XCTAssertGreaterThan(recentCoverFrames.count, 5)
        for frame in recentCoverFrames {
            XCTAssertEqual(frame.minX, finalCoverFrame.minX, accuracy: 1, "Album fill must not slide inside the recently-added row")
            XCTAssertEqual(frame.minY, finalCoverFrame.minY, accuracy: 1, "Restored artwork must occupy its final position")
        }

        let survivingPin = try XCTUnwrap(pinned.cellForItem(at: IndexPath(item: 0, section: 0)))
        let categoryCell = try XCTUnwrap(firstCategoryCell())
        func windowPresentationFrame(_ view: UIView) -> CGRect? {
            guard view.window === window, let layer = view.layer.presentation(),
                  let root = window.layer.presentation() else { return nil }
            return layer.convert(layer.bounds, to: root)
        }
        func layerEvidence(_ view: UIView) -> [String: Any] {
            var ancestors: [[String: Any]] = []
            var layer: CALayer? = view.layer
            while let current = layer {
                let presentation = current.presentation()
                ancestors.append([
                    "type": String(describing: type(of: current)),
                    "frame": NSCoder.string(for: current.frame),
                    "bounds": NSCoder.string(for: current.bounds),
                    "presentationFrame": presentation.map { NSCoder.string(for: $0.frame) } ?? "none",
                    "presentationBounds": presentation.map { NSCoder.string(for: $0.bounds) } ?? "none",
                    "presentationOpacity": presentation.map { Double($0.opacity) } ?? Double(current.opacity),
                    "animations": current.animationKeys() ?? []
                ])
                layer = current.superlayer
            }
            return [
                "attachedToWindow": view.window === window,
                "modelWindowFrame": NSCoder.string(for: view.convert(view.bounds, to: window)),
                "presentationWindowFrame": windowPresentationFrame(view).map { NSCoder.string(for: $0) } ?? "none",
                "ancestors": ancestors
            ]
        }
        func attachEditFrame(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachEditFrame("explicit-pin-removal-before")
        let initialPinWindowFrame = try XCTUnwrap(windowPresentationFrame(survivingPin))
        var editSamples: [[String: Any]] = [[
            "phase": "before", "pin": layerEvidence(survivingPin),
            "category": firstCategoryCell().map(layerEvidence) ?? [:],
            "listOffset": NSCoder.string(for: list.contentOffset),
            "uiAnimationsEnabled": UIView.areAnimationsEnabled
        ]]
        let sampled = expectation(description: "Native frames after the explicit pin edit")
        var started: CFTimeInterval?
        var finished = false
        var frames: [(elapsed: CFTimeInterval, timestamp: CFTimeInterval, pin: CGRect?, pinModel: CGRect,
                      category: CGRect?, grid: CGRect?, offset: CGPoint)] = []
        let sampler = NativeDisplayFrameSampler { link in
            guard !finished else { return }
            let now = CACurrentMediaTime()
            guard let start = started else {
                started = now
                withAnimation(.linear(duration: 0.5)) { probe.pinCount = 1 }
                return
            }
            frames.append((now - start, link.timestamp, windowPresentationFrame(survivingPin),
                           survivingPin.convert(survivingPin.bounds, to: window),
                           windowPresentationFrame(categoryCell), windowPresentationFrame(pinned), list.contentOffset))
            if now - start >= 0.8 {
                finished = true
                sampled.fulfill()
            }
        }
        sampler.start()
        defer { sampler.stop() }
        await fulfillment(of: [sampled], timeout: 3)
        sampler.stop()
        let pinWindowFrames = frames.compactMap { $0.pin }
        for (index, frame) in frames.enumerated() {
            editSamples.append([
                "phase": "sample", "index": index, "elapsed": frame.elapsed, "displayTimestamp": frame.timestamp,
                "pin": [
                    "presentationWindowFrame": frame.pin.map { NSCoder.string(for: $0) } ?? "none",
                    "modelWindowFrame": NSCoder.string(for: frame.pinModel)
                ],
                "category": ["presentationWindowFrame": frame.category.map { NSCoder.string(for: $0) } ?? "none"],
                "gridWindowFrame": frame.grid.map { NSCoder.string(for: $0) } ?? "none",
                "listOffset": NSCoder.string(for: frame.offset)
            ])
        }
        attachEditFrame("explicit-pin-removal-after")
        let editEvidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: editSamples, options: [.prettyPrinted, .sortedKeys]),
                                         uniformTypeIdentifier: "public.json")
        editEvidence.name = "explicit-pin-removal-window-and-layer-evidence"
        editEvidence.lifetime = .keepAlways
        add(editEvidence)
        let removedCategoryY = try XCTUnwrap(firstCategoryCell()).frame.minY
        XCTAssertEqual(pinned.numberOfItems(inSection: 0), 1)
        XCTAssertLessThan(removedCategoryY, finalCategoryY - 1)
        // List owns its row resize; the diffable shelf owns continuous item movement.
        let finalPinWindowFrame = survivingPin.convert(survivingPin.bounds, to: window)
        XCTAssertGreaterThan(finalPinWindowFrame.minX, initialPinWindowFrame.minX + 1)
        XCTAssertTrue(pinWindowFrames.contains {
            $0.minX > initialPinWindowFrame.minX + 1 && $0.minX < finalPinWindowFrame.minX - 1
        }, "The retained cover must move continuously into its centered single-item position")
        XCTAssertFalse(pinWindowFrames.isEmpty)
        for frame in pinWindowFrames {
            XCTAssertEqual(frame.minY, initialPinWindowFrame.minY, accuracy: 2,
                           "The retained first-row cover must stay vertically anchored while the pinned shelf shrinks")
        }
    }

    func testActualLibraryHomePublishesItsToolbar() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let library = PlaylistLibrary(playlists: [])
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: LibraryHomeView(pinned: [.init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites"))], recentlyAdded: [], playlistLibrary: library)
                .safeAreaInset(edge: .bottom) { Text("status") }
                .libraryToasts(LibraryToastCenter())
                .playlistDeletionConfirmation(library),
            destination: { _ in AnyView(EmptyView()) }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        try assertNativeToolbar(in: bridge.navigationController)
        let directBridge = LibraryDetailNavigation()
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: directBridge, root: LocalLibraryHome(), destination: { _ in AnyView(EmptyView()) }).environment(account))
        try await settle()
        try assertNativeToolbar(in: directBridge.navigationController)
        window.rootViewController = UIHostingController(rootView: LocalLibrary.app.environment(account))
        try await settle()
        func inspect(_ vc: UIViewController) throws {
            if let tabs = vc as? UITabBarController {
                XCTAssertEqual(tabs.selectedTab?.identifier, AppTab.library.rawValue)
                try inspect(XCTUnwrap(tabs.selectedViewController))
                return
            }
            if let nav = vc as? UINavigationController {
                try assertNativeToolbar(in: nav)
            }
            try vc.children.forEach(inspect)
        }
        try inspect(window.rootViewController!)
    }

    func testLibraryHomeRevealsPinsOnceAndKeepsTheirLayoutOnReturn() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let items: [LibraryShelfItem] = [
            .init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites")),
            .init(id: "album", title: "专辑", artwork: .missing, route: .album("album"))
        ]
        var nextRootAppearance = expectation(description: "Root appears with its pinned content")
        let destinationReady = expectation(description: "Destination appears")
        var firstCollection: UICollectionView?
        var firstFrame: CGRect?
        var appearances = 0
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: LibraryHomeView(pinned: items, recentlyAdded: [], playlistLibrary: PlaylistLibrary(playlists: []))
                .background {
                    AlbumAppearanceProbe(onAppearance: { _ in }, onDisplayed: { probe in
                        do {
                            let page = try XCTUnwrap(probe.navigationController?.topViewController)
                            let collection = try XCTUnwrap(self.descendants(of: UICollectionView.self, in: page.view)
                                .first { $0.visibleCells.contains { $0 is PinnedCollectionCell } })
                            XCTAssertEqual(collection.numberOfItems(inSection: 0), items.count)
                            XCTAssertEqual(collection.visibleCells.count, items.count)
                            let frame = collection.convert(collection.bounds, to: page.view)
                            XCTAssertGreaterThan(frame.width, 0)
                            XCTAssertGreaterThan(frame.height, 0)
                            if let firstCollection, let firstFrame {
                                XCTAssertTrue(collection === firstCollection, "Returning must retain the existing pinned collection")
                                XCTAssertEqual(frame.minX, firstFrame.minX, accuracy: 1)
                                XCTAssertEqual(frame.minY, firstFrame.minY, accuracy: 1)
                                XCTAssertEqual(frame.width, firstFrame.width, accuracy: 1)
                                XCTAssertEqual(frame.height, firstFrame.height, accuracy: 1)
                            }
                        } catch { XCTFail("The first and returning frames must contain the pinned shelf: \(error)") }
                        appearances += 1
                        nextRootAppearance.fulfill()
                    }).frame(width: 0, height: 0)
                },
            destination: { route in
                AnyView(TestDetail(route: route).background {
                    AlbumAppearanceProbe(onAppearance: { _ in }, onDisplayed: { _ in destinationReady.fulfill() })
                        .frame(width: 0, height: 0)
                })
            }).environment(account))
        window.makeKeyAndVisible()
        await fulfillment(of: [nextRootAppearance], timeout: 3)
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: root.view)
            .first { $0.delegate is PinnedCollectionView.Coordinator })
        XCTAssertEqual(collection.numberOfItems(inSection: 0), items.count)
        XCTAssertEqual(collection.visibleCells.count, items.count)
        firstCollection = collection
        firstFrame = collection.convert(collection.bounds, to: root.view)
        XCTAssertGreaterThan(try XCTUnwrap(firstFrame).height, 0)
        bridge.open(.category(.albums), animated: false)
        await fulfillment(of: [destinationReady], timeout: 3)
        nextRootAppearance = expectation(description: "Root returns with the same pinned layout")
        nav.popViewController(animated: false)
        await fulfillment(of: [nextRootAppearance], timeout: 3)
        XCTAssertEqual(appearances, 2)
    }

    func testPlaylistScrollIncludesLargeTitleDuringPush() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let library = PlaylistLibrary(playlists: [])
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge, root: TestRoot(),
            destination: { _ in AnyView(PlaylistsListView(library: library)) }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        bridge.open(.category(.playlists))
        try await Task.sleep(for: .milliseconds(180))
        let navigation = try XCTUnwrap(bridge.navigationController)
        XCTAssertNotNil(navigation.transitionCoordinator)
        let page = try XCTUnwrap(navigation.topViewController)
        let list = try XCTUnwrap(descendants(of: UICollectionView.self, in: page.view).first)
        let viewport = list.convert(list.bounds, to: page.view)
        XCTAssertEqual(viewport.minY, 0, accuracy: 1,
                       "The scroll viewport must include the system large title during the push")
        XCTAssertGreaterThan(list.adjustedContentInset.top, navigation.navigationBar.bounds.height)
        XCTAssertEqual(page.navigationItem.title, "播放列表")
    }

    func testPlaylistCollectionReconfiguresVisibleCellsWhenHostedAppearanceChanges() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let list = PlaylistCollectionList(
            entries: [.playlist(.init(id: "playlist", title: "播放列表", artwork: .playlist))],
            menu: { _ in UIMenu() }, open: { _, _ in }, movePlaylist: { _, _ in })
        func content(_ colorScheme: ColorScheme, _ typeSize: DynamicTypeSize, _ locale: Locale) -> AnyView {
            AnyView(list.environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, typeSize).environment(\.locale, locale))
        }
        let host = UIHostingController(rootView: content(.light, .large, Locale(identifier: "en_US")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        let path = IndexPath(item: 0, section: 0)
        let cell = try XCTUnwrap(collection.cellForItem(at: path))
        XCTAssertEqual(cell.accessibilityTraits, .button)

        let appearances: [(ColorScheme, DynamicTypeSize, Locale)] = [
            (.dark, .large, Locale(identifier: "en_US")),
            (.dark, .accessibility5, Locale(identifier: "en_US")),
            (.dark, .accessibility5, Locale(identifier: "zh_CN"))
        ]
        for (scheme, size, locale) in appearances {
            // The production cell provider restores its button trait when it reconfigures.
            cell.accessibilityTraits = .header
            host.rootView = content(scheme, size, locale)
            try await settle()
            XCTAssertTrue(collection.cellForItem(at: path) === cell)
            XCTAssertEqual(cell.accessibilityTraits, .button)
        }

        cell.accessibilityTraits = .header
        host.rootView = content(.dark, .accessibility5, Locale(identifier: "zh_CN"))
        try await settle()
        XCTAssertEqual(cell.accessibilityTraits, .header, "Unchanged inputs leave the existing configuration in place")
    }

    func testCategoryTitlesArePreparedBeforeDestinationContentLoads() {
        let bridge = LibraryDetailNavigation()
        let expected: [(LibraryCategory, String)] = [
            (.playlists, "播放列表"), (.artists, "艺人"), (.albums, "专辑"),
            (.songs, "歌曲"), (.downloaded, "已下载")
        ]
        for (category, title) in expected {
            var routes: [LibraryRoute] = [.category(category)]
            if category != .downloaded { routes.append(.downloadedCategory(category)) }
            for route in routes {
                // An empty destination cannot supply title preferences later.
                let page = bridge.makePage(AnyView(EmptyView()), route: route)
                XCTAssertFalse(page.isViewLoaded)
                XCTAssertEqual(page.navigationItem.title, title, "\(route)")
                XCTAssertEqual(page.navigationItem.largeTitleDisplayMode,
                               category == .downloaded ? .never : .always, "\(route)")
                XCTAssertNil(page.navigationItem.searchController)
                XCTAssertNil(page.contentScrollView(for: .top))
            }
        }
    }

    func testInitialCategoryTitlesDoNotOverrideEntityTitlesOrConfigureSearch() {
        let routes: [LibraryRoute] = [
            .album("album"), .artist("artist"), .playlist("playlist"),
            .playlistFolder("folder"), .downloadedCategory(.downloaded)
        ]
        for route in routes {
            XCTAssertNil(route.initialCategoryTitle)
            let chrome = LibraryNavigationChrome(isRoot: false, route: route)
            // Entity titles still come from the current destination's content.
            chrome.title = "当前名称"
            chrome.mode = .always
            let page = LibraryDetailHostingController(chrome: chrome)
            XCTAssertEqual(page.navigationItem.title, "当前名称")
            XCTAssertEqual(page.navigationItem.largeTitleDisplayMode, .always)
            XCTAssertNil(page.navigationItem.searchController)
        }
    }

    func testReattachingChromeReusesSearchOnNewHost() throws {
        let chrome = LibraryNavigationChrome(isRoot: false, route: .category(.playlists))
        let first = UIViewController()
        chrome.attach(first)
        var text = "保留查询"
        chrome.setSearch(Binding(get: { text }, set: { text = $0 }), prompt: "搜索播放列表")
        let search = try XCTUnwrap(first.navigationItem.searchController)

        let second = UIViewController()
        chrome.attach(second)
        XCTAssertTrue(second.navigationItem.searchController === search)
        XCTAssertEqual(search.searchBar.text, "保留查询")
        XCTAssertEqual(search.searchBar.placeholder, "搜索播放列表")
        XCTAssertTrue(second.navigationItem.hidesSearchBarWhenScrolling)
        XCTAssertTrue(second.definesPresentationContext)
        XCTAssertEqual(second.navigationItem.title, "播放列表")
        search.searchBar.text = "新查询"
        chrome.updateSearchResults(for: search)
        XCTAssertEqual(text, "新查询")
        chrome.setSearch(nil, prompt: "搜索播放列表")
        XCTAssertNil(second.navigationItem.searchController)
    }

    func testSearchScopeUsesNativeActivationAndKeepsCurrentScopeInPrompt() throws {
        let page = UIViewController()
        let chrome = LibraryNavigationChrome(isRoot: true)
        chrome.attach(page)
        let model = SearchPageModel()
        model.query = "Song"
        model.isSearching = true
        model.submitted = true
        chrome.setSearchPage(model)
        let search = try XCTUnwrap(page.navigationItem.searchController)
        XCTAssertEqual(search.scopeBarActivation, .onSearchActivation)
        XCTAssertEqual(search.searchBar.placeholder, "网易云音乐中的歌曲、艺人、专辑及歌单")
        XCTAssertEqual(search.searchBar.text, "Song")
        model.selectScope(.library)
        chrome.setSearchPage(model)
        XCTAssertEqual(search.searchBar.selectedScopeButtonIndex, 1)
        XCTAssertEqual(search.searchBar.placeholder, "资料库中的歌曲、艺人、专辑及歌单")
        XCTAssertEqual(search.searchBar.text, "Song")
        XCTAssertTrue(model.submitted)
    }

    func testSearchDismissalRestoresBrowseBeforeCompletionAndIgnoresLateUpdates() throws {
        let page = UIViewController()
        let chrome = LibraryNavigationChrome(isRoot: true)
        chrome.attach(page)
        chrome.hasAppeared = true
        let model = SearchPageModel()
        model.query = "周杰伦"
        model.isSearching = true
        model.submitted = true
        var queries = 0
        model.onQuery = { queries += 1 }
        chrome.setSearchPage(model)
        let search = try XCTUnwrap(page.navigationItem.searchController)

        chrome.willDismissSearchController(search)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.submitted)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(queries, 1)
        search.searchBar.text = "迟到的文本"
        chrome.updateSearchResults(for: search)
        chrome.searchBarTextDidBeginEditing(search.searchBar)
        chrome.didPresentSearchController(search)
        chrome.setSearchPage(model)
        chrome.activateSearchPageIfNeeded()

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(search.isActive)
        XCTAssertFalse(model.isSearching)
    }

    func testActiveSearchAcceptsFirstChineseInputAndResumesEditingSubmittedResults() throws {
        let page = UIViewController()
        let chrome = LibraryNavigationChrome(isRoot: true)
        chrome.attach(page)
        let model = SearchPageModel()
        chrome.setSearchPage(model)
        let search = try XCTUnwrap(page.navigationItem.searchController)
        chrome.willPresentSearchController(search)

        search.searchBar.text = "周"
        chrome.updateSearchResults(for: search)
        XCTAssertEqual(model.query, "周")
        XCTAssertTrue(model.isSearching)
        model.submit()
        XCTAssertTrue(model.submitted)
        chrome.searchBarTextDidBeginEditing(search.searchBar)
        XCTAssertFalse(model.submitted)
        search.searchBar.text = "周杰伦"
        chrome.updateSearchResults(for: search)
        XCTAssertEqual(model.query, "周杰伦")
        XCTAssertTrue(model.isSearching)
    }

    func testSearchChromeRefreshKeepsKeyboardUntilSubmissionEvent() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let chrome = LibraryNavigationChrome(isRoot: true)
        let page = LibraryDetailHostingController(chrome: chrome)
        let model = SearchPageModel()
        model.isSearching = true
        chrome.setSearchPage(model)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle()
        let search = try XCTUnwrap(page.navigationItem.searchController)
        search.searchBar.becomeFirstResponder()
        XCTAssertTrue(search.searchBar.searchTextField.isFirstResponder)

        model.submit("晨光")
        chrome.setSearchPage(model)
        XCTAssertTrue(search.searchBar.searchTextField.isFirstResponder)
        chrome.completeSearchSubmission()
        XCTAssertFalse(search.searchBar.searchTextField.isFirstResponder)
        XCTAssertTrue(model.submitted)
    }

    func testNativeSearchUpdatesBindingAndCanBeRemoved() {
        let chrome = LibraryNavigationChrome(isRoot: false)
        let page = LibraryDetailHostingController(chrome: chrome)
        var text = "before"
        chrome.setSearch(Binding(get: { text }, set: { text = $0 }), prompt: "搜索专辑")
        let search = page.navigationItem.searchController!
        XCTAssertEqual(search.searchBar.text, "before")
        XCTAssertEqual(search.searchBar.placeholder, "搜索专辑")
        XCTAssertTrue(page.navigationItem.hidesSearchBarWhenScrolling)
        search.searchBar.text = "after"
        chrome.updateSearchResults(for: search)
        XCTAssertEqual(text, "after")
        chrome.setSearch(nil, prompt: "搜索专辑")
        XCTAssertNil(page.navigationItem.searchController)
    }

    func testZoomSourceIsArtworkOnly() {
        let card = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 210))
        let cover = LibraryArtworkSurfaceView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        card.addSubview(cover)
        card.addSubview(UILabel(frame: CGRect(x: 0, y: 170, width: 160, height: 30)))
        XCTAssertTrue(card.libraryArtworkSource() === cover)
        XCTAssertNil(UILabel().libraryArtworkSource())
    }

    func testHomeZoomSourceResolvesReplacementByStableIdentity() {
        let sources = LibraryArtworkSources()
        let first = UIView(), replacement = UIView(), otherAccount = UIView()
        sources.register(first, for: "42:recommended:list/12")
        let provider = { sources.view(for: "42:recommended:list/12") }
        XCTAssertTrue(provider() === first)
        sources.register(replacement, for: "42:recommended:list/12")
        sources.remove(first, for: "42:recommended:list/12")
        sources.register(otherAccount, for: "43:recommended:list/12")
        XCTAssertTrue(provider() === replacement)
        sources.remove(replacement, for: "42:recommended:list/12")
        XCTAssertNil(provider())
        XCTAssertTrue(sources.view(for: "43:recommended:list/12") === otherAccount)
    }

    func testZoomAlignmentTracksCoverThroughScrollingAndClipping() throws {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 600))
        scroll.contentSize = CGSize(width: 390, height: 1400)
        page.addSubview(scroll)
        let cover = LibraryArtworkSurfaceView(frame: CGRect(x: 62, y: 13, width: 266, height: 266))
        cover.isZoomAlignmentTarget = true
        scroll.addSubview(cover)
        // Other artwork must not be mistaken for the detail header, even when larger.
        scroll.addSubview(LibraryArtworkSurfaceView(frame: CGRect(x: 0, y: 400, width: 390, height: 390)))
        XCTAssertEqual(page.libraryArtworkAlignmentRect(), CGRect(x: 62, y: 113, width: 266, height: 266))
        scroll.contentOffset.y = 80
        XCTAssertEqual(page.libraryArtworkAlignmentRect(), CGRect(x: 62, y: 33, width: 266, height: 266))
        scroll.contentOffset.y = 300
        XCTAssertNil(page.libraryArtworkAlignmentRect())
        scroll.contentOffset = .zero
        cover.isHidden = true
        XCTAssertNil(page.libraryArtworkAlignmentRect())
        cover.isHidden = false
        cover.removeFromSuperview()
        XCTAssertNil(page.libraryArtworkAlignmentRect())
    }

    func testActualAlbumHeaderExposesZoomAlignmentTarget() async throws {
        let bridge = LibraryDetailNavigation()
        let sourceContainer = UIView()
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge, root: TestRoot(sourceContainer: sourceContainer), destination: { route in
                AnyView(CollectionDetailView(detail: CollectionDetail(kind: .album, title: "Album",
                    artwork: .missing, tint: .blue, songs: [], route: route)))
            }))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 120, height: 120))
        sourceContainer.addSubview(source)
        XCTAssertTrue(source.isDescendant(of: root.view))
        bridge.open(.album("alignment"), source: source)
        try await settle()
        let page = try XCTUnwrap(nav.topViewController)
        let rect = try XCTUnwrap(page.view.libraryArtworkAlignmentRect())
        XCTAssertEqual(rect.width, 266, accuracy: 0.5)
        XCTAssertEqual(rect.height, 266, accuracy: 0.5)
        XCTAssertEqual(rect.midX, page.view.bounds.midX, accuracy: 1)
        XCTAssertNotNil(page.preferredTransition)
        nav.popViewController(animated: true)
        try await settle()
        XCTAssertTrue(nav.topViewController === root)
    }

    func testHomeDailyDetailExposesNativePlaylistZoomTarget() async throws {
        let bridge = LibraryDetailNavigation()
        let sourceContainer = UIView()
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let library = PlaylistLibrary(playlists: [.init(id: "daily", title: "每日推荐", artwork: .image(Image("AlbumSample01")))])
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge, root: TestRoot(sourceContainer: sourceContainer), destination: { _ in
                AnyView(PlaylistDetailView(playlistID: "daily", library: library, songs: []))
            }))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 248, height: 330))
        sourceContainer.addSubview(source)
        XCTAssertTrue(source.isDescendant(of: root.view))
        bridge.open(.playlist("daily"), source: source)
        try await settle()
        let page = try XCTUnwrap(nav.topViewController)
        let rect = try XCTUnwrap(page.view.libraryArtworkAlignmentRect())
        XCTAssertEqual(rect.width, 266, accuracy: 0.5)
        XCTAssertEqual(rect.height, 266, accuracy: 0.5)
        XCTAssertNotNil(page.preferredTransition)
        nav.popViewController(animated: true)
        try await settle()
        XCTAssertTrue(nav.topViewController === root)
    }

    func testLibraryAlbumCardOpensWithCoverBeforeDetailLoads() async throws {
        let bridge = LibraryDetailNavigation()
        let integration = ArtistMusicIntegration(account: account)
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let backdrop = AlbumArtworkBackdrop(red: 0.05, green: 0.1, blue: 0.15)
        let item = LibraryShelfItem(id: "catalog:album:88", title: "Visible album", subtitle: "Artist",
                                   artwork: .image(Image(systemName: "circle.fill")), route: .album("catalog:album:88"),
                                   albumBackdrop: backdrop)
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: CollectionCardLink(item: item) { AlbumCard(item: item) }.frame(width: 160),
            destination: { integration.destination($0) ?? AnyView(Color.clear) }))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let selector = NSSelectorFromString("openCard")
        let source = try XCTUnwrap(descendants(of: UIView.self, in: root.view).first { $0.responds(to: selector) })
        source.perform(selector)
        let initialPage = try XCTUnwrap(nav.topViewController as? LibraryDetailHostingController)
        XCTAssertEqual(initialPage.chrome.colorScheme, backdrop.colorScheme)
        XCTAssertEqual(initialPage.view.backgroundColor, backdrop.uiColor,
                       "The native destination background must be ready when the zoom starts")
        try await settle()
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertNotNil(nav.topViewController?.view.libraryArtworkAlignmentRect())
        XCTAssertNil(integration.albumDetail(88))
        let view = try XCTUnwrap(nav.topViewController?.view)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Library album cover before detail response"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLocalAlbumSourcePreparesNativeBackgroundBeforePush() throws {
        let original = LocalLibrary.songLibrary.songs
        defer { LocalLibrary.songLibrary.replace(original) }
        let backdrop = AlbumArtworkBackdrop(red: 0.1, green: 0.15, blue: 0.2)
        let song = LibrarySongItem(id: "initial-appearance-local", title: "Local song", artist: "Artist", album: "Local album",
            albumArtist: "Artist", trackNumber: 1, artwork: .missing, albumDirectory: UUID().uuidString,
            artworkBackdrop: backdrop)
        LocalLibrary.songLibrary.replace([song])
        let item = try XCTUnwrap(LocalLibrary.albums.first { $0.id == song.albumID })
        let detail = try XCTUnwrap(LocalLibrary.albumDetail(song.albumID))
        var preview: LibraryNavigationPreview?
        OpenLibraryRouteAction(handler: { _ in XCTFail("Expected the source preview") },
            previewSourceHandler: { _, value, _ in preview = value })(item, sourceProvider: { nil })
        let captured = try XCTUnwrap(preview)
        XCTAssertEqual(captured.albumBackdrop, backdrop)
        let bridge = LibraryDetailNavigation()
        let page = bridge.makePage(AnyView(CollectionDetailView(detail: detail)), route: item.route, preview: captured)
        XCTAssertNil(page.navigationController, "This assertion runs before the native push")
        XCTAssertEqual(page.view.backgroundColor, backdrop.uiColor)
        XCTAssertEqual(page.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(page.chrome.colorScheme, backdrop.colorScheme)

        let other = LibraryNavigationPreview(route: captured.route, ownerID: "other-account", title: item.title,
            artwork: item.artwork, albumBackdrop: backdrop)
        let rejected = bridge.makePage(AnyView(EmptyView()), route: item.route, preview: other)
        XCTAssertNil(rejected.chrome.colorScheme, "A rejected account preview must not seed the native page appearance")
    }

    func testUnloadedHomeAlbumUsesPreviewHeaderAndRejectsAnotherAccountsPreview() async throws {
        let bridge = LibraryDetailNavigation()
        let sourceContainer = UIView()
        let integration = ArtistMusicIntegration(account: account)
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge, root: TestRoot(sourceContainer: sourceContainer), destination: { integration.destination($0) ?? AnyView(Color.clear) }))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 161, height: 161))
        sourceContainer.addSubview(source)
        XCTAssertTrue(source.isDescendant(of: root.view))
        let route = LibraryRoute.album("catalog:album:88")
        let preview = LibraryNavigationPreview(route: route, ownerID: nil, title: "Visible album", subtitle: "Artist", artwork: .missing)
        bridge.open(route, source: source, animated: false, preview: preview)
        try await settle()
        XCTAssertNotNil(nav.topViewController?.view.libraryArtworkAlignmentRect())
        XCTAssertNil(integration.albumDetail(88))
        nav.popViewController(animated: false)
        try await settle()
        let other = LibraryNavigationPreview(route: route, ownerID: "42", title: "Other account", artwork: .favorites)
        bridge.open(route, source: source, animated: false, preview: other)
        try await settle()
        XCTAssertNil(nav.topViewController?.view.libraryArtworkAlignmentRect())
    }

    func testPinnedCellsKeepOneArtworkOnlyZoomSurfaceWhenEditing() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: TestPinnedShelf(isEditing: false))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()

        func assertArtworkSurfaces() throws {
            host.view.layoutIfNeeded()
            let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), 3)
            for index in 0..<3 {
                let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)))
                let surfaces = descendants(of: LibraryArtworkSurfaceView.self, in: cell)
                XCTAssertEqual(surfaces.count, 1, "Each pinned cell must expose exactly one actual artwork surface")
                let cover = try XCTUnwrap(surfaces.first)
                XCTAssertTrue(cell.libraryArtworkSource() === cover)
                XCTAssertFalse(cover.isHidden)
                XCTAssertGreaterThan(cover.bounds.width, 0)
                XCTAssertEqual(cover.bounds.width, cover.bounds.height, accuracy: 0.5)
                XCTAssertEqual(cover.bounds.width, cell.contentView.bounds.width, accuracy: 0.5)
                // Measure local bounds so edit-mode wobble cannot distort the check.
                // The caption remains outside this square; a whole-card zoom source
                // would consume the title row and fail these geometry assertions.
                let captionHeight = UIFont.preferredFont(forTextStyle: .caption1,
                                                        compatibleWith: cell.traitCollection).lineHeight
                XCTAssertGreaterThanOrEqual(cell.contentView.bounds.height - cover.bounds.height,
                                            captionHeight - 1)
            }
        }

        try assertArtworkSurfaces()
        // Update the existing representable, rather than mounting an unrelated edit fixture.
        host.rootView = TestPinnedShelf(isEditing: true)
        try await settle()
        try assertArtworkSurfaces()
    }

    func testRecentlyAddedZoomSourceIsEachCover() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let items: [LibraryShelfItem] = [
            .init(id: "left", title: "左上封面", subtitle: "艺人", artwork: .missing, route: .album("left")),
            .init(id: "right", title: "右上封面", subtitle: "艺人", artwork: .missing, route: .album("right")),
            .init(id: "below", title: "下一行封面", subtitle: "艺人", artwork: .missing, route: .playlist("below")),
            .init(id: "song", title: "单曲", subtitle: "艺人", artwork: .missing, songID: "song-1")
        ]
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: LibraryHomeView(pinned: [], recentlyAdded: items, playlistLibrary: PlaylistLibrary(playlists: [])),
            destination: { _ in AnyView(EmptyView()) }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        let page = try XCTUnwrap(bridge.navigationController?.topViewController?.view)
        page.layoutIfNeeded()
        if let list = descendants(of: UIScrollView.self, in: page).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            list.layoutIfNeeded()
            list.setContentOffset(CGPoint(x: 0, y: max(0, list.contentSize.height - list.bounds.height)), animated: false)
            list.layoutIfNeeded()
        }
        try await settle()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: page).first { $0.numberOfItems(inSection: 0) == 4 })
        collection.layoutIfNeeded()
        var origins: [CGPoint] = []
        for index in 0..<3 {
            let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)),
                                     "Recently added card \(index) must be on screen")
            let surfaces = descendants(of: LibraryArtworkSurfaceView.self, in: cell)
            XCTAssertEqual(surfaces.count, 1, "Each album or playlist card needs one cover zoom source")
            let cover = try XCTUnwrap(surfaces.first)
            XCTAssertTrue(cell.libraryArtworkSource() === cover)
            let coverFrame = collection.convert(cover.bounds, from: cover)
            let cellFrame = collection.convert(cell.contentView.bounds, from: cell.contentView)
            XCTAssertEqual(coverFrame.midX, cellFrame.midX, accuracy: 1)
            XCTAssertEqual(coverFrame.minY, cellFrame.minY, accuracy: 8)
            XCTAssertEqual(coverFrame.width, coverFrame.height, accuracy: 0.5)
            XCTAssertEqual(coverFrame.width, cellFrame.width, accuracy: 16)
            XCTAssertGreaterThan(cellFrame.maxY, coverFrame.maxY + 12, "The title stays outside the zoom source")
            origins.append(coverFrame.origin)
        }
        XCTAssertGreaterThan(origins[1].x, origins[0].x + 20)
        XCTAssertEqual(origins[1].y, origins[0].y, accuracy: 1)
        XCTAssertEqual(origins[2].x, origins[0].x, accuracy: 1)
        XCTAssertGreaterThan(origins[2].y, origins[0].y + 20)
        let song = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 3, section: 0)))
        XCTAssertTrue(descendants(of: LibraryArtworkSurfaceView.self, in: song).isEmpty)
    }

    func testAccessibilityRecentlyAddedCardFitsScrollableContentAndKeepsCoverSourceOnReturn() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let item = LibraryShelfItem(
            id: "long-album",
            title: "沿着城市边缘一直走到海边的那些漫长夜晚与清晨：完整现场录音特别纪念版",
            subtitle: "The Northern Lights Collective with Friends from Every Corner of the City",
            artwork: .missing, route: .album("long-album"))
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: LibraryHomeView(pinned: [], recentlyAdded: [item], playlistLibrary: PlaylistLibrary(playlists: [])),
            destination: { route in
                AnyView(CollectionDetailView(detail: CollectionDetail(
                    kind: .album, title: item.title, subtitle: item.subtitle,
                    artwork: item.artwork, tint: Color(.systemBackground), songs: [], route: route)))
            })
            .environment(account)
            .environment(\.dynamicTypeSize, .accessibility5))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let page = try XCTUnwrap(nav.topViewController?.view)
        let list = try XCTUnwrap(descendants(of: UIScrollView.self, in: page)
            .max { $0.contentSize.height < $1.contentSize.height })
        let surfaces = descendants(of: LibraryArtworkSurfaceView.self, in: page)
        XCTAssertEqual(surfaces.count, 1)
        let cover = try XCTUnwrap(surfaces.first)
        // The list also owns a context-menu interaction. Resolve the card's nearest
        // menu host from its cover instead of accepting an ancestor of the whole list.
        var ancestor = cover.superview
        while let current = ancestor,
              !current.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
            ancestor = current.superview
        }
        let card = try XCTUnwrap(ancestor)
        XCTAssertFalse(card is UIScrollView)
        XCTAssertTrue(card.isDescendant(of: list))
        XCTAssertTrue(card.libraryArtworkSource() === cover)
        XCTAssertGreaterThan(cover.bounds.width, list.bounds.width * 0.75,
                             "An accessibility card uses the single-column content width")
        XCTAssertEqual(cover.bounds.width, cover.bounds.height, accuracy: 0.5)

        let cardFrame = list.convert(card.bounds, from: card)
        XCTAssertGreaterThanOrEqual(cardFrame.minY, -1)
        XCTAssertLessThanOrEqual(cardFrame.maxY, list.contentSize.height + 1,
                                 "The complete multi-line card must be reachable in the list's scrollable content")
        let fittingSize = card.systemLayoutSizeFitting(
            CGSize(width: card.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThanOrEqual(card.bounds.height, fittingSize.height - 1,
                                    "The card must include its full content at the displayed width")
        let largeTextTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let lineHeight = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: largeTextTraits).lineHeight
        XCTAssertGreaterThan(card.bounds.height - cover.bounds.height, lineHeight * 4,
                             "Long title and subtitle grow beyond a fixed two-line caption")

        let coverFrame = list.convert(cover.bounds, from: cover)
        let minimumOffset = -list.adjustedContentInset.top
        let maximumOffset = max(minimumOffset, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        list.setContentOffset(CGPoint(x: 0, y: min(maximumOffset, max(minimumOffset, coverFrame.minY - 40))), animated: false)
        try await settle()
        let retainedOffset = list.contentOffset
        bridge.open(.album("long-album"), source: cover, animated: false)
        try await settle()
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertNotNil(nav.topViewController?.preferredTransition)
        nav.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(nav.topViewController?.view === page)
        XCTAssertTrue(card.libraryArtworkSource() === cover)
        XCTAssertTrue(cover.isDescendant(of: page))
        XCTAssertEqual(list.contentOffset.y, retainedOffset.y, accuracy: 1)
    }

    func testPinnedEditingWobbleStopsAndRestartsWithCellLifecycle() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: TestPinnedShelf(isEditing: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()
        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)

        func assertWobble(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(collection.visibleCells.count, 3, file: file, line: line)
            for cell in collection.visibleCells {
                let rotations = (cell.contentView.layer.animationKeys() ?? []).compactMap {
                    cell.contentView.layer.animation(forKey: $0) as? CAPropertyAnimation
                }.filter { $0.keyPath == "transform.rotation.z" }
                XCTAssertEqual(rotations.isEmpty, !expected, file: file, line: line)
                if !expected {
                    let transform = cell.contentView.layer.presentation()?.transform ?? cell.contentView.layer.transform
                    XCTAssertTrue(CATransform3DIsIdentity(transform), "Stopped cards must be upright", file: file, line: line)
                }
            }
        }

        assertWobble(true)
        // Exercise the same hosted cells, including entering editing a second time.
        for _ in 0..<2 {
            host.rootView = TestPinnedShelf(isEditing: false)
            try await settle()
            assertWobble(false)
            try await Task.sleep(for: .milliseconds(180))
            assertWobble(false)
            host.rootView = TestPinnedShelf(isEditing: true)
            try await settle()
            assertWobble(true)
        }
        for (phase, cell) in collection.visibleCells.enumerated() {
            let card = try XCTUnwrap(cell as? PinnedCollectionCell)
            card.setEditing(true, phase: phase, reduceMotion: true)
        }
        try await Task.sleep(for: .milliseconds(180))
        assertWobble(false)
        for (phase, cell) in collection.visibleCells.enumerated() {
            let card = try XCTUnwrap(cell as? PinnedCollectionCell)
            card.setEditing(true, phase: phase, reduceMotion: false)
        }
        try await Task.sleep(for: .milliseconds(180))
        assertWobble(true)

        let cells = collection.visibleCells
        host.view.removeFromSuperview()
        for cell in cells {
            XCTAssertNil(cell.window)
            XCTAssertTrue((cell.contentView.layer.animationKeys() ?? []).isEmpty)
            XCTAssertTrue(CATransform3DIsIdentity(cell.contentView.layer.transform))
        }
        window.addSubview(host.view)
        try await settle()
        assertWobble(true)
        for cell in cells {
            cell.prepareForReuse()
            XCTAssertTrue((cell.contentView.layer.animationKeys() ?? []).isEmpty)
            XCTAssertTrue(CATransform3DIsIdentity(cell.contentView.layer.transform))
        }
    }

    func testNativeZoomQueriesReplacementSourceWhenReturning() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else {
            throw XCTSkip("Requires system zoom animations to exercise UIKit's source-provider callbacks")
        }
        let bridge = LibraryDetailNavigation()
        let sourceContainer = UIView()
        let window = try await mount(bridge, sourceContainer: sourceContainer)
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let first = UIView(frame: CGRect(x: 20, y: 160, width: 120, height: 120))
        first.backgroundColor = .systemBlue
        sourceContainer.addSubview(first)
        XCTAssertTrue(first.isDescendant(of: root.view))
        var currentSource: UIView = first
        var queriedSources: [ObjectIdentifier] = []
        let open = OpenLibraryRouteAction(
            handler: { _ in XCTFail("The source-provider route must not fall back to plain navigation") },
            sourceProviderHandler: { route, provider in
                bridge.open(route, sourceProvider: provider)
            })
        open(.album("dynamic-source"), sourceProvider: {
            queriedSources.append(ObjectIdentifier(currentSource))
            return currentSource
        })
        try await settle()
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertNotNil(nav.topViewController?.preferredTransition)
        XCTAssertTrue(queriedSources.contains(ObjectIdentifier(first)), "Zoom-in must query its live source")

        let replacement = UIView(frame: CGRect(x: 170, y: 190, width: 100, height: 100))
        replacement.backgroundColor = .systemGreen
        sourceContainer.addSubview(replacement)
        XCTAssertTrue(replacement.isDescendant(of: root.view))
        currentSource = replacement
        first.removeFromSuperview()
        let queriesBeforeReturn = queriedSources.count
        nav.popViewController(animated: true)
        try await settle()
        XCTAssertTrue(nav.topViewController === root)
        let returnQueries = Array(queriedSources.dropFirst(queriesBeforeReturn))
        XCTAssertFalse(returnQueries.isEmpty, "Zoom-out must query again instead of retaining the original source")
        XCTAssertTrue(returnQueries.allSatisfy { $0 == ObjectIdentifier(replacement) })
    }

    private func assertNativeToolbar(in navigation: UINavigationController?, file: StaticString = #filePath, line: UInt = #line) throws {
        let navigation = try XCTUnwrap(navigation, file: file, line: line)
        let page = try XCTUnwrap(navigation.topViewController, file: file, line: line)
        // UIKit groups include system spacing items. HomeFeedTests checks each
        // visible action through the SwiftUI accessibility tree and opens Account.
        XCTAssertFalse(page.navigationItem.trailingItemGroups.isEmpty, file: file, line: line)
        XCTAssertTrue(navigation.navigationBar.topItem === page.navigationItem, file: file, line: line)
        XCTAssertFalse(navigation.isNavigationBarHidden, file: file, line: line)
    }

    private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    func testRootRegistersActualSwiftUIListForNativeMinimization() async throws {
        let bridge = LibraryDetailNavigation()
        let window = try await mount(bridge)
        defer { window.isHidden = true }
        try await settle()
        let page = try XCTUnwrap(bridge.navigationController?.topViewController as? LibraryDetailHostingController)
        XCTAssertNotNil(page.contentScrollView(for: .top))
        XCTAssertEqual(page.navigationItem.navigationBarMinimization.minimizationBehavior, .onScrollDown)
        XCTAssertEqual(page.navigationItem.navigationBarMinimization.restorationBehavior, .atScrollEdge)
        XCTAssertEqual(page.navigationItem.navigationBarMinimization.safeAreaAdjustment, .disabled)
    }
}

@MainActor
final class AlbumInitialAppearanceTests: XCTestCase {
    func testPreparedAppearanceBeforeLayoutAndInitialRenderedBackground() async throws {
        let bridge = LibraryDetailNavigation()
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let rootReady = expectation(description: "Library root appears")
        var rootHasAppeared = false
        var rootReturned: XCTestExpectation?
        var nextAppearance: XCTestExpectation?
        var appearances: [String] = []
        var displayedPage: LibraryDetailHostingController?
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: TestRoot().background {
                AlbumAppearanceProbe(onAppearance: { _ in
                    if rootHasAppeared { rootReturned?.fulfill() }
                }, onDisplayed: { _ in
                    if !rootHasAppeared {
                        rootHasAppeared = true
                        rootReady.fulfill()
                    }
                }).frame(width: 0, height: 0)
            },
            destination: { [weak bridge] route in
                guard case .album(let id) = route else { return AnyView(EmptyView()) }
                let component: Double = id == "dark" ? 0 : 1
                let backdrop = AlbumArtworkBackdrop(red: component, green: component, blue: component)
                return AnyView(CollectionDetailView(detail: CollectionDetail(kind: .album, title: id,
                    artwork: .missing, tint: .clear, albumBackdrop: backdrop, songs: [], route: route))
                    .background {
                        AlbumAppearanceProbe(onAppearance: { probe in
                            // UIKit has prepared traits and geometry, but has not yet
                            // completed subtree layout/display. Check prepared state here.
                            do {
                                let page = try XCTUnwrap(probe.navigationController?.topViewController as? LibraryDetailHostingController)
                                let sequence = appearances + [id]
                                let appearance = "album=\(id), appearances=\(sequence)"
                                XCTAssertEqual(page.chrome.colorScheme, backdrop.colorScheme, appearance)
                                XCTAssertEqual(bridge?.colorScheme, backdrop.colorScheme, appearance)
                            } catch { XCTFail("Unable to inspect prepared album appearance: \(error)") }
                            appearances.append(id)
                        }, onDisplayed: { probe in
                            do {
                                displayedPage = try XCTUnwrap(probe.navigationController?.topViewController as? LibraryDetailHostingController)
                                nextAppearance?.fulfill()
                            } catch { XCTFail("Unable to inspect displayed album: \(error)") }
                        }).frame(width: 0, height: 0)
                    })
            }))
        window.makeKeyAndVisible()
        await fulfillment(of: [rootReady], timeout: 3)
        let nav = try XCTUnwrap(bridge.navigationController)
        XCTAssertNil(bridge.colorScheme)

        nextAppearance = expectation(description: "Dark album first appearance")
        bridge.open(.album("dark"), animated: false)
        await fulfillment(of: [try XCTUnwrap(nextAppearance)], timeout: 3)
        let darkPage = try XCTUnwrap(displayedPage)
        XCTAssertTrue(nav.topViewController === darkPage)
        try assertRenderedAppearance(of: darkPage, component: 0, appearances: appearances, bridge: bridge)

        nextAppearance = expectation(description: "Light album first appearance")
        bridge.open(.album("light"), animated: false)
        await fulfillment(of: [try XCTUnwrap(nextAppearance)], timeout: 3)
        try assertRenderedAppearance(of: XCTUnwrap(displayedPage), component: 1, appearances: appearances, bridge: bridge)

        nextAppearance = expectation(description: "Dark album reappears")
        nav.popViewController(animated: false)
        await fulfillment(of: [try XCTUnwrap(nextAppearance)], timeout: 3)
        XCTAssertTrue(nav.topViewController === darkPage)
        XCTAssertEqual(appearances, ["dark", "light", "dark"])

        nextAppearance = nil
        rootReturned = expectation(description: "Library root reappears")
        nav.popViewController(animated: false)
        await fulfillment(of: [try XCTUnwrap(rootReturned)], timeout: 3)
        XCTAssertNil(bridge.colorScheme, "Returning to the library restores inherited appearance")
    }

    private func assertRenderedAppearance(of page: LibraryDetailHostingController, component: Double,
                                          appearances: [String], bridge: LibraryDetailNavigation) throws {
        // Capture after UIKit returns from viewDidAppear, outside its layout/display transaction.
        XCTAssertNotNil(page.view.libraryArtworkAlignmentRect(), "The album content must be present")
        let id = component == 0 ? "dark" : "light"
        let appearance = "album=\(id), appearances=\(appearances)"
        let image = snapshot(of: page.view)
        let pixel = try backgroundPixel(in: page.view, snapshot: image)
        let diagnostic = "\(appearance), RGBA=\(pixel), sample=\(backgroundSamplePoint(in: page.view)), bounds=\(page.view.bounds), chrome=\(String(describing: page.chrome.colorScheme)), bridge=\(String(describing: bridge.colorScheme))"
        attachAppearance(of: page.view, snapshot: image, name: "\(appearances.count)-\(id)", diagnostic: diagnostic)
        for (index, channel) in pixel.prefix(3).enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(channel) - (component == 0 ? 0 : 255)), 2,
                                    "channel=\(index), \(diagnostic)")
        }
        XCTAssertEqual(pixel[3], 255, "The initially rendered page background must be opaque: \(diagnostic)")
    }

    private func backgroundSamplePoint(in view: UIView) -> CGPoint {
        CGPoint(x: view.bounds.minX + 8, y: view.bounds.midY)
    }

    private func snapshot(of view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var complete = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            complete = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(complete, "The initial completed appearance snapshot must contain every view's image data")
        return image
    }

    private func attachAppearance(of view: UIView, snapshot: UIImage, name: String, diagnostic: String) {
        let details = XCTAttachment(string: diagnostic)
        details.name = "\(name)-appearance-details"
        details.lifetime = .keepAlways
        add(details)
        let page = XCTAttachment(image: snapshot)
        page.name = "\(name)-page-initial-viewDidAppear"
        page.lifetime = .keepAlways
        add(page)
        if let window = view.window {
            let screen = XCTAttachment(image: self.snapshot(of: window))
            screen.name = "\(name)-window-initial-viewDidAppear"
            screen.lifetime = .keepAlways
            add(screen)
        }
    }

    private func backgroundPixel(in view: UIView, snapshot: UIImage) throws -> [UInt8] {
        XCTAssertGreaterThan(view.bounds.width, 20)
        XCTAssertGreaterThan(view.bounds.height, 20)
        // The leading page margin lies outside the centered artwork and all list text.
        let point = backgroundSamplePoint(in: view)
        let image = try XCTUnwrap(snapshot.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        let offset = (Int(point.y - view.bounds.minY) * width + Int(point.x - view.bounds.minX)) * 4
        let pixel = Array(pixels[offset..<(offset + 4)])
        let hasContent = stride(from: 0, to: pixels.count, by: 4).contains { offset in
            (0..<3).contains { abs(Int(pixels[offset + $0]) - Int(pixel[$0])) > 2 }
        }
        XCTAssertTrue(hasContent, "The completed album snapshot must contain artwork/text, not only a blank background")
        return pixel
    }
}

/// Test-only observation of the real UIKit appearance lifecycle; no delayed sampling.
private struct AlbumAppearanceProbe: UIViewControllerRepresentable {
    let onAppearance: (UIViewController) -> Void
    let onDisplayed: (UIViewController) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(onAppearance: onAppearance, onDisplayed: onDisplayed) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAppearance = onAppearance
        controller.onDisplayed = onDisplayed
    }

    final class Controller: UIViewController {
        var onAppearance: (UIViewController) -> Void
        var onDisplayed: (UIViewController) -> Void
        init(onAppearance: @escaping (UIViewController) -> Void, onDisplayed: @escaping (UIViewController) -> Void) {
            self.onAppearance = onAppearance
            self.onDisplayed = onDisplayed
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            onAppearance(self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onDisplayed(self)
        }
    }
}

private struct TestPinnedShelf: View {
    let isEditing: Bool
    private let items: [LibraryShelfItem] = [
        .init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites")),
        .init(id: "album", title: "标题不应成为缩放封面的一部分", artwork: .missing, route: .album("album")),
        .init(id: "playlist", title: "播放列表", artwork: .playlist, route: .playlist("playlist"))
    ]

    var body: some View {
        VStack {
            PinnedCollectionView(items: items, isEditing: isEditing, tapActions: .constant([:]),
                                 reorder: { _ in true }, remove: { _ in })
                .frame(width: 330)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .environment(\.nativeArtworkSurfaceEnabled, true)
    }
}

private struct TestSourceContainer: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {}
}

private struct TestRoot: View {
    var showsArtwork = false
    var sourceContainer: UIView? = nil
    var body: some View {
        List {
            if showsArtwork {
                LibraryArtworkSurface(content: Color.blue, cornerRadius: 6)
                    .frame(width: 140, height: 140)
            }
            LibraryRouteLink(value: .category(.albums)) { Label("专辑", systemImage: "square.stack") }
        }
            .overlay {
                if let sourceContainer {
                    TestSourceContainer(view: sourceContainer)
                }
            }
            .libraryHomeNavigation()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("新建播放列表", systemImage: "text.badge.plus") {} }
                ToolbarItem(placement: .topBarTrailing) { Menu("更多", systemImage: "ellipsis") { Button("编辑置顶", systemImage: "pin") {} } }
            }
    }
}
private struct TestDetail: View {
    let route: LibraryRoute
    @State private var query = ""
    var body: some View {
        List { Text("Original content") }
            .libraryNavigationTitle("专辑")
            .libraryTitleDisplayMode(.large)
            .librarySearchable(text: $query, prompt: "搜索")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu("更多", systemImage: "ellipsis") { Button("Test") {} } } }
    }
}
