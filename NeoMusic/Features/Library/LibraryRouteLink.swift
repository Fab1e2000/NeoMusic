import SwiftUI
import UIKit

/// Value links need a SwiftUI NavigationStack. Destination links use the existing
/// UIKit navigation controller and retain the system row, selection and accessibility.
struct LibraryRouteLink<Label: View>: View {
    let value: LibraryRoute
    @ViewBuilder var label: Label
    @Environment(\.libraryRouteDestination) private var destination
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.songRowPlayback) private var playback
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.nativeArtworkSurfaceEnabled) private var nativeArtwork
    var body: some View {
        if let makePage = destination.makePage {
            NavigationLink {
                LibraryLinkedPage(content: makePage(value), route: value)
                    .environment(\.openLibraryRoute, openRoute)
                    .environment(\.libraryRouteDestination, destination)
                    .environment(\.collectionMenuActions, collectionActions)
                    .environment(\.songMenuActions, songActions)
                    .environment(\.songRowPlayback, playback)
                    .environment(\.libraryDownloads, downloads)
                    .environment(\.nativeArtworkSurfaceEnabled, nativeArtwork)
            } label: { label }
        } else { NavigationLink(value: value) { label } }
    }
}

struct LibraryRouteDestination {
    var makePage: ((LibraryRoute) -> AnyView)?
}
extension EnvironmentValues {
    @Entry var libraryRouteDestination = LibraryRouteDestination()
}

private struct LibraryLinkedPage: View {
    let content: AnyView
    let route: LibraryRoute
    @State private var chrome: LibraryNavigationChrome

    init(content: AnyView, route: LibraryRoute) {
        self.content = content
        self.route = route
        _chrome = State(initialValue: LibraryNavigationChrome(isRoot: false, route: route))
    }

    var body: some View {
        if let initial = route.initialCategoryTitle {
            // NavigationLink reads these preferences while preparing its destination.
            // Do not wait for the attachment controller's first layout to publish them.
            page.navigationTitle(initial.title)
                .navigationBarTitleDisplayMode(initial.mode)
        } else {
            page
        }
    }

    private var page: some View {
        content
            .environment(\.libraryNavigationChrome, chrome)
            .environment(\.closeLibraryDetail, CloseLibraryDetailAction {
                guard let controller = chrome.controller, let nav = controller.navigationController,
                      nav.topViewController === controller else { return }
                nav.popViewController(animated: true)
            })
            .background { LibraryLinkedPageAttachment(chrome: chrome).frame(width: 0, height: 0) }
    }
}

private struct LibraryLinkedPageAttachment: UIViewControllerRepresentable {
    let chrome: LibraryNavigationChrome
    func makeUIViewController(context: Context) -> Controller { Controller(chrome: chrome) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.attach() }
    final class Controller: UIViewController {
        let chrome: LibraryNavigationChrome
        private weak var registeredScroll: UIScrollView?
        init(chrome: LibraryNavigationChrome) { self.chrome = chrome; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        func attach() {
            guard let nav = navigationController else { return }
            var candidate = parent
            while let controller = candidate {
                if nav.viewControllers.contains(where: { $0 === controller }) {
                    chrome.attach(controller)
                    if let scroll = firstScroll(in: controller.view), registeredScroll !== scroll {
                        registeredScroll = scroll
                        controller.setContentScrollView(scroll, for: .top)
                    }
                    return
                }
                candidate = controller.parent
            }
        }
        private func firstScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews { if let scroll = firstScroll(in: child) { return scroll } }
            return nil
        }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); attach() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); chrome.isActive = true; attach() }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); chrome.isActive = false }
    }
}
