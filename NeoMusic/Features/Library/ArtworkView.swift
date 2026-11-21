import SwiftUI
import Observation

enum Artwork: Equatable {
    static let favoritesRed = DesignTokens.Colors.favoritesRed
    static let favoritesBackground = DesignTokens.Colors.favoritesBackground

    case image(Image)
    case file(URL)
    case deferred(id: String, placeholder: ArtworkPlaceholder)
    case favorites
    case playlist
    indirect case folder([Artwork])
    case missing

    var loadID: String? { if case .deferred(let id, _) = self { id } else { nil } }
}

enum ArtworkPlaceholder: Equatable { case missing, playlist }

struct ArtworkLoadAction {
    var handler: (@MainActor (String) -> Void)?
    var resolve: (@MainActor (String) async -> URL?)? = nil
    @MainActor func callAsFunction(_ id: String?) {
        guard let id else { return }
        handler?(id)
    }
}

extension EnvironmentValues {
    @Entry var artworkLoadAction = ArtworkLoadAction()
}

struct ArtworkView: View {
    let artwork: Artwork
    var contentID: String?
    var previewArtwork: Artwork? = nil
    var cornerRadius: CGFloat = 8
    var hidesLoadingPlaceholder = false
    var showsBorder = true
    var isZoomAlignmentTarget = false
    var loadImage: @MainActor (URL, Int) async -> UIImage? = LocalArtworkImages.load
    @Environment(\.displayScale) private var displayScale
    @Environment(\.nativeArtworkSurfaceEnabled) private var nativeSurface

    var body: some View {
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
            LoadedArtworkView(artwork: artwork, previewArtwork: previewArtwork, retainsImageAcrossSources: contentID != nil, hidesLoadingPlaceholder: hidesLoadingPlaceholder, loadImage: loadImage)
                .id(contentID)
        case .favorites:
            GeometryReader { proxy in
                Artwork.favoritesBackground
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: proxy.size.width * 0.50))
                            .foregroundStyle(Artwork.favoritesRed)
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
         loadImage: @escaping @MainActor (URL, Int) async -> UIImage?) {
        self.artwork = artwork
        self.hidesLoadingPlaceholder = hidesLoadingPlaceholder
        self.retainsImageAcrossSources = retainsImageAcrossSources
        self.loadImage = loadImage
        let kind: ArtworkPlaceholder
        if case .deferred(_, let value) = artwork { kind = value } else { kind = .missing }
        _placeholderKind = State(initialValue: kind)
        _initialArtwork = State(initialValue: previewArtwork)
        switch artwork {
        case .file(let url):
            _image = State(initialValue: LocalArtworkImages.cached(url, pixels: 0))
            _imageURL = State(initialValue: url)
        case .deferred(let id, _):
            if let resolved = LocalArtworkImages.resolvedURL(for: id) {
                _resolvedURL = State(initialValue: resolved)
                _image = State(initialValue: LocalArtworkImages.cached(resolved, pixels: 0))
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
        if let url, let ready = (imageURL == url ? image : nil) ?? LocalArtworkImages.cached(url, pixels: pixels) {
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
            let pixels = geometry.size.width > 0 ? LocalArtworkImages.pixelSize(geometry.size.width * displayScale) : 0
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
            guard let id = artwork.loadID else {
                resolvedURL = nil
                return
            }
            if let alreadyResolved = LocalArtworkImages.resolvedURL(for: id) {
                if resolvedURL != alreadyResolved { resolvedURL = alreadyResolved }
                loadArtwork(id)
                return
            }
            resolvedURL = nil
            loadArtwork(id)
            guard let file = await loadArtwork.resolve?(id), !Task.isCancelled else { return }
            LocalArtworkImages.registerResolvedArtwork(id, url: file)
            resolvedURL = file
        }
        .onChange(of: artwork) {
            if case .deferred(_, let kind) = artwork { placeholderKind = kind }
        }
    }
}

@propertyWrapper struct ArtworkResource<Value: Equatable>: Equatable {
    private var state: ArtworkResourceState<Value>
    init(wrappedValue: Value) { state = ArtworkResourceState(wrappedValue) }
    var wrappedValue: Value {
        get { state.value }
        set { state = ArtworkResourceState(newValue) }
    }
    var projectedValue: ArtworkResourceState<Value> { state }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state || lhs.state.snapshot == rhs.state.snapshot
    }
}

@Observable final class ArtworkResourceState<Value: Equatable> {
    @ObservationIgnored private(set) var snapshot: Value
    init(_ value: Value) { snapshot = value }
    var value: Value {
        access(keyPath: \.value)
        return snapshot
    }
    func update(_ value: Value) {
        guard snapshot != value else { return }
        withMutation(keyPath: \.value) { snapshot = value }
    }
}

struct ResourceArtworkView: View {
    let resource: ArtworkResourceState<Artwork>
    var contentID: String?
    var cornerRadius: CGFloat = 8
    var body: some View {
        ArtworkView(artwork: resource.value, contentID: contentID, cornerRadius: cornerRadius)
    }
}
