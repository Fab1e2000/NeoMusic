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

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIViewController(context: Context) -> UITabBarController {
        navigation.configure(environment: context.environment, destination: destination)
        let libraryController = navigation.makeNavigationController(root: AnyView(library), initialPath: initialPath)
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        controller.tabBarMinimizeBehavior = .onScrollDown
        func tab(_ id: AppTab, _ title: String, _ symbol: String) -> UITab {
            UITab(title: title, image: UIImage(systemName: symbol), identifier: id.rawValue) { _ in
                UIHostingController(rootView: PlaceholderTab(title: LocalizedStringKey(title)))
            }
        }
        let search = UISearchTab { _ in UIHostingController(rootView: PlaceholderTab(title: "搜索")) }
        context.coordinator.searchIdentifier = search.identifier
        controller.tabs = [
            UITab(title: "主页", image: UIImage(named: "HomeTabIcon"), identifier: AppTab.home.rawValue) { _ in
                UIHostingController(rootView: HomeFeedView())
            },
            tab(.discover, "新发现", "square.grid.2x2.fill"),
            tab(.radio, "广播", "dot.radiowaves.left.and.right"),
            UITab(title: "资料库", image: UIImage(systemName: "music.note.square.stack.fill"), identifier: AppTab.library.rawValue) { _ in libraryController },
            search
        ]
        controller.selectedTab = controller.tabs.first { $0.identifier == selection.rawValue }
        // Resolve system appearance from the container when a page has no preference.
        controller.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak navigationBar = libraryController.navigationBar] (controller: UITabBarController, _) in
            Self.applyAppearance(controller.traitCollection.userInterfaceStyle, to: controller.tabBar,
                                 navigationBar: navigationBar)
        }
        updateAppearance(of: controller)
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.selection = $selection
        navigation.configure(environment: context.environment, destination: destination)
        let id = selection == .search ? context.coordinator.searchIdentifier : selection.rawValue
        if controller.selectedTab?.identifier != id {
            controller.selectedTab = controller.tabs.first { $0.identifier == id }
        }
        updateAppearance(of: controller)
    }
    private func updateAppearance(of controller: UITabBarController) {
        let style = colorScheme.map { UIUserInterfaceStyle($0) }
            ?? controller.traitCollection.userInterfaceStyle
        Self.applyAppearance(style, to: controller.tabBar,
                             navigationBar: navigation.navigationController?.navigationBar)
    }
    private static func applyAppearance(_ style: UIUserInterfaceStyle, to tabBar: UITabBar,
                                        navigationBar: UINavigationBar?) {
        // Navigation-item preferences can reach the bar only when zoom finishes.
        // Give the actual bar the same resolved style as the enclosing shell.
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
        init(selection: Binding<AppTab>) { self.selection = selection }
        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            let value = selectedTab.identifier == searchIdentifier ? AppTab.search : AppTab(rawValue: selectedTab.identifier)
            if let value { selection.wrappedValue = value }
        }
    }
}
