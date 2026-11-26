import FrontAMNavigation
import SwiftUI
import UIKit

struct LibraryAppTabs<Library: View>: View {
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
    var sectionNavigation: ((AppTab) -> LibraryDetailNavigation)? = nil
    var playlistTabs: [AppTabPlaylist] = []
    @State private var fallbackNavigations = AppTabNavigationRegistry(initialTabs: [])
    @State private var emptyHome = HomeContentModel()

    var body: some View {
        FrontAMTabs(selection: $selection, colorScheme: colorScheme, orderStore: storesOrder ? AppTabOrder.storage : nil,
                    order: desiredOrder, items: items)
    }

    private func desiredOrder() -> [AppTab] {
        guard storesOrder else { return tabOrder }
        let storage = AppTabOrder.storage
        return AppTabOrder.displayed(order: storage.order ?? AppTabOrder.defaultRaw, hidden: storage.hidden,
                                     playlists: playlistTabs.map(\.id))
    }

    private func items(_ environment: EnvironmentValues) -> [FrontAMTabItem<AppTab>] {
        let homeBridge = homeNavigation ?? fallbackNavigations.navigation(for: .home)
        let homeRoot = homeContent ?? AnyView(HomeFeedView(model: emptyHome))
        navigation.configure(environment: environment, destination: destination)
        homeBridge.configure(environment: environment, destination: homeDestination ?? destination)
        searchNavigation?.configure(environment: environment, destination: searchDestination ?? destination)
        fallbackNavigations.prunePlaylists(keeping: Set(playlistTabs.map(\.id)))

        var tabs = [
            tab(.home, image: UIImage(named: "HomeTabIcon"), navigation: homeBridge) {
                homeBridge.makeNavigationController(root: homeRoot, rootTitle: AppTab.home.title)
            },
            tab(.library, navigation: navigation) {
                navigation.makeNavigationController(root: AnyView(library), initialPath: initialPath)
            },
            FrontAMTabItem(id: .search, identifier: AppTab.search.rawValue, title: AppTab.search.title,
                           isSearch: true, makeController: {
                if let searchNavigation, let searchContent {
                    return searchNavigation.makeNavigationController(root: searchContent, rootTitle: AppTab.search.title)
                }
                return UIHostingController(rootView: EmptyView())
            }),
        ]
        for item in AppTab.reorderable {
            guard let route = item.rootRoute else { continue }
            let bridge = configureSection(item, environment: environment)
            tabs.append(tab(item, navigation: bridge) {
                bridge.makeNavigationController(root: destination(route), rootTitle: item == .favorites ? "" : item.title)
            })
        }
        for item in playlistTabs where !item.id.isEmpty && !item.id.contains(",") {
            let id = AppTab.playlist(item.id)
            let bridge = configureSection(id, environment: environment)
            tabs.append(tab(id, title: item.title, navigation: bridge) {
                bridge.makeNavigationController(root: destination(.playlist(item.id)), rootTitle: "")
            })
        }
        return tabs
    }

    private func configureSection(_ id: AppTab, environment: EnvironmentValues) -> LibraryDetailNavigation {
        let bridge = sectionNavigation?(id) ?? fallbackNavigations.navigation(for: id)
        bridge.configure(environment: environment, destination: destination)
        return bridge
    }

    private func tab(_ id: AppTab, title: String? = nil, image: UIImage? = nil, navigation: LibraryDetailNavigation,
                     makeController: @escaping @MainActor () -> UIViewController) -> FrontAMTabItem<AppTab> {
        FrontAMTabItem(id: id, identifier: id.rawValue, title: title ?? id.title,
                       image: id == .home ? image : UIImage(systemName: id.systemImage), makeController: makeController,
                       updateNavigationAppearance: { style in
            navigation.navigationController?.navigationBar.overrideUserInterfaceStyle =
                navigation.colorScheme.map { UIUserInterfaceStyle($0) } ?? style
        })
    }
}
