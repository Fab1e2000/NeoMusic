import SwiftUI
import UIKit

/// UIKit owns both levels of chrome. SwiftUI TabView would otherwise apply its
/// outer toolbar preferences to the independently hosted library navigation bar.
struct LibraryAppTabs<Library: View>: UIViewControllerRepresentable {
    @Binding var selection: AppTab
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
        func tab(_ id: AppTab, _ title: String, _ symbol: String) -> UITab {
            UITab(title: title, image: UIImage(systemName: symbol), identifier: id.rawValue) { _ in
                UIHostingController(rootView: PlaceholderTab(title: LocalizedStringKey(title)).environment(account))
            }
        }
        let search = UISearchTab { _ in
            if let searchNavigation, let searchContent {
                searchNavigation.configure(environment: context.environment, destination: searchDestination ?? destination)
                return searchNavigation.makeNavigationController(root: searchContent, rootTitle: "搜索")
            }
            return UIHostingController(rootView: PlaceholderTab(title: "搜索").environment(account))
        }
        search.automaticallyActivatesSearch = false
        context.coordinator.searchIdentifier = search.identifier
        let tabs: [UITab] = [
            UITab(title: "主页", image: UIImage(named: "HomeTabIcon"), identifier: AppTab.home.rawValue) { _ in
                homeBridge.makeNavigationController(root: homeRoot, rootTitle: "主页", rootColorScheme: .light)
            },
            tab(.discover, "新发现", "square.grid.2x2.fill"),
            tab(.radio, "广播", "dot.radiowaves.left.and.right"),
            UITab(title: "资料库", image: UIImage(systemName: "music.note.square.stack.fill"), identifier: AppTab.library.rawValue) { _ in
                navigation.makeNavigationController(root: AnyView(library), initialPath: initialPath)
            },
            search
        ]
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
        let id = selection == .search ? context.coordinator.searchIdentifier : selection.rawValue
        if controller.selectedTab?.identifier != id {
            controller.selectedTab = controller.tabs.first { $0.identifier == id }
        }
        updateAppearance(of: controller)
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
        var preferredStyle: UIUserInterfaceStyle?
        weak var libraryBridge: LibraryDetailNavigation?
        weak var homeBridge: LibraryDetailNavigation?
        func updateNavigationAppearance(systemStyle: UIUserInterfaceStyle) {
            libraryBridge?.navigationController?.navigationBar.overrideUserInterfaceStyle = libraryBridge?.colorScheme.map { UIUserInterfaceStyle($0) } ?? systemStyle
            homeBridge?.navigationController?.navigationBar.overrideUserInterfaceStyle = homeBridge?.colorScheme.map { UIUserInterfaceStyle($0) } ?? .light
        }
        let homeNavigation = LibraryDetailNavigation()
        let emptyHome = HomeContentModel()
        init(selection: Binding<AppTab>) { self.selection = selection }
        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            let value = selectedTab.identifier == searchIdentifier ? AppTab.search : AppTab(rawValue: selectedTab.identifier)
            if let value { selection.wrappedValue = value }
        }
    }
}
