import SwiftUI
import Observation

public enum Artwork: Equatable {
    public static let favoritesRed = DesignTokens.Colors.favoritesRed
    public static let favoritesBackground = DesignTokens.Colors.favoritesBackground

    case image(Image)
    case file(URL)
    case deferred(id: String, placeholder: ArtworkPlaceholder)
    case favorites
    case playlist
    indirect case folder([Artwork])
    case missing

    public var loadID: String? { if case .deferred(let id, _) = self { id } else { nil } }

    @MainActor public var resolvedFileURL: URL? { resolvedFileURL(using: FrontAMLocalArtworkProvider.shared) }

    @MainActor public func resolvedFileURL(using provider: any FrontAMArtworkProvider) -> URL? {
        switch self {
        case .file(let url): url
        case .deferred(let id, _): provider.resolvedURL(for: id)
        default: nil
        }
    }
}

public enum ArtworkPlaceholder: Equatable { case missing, playlist }

public struct ArtworkLoadAction {
    public var handler: (@MainActor (String) -> Void)?
    public var resolve: (@MainActor (String) async -> URL?)? = nil
    public var queueHandler: (@MainActor (String, Bool) -> Task<Void, Never>?)? = nil
    public var artistPortraits: LibraryArtistPortraitAccess? = nil
    public var artworkProvider: (any FrontAMArtworkProvider)? = nil
    @MainActor public var provider: any FrontAMArtworkProvider { artworkProvider ?? FrontAMLocalArtworkProvider.shared }
    @MainActor public func callAsFunction(_ id: String?) {
        guard let id else { return }
        handler?(id)
    }

    @MainActor public func resolveDeferred(_ id: String?, reuseRegisteredURL: Bool = true,
                                    publish: (URL?) -> Void) async {
        guard !Task.isCancelled else { return }
        let registered = reuseRegisteredURL ? id.flatMap(provider.resolvedURL(for:)) : nil
        publish(registered)
        guard let id else { return }
        callAsFunction(id)
        guard registered == nil, let file = await resolve?(id), !Task.isCancelled else { return }
        provider.registerResolvedArtwork(id, url: file)
        publish(file)
    }

    public init(handler: (@MainActor (String) -> Void)? = nil,
                resolve: (@MainActor (String) async -> URL?)? = nil,
                queueHandler: (@MainActor (String, Bool) -> Task<Void, Never>?)? = nil,
                artistPortraits: LibraryArtistPortraitAccess? = nil,
                artworkProvider: (any FrontAMArtworkProvider)? = nil) {
        self.handler = handler
        self.resolve = resolve
        self.queueHandler = queueHandler
        self.artistPortraits = artistPortraits
        self.artworkProvider = artworkProvider
    }
}

extension EnvironmentValues {
    @Entry public var artworkLoadAction = ArtworkLoadAction()
}

public struct ArtworkView: View {
    public let artwork: Artwork
    public var contentID: String?
    public var previewArtwork: Artwork? = nil
    public var cornerRadius: CGFloat = DesignTokens.Radius.card
    public var hidesLoadingPlaceholder = false
    public var showsBorder = true
    public var isZoomAlignmentTarget = false
    public var loadImage: (@MainActor (URL, Int) async -> UIImage?)? = nil
    @Environment(\.artworkLoadAction) private var loadArtwork
    @Environment(\.displayScale) private var displayScale
    @Environment(\.nativeArtworkSurfaceEnabled) private var nativeSurface

    public var body: some View {
        if nativeSurface {
            LibraryArtworkSurface(content: drawing, cornerRadius: cornerRadius,
                                  isZoomAlignmentTarget: isZoomAlignmentTarget)
                .aspectRatio(1, contentMode: .fit)
        }
        else { drawing }
    }

