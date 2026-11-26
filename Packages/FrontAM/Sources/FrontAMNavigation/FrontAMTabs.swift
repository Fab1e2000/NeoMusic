import SwiftUI
import UIKit

public struct FrontAMTabItem<Tab: Hashable> {
    public let id: Tab
    public let identifier: String
    public let title: String
    public let image: UIImage?
    public let isSearch: Bool
    let makeController: @MainActor () -> UIViewController
    let updateNavigationAppearance: ((UIUserInterfaceStyle) -> Void)?

    public init(id: Tab, identifier: String, title: String, image: UIImage? = nil, isSearch: Bool = false,
                makeController: @escaping @MainActor () -> UIViewController,
                updateNavigationAppearance: ((UIUserInterfaceStyle) -> Void)? = nil) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.image = image
        self.isSearch = isSearch
        self.makeController = makeController
        self.updateNavigationAppearance = updateNavigationAppearance
    }
}

public struct FrontAMTabs<Tab: Hashable>: UIViewControllerRepresentable {
    @Binding private var selection: Tab
    private let colorScheme: ColorScheme?
    private let orderStore: FrontAMTabStorage?
    private let order: () -> [Tab]
    private let items: (EnvironmentValues) -> [FrontAMTabItem<Tab>]

    public init(selection: Binding<Tab>, colorScheme: ColorScheme? = nil, orderStore: FrontAMTabStorage? = nil,
                order: @escaping () -> [Tab], items: @escaping (EnvironmentValues) -> [FrontAMTabItem<Tab>]) {
        _selection = selection
        self.colorScheme = colorScheme
        self.orderStore = orderStore
        self.order = order
        self.items = items
    }

    public func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, order: order) }

    public func makeUIViewController(context: Context) -> UITabBarController {
        let coordinator = context.coordinator
        coordinator.updateItems(items(context.environment))
        let controller = UITabBarController()
        controller.delegate = coordinator
        controller.tabBarMinimizeBehavior = .onScrollDown
        coordinator.controller = controller
        coordinator.observeOrder(in: orderStore?.defaults)
        UIView.performWithoutAnimation {
            let order = order()
            controller.setTabs(order.compactMap { coordinator.builtTabs[$0] }, animated: false)
            coordinator.appliedOrder = order
            controller.selectedTab = controller.tabs.first { $0 === coordinator.builtTabs[selection] }
        }
        controller.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak coordinator] (controller: UITabBarController, _) in
            coordinator?.updateNavigationAppearance(systemStyle: controller.traitCollection.userInterfaceStyle)
            Self.updatePageInheritance(in: controller)
            let overrides = controller.view.traitOverrides
            let style = overrides.contains(UITraitUserInterfaceStyle.self)
                ? overrides.userInterfaceStyle : controller.traitCollection.userInterfaceStyle
            Self.applySelectedItemAppearance(style, to: controller.tabBar)
        }
        updateAppearance(of: controller, coordinator: coordinator)
        return controller
    }

    public func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.order = order
        coordinator.updateItems(items(context.environment))
        coordinator.observeOrder(in: orderStore?.defaults)
        let desired = order()
        coordinator.apply(desired, to: controller, animated: !coordinator.appliedOrder.isEmpty)
        if let tab = coordinator.builtTabs[selection], controller.tabs.contains(where: { $0 === tab }) {
            if controller.selectedTab !== tab { controller.selectedTab = tab }
        } else if let fallback = coordinator.fallback(in: desired),
                  let tab = controller.tabs.first(where: { $0 === coordinator.builtTabs[fallback] }) {
            controller.selectedTab = tab
            selection = fallback
        }
        updateAppearance(of: controller, coordinator: coordinator)
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
        // Each navigation stack retains page appearance when UIKit animates the chrome.
        for case let nav as UINavigationController in controller.children {
            nav.traitOverrides.userInterfaceStyle = controller.traitCollection.userInterfaceStyle
        }
    }

    @MainActor public final class Coordinator: NSObject, UITabBarControllerDelegate {
        fileprivate var selection: Binding<Tab>
        fileprivate var order: () -> [Tab]
        fileprivate var builtTabs: [Tab: UITab] = [:]
        fileprivate var appliedOrder: [Tab] = []
        fileprivate weak var controller: UITabBarController?
        private var items: [FrontAMTabItem<Tab>] = []
        private var observedDefaults: UserDefaults?

        fileprivate init(selection: Binding<Tab>, order: @escaping () -> [Tab]) {
            self.selection = selection
            self.order = order
        }

        fileprivate func updateItems(_ items: [FrontAMTabItem<Tab>]) {
            self.items = items
            let live = Set(items.map(\.id))
            builtTabs = builtTabs.filter { live.contains($0.key) }
            for item in items {
                if let tab = builtTabs[item.id] {
                    if tab.title != item.title { tab.title = item.title }
                } else if item.isSearch {
                    let tab = UISearchTab { _ in item.makeController() }
                    tab.title = item.title
                    tab.preferredPlacement = .pinned
                    tab.automaticallyActivatesSearch = false
                    builtTabs[item.id] = tab
                } else {
                    let tab = UITab(title: item.title, image: item.image, identifier: item.identifier) { _ in item.makeController() }
                    tab.preferredPlacement = .movable
                    builtTabs[item.id] = tab
                }
            }
        }

        fileprivate func updateNavigationAppearance(systemStyle: UIUserInterfaceStyle) {
            for item in items { item.updateNavigationAppearance?(systemStyle) }
        }

        fileprivate func observeOrder(in defaults: UserDefaults?) {
            guard observedDefaults !== defaults else { return }
            if let observedDefaults {
                NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: observedDefaults)
            }
            observedDefaults = defaults
            if let defaults {
                NotificationCenter.default.addObserver(self, selector: #selector(storedOrderChanged),
                                                        name: UserDefaults.didChangeNotification, object: defaults)
            }
        }

        @objc private func storedOrderChanged() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller else { return }
                apply(order(), to: controller, animated: true)
            }
        }

        fileprivate func fallback(in order: [Tab]) -> Tab? {
            order.first { builtTabs[$0] != nil && !(builtTabs[$0] is UISearchTab) } ?? order.first
        }

        fileprivate func apply(_ order: [Tab], to controller: UITabBarController, animated: Bool) {
            guard appliedOrder != order else { return }
            let next = order.compactMap { builtTabs[$0] }
            guard next.count == order.count else { return }
            let selectedID = controller.selectedTab?.identifier
            controller.setTabs(next, animated: animated)
            appliedOrder = order
            if let selectedID, let kept = next.first(where: { $0.identifier == selectedID }) {
                controller.selectedTab = kept
            } else if let fallback = fallback(in: order) {
                controller.selectedTab = builtTabs[fallback]
                if selection.wrappedValue != fallback { selection.wrappedValue = fallback }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        public func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            if let id = builtTabs.first(where: { $0.value.identifier == selectedTab.identifier })?.key {
                selection.wrappedValue = id
            }
        }
    }
}
