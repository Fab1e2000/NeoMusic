import SwiftUI

@MainActor public final class FrontAMTabNavigations<Tab: Hashable, Route: Hashable, Preview> {
    public private(set) var navigations: [Tab: FrontAMNavigationStack<Route, Preview>] = [:]
    private let makeNavigation: () -> FrontAMNavigationStack<Route, Preview>

    public init(initialTabs: [Tab] = [], makeNavigation: @escaping () -> FrontAMNavigationStack<Route, Preview>) {
        self.makeNavigation = makeNavigation
        for tab in initialTabs { _ = navigation(for: tab) }
    }

    public func navigation(for tab: Tab) -> FrontAMNavigationStack<Route, Preview> {
        if let navigation = navigations[tab] { return navigation }
        let navigation = makeNavigation()
        navigations[tab] = navigation
        return navigation
    }

    public func colorScheme(for tab: Tab) -> ColorScheme? {
        navigations[tab]?.displayedChrome?.colorScheme
    }

    public func removeTabs(where shouldRemove: (Tab) -> Bool) {
        for tab in navigations.keys where shouldRemove(tab) { navigations[tab] = nil }
    }
}

public struct FrontAMPlayerNavigationHandoff<Route: Equatable> {
    private var closingRoute: Route?

    public init() {}

    public mutating func begin(_ route: Route) -> Bool {
        guard closingRoute != route else { return false }
        closingRoute = route
        return true
    }

    public mutating func didFinishClosing() { closingRoute = nil }
    public mutating func didBeginPresentation() { didFinishClosing() }
}

public struct FrontAMShell<Route: Hashable, Preview, Content: View>: View {
    @Binding private var isPlayerPresented: Bool
    @State private var handoff = FrontAMPlayerNavigationHandoff<Route>()
    private let currentRoute: () -> Route?
    private let openInCurrentTab: (Route, Preview?) -> Void
    private let content: (@escaping (Route, Preview?) -> Void, @escaping () -> Void) -> Content

    public init(isPlayerPresented: Binding<Bool>, currentRoute: @escaping () -> Route?,
                openInCurrentTab: @escaping (Route, Preview?) -> Void,
                @ViewBuilder content: @escaping (_ openFromPlayer: @escaping (Route, Preview?) -> Void,
                                                _ popupClosed: @escaping () -> Void) -> Content) {
        _isPlayerPresented = isPlayerPresented
        self.currentRoute = currentRoute
        self.openInCurrentTab = openInCurrentTab
        self.content = content
    }

    public var body: some View {
        content(openFromPlayer, popupClosed)
            .onChange(of: isPlayerPresented) { _, presented in
                if presented { handoff.didBeginPresentation() }
            }
    }

    private func openFromPlayer(_ route: Route, _ preview: Preview?) {
        guard handoff.begin(route) else { return }
        if currentRoute() != route { openInCurrentTab(route, preview) }
        isPlayerPresented = false
    }

    private func popupClosed() {
        handoff.didFinishClosing()
        isPlayerPresented = false
    }
}
