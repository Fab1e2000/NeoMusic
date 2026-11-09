import XCTest
import SwiftUI
@testable import NeoMusic

@MainActor
final class AppStartupPerformanceTests: XCTestCase {
    func testArtistShelfKeepsCardHeightAndRequestsOnlyVisibleCovers() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        var requested = Set<String>()
        let first = expectation(description: "The visible artist album requests artwork")
        let albums = (0..<30).map { index in
            LibraryShelfItem(id: "album-\(index)", title: "Album \(index)", subtitle: "2026",
                artwork: .deferred(id: "cover-\(index)", placeholder: .missing), route: .album("album-\(index)"))
        }
        let page = ArtistDetailView(detail: ArtistDetail(name: "Artist", albums: albums))
            .environment(\.artworkLoadAction, ArtworkLoadAction { id in
                if requested.insert(id).inserted, id == "cover-0" { first.fulfill() }
            })
        let host = UIHostingController(rootView: page)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [first], timeout: 3)
        host.view.layoutIfNeeded()
        // Inspect children too because the album strip is inside the vertical page.
        func horizontal(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 100 { return scroll }
            return view.subviews.lazy.compactMap(horizontal).first
        }
        let shelf = try XCTUnwrap(horizontal(host.view))
        XCTAssertGreaterThan(shelf.bounds.height, 180)
        XCTAssertLessThan(shelf.bounds.height, 260)
        XCTAssertLessThan(requested.count, albums.count)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Artist lazy shelf"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSongThumbnailAvoidsNestedHostingWhileAlbumKeepsNativeZoomSurface() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let appeared = expectation(description: "Song row and album card appeared")
        let song = LibrarySongItem(id: "song", title: "Song", artist: "Artist", album: "Album",
            albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        let album = LibraryShelfItem(id: "album", title: "Album", artwork: .missing, route: .album("album"))
        let page = VStack(alignment: .leading, spacing: 20) {
            SongRow(song: song).frame(width: 320)
            AlbumCard(item: album).frame(width: 180)
        }
        .environment(\.nativeArtworkSurfaceEnabled, true)
        .onAppear { appeared.fulfill() }
        let host = UIHostingController(rootView: page)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [appeared], timeout: 3)
        host.view.layoutIfNeeded()

        func surfaces(in view: UIView) -> [LibraryArtworkSurfaceView] {
            (view as? LibraryArtworkSurfaceView).map { [$0] } ?? view.subviews.flatMap { surfaces(in: $0) }
        }
        let covers = surfaces(in: host.view)
        XCTAssertEqual(covers.count, 1, "Only the album cover needs a UIKit zoom source")
        let cover = try XCTUnwrap(covers.first)
        XCTAssertEqual(cover.bounds.width, 180, accuracy: 1)
        XCTAssertEqual(cover.bounds.height, 180, accuracy: 1)
    }

    func testTabsKeepUnselectedContentUnloadedAndRetainNavigationWhenReturning() async throws {
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in throw URLError(.badURL) }, clearAvatarCache: {})
        let library = LibraryDetailNavigation()
        let home = LibraryDetailNavigation()
        let content = LibraryAppTabs(selection: .constant(.library), navigation: library,
            library: Text("Library"), destination: { _ in AnyView(Text("Detail")) },
            homeNavigation: home, homeContent: AnyView(Text("Home")))
            .environment(account)
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        func findTabs(_ controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap(findTabs).first
        }
        let tabs = try XCTUnwrap(findTabs(host))
        let original = try XCTUnwrap(library.navigationController)
        // UITab may resolve its provider to inspect controller metadata before selection.
        XCTAssertFalse(home.navigationController?.topViewController?.isViewLoaded ?? false,
                       "Unselected home must not load its initial SwiftUI view tree")
        library.open(.category(.songs), animated: false)
        let detail = try XCTUnwrap(original.topViewController)
        tabs.selectedTab = tabs.tabs.first { $0.identifier == AppTab.home.rawValue }
        tabs.view.layoutIfNeeded()
        XCTAssertNotNil(home.navigationController)
        tabs.selectedTab = tabs.tabs.first { $0.identifier == AppTab.library.rawValue }
        XCTAssertTrue(tabs.selectedViewController === original)
        XCTAssertTrue(original.topViewController === detail)
    }

    func testRemovedTabsStayOutAndStoredOrderReordersTheBar() async throws {
        XCTAssertEqual(AppTabOrder.resolve("radio,search,home,home,missing"),
                       [.home, .library, .favorites, .playlists, .albums, .artists, .songs])
        XCTAssertEqual(AppTabOrder.displayed(order: "library"), [.library, .home, .search])
        XCTAssertEqual(AppTabOrder.displayed(order: "home,library", playlists: ["demo"]), [.home, .library, .search])
        XCTAssertEqual(AppTabOrder.displayed(order: "playlist:demo,home",
                                            hidden: "library,favorites,playlists,albums,artists,songs",
                                            playlists: ["demo"]),
                       [.playlist("demo"), .home, .search])
        XCTAssertFalse(AppTabOrder.resolve("playlist:gone", playlists: ["demo"]).contains(.playlist("gone")))
        XCTAssertEqual(AppTabOrder.displayed(order: "home,favorites,library", hidden: "playlists,albums,artists,songs"),
                       [.home, .favorites, .library, .search])
        XCTAssertEqual(AppTabOrder.visible(order: "home,library,favorites,playlists,albums,artists,songs", hidden: "").count, 4)
        let previous = UserDefaults.standard.string(forKey: AppTabOrder.storageKey)
        let previousHidden = UserDefaults.standard.string(forKey: AppTabOrder.hiddenKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppTabOrder.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppTabOrder.storageKey)
            }
            if let previousHidden {
                UserDefaults.standard.set(previousHidden, forKey: AppTabOrder.hiddenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppTabOrder.hiddenKey)
            }
        }
        UserDefaults.standard.set("home,library", forKey: AppTabOrder.storageKey)
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in throw URLError(.badURL) }, clearAvatarCache: {})
        let content = LibraryAppTabs(selection: .constant(.library), navigation: LibraryDetailNavigation(),
            library: Text("Library"), destination: { _ in AnyView(Text("Detail")) },
            homeContent: AnyView(Text("Home")), searchContent: AnyView(Text("Search")))
            .environment(account)
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        func findTabs(_ controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap(findTabs).first
        }
        let tabs = try XCTUnwrap(findTabs(window.rootViewController!))
        XCTAssertEqual(tabs.tabs.map(\.title), ["主页", "资料库", "搜索"])
        UserDefaults.standard.set("library,home", forKey: AppTabOrder.storageKey)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(tabs.tabs.map(\.title), ["资料库", "主页", "搜索"])
        UserDefaults.standard.set("playlists,albums,artists,songs", forKey: AppTabOrder.hiddenKey)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(tabs.tabs.map(\.title), ["资料库", "主页", "喜爱歌曲", "搜索"])
        XCTAssertEqual(tabs.selectedTab?.identifier, AppTab.library.rawValue)
        window.rootViewController = UIHostingController(rootView: LibraryAppTabs(
            selection: .constant(.library), tabOrder: [.playlist("demo"), .home, .search], storesOrder: false,
            navigation: LibraryDetailNavigation(), library: Text("Library"), destination: { _ in AnyView(Text("Detail")) },
            playlistTabs: [AppTabPlaylist(id: "demo", title: "夜游")]).environment(account))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(100))
        let playlistTabs = try XCTUnwrap(findTabs(window.rootViewController!))
        XCTAssertEqual(playlistTabs.tabs.map(\.title), ["夜游", "主页", "搜索"])
    }
}

@MainActor extension XCTestCase {
    /// Hosted tests can begin before UIKit connects the application's first scene.
    func applicationWindowScene() async throws -> UIWindowScene {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return scene
        }
        let activation = expectation(forNotification: UIScene.didActivateNotification, object: nil)
        await fulfillment(of: [activation], timeout: 10)
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }
}
