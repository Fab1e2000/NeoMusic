import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var nativeArtworkSurfaceEnabled = false
}

/// A real, cover-only UIKit surface for zoom. The existing SwiftUI artwork drawing
/// is retained verbatim, including placeholder symbols, stroke and corner radius.
struct LibraryArtworkSurface<Content: View>: UIViewRepresentable {
    let content: Content
    let cornerRadius: CGFloat
    var isZoomAlignmentTarget = false

    func makeUIView(context: Context) -> LibraryArtworkSurfaceView { LibraryArtworkSurfaceView() }

    func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        view.isZoomAlignmentTarget = isZoomAlignmentTarget
        let configuration = UIHostingConfiguration {
            content.libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, false)
        }.margins(.all, 0)
        if let hosted = view.subviews.first as? any UIContentView {
            hosted.configuration = configuration
        } else {
            let hosted = configuration.makeContentView()
            hosted.backgroundColor = .clear
            hosted.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosted)
            NSLayoutConstraint.activate([
                hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosted.topAnchor.constraint(equalTo: view.topAnchor),
                hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LibraryArtworkSurfaceView, context: Context) -> CGSize? {
        let side = proposal.width ?? proposal.height ?? 100
        return CGSize(width: side, height: proposal.height ?? side)
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
/// appearance values and the image-loading action, never navigation internals.
extension View {
    func libraryHostedAppearance(_ environment: EnvironmentValues) -> some View {
        self.environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.artworkLoadAction, environment.artworkLoadAction)
    }
}

@MainActor final class LibraryArtworkSources {
    private final class Entry { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
    private var entries: [String: Entry] = [:]
    func register(_ view: UIView, for id: String) { entries[id] = Entry(view) }
    func remove(_ view: UIView, for id: String) { if entries[id]?.view === view { entries[id] = nil } }
    func view(for id: String) -> UIView? { entries[id]?.view }
}

struct LibraryCardArtwork: UIViewRepresentable {
    let content: AnyView
    let sources: LibraryArtworkSources
    let sourceID: String
    let cornerRadius: CGFloat
    final class Coordinator {
        var sources: LibraryArtworkSources
        var sourceID: String
        init(_ sources: LibraryArtworkSources, _ sourceID: String) { self.sources = sources; self.sourceID = sourceID }
    }
    func makeCoordinator() -> Coordinator { Coordinator(sources, sourceID) }
    func makeUIView(context: Context) -> LibraryArtworkSurfaceView {
        let view = LibraryArtworkSurfaceView()
        view.isUserInteractionEnabled = false
        sources.register(view, for: sourceID)
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        if context.coordinator.sourceID != sourceID || context.coordinator.sources !== sources {
            context.coordinator.sources.remove(view, for: context.coordinator.sourceID)
            context.coordinator.sources = sources
            context.coordinator.sourceID = sourceID
        }
        sources.register(view, for: sourceID)
        let configuration = UIHostingConfiguration { content.libraryHostedAppearance(context.environment) }.margins(.all, 0)
        if let hosted = view.subviews.first as? any UIContentView {
            hosted.configuration = configuration
        } else {
            let hosted = configuration.makeContentView()
            hosted.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosted)
            NSLayoutConstraint.activate([
                hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosted.topAnchor.constraint(equalTo: view.topAnchor), hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }
    static func dismantleUIView(_ view: LibraryArtworkSurfaceView, coordinator: Coordinator) {
        coordinator.sources.remove(view, for: coordinator.sourceID)
    }
}