    private var drawing: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.black.opacity(DesignTokens.Artwork.hairlineStrokeOpacity), lineWidth: 1 / displayScale)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch artwork {
        case .image(let image):
            image.resizable().scaledToFill()
        case .file, .deferred:
            LoadedArtworkView(artwork: artwork, previewArtwork: previewArtwork, retainsImageAcrossSources: contentID != nil, hidesLoadingPlaceholder: hidesLoadingPlaceholder, provider: loadArtwork.provider,
                                  loadImage: loadImage ?? loadArtwork.provider.load(_:pixels:))
                .id(contentID)
        case .favorites:
            GeometryReader { proxy in
                DesignTokens.Colors.favoritesBackground
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: proxy.size.width * 0.50))
                            .foregroundStyle(DesignTokens.Colors.favoritesRed)
                    }
            }
        case .playlist:
            placeholder(systemImage: "music.note.list", symbolScale: 0.38)
        case .folder(let artworks) where artworks.isEmpty:
            placeholder(systemImage: "folder", symbolScale: 0.44)
        case .folder(let artworks):
            GeometryReader { proxy in
                Color(.tertiarySystemFill)
                    .overlay(alignment: .topLeading) {
                        Grid(horizontalSpacing: proxy.size.width * 0.06, verticalSpacing: proxy.size.width * 0.06) {
                            GridRow {
                                folderThumbnail(artworks, at: 0, width: proxy.size.width)
                                folderThumbnail(artworks, at: 1, width: proxy.size.width)
                            }
                            GridRow {
                                folderThumbnail(artworks, at: 2, width: proxy.size.width)
                                folderThumbnail(artworks, at: 3, width: proxy.size.width)
                            }
                        }
                        .padding(proxy.size.width * 0.10)
                    }
            }
        case .missing:
            placeholder(systemImage: "music.note")
        }
    }

    private func placeholder(systemImage: String, symbolScale: CGFloat = 0.3) -> some View {
        GeometryReader { proxy in
            Color(.secondarySystemFill)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: proxy.size.width * symbolScale))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func folderThumbnail(_ artworks: [Artwork], at index: Int, width: CGFloat) -> some View {
        Group {
            if artworks.indices.contains(index) {
                ArtworkView(artwork: artworks[index], cornerRadius: width * 0.025)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: width * 0.36)
    }

    public init(artwork: Artwork,
                contentID: String? = nil,
                previewArtwork: Artwork? = nil,
                cornerRadius: CGFloat = DesignTokens.Radius.card,
                hidesLoadingPlaceholder: Bool = false, showsBorder: Bool = true,
                isZoomAlignmentTarget: Bool = false,
                loadImage: (@MainActor (URL, Int) async -> UIImage?)? = nil) {
        self.artwork = artwork
        self.contentID = contentID
        self.previewArtwork = previewArtwork
        self.cornerRadius = cornerRadius
        self.hidesLoadingPlaceholder = hidesLoadingPlaceholder
        self.showsBorder = showsBorder
        self.isZoomAlignmentTarget = isZoomAlignmentTarget
        self.loadImage = loadImage
    }
}

private struct ArtworkPlaceholderView: View {
    let kind: ArtworkPlaceholder

