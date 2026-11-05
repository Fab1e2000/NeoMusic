import SwiftUI

/// 专辑、播放列表或歌曲的封面。
enum Artwork: Equatable {
    /// Apple Music“喜爱歌曲”星标的实测颜色。
    static let favoritesRed = Color(red: 251 / 255, green: 35 / 255, blue: 60 / 255)
    static let favoritesBackground = Color(red: 233 / 255, green: 237 / 255, blue: 238 / 255)

    case image(Image)
    case file(URL)
    case deferred(id: String, placeholder: ArtworkPlaceholder)
    /// “喜爱歌曲”固定使用浅灰底上的红色星标。
    case favorites
    /// 没有封面的播放列表。
    case playlist
    /// 播放列表文件夹。
    indirect case folder([Artwork])
    /// 没有封面的歌曲或专辑。
    case missing

    var loadID: String? { if case .deferred(let id, _) = self { id } else { nil } }
}

enum ArtworkPlaceholder: Equatable { case missing, playlist }

struct ArtworkLoadAction {
    var handler: (@MainActor (String) -> Void)?
    @MainActor func callAsFunction(_ id: String?) {
        guard let id else { return }
        handler?(id)
    }
}

extension EnvironmentValues {
    @Entry var artworkLoadAction = ArtworkLoadAction()
}

/// 方形封面，按宽度铺满并裁切圆角。
struct ArtworkView: View {
    let artwork: Artwork
    var contentID: String?
    var previewArtwork: Artwork? = nil
    var cornerRadius: CGFloat = 8
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
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 1 / displayScale)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch artwork {
        case .image(let image):
            image.resizable().scaledToFill()
        case .file, .deferred:
            LoadedArtworkView(artwork: artwork, previewArtwork: previewArtwork, retainsImageAcrossSources: contentID != nil, loadImage: loadImage)
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
            // 空文件夹显示文件夹符号，与 Apple Music 一致。
            placeholder(systemImage: "folder", symbolScale: 0.44)
        case .folder(let artworks):
            GeometryReader { proxy in
                Color(.tertiarySystemFill)
                    .overlay(alignment: .topLeading) {
                        // 文件夹封面是内容的 2×2 缩略图；空文件夹保留空底。
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

/// A downloaded file keeps the deferred cover's placeholder until its pixels are ready.
private struct LoadedArtworkView: View {
    let artwork: Artwork
    let retainsImageAcrossSources: Bool
    let loadImage: @MainActor (URL, Int) async -> UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.artworkLoadAction) private var loadArtwork
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var placeholderKind: ArtworkPlaceholder
    @State private var initialArtwork: Artwork?

    init(artwork: Artwork, previewArtwork: Artwork?, retainsImageAcrossSources: Bool,
         loadImage: @escaping @MainActor (URL, Int) async -> UIImage?) {
        self.artwork = artwork
        self.retainsImageAcrossSources = retainsImageAcrossSources
        self.loadImage = loadImage
        // Seed once, then retain this neutral placeholder across deferred -> file.
        let kind: ArtworkPlaceholder
        if case .deferred(_, let value) = artwork { kind = value } else { kind = .missing }
        _placeholderKind = State(initialValue: kind)
        // The navigation source is a one-time seed for this stable resource identity.
        _initialArtwork = State(initialValue: previewArtwork)
        // A cached thumbnail is already visible before the larger decode finishes.
        // Keep those pixels if metadata changes the file during that decode.
        if case .file(let url) = artwork {
            _image = State(initialValue: LocalArtworkImages.cached(url, pixels: 0))
            _imageURL = State(initialValue: url)
        }
    }

    private var url: URL? { if case .file(let url) = artwork { url } else { nil } }
    private var currentPlaceholder: ArtworkPlaceholder {
        if case .deferred(_, let kind) = artwork { kind } else { placeholderKind }
    }

    private func displayedImage(pixels: Int) -> UIImage? {
        if let url, let ready = (imageURL == url ? image : nil) ?? LocalArtworkImages.cached(url, pixels: pixels) {
            return ready
        }
        // Only a caller-supplied stable item identity permits retaining a different file.
        return retainsImageAcrossSources ? image : nil
    }

    var body: some View {
        GeometryReader { geometry in
            let pixels = geometry.size.width > 0 ? LocalArtworkImages.pixelSize(geometry.size.width * displayScale) : 0
            Group {
                if let image = displayedImage(pixels: pixels) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let initialArtwork {
                    ArtworkView(artwork: initialArtwork, cornerRadius: 0, loadImage: loadImage)
                        .environment(\.nativeArtworkSurfaceEnabled, false)
                } else { ArtworkPlaceholderView(kind: currentPlaceholder) }
            }
            .task(id: (url?.absoluteString ?? "") + ":" + String(pixels)) {
                guard let url, pixels > 0 else { return }
                let loaded = await loadImage(url, pixels)
                guard !Task.isCancelled, let loaded else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    image = loaded
                    imageURL = url
                }
            }
        }
        .task(id: artwork.loadID) { loadArtwork(artwork.loadID) }
        .onChange(of: artwork) {
            if case .deferred(_, let kind) = artwork { placeholderKind = kind }
        }
    }
}
