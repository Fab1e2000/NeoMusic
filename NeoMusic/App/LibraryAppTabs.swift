import SwiftUI
import UIKit

/// UIKit owns both levels of chrome. SwiftUI TabView would otherwise apply its
/// outer toolbar preferences to the independently hosted library navigation bar.
struct LibraryAppTabs<Library: View>: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    var tabOrder: [AppTab] = AppTab.defaultOrder
    /// 正式应用读 UserDefaults。测试传入固定顺序时关掉，避免被模拟器里已保存的顺序盖掉。
    var storesOrder = true
    let navigation: LibraryDetailNavigation
    let library: Library
    let destination: (LibraryRoute) -> AnyView
    var initialPath: [LibraryRoute] = []
    var colorScheme: ColorScheme?
    var homeNavigation: LibraryDetailNavigation? = nil
    var homeContent: AnyView? = nil
    var homeDestination: ((LibraryRoute) -> AnyView)? = nil
    var searchNavigation: LibraryDetailNavigation? = nil
    var searchContent: AnyView? = nil
    var searchDestination: ((LibraryRoute) -> AnyView)? = nil
    var sectionNavigation: (AppTab) -> LibraryDetailNavigation = { _ in LibraryDetailNavigation() }
    var playlistTabs: [AppTabPlaylist] = []

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let account = context.environment[NeteaseAccount.self]
        navigation.configure(environment: context.environment, destination: destination)
        let homeBridge = homeNavigation ?? context.coordinator.homeNavigation
        context.coordinator.libraryBridge = navigation
        context.coordinator.homeBridge = homeBridge
        homeBridge.configure(environment: context.environment, destination: homeDestination ?? destination)
        let homeRoot = homeContent ?? AnyView(HomeFeedView(model: context.coordinator.emptyHome))
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        context.coordinator.preferredStyle = colorScheme.map { UIUserInterfaceStyle($0) }
        controller.tabBarMinimizeBehavior = .onScrollDown
        let search = UISearchTab { _ in
            if let searchNavigation, let searchContent {
                searchNavigation.configure(environment: context.environment, destination: searchDestination ?? destination)
                return searchNavigation.makeNavigationController(root: searchContent, rootTitle: "搜索")
            }
            return UIHostingController(rootView: PlaceholderTab(title: "搜索").environment(account))
        }
        search.title = "搜索"
        search.preferredPlacement = .pinned
        search.automaticallyActivatesSearch = false
        context.coordinator.searchIdentifier = search.identifier
        let home = UITab(title: "主页", image: UIImage(named: "HomeTabIcon"), identifier: AppTab.home.rawValue) { _ in
            homeBridge.makeNavigationController(root: homeRoot, rootTitle: "主页", rootColorScheme: .light)
        }
        let libraryTab = UITab(title: "资料库", image: UIImage(systemName: "music.note.square.stack.fill"), identifier: AppTab.library.rawValue) { _ in
            navigation.makeNavigationController(root: AnyView(library), initialPath: initialPath)
        }
        home.preferredPlacement = .movable
        libraryTab.preferredPlacement = .movable
        var built: [AppTab: UITab] = [.home: home, .library: libraryTab, .search: search]
        for tab in AppTab.reorderable where tab.rootRoute != nil {
            let bridge = sectionNavigation(tab)
            context.coordinator.sectionBridges[tab] = bridge
            bridge.configure(environment: context.environment, destination: destination)
            let item = UITab(title: tab.title, image: UIImage(systemName: tab.systemImage), identifier: tab.rawValue) { _ in
                bridge.makeNavigationController(root: destination(tab.rootRoute!), rootTitle: tab == .favorites ? "" : tab.title)
            }
            item.preferredPlacement = .movable
            built[tab] = item
        }
        context.coordinator.builtTabs = built
        context.coordinator.storesOrder = storesOrder
        ensurePlaylistTabs(context.coordinator, environment: context.environment)
        context.coordinator.controller = controller
        let tabs = orderedTabs(context.coordinator)
        context.coordinator.appliedOrder = desiredOrder(context.coordinator)
        context.coordinator.startObservingOrder()
        UIView.performWithoutAnimation {
            controller.setTabs(tabs, animated: false)
            controller.selectedTab = tabs.first { $0.identifier == (selection == .search ? search.identifier : selection.rawValue) }
        }
        // Resolve system appearance from the container when a page has no preference.
        controller.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak coordinator = context.coordinator] (controller: UITabBarController, _) in
            let style = coordinator?.preferredStyle ?? controller.traitCollection.userInterfaceStyle
            coordinator?.updateNavigationAppearance(systemStyle: controller.traitCollection.userInterfaceStyle)
            Self.applyAppearance(style, to: controller.tabBar, navigationBar: nil)
        }
        updateAppearance(of: controller)
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.preferredStyle = colorScheme.map { UIUserInterfaceStyle($0) }
        navigation.configure(environment: context.environment, destination: destination)
        searchNavigation?.configure(environment: context.environment, destination: searchDestination ?? destination)
        (homeNavigation ?? context.coordinator.homeNavigation).configure(environment: context.environment,
                                                                        destination: homeDestination ?? destination)
        ensurePlaylistTabs(context.coordinator, environment: context.environment)
        for bridge in context.coordinator.sectionBridges.values {
            bridge.configure(environment: context.environment, destination: destination)
        }
        let id = selection == .search ? context.coordinator.searchIdentifier : selection.rawValue
        applyOrder(to: controller, coordinator: context.coordinator)
        if let match = controller.tabs.first(where: { $0.identifier == id }) {
            if controller.selectedTab !== match { controller.selectedTab = match }
        } else if let fallback = desiredOrder(context.coordinator).first(where: { $0 != .search }) ?? desiredOrder(context.coordinator).first,
                  let tab = controller.tabs.first(where: { $0.identifier == (fallback == .search ? context.coordinator.searchIdentifier : fallback.rawValue) }) {
            controller.selectedTab = tab
            context.coordinator.selection.wrappedValue = fallback
        }
        updateAppearance(of: controller)
        for bridge in context.coordinator.sectionBridges.values {
            let style = bridge.colorScheme.map { UIUserInterfaceStyle($0) } ?? controller.traitCollection.userInterfaceStyle
            bridge.navigationController?.navigationBar.overrideUserInterfaceStyle = style
        }
    }
    private func desiredOrder(_ coordinator: Coordinator) -> [AppTab] {
        guard storesOrder else { return tabOrder }
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: AppTabOrder.storageKey) ?? AppTabOrder.defaultRaw
        return AppTabOrder.displayed(order: raw, hidden: defaults.string(forKey: AppTabOrder.hiddenKey),
                                     playlists: coordinator.playlistIDs)
    }
    private func ensurePlaylistTabs(_ coordinator: Coordinator, environment: EnvironmentValues) {
        coordinator.playlistIDs = playlistTabs.map(\.id)
        var live = Set<AppTab>()
        for item in playlistTabs where !item.id.isEmpty && !item.id.contains(",") {
            let tab = AppTab.playlist(item.id)
            live.insert(tab)
            if let existing = coordinator.builtTabs[tab] {
                if existing.title != item.title { existing.title = item.title }
                continue
            }
            let bridge = sectionNavigation(tab)
            coordinator.sectionBridges[tab] = bridge
            bridge.configure(environment: environment, destination: destination)
            let playlistID = item.id
            let root = destination
            let itemTab = UITab(title: item.title, image: UIImage(systemName: "music.note.list"), identifier: tab.rawValue) { _ in
                bridge.makeNavigationController(root: root(.playlist(playlistID)), rootTitle: "")
            }
            itemTab.preferredPlacement = .movable
            coordinator.builtTabs[tab] = itemTab
        }
        for key in coordinator.builtTabs.keys {
            if case .playlist = key, !live.contains(key) {
                coordinator.builtTabs.removeValue(forKey: key)
                coordinator.sectionBridges.removeValue(forKey: key)
            }
        }
    }
    private func orderedTabs(_ coordinator: Coordinator) -> [UITab] {
        desiredOrder(coordinator).compactMap { coordinator.builtTabs[$0] }
    }
    private func applyOrder(to controller: UITabBarController, coordinator: Coordinator) {
        coordinator.apply(desiredOrder(coordinator), to: controller, animated: coordinator.appliedOrder.isEmpty == false)
    }
    private func updateAppearance(of controller: UITabBarController) {
        let style = colorScheme.map { UIUserInterfaceStyle($0) }
            ?? controller.traitCollection.userInterfaceStyle
        let libraryStyle = navigation.colorScheme.map { UIUserInterfaceStyle($0) } ?? controller.traitCollection.userInterfaceStyle
        navigation.navigationController?.navigationBar.overrideUserInterfaceStyle = libraryStyle
        if let homeNavigation {
            homeNavigation.navigationController?.navigationBar.overrideUserInterfaceStyle = homeNavigation.colorScheme.map { UIUserInterfaceStyle($0) } ?? .light
        }
        Self.applyAppearance(style, to: controller.tabBar, navigationBar: nil)
    }
    private static func applyAppearance(_ style: UIUserInterfaceStyle, to tabBar: UITabBar,
                                        navigationBar: UINavigationBar?) {
        // Navigation-item preferences can reach the bar only when zoom finishes.
        // Resolve the bars independently so the source page keeps its own appearance.
        navigationBar?.overrideUserInterfaceStyle = style
        // Keep the bar view and UIKit-owned glass/items on the same resolved style.
        // A UIView override alone leaves the visible tab content unchanged until zoom ends.
        // Use a resolved style: clearing to .unspecified can retain the previous appearance.
        tabBar.overrideUserInterfaceStyle = style
        if tabBar.standardAppearance.overrideUserInterfaceStyle != style {
            let appearance = tabBar.standardAppearance.copy()
            appearance.overrideUserInterfaceStyle = style
            tabBar.standardAppearance = appearance
        }
        // At the scroll edge, UIKit's implicit appearance can retain the old style
        // for minimized controls. Preserve its configuration and resolve it explicitly.
        if tabBar.scrollEdgeAppearance?.overrideUserInterfaceStyle != style {
            let appearance = (tabBar.scrollEdgeAppearance ?? tabBar.standardAppearance).copy()
            appearance.overrideUserInterfaceStyle = style
            tabBar.scrollEdgeAppearance = appearance
        }
    }
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selection: Binding<AppTab>
        var searchIdentifier = ""
        var builtTabs: [AppTab: UITab] = [:]
        var appliedOrder: [AppTab] = []
        var storesOrder = true
        weak var controller: UITabBarController?
        private var observingOrder = false
        var preferredStyle: UIUserInterfaceStyle?
        weak var libraryBridge: LibraryDetailNavigation?
        weak var homeBridge: LibraryDetailNavigation?
        var sectionBridges: [AppTab: LibraryDetailNavigation] = [:]
        var playlistIDs: [String] = []
        func updateNavigationAppearance(systemStyle: UIUserInterfaceStyle) {
            libraryBridge?.navigationController?.navigationBar.overrideUserInterfaceStyle = libraryBridge?.colorScheme.map { UIUserInterfaceStyle($0) } ?? systemStyle
            homeBridge?.navigationController?.navigationBar.overrideUserInterfaceStyle = homeBridge?.colorScheme.map { UIUserInterfaceStyle($0) } ?? .light
            for bridge in sectionBridges.values {
                bridge.navigationController?.navigationBar.overrideUserInterfaceStyle = bridge.colorScheme.map { UIUserInterfaceStyle($0) } ?? systemStyle
            }
        }
        let homeNavigation = LibraryDetailNavigation()
        let emptyHome = HomeContentModel()
        init(selection: Binding<AppTab>) { self.selection = selection }
        func startObservingOrder() {
            guard storesOrder, !observingOrder else { return }
            observingOrder = true
            NotificationCenter.default.addObserver(self, selector: #selector(storedOrderChanged),
                                                    name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }
        @objc private func storedOrderChanged() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller else { return }
                let defaults = UserDefaults.standard
                let raw = defaults.string(forKey: AppTabOrder.storageKey) ?? AppTabOrder.defaultRaw
                self.apply(AppTabOrder.displayed(order: raw, hidden: defaults.string(forKey: AppTabOrder.hiddenKey), playlists: self.playlistIDs), to: controller, animated: true)
            }
        }
        func apply(_ order: [AppTab], to controller: UITabBarController, animated: Bool) {
            guard appliedOrder != order else { return }
            let next = order.compactMap { builtTabs[$0] }
            guard next.count == order.count else { return }
            let selectedID = controller.selectedTab?.identifier
            controller.setTabs(next, animated: animated)
            appliedOrder = order
            if let selectedID, let kept = next.first(where: { $0.identifier == selectedID }) {
                controller.selectedTab = kept
            } else if let fallback = order.first(where: { $0 != .search }) ?? order.first {
                let identifier = fallback == .search ? searchIdentifier : fallback.rawValue
                controller.selectedTab = next.first { $0.identifier == identifier }
                if selection.wrappedValue != fallback { selection.wrappedValue = fallback }
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            let value = selectedTab.identifier == searchIdentifier ? AppTab.search : AppTab(rawValue: selectedTab.identifier)
            if let value { selection.wrappedValue = value }
        }
    }
}
