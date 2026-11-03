import XCTest
import SwiftUI
import LNPopupController
@testable import NeoMusic

@MainActor @Observable
private final class StartupLibraryProbe {
    var isReady = false
    let library = PlaylistLibrary(playlists: [])
}

@MainActor
private final class NavigationAccountStorage {
    var session: NeteaseSavedSession?
}

private struct StartupLibraryProbeView: View {
    let probe: StartupLibraryProbe
    var body: some View {
        LibraryHomeView(pinned: probe.isReady ? [
            .init(id: "first", title: "专辑一", artwork: .missing, route: .album("first")),
            .init(id: "second", title: "专辑二", artwork: .missing, route: .album("second")),
            .init(id: "third", title: "专辑三", artwork: .missing, route: .album("third")),
            .init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites"))
        ] : [], recentlyAdded: probe.isReady ? [
            .init(id: "recent-first", title: "最近专辑一", artwork: .missing, route: .album("recent-first")),
            .init(id: "recent-second", title: "最近专辑二", artwork: .missing, route: .album("recent-second"))
        ] : [],
                        playlistLibrary: probe.library, isContentReady: probe.isReady)
    }
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

    private func mount(_ bridge: LibraryDetailNavigation) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            LibraryNavigationContainer(navigation: bridge, root: TestRoot(),
                destination: { route in AnyView(TestDetail(route: route)) }))
        window.makeKeyAndVisible()
        return window
    }

    func testOwnsNativeStackAndRetainsOriginalToolbarGroups() async throws {
        let bridge = LibraryDetailNavigation()
        let window = try mount(bridge)
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
        let window = try mount(bridge)
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let player = PlayerTestFixtures.state(tracks: [ReferenceTrack(id: "appearance", title: "Track",
            artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60)])
        window.rootViewController = UIHostingController(rootView: AppShell(
            library: { TestRoot(showsArtwork: true) }, detailDestination: { AnyView(TestDetail(route: $0)) }, nowPlaying: nil,
            playlistLibrary: PlaylistLibrary(playlists: []), toasts: LibraryToastCenter(),
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(),
            makePlayerActions: { _ in PlayerTestFixtures.actions() }).environment(account))
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
        nav.popViewController(animated: false)
        try await settle()
        assertAppearance(.dark)
        page.chrome.setColorScheme(.light)
        try await settle()
        assertAppearance(.dark)
        window.overrideUserInterfaceStyle = .light
        try await settle()
        assertAppearance(.light)
    }

    func testAlbumScrollContentExtendsBehindBarsWithNativeTopEffect() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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
            referencePlayer: player, referenceLibrary: PlayerTestFixtures.library(), makePlayerActions: { _ in PlayerTestFixtures.actions() }).environment(account))
        window.makeKeyAndVisible()
        try await settle()
        func findNavigation(in controller: UIViewController) -> UINavigationController? {
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
        let window = try mount(bridge)
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 140, height: 140))
        source.backgroundColor = .systemBlue
        root.view.addSubview(source)
        bridge.open(.album("first"), source: source)
        XCTAssertNotNil(nav.topViewController?.preferredTransition)
        try await Task.sleep(for: .milliseconds(100))
        nav.popViewController(animated: true)
        try await settle()
        XCTAssertTrue(nav.topViewController === root)
        XCTAssertEqual(bridge.depth, 0)
        bridge.open(.album("second"), source: source)
        try await settle()
        XCTAssertTrue(nav.topViewController is LibraryDetailHostingController)
        XCTAssertEqual(bridge.depth, 1)
    }

    func testNavigationGeometryMatchesOriginalSwiftUIContainer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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
        XCTAssertEqual(tabs.tabs.count, 5)
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
        func recentCoverFrame(presentation: Bool) -> CGRect? {
            guard let cover = descendants(of: LibraryArtworkSurfaceView.self, in: page.view)
                .first(where: { $0.bounds.width > 150 }),
                  let row = list.visibleCells.first(where: { cover.isDescendant(of: $0) }) else { return nil }
            if presentation, let coverLayer = cover.layer.presentation(), let rowLayer = row.layer.presentation() {
                return coverLayer.convert(coverLayer.bounds, to: rowLayer)
            }
            return cover.convert(cover.bounds, to: row)
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
        XCTAssertTrue(categoryPositions.contains { $0 > initialCategoryY + 1 && $0 < finalCategoryY - 1 },
                      "The categories must move through intermediate positions during insertion")
        let finalCoverFrame = try XCTUnwrap(recentCoverFrame(presentation: false))
        XCTAssertGreaterThan(recentCoverFrames.count, 5)
        for frame in recentCoverFrames {
            XCTAssertEqual(frame.minX, finalCoverFrame.minX, accuracy: 1, "Album fill must not slide inside the recently-added row")
            XCTAssertEqual(frame.minY, finalCoverFrame.minY, accuracy: 1, "The shelf insertion moves the row, not its album content")
        }
    }

    func testActualLibraryHomePublishesItsToolbar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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
            if let nav = vc as? UINavigationController {
                try assertNativeToolbar(in: nav)
            }
            try vc.children.forEach(inspect)
        }
        try inspect(window.rootViewController!)
    }

    func testLibraryHomeRevealsPinsOnceAndKeepsTheirLayoutOnReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let bridge = LibraryDetailNavigation()
        let items: [LibraryShelfItem] = [
            .init(id: "favorites", title: "喜爱歌曲", artwork: .favorites, route: .playlist("favorites")),
            .init(id: "album", title: "专辑", artwork: .missing, route: .album("album"))
        ]
        var nextRootAppearance = expectation(description: "Root appears before revealing pins")
        let destinationReady = expectation(description: "Destination appears")
        var firstCollection: UICollectionView?
        var firstFrame: CGRect?
        var appearances = 0
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge,
            root: LibraryHomeView(pinned: items, recentlyAdded: [], playlistLibrary: PlaylistLibrary(playlists: []))
                .background {
                    AlbumAppearanceProbe(onAppearance: { _ in }, onDisplayed: { probe in
                        if appearances > 0 {
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
                            } catch { XCTFail("Returning must keep the revealed shelf in place: \(error)") }
                        }
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: LibraryNavigationContainer(
            navigation: bridge, root: TestRoot(), destination: { route in
                AnyView(CollectionDetailView(detail: CollectionDetail(kind: .album, title: "Album",
                    artwork: .missing, tint: .blue, songs: [], route: route)))
            }))
        window.makeKeyAndVisible()
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let source = UIView(frame: CGRect(x: 20, y: 160, width: 120, height: 120))
        root.view.addSubview(source)
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

    func testPinnedCellsKeepOneArtworkOnlyZoomSurfaceWhenEditing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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

    func testPinnedEditingWobbleStopsAndRestartsWithCellLifecycle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
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
        let window = try mount(bridge)
        defer { window.isHidden = true }
        try await settle()
        let nav = try XCTUnwrap(bridge.navigationController)
        let root = try XCTUnwrap(nav.topViewController)
        let first = UIView(frame: CGRect(x: 20, y: 160, width: 120, height: 120))
        first.backgroundColor = .systemBlue
        root.view.addSubview(first)
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
        root.view.addSubview(replacement)
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
        let window = try mount(bridge)
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let rootReady = expectation(description: "Library root appears")
        var rootHasAppeared = false
        var rootReturned: XCTestExpectation?
        var nextAppearance: XCTestExpectation?
        var appearances: [String] = []
        var renderedPages: Set<ObjectIdentifier> = []
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
                            // Signal the UIKit event before rendering/encoding diagnostic
                            // attachments, so their cost is not part of the lifecycle wait.
                            nextAppearance?.fulfill()
                            // All pushes are nonanimated. This observes the first completed
                            // appearance, not the compositor's first frame of an animated zoom.
                            do {
                                let page = try XCTUnwrap(probe.navigationController?.topViewController as? LibraryDetailHostingController)
                                // Snapshot only newly created destinations. Return appearances
                                // retain the state checks above; their pixels require device review.
                                guard renderedPages.insert(ObjectIdentifier(page)).inserted else { return }
                                XCTAssertNotNil(page.view.libraryArtworkAlignmentRect(), "The album content must be present")
                                let sequence = appearances
                                let appearance = "album=\(id), appearances=\(sequence)"
                                let image = self.snapshot(of: page.view)
                                let pixel = try self.backgroundPixel(in: page.view, snapshot: image)
                                let diagnostic = "\(appearance), RGBA=\(pixel), sample=\(self.backgroundSamplePoint(in: page.view)), bounds=\(page.view.bounds), chrome=\(String(describing: page.chrome.colorScheme)), bridge=\(String(describing: bridge?.colorScheme))"
                                self.attachAppearance(of: page.view, snapshot: image, name: "\(sequence.count)-\(id)", diagnostic: diagnostic)
                                for (index, channel) in pixel.prefix(3).enumerated() {
                                    XCTAssertLessThanOrEqual(abs(Int(channel) - (component == 0 ? 0 : 255)), 2,
                                                            "channel=\(index), \(diagnostic)")
                                }
                                XCTAssertEqual(pixel[3], 255, "The initially rendered page background must be opaque: \(diagnostic)")
                            } catch { XCTFail("Unable to inspect initially rendered album content: \(error)") }
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
        let darkPage = try XCTUnwrap(nav.topViewController)

        nextAppearance = expectation(description: "Light album first appearance")
        bridge.open(.album("light"), animated: false)
        await fulfillment(of: [try XCTUnwrap(nextAppearance)], timeout: 3)

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

private struct TestRoot: View {
    var showsArtwork = false
    var body: some View {
        List {
            if showsArtwork {
                LibraryArtworkSurface(content: Color.blue, cornerRadius: 6)
                    .frame(width: 140, height: 140)
            }
            LibraryRouteLink(value: .category(.albums)) { Label("专辑", systemImage: "square.stack") }
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
