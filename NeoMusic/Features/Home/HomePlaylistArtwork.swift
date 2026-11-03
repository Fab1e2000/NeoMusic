import SwiftUI
import UIKit
import CoreImage

/// The approved square cover and its softly extended lower edge.
struct HomePlaylistArtwork: View {
    let artwork: Artwork
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: HomePlaylistArtworkRenderer.Images?
    @State private var renderedURL: URL?
    private var url: URL? { if case .file(let url) = artwork { url } else { nil } }
    private static let fade = Gradient(stops: (0...64).map { index in
        let t = Double(index) / 64
        let value = pow(t, 2.8)
        return .init(color: .white.opacity(1 - value * value * (3 - 2 * value)), location: 0.5 + 0.5 * t)
    })

    var body: some View {
        ZStack(alignment: .top) {
            if let rendered, renderedURL == url {
                Image(uiImage: rendered.background).resizable()
                Color.black.opacity(0.2)
                Image(uiImage: rendered.cover).resizable()
                    .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroWidth)
                    .mask(LinearGradient(gradient: Self.fade, startPoint: .top, endPoint: .bottom))
            } else {
                Color(.secondarySystemFill)
                ArtworkView(artwork: artwork, cornerRadius: 0)
                    .environment(\.nativeArtworkSurfaceEnabled, false)
                    .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroWidth)
            }
        }
        .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroHeight)
        .clipped()
        .task(id: url) {
            guard let url else { rendered = nil; renderedURL = nil; return }
            let pixels = LocalArtworkImages.pixelSize(HomeMetrics.heroWidth * displayScale)
            guard let image = await LocalArtworkImages.load(url, pixels: pixels), !Task.isCancelled else { return }
            let result = await HomePlaylistArtworkRenderer.shared.render(image, key: url.absoluteString, scale: displayScale)
            guard !Task.isCancelled else { return }
            rendered = result
            renderedURL = url
        }
    }
}

/// Processes local cached artwork off the UI actor, once per image and display scale.
actor HomePlaylistArtworkRenderer {
    struct Images: Sendable { let cover: UIImage; let background: UIImage }
    static let shared = HomePlaylistArtworkRenderer()
    private let context = CIContext()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 24 * 1_024 * 1_024 }

    func render(_ image: UIImage, key: String, scale: CGFloat) -> Images? {
        let cacheKey = "\(key):\(scale)" as NSString
        if let background = cache.object(forKey: cacheKey) { return Images(cover: image, background: background) }
        guard !Task.isCancelled, let source = image.cgImage,
              let band = source.cropping(to: CGRect(x: 0, y: CGFloat(source.height) * 0.91,
                                                    width: CGFloat(source.width), height: CGFloat(source.height) * 0.09)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let extended = UIGraphicsImageRenderer(size: CGSize(width: 248, height: 330), format: format).image { renderer in
            image.draw(in: CGRect(x: 0, y: 0, width: 248, height: 248))
            let graphics = renderer.cgContext
            graphics.saveGState()
            graphics.translateBy(x: 0, y: 330)
            graphics.scaleBy(x: 1, y: -1)
            UIImage(cgImage: band).draw(in: CGRect(x: 0, y: 0, width: 248, height: 82))
            graphics.restoreGState()
        }
        guard let cgImage = extended.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        // Extend edge colors before blurring so transparent samples cannot darken the perimeter.
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7 * scale])
            .cropped(to: input.extent)
        guard !Task.isCancelled, let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        let background = UIImage(cgImage: output, scale: scale, orientation: .up)
        cache.setObject(background, forKey: cacheKey, cost: output.bytesPerRow * output.height)
        return Images(cover: image, background: background)
    }
}