    var body: some View {
        GeometryReader { proxy in
            Color(.secondarySystemFill)
                .overlay {
                    Image(systemName: kind == .playlist ? "music.note.list" : "music.note")
                        .font(.system(size: proxy.size.width * (kind == .playlist ? 0.38 : 0.3)))
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

private struct LoadedArtworkView: View {
    let artwork: Artwork
    let hidesLoadingPlaceholder: Bool
    @State private var failedURL: URL?
    let retainsImageAcrossSources: Bool
    let provider: any FrontAMArtworkProvider
    let loadImage: @MainActor (URL, Int) async -> UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.artworkLoadAction) private var loadArtwork
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var resolvedURL: URL?
    @State private var placeholderKind: ArtworkPlaceholder
    @State private var initialArtwork: Artwork?

    init(artwork: Artwork, previewArtwork: Artwork?, retainsImageAcrossSources: Bool, hidesLoadingPlaceholder: Bool,
         provider: any FrontAMArtworkProvider, loadImage: @escaping @MainActor (URL, Int) async -> UIImage?) {
        self.artwork = artwork
        self.hidesLoadingPlaceholder = hidesLoadingPlaceholder
        self.retainsImageAcrossSources = retainsImageAcrossSources
        self.provider = provider
        self.loadImage = loadImage
        let kind: ArtworkPlaceholder
        if case .deferred(_, let value) = artwork { kind = value } else { kind = .missing }
        _placeholderKind = State(initialValue: kind)
        _initialArtwork = State(initialValue: previewArtwork)
        switch artwork {
        case .file(let url):
            _image = State(initialValue: provider.cached(url, pixels: 0))
            _imageURL = State(initialValue: url)
        case .deferred(let id, _):
            if let resolved = provider.resolvedURL(for: id) {
                _resolvedURL = State(initialValue: resolved)
                _image = State(initialValue: provider.cached(resolved, pixels: 0))
                _imageURL = State(initialValue: resolved)
            }
        default:
            break
        }
    }

    private var url: URL? { if case .file(let url) = artwork { url } else { resolvedURL } }
    private var currentPlaceholder: ArtworkPlaceholder {
        if case .deferred(_, let kind) = artwork { kind } else { placeholderKind }
    }

    private func displayedImage(pixels: Int) -> UIImage? {
        if let url, let ready = (imageURL == url ? image : nil) ?? provider.cached(url, pixels: pixels) {
            return ready
        }
        return retainsImageAcrossSources ? image : nil
    }

    private var hasPreviewImage: Bool {
        switch initialArtwork {
        case .image, .file: true
        default: false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let pixels = geometry.size.width > 0 ? FrontAMArtworkSize.pixelSize(geometry.size.width * displayScale) : 0
            ZStack {
                if let image = displayedImage(pixels: pixels) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else if let initialArtwork {
                    ArtworkView(artwork: initialArtwork, cornerRadius: 0, loadImage: loadImage)
                        .environment(\.nativeArtworkSurfaceEnabled, false)
                } else if !hidesLoadingPlaceholder || (url != nil && failedURL == url) {
                    ArtworkPlaceholderView(kind: currentPlaceholder)
                }
            }
            .animation(!reduceMotion && (displayedImage(pixels: pixels) != nil || hasPreviewImage) ? .easeInOut(duration: 0.2) : nil,
                       value: displayedImage(pixels: pixels) != nil || hasPreviewImage)
            .task(id: (url?.absoluteString ?? "") + ":" + String(pixels)) {
                guard let url, pixels > 0 else { return }
                failedURL = nil
                let loaded = await loadImage(url, pixels)
                guard !Task.isCancelled else { return }
                guard let loaded else { failedURL = url; return }
                image = loaded
                imageURL = url
            }
        }
        .task(id: artwork.loadID) {
            await loadArtwork.resolveDeferred(artwork.loadID) {
                if resolvedURL != $0 { resolvedURL = $0 }
            }
        }
        .onChange(of: artwork) {
            if case .deferred(_, let kind) = artwork { placeholderKind = kind }
        }
    }
}

@propertyWrapper public struct ArtworkResource<Value: Equatable>: Equatable {
    private var state: ArtworkResourceState<Value>
    public init(wrappedValue: Value) { state = ArtworkResourceState(wrappedValue) }
    public var wrappedValue: Value {
        get { state.value }
        set { state = ArtworkResourceState(newValue) }
    }
    public var projectedValue: ArtworkResourceState<Value> { state }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state || lhs.state.snapshot == rhs.state.snapshot
    }
}

@Observable public final class ArtworkResourceState<Value: Equatable> {
    @ObservationIgnored private(set) var snapshot: Value
    public init(_ value: Value) { snapshot = value }
    public var value: Value {
        access(keyPath: \.value)
        return snapshot
    }
    public func update(_ value: Value) {
        guard snapshot != value else { return }
        withMutation(keyPath: \.value) { snapshot = value }
    }
}

public struct ResourceArtworkView: View {
    public let resource: ArtworkResourceState<Artwork>
    public var contentID: String?
    public var cornerRadius: CGFloat = DesignTokens.Radius.card
    public var body: some View {
        ArtworkView(artwork: resource.value, contentID: contentID, cornerRadius: cornerRadius)
    }

    public init(resource: ArtworkResourceState<Artwork>,
                contentID: String? = nil,
                cornerRadius: CGFloat = DesignTokens.Radius.card) {
        self.resource = resource
        self.contentID = contentID
        self.cornerRadius = cornerRadius
    }
}
