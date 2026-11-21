import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

private enum ArtistBackdropFade {
    static let start: CGFloat = 155.0 / 520
    static let end: CGFloat = 518.0 / 520
}

struct ArtistDetailBackdrop: View {
    let artwork: Artwork?
    let theme: ArtistBackdropColor?
    let onBackgroundReady: (ArtistBackdropColor?) -> Void
    @State private var shown: (artwork: Artwork?, backdrop: PreparedArtistBackdrop)?
    @State private var fadeMask: UIImage?
    private static let cache: NSCache<NSURL, PreparedArtistBackdrop> = {
        let cache = NSCache<NSURL, PreparedArtistBackdrop>()
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    static func cachedTheme(for artwork: Artwork?) -> ArtistBackdropColor? {
        guard case .file(let url) = artwork else { return nil }
        return cache.object(forKey: url as NSURL)?.color
    }

    private static let preparer = ArtistBackdropPreparer()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.artworkLoadAction) private var loadArtwork
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    private var artworkURL: URL? { if case .file(let url) = artwork { url } else { nil } }

    var body: some View {
        GeometryReader { geometry in
            let request = ArtistBackdropRequest(url: artworkURL, width: geometry.size.width, scale: displayScale)
            let cached = request.url.flatMap { Self.cache.object(forKey: $0 as NSURL) }
            let ready = cached?.request == request ? cached : nil
            let y = geometry.frame(in: .scrollView).minY
            let upward = max(0, -y)
            let imageProgress = min(1, max(0, (upward - 150) / 330))
            let extent: CGFloat = 520
            let maskSize = CGSize(width: geometry.size.width * displayScale, height: extent * displayScale)
            let pull = max(0, y)
            let magnification = 1 + pull / 500

            ZStack(alignment: .top) {
                if let ready {
                    Image(uiImage: ready.image).resizable()
                } else if let shown, shown.backdrop.request == request, shown.artwork == artwork {
                    Image(uiImage: shown.backdrop.image).resizable()
                } else if let theme {
                    LinearGradient(colors: [theme.dimmed(by: 1.4), theme.dimmed(by: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: extent, alignment: .top)
            .compositingGroup()
            .blur(radius: reducesMotion ? 0 : 60 * imageProgress)
            .mask {
                if let fadeMask {
                    Image(uiImage: fadeMask).resizable()
                } else {
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .init(x: 0.5, y: ArtistBackdropFade.start),
                                   endPoint: .init(x: 0.5, y: ArtistBackdropFade.end))
                }
            }
            .scaleEffect(reducesMotion ? 1 : magnification, anchor: .top)
            .offset(y: reducesMotion ? 0 : upward * 0.6 - pull)
            .opacity(1 - imageProgress)
            .task(id: maskSize) {
                let mask = await Self.preparer.fadeMask(pixelSize: maskSize)
                guard !Task.isCancelled else { return }
                fadeMask = mask
            }
            .task(id: ArtistBackdropInput(artwork: artwork, request: request)) {
                guard request.width > 0 else { return }
                if let url = request.url {
                    if let cached = ready {
                        guard !Task.isCancelled else { return }
                        shown = (artwork, cached)
                        onBackgroundReady(cached.color)
                        return
                    }
                    let color = await Self.preparer.theme(at: url)
                    guard !Task.isCancelled else { return }
                    onBackgroundReady(color)
                    let pixels = LocalArtworkImages.pixelSize(max(request.width, extent) * displayScale)
                    let image = await LocalArtworkImages.loadThumbnail(url, pixels: pixels)
                    await display(image, color: color, request: request)
                } else if case .image(let image) = artwork {
                    let source = ImageRenderer(content: image).uiImage
                    let color = await Self.preparer.theme(in: source)
                    guard !Task.isCancelled else { return }
                    onBackgroundReady(color)
                    await display(source, color: color, request: request)
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: artwork?.loadID) { loadArtwork(artwork?.loadID) }
    }

    @MainActor private func display(_ image: UIImage?, color: ArtistBackdropColor?, request: ArtistBackdropRequest) async {
        guard !Task.isCancelled else { return }
        if let image, let prepared = await Self.preparer.prepare(image, request: request, color: color) {
            guard !Task.isCancelled else { return }
            if let url = request.url, let cgImage = prepared.image.cgImage {
                Self.cache.setObject(prepared, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
            }
            shown = (artwork, prepared)
        } else if !Task.isCancelled {
            onBackgroundReady(nil)
        }
    }

}

private struct ArtistBackdropInput: Equatable {
    let artwork: Artwork?
    let request: ArtistBackdropRequest
}

private struct ArtistBackdropRequest: Hashable, Sendable {
    let url: URL?
    let width: CGFloat
    let scale: CGFloat
}

struct ArtistBackdropColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static func theme(from candidates: [AlbumArtworkBackdrop.Candidate]) -> Self? {
        // Ignore nearly neutral clusters and accents covering less than 4% of the image.
        let accents = candidates.filter { $0.weight >= 0.04 && $0.chroma >= 0.10 }
        let selected = accents.max { $0.weight * $0.chroma < $1.weight * $1.chroma }
            ?? candidates.max { $0.weight < $1.weight }
        guard let color = selected?.color else { return nil }
        let (r, g, b) = color.linearRGB
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let scale = luminance > 0.14 ? 0.14 / luminance : 1
        return Self(red: r * scale, green: g * scale, blue: b * scale)
    }

    func dimmed(by factor: Double) -> Color {
        let linearFactor = pow(factor, 2.2)
        return Color(.sRGBLinear, red: red * linearFactor, green: green * linearFactor, blue: blue * linearFactor)
    }
}

private final class PreparedArtistBackdrop: Sendable {
    let image: UIImage
    let color: ArtistBackdropColor?

    let request: ArtistBackdropRequest

    init(image: UIImage, color: ArtistBackdropColor?, request: ArtistBackdropRequest) {
        self.request = request
        self.image = image
        self.color = color
    }
}

private actor ArtistBackdropPreparer {
    private let context = CIContext()
    private let artworkContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var cachedFadeMask: (size: CGSize, image: UIImage)?

    func fadeMask(pixelSize: CGSize) -> UIImage? {
        guard pixelSize.width > 0, pixelSize.height > 0, !Task.isCancelled else { return nil }
        if let cachedFadeMask, cachedFadeMask.size == pixelSize { return cachedFadeMask.image }

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: pixelSize.height * (1 - ArtistBackdropFade.end))
        gradient.point1 = CGPoint(x: 0, y: pixelSize.height * (1 - ArtistBackdropFade.start))
        gradient.color0 = .black
        gradient.color1 = .white

        let dither = CIFilter.dither()
        dither.inputImage = gradient.outputImage
        dither.intensity = 0.01

        let alpha = CIFilter.maskToAlpha()
        alpha.inputImage = dither.outputImage
        guard let output = alpha.outputImage,
              let rendered = context.createCGImage(output, from: CGRect(origin: .zero, size: pixelSize)) else { return nil }
        let image = UIImage(cgImage: rendered)
        cachedFadeMask = (pixelSize, image)
        return image
    }

    func theme(at url: URL) -> ArtistBackdropColor? {
        CIImage(contentsOf: url).flatMap { ArtistBackdropColor.theme(from: AlbumArtworkBackdrop.candidates(from: $0)) }
    }

    func theme(in image: UIImage?) -> ArtistBackdropColor? {
        image?.cgImage.flatMap { ArtistBackdropColor.theme(from: AlbumArtworkBackdrop.candidates(from: CIImage(cgImage: $0))) }
    }

    func prepare(_ image: UIImage, request: ArtistBackdropRequest, color: ArtistBackdropColor?) -> PreparedArtistBackdrop? {
        let width = request.width, displayScale = request.scale
        guard width > 0, !Task.isCancelled else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true
        let scale = max(width / image.size.width, 400 / image.size.height)
        let rect = CGRect(x: (width - image.size.width * scale) / 2, y: 0,
                          width: image.size.width * scale, height: image.size.height * scale)
        let source = UIGraphicsImageRenderer(size: CGSize(width: width, height: 400), format: format).image { context in
            image.draw(in: rect)
            if rect.maxY < 400 {
                context.cgContext.saveGState()
                context.cgContext.clip(to: CGRect(x: 0, y: rect.maxY, width: width, height: 400 - rect.maxY))
                context.cgContext.translateBy(x: 0, y: rect.maxY * 2)
                context.cgContext.scaleBy(x: 1, y: -1)
                image.draw(in: rect)
                context.cgContext.restoreGState()
            }
        }
        let extended = UIGraphicsImageRenderer(size: CGSize(width: width, height: 520), format: format).image { context in
            source.draw(at: .zero)
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(x: 0, y: 400, width: width, height: 120))
            context.cgContext.translateBy(x: 0, y: 800)
            context.cgContext.scaleBy(x: 1, y: -1)
            source.draw(at: .zero)
            context.cgContext.restoreGState()
        }
        guard let cgImage = extended.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let output = layeredBlur(input, scale: displayScale),
              let rendered = artworkContext.createCGImage(output, from: input.extent) else { return nil }
        guard !Task.isCancelled else { return nil }
        return PreparedArtistBackdrop(
            image: UIImage(cgImage: rendered, scale: displayScale, orientation: .up),
            color: color, request: request
        )
    }

    private func layeredBlur(_ image: CIImage, scale: CGFloat) -> CIImage? {
        func ramp(from start: CGFloat, to end: CGFloat) -> CIImage? {
            let gradient = CIFilter.smoothLinearGradient()
            gradient.point0 = CGPoint(x: 0, y: image.extent.maxY - start * scale)
            gradient.point1 = CGPoint(x: 0, y: image.extent.maxY - end * scale)
            gradient.color0 = .black
            gradient.color1 = .white
            return gradient.outputImage
        }
        func blend(_ background: CIImage, toward foreground: CIImage, mask: CIImage) -> CIImage {
            foreground.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask
            ])
        }
        let extended = image.clampedToExtent()
        func blurred(radius: CGFloat) -> CIImage {
            extended.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
                .cropped(to: image.extent)
        }

        guard let depth = ramp(from: 337, to: 390),
              let transition = ramp(from: 304, to: 348) else { return nil }
        let blurredLayer = blend(blurred(radius: 3), toward: blurred(radius: 10), mask: depth)
        let dimmedLayer = blurredLayer.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.94, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.94, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.94, w: 0)
        ])
        let background = blend(blurredLayer, toward: dimmedLayer, mask: depth)
        return blend(image, toward: background, mask: transition).cropped(to: image.extent)
    }
}
