import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var nativeArtworkSurfaceEnabled = false
}

/// A real, cover-only UIKit surface for zoom. The existing SwiftUI artwork drawing
/// is retained verbatim, including placeholder symbols, stroke and corner radius.
struct LibraryArtworkSurface<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let cornerRadius: CGFloat
    var isZoomAlignmentTarget = false
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.loadViewIfNeeded()
        controller.view.layer.cornerRadius = cornerRadius
        controller.view.clipsToBounds = true
        (controller.view as? LibraryArtworkSurfaceView)?.isZoomAlignmentTarget = isZoomAlignmentTarget
        controller.host.rootView = AnyView(content.libraryHostedAppearance(context.environment)
            .environment(\.nativeArtworkSurfaceEnabled, false))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        let side = proposal.width ?? proposal.height ?? 100
        return CGSize(width: side, height: proposal.height ?? side)
    }
    final class Controller: UIViewController {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        override func loadView() {
            view = LibraryArtworkSurfaceView()
            host.safeAreaRegions = []
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
        }
    }
}
final class LibraryArtworkSurfaceView: UIView {
    var isZoomAlignmentTarget = false
}

extension UIView {
    /// Resolve the marked detail cover each time, including after scrolling. A missing
    /// or fully clipped cover leaves alignment to UIKit instead of choosing a track image.
    func libraryArtworkAlignmentRect() -> CGRect? {
        func target(in view: UIView) -> LibraryArtworkSurfaceView? {
            if let cover = view as? LibraryArtworkSurfaceView, cover.isZoomAlignmentTarget { return cover }
            for child in view.subviews { if let cover = target(in: child) { return cover } }
            return nil
        }
        guard let cover = target(in: self), !cover.bounds.isEmpty else { return nil }
        let rect = cover.convert(cover.bounds, to: self)
        var visible = rect.intersection(bounds)
        var ancestor: UIView? = cover
        while let view = ancestor, view !== self {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: self)) }
            ancestor = view.superview
        }
        return visible.isEmpty || visible.isNull ? nil : rect
    }
    func libraryArtworkSource() -> UIView? {
        if self is LibraryArtworkSurfaceView { return self }
        return subviews.compactMap { $0.libraryArtworkSource() }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}

/// Independent hosting roots inherit traits from UIKit. Copy only explicit public
/// appearance values, never SwiftUI's parent navigation/interaction internals.
extension View {
    func libraryHostedAppearance(_ environment: EnvironmentValues) -> some View {
        self.environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
    }
}
