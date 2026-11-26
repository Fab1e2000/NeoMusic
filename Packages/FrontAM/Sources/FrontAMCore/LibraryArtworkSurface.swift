import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry public var nativeArtworkSurfaceEnabled = false
}

public struct LibraryArtworkSurface<Content: View>: UIViewRepresentable {
    public let content: Content
    public let cornerRadius: CGFloat
    public var isZoomAlignmentTarget = false
    public var isUserInteractionEnabled = true
    public var hostedBackgroundColor: UIColor? = .clear

    public func makeUIView(context: Context) -> LibraryArtworkSurfaceView { LibraryArtworkSurfaceView() }

    public func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        view.isZoomAlignmentTarget = isZoomAlignmentTarget
        view.isUserInteractionEnabled = isUserInteractionEnabled
        let configuration = UIHostingConfiguration {
            content.libraryHostedAppearance(context.environment)
                .environment(\.nativeArtworkSurfaceEnabled, false)
        }.margins(.all, 0)
        if let hosted = view.subviews.first as? any UIContentView {
            hosted.configuration = configuration
        } else {
            let hosted = configuration.makeContentView()
            if let hostedBackgroundColor { hosted.backgroundColor = hostedBackgroundColor }
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

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: LibraryArtworkSurfaceView, context: Context) -> CGSize? {
        let side = proposal.width ?? proposal.height ?? 100
        return CGSize(width: side, height: proposal.height ?? side)
    }

    public init(content: Content,
                cornerRadius: CGFloat, isZoomAlignmentTarget: Bool = false,
                isUserInteractionEnabled: Bool = true, hostedBackgroundColor: UIColor? = .clear) {
        self.content = content
        self.cornerRadius = cornerRadius
        self.isZoomAlignmentTarget = isZoomAlignmentTarget
        self.isUserInteractionEnabled = isUserInteractionEnabled
        self.hostedBackgroundColor = hostedBackgroundColor
    }
}
public final class LibraryArtworkSurfaceView: UIView {
    public var isZoomAlignmentTarget = false
}

extension UIView {
    public func libraryArtworkAlignmentRect() -> CGRect? {
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
    public func libraryArtworkSource() -> UIView? {
        if self is LibraryArtworkSurfaceView { return self }
        return subviews.compactMap { $0.libraryArtworkSource() }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}

extension View {
    public func libraryHostedAppearance(_ environment: EnvironmentValues) -> some View {
        self.environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.artworkLoadAction, environment.artworkLoadAction)
            .environment(\.frontAMViewEvent, environment.frontAMViewEvent)
    }
}

@MainActor public final class LibraryArtworkSources {
    public init() {}
    private final class Entry { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
    private var entries: [String: Entry] = [:]
    public func register(_ view: UIView, for id: String) { entries[id] = Entry(view) }
    public func remove(_ view: UIView, for id: String) { if entries[id]?.view === view { entries[id] = nil } }
    public func view(for id: String) -> UIView? { entries[id]?.view }
}

public struct LibraryCardArtwork: UIViewRepresentable {
    public let content: AnyView
    public let sources: LibraryArtworkSources
    public let sourceID: String
    public let cornerRadius: CGFloat
    public final class Coordinator {
        public var sources: LibraryArtworkSources
        public var sourceID: String
        public init(_ sources: LibraryArtworkSources, _ sourceID: String) { self.sources = sources; self.sourceID = sourceID }
    }
    public func makeCoordinator() -> Coordinator { Coordinator(sources, sourceID) }
    public func makeUIView(context: Context) -> LibraryArtworkSurfaceView {
        let view = LibraryArtworkSurfaceView()
        view.isUserInteractionEnabled = false
        sources.register(view, for: sourceID)
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }
    public func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
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
    public static func dismantleUIView(_ view: LibraryArtworkSurfaceView, coordinator: Coordinator) {
        coordinator.sources.remove(view, for: coordinator.sourceID)
    }

    public init(content: AnyView,
                sources: LibraryArtworkSources,
                sourceID: String,
                cornerRadius: CGFloat) {
        self.content = content
        self.sources = sources
        self.sourceID = sourceID
        self.cornerRadius = cornerRadius
    }
}
