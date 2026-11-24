import SwiftUI
import UIKit

struct LibraryAppTabs<Library: View>: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    var tabOrder: [AppTab] = AppTab.defaultOrder
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
        navigation.configure(environment: context.environment, destination: destination)
        let homeBridge = homeNavigation ?? context.coordinator.homeNavigation
        context.coordinator.libraryBridge = navigation
        context.coordinator.homeBridge = homeBridge
        homeBridge.configure(environment: context.environment, destination: homeDestination ?? destination)
        let homeRoot = homeContent ?? AnyView(HomeFeedView(model: context.coordinator.emptyHome))
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        controller.tabBarMinimizeBehavior = .onScrollDown
        let search = UISearchTab { _ in
            if let searchNavigation, let searchContent {
                searchNavigation.configure(environment: context.environment, destination: searchDestination ?? destination)
                return searchNavigation.makeNavigationController(root: searchContent, rootTitle: "搜索")
            }
            return UIHostingController(rootView: EmptyView())
        }
        search.title = "搜索"
        search.preferredPlacement = .pinned
        search.automaticallyActivatesSearch = false
        context.coordinator.searchIdentifier = search.identifier
        let home = UITab(title: "主页", image: UIImage(named: "HomeTabIcon"), identifier: AppTab.home.rawValue) { _ in
            homeBridge.makeNavigationController(root: homeRoot, rootTitle: "主页")
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
        controller.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak coordinator = context.coordinator] (controller: UITabBarController, _) in
            coordinator?.updateNavigationAppearance(systemStyle: controller.traitCollection.userInterfaceStyle)
            Self.updatePageInheritance(in: controller)
            let overrides = controller.view.traitOverrides
            let style = overrides.contains(UITraitUserInterfaceStyle.self)
                ? overrides.userInterfaceStyle : controller.traitCollection.userInterfaceStyle
            Self.applySelectedItemAppearance(style, to: controller.tabBar)
        }
        updateAppearance(of: controller, coordinator: context.coordinator)
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.selection = $selection
        let homeBridge = homeNavigation ?? context.coordinator.homeNavigation
        context.coordinator.libraryBridge = navigation
        context.coordinator.homeBridge = homeBridge
        navigation.configure(environment: context.environment, destination: destination)
        searchNavigation?.configure(environment: context.environment, destination: searchDestination ?? destination)
        homeBridge.configure(environment: context.environment, destination: homeDestination ?? destination)
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
        updateAppearance(of: controller, coordinator: context.coordinator)
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
    private func updateAppearance(of controller: UITabBarController, coordinator: Coordinator) {
        coordinator.updateNavigationAppearance(systemStyle: controller.traitCollection.userInterfaceStyle)
        Self.updatePageInheritance(in: controller)
        let style = colorScheme.map { UIUserInterfaceStyle($0) } ?? controller.traitCollection.userInterfaceStyle
        Self.applySelectedItemAppearance(style, to: controller.tabBar)
        if let colorScheme {
            controller.view.traitOverrides.userInterfaceStyle = UIUserInterfaceStyle(colorScheme)
        } else {
            controller.view.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        }
    }

    private static func applySelectedItemAppearance(_ style: UIUserInterfaceStyle, to bar: UITabBar) {
        // UIKit consults the selected item's edge appearance while zooming over scrolling content.
        if bar.overrideUserInterfaceStyle != style { bar.overrideUserInterfaceStyle = style }
        guard let item = bar.selectedItem else { return }
        let standard = item.standardAppearance ?? bar.standardAppearance
        if item.standardAppearance?.overrideUserInterfaceStyle != style {
            let appearance = standard.copy()
            appearance.overrideUserInterfaceStyle = style
            item.standardAppearance = appearance
        }
        if item.scrollEdgeAppearance?.overrideUserInterfaceStyle != style {
            let appearance = (item.scrollEdgeAppearance ?? bar.scrollEdgeAppearance ?? standard).copy()
            appearance.overrideUserInterfaceStyle = style
            item.scrollEdgeAppearance = appearance
        }
    }

    private static func updatePageInheritance(in controller: UITabBarController) {
        // Keep the pages behind the zoom in their own appearance while the two bars inherit the shell's.
        for case let nav as UINavigationController in controller.children {
            nav.traitOverrides.userInterfaceStyle = controller.traitCollection.userInterfaceStyle
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
        weak var libraryBridge: LibraryDetailNavigation?
        weak var homeBridge: LibraryDetailNavigation?
        var sectionBridges: [AppTab: LibraryDetailNavigation] = [:]
        var playlistIDs: [String] = []
        func updateNavigationAppearance(systemStyle: UIUserInterfaceStyle) {
            let bridges = [libraryBridge, homeBridge].compactMap { $0 } + Array(sectionBridges.values)
            for bridge in bridges {
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
