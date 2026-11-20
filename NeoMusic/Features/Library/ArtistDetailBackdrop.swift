import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct ArtistDetailBackdrop: View {
    let artwork: Artwork?
    var preview: Artwork? = nil
    let onBackgroundReady: (URL, ArtistBackdropColor) -> Void
    @State private var shownImage: UIImage?
    @State private var shownRequest: ArtistBackdropRequest?
    @State private var shownIsPrepared = false
    @State private var fadeMask: UIImage?
    private static let preparer = ArtistBackdropPreparer()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.artworkLoadAction) private var loadArtwork
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    private var artworkURL: URL? { if case .file(let url) = artwork { url } else { nil } }

    var body: some View {
        GeometryReader { geometry in
            let request = ArtistBackdropRequest(url: artworkURL, width: geometry.size.width, scale: displayScale)
            let y = geometry.frame(in: .scrollView).minY
            let upward = max(0, -y)
            // Blur and color loss are one image transition, independent of the page shade.
            let imageProgress = min(1, max(0, (upward - 150) / 330))
            let extent: CGFloat = 520
            let maskSize = CGSize(width: geometry.size.width * displayScale, height: extent * displayScale)
            let pull = max(0, y)
            let magnification = 1 + pull / 500

            ZStack(alignment: .top) {
                if let image = immediateImage {
                    image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: extent)
                        .clipped()
                }
                if let shownImage, shownRequest == request {
                    if shownIsPrepared {
                        Image(uiImage: shownImage).resizable()
                            .frame(width: geometry.size.width, height: extent)
                    } else {
                        Image(uiImage: shownImage).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: extent)
                            .clipped()
                    }
                }
            }
            .frame(width: geometry.size.width, height: extent, alignment: .top)
            .compositingGroup()
            .blur(radius: reducesMotion ? 0 : 60 * imageProgress)
            .mask {
                if let fadeMask {
                    Image(uiImage: fadeMask).resizable()
                } else {
                    LinearGradient(colors: [.black, .clear], startPoint: .init(x: 0.5, y: 0.52), endPoint: .bottom)
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
            .task(id: request) {
                guard let url = request.url else { return }
                let image = await LocalArtworkImages.load(url, pixels: LocalArtworkImages.pixelSize(max(geometry.size.width, 520) * displayScale))
                guard !Task.isCancelled, let image else { return }
                shownImage = image
                shownRequest = request
                shownIsPrepared = false
                let prepared = await Self.preparer.prepare(image, request: request)
                guard !Task.isCancelled, let prepared else { return }
                shownImage = prepared.image
                shownRequest = request
                shownIsPrepared = true
                if let color = prepared.color { onBackgroundReady(url, color) }
            }
        }
        .allowsHitTesting(false)
        .task(id: artwork?.loadID) { loadArtwork(artwork?.loadID) }
        .task(id: preview?.loadID) { loadArtwork(preview?.loadID) }
    }

    private var immediateImage: Image? {
        if case .image(let image) = preview { return image }
        if artworkURL == nil, case .image(let image) = artwork { return image }
        return nil
    }

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

    func dimmed(by factor: Double) -> Color {
        let linearFactor = pow(factor, 2.2)
        return Color(.sRGBLinear, red: red * linearFactor, green: green * linearFactor, blue: blue * linearFactor)
    }
}

private final class PreparedArtistBackdrop: Sendable {
    let image: UIImage
    let color: ArtistBackdropColor?

    init(image: UIImage, color: ArtistBackdropColor?) {
        self.image = image
        self.color = color
    }
}

private actor ArtistBackdropPreparer {
    private let context = CIContext()
    private let cache = NSCache<NSString, PreparedArtistBackdrop>()
    private var cachedFadeMask: (size: CGSize, image: UIImage)?

    init() { cache.totalCostLimit = 24 * 1_024 * 1_024 }

    func fadeMask(pixelSize: CGSize) -> UIImage? {
        guard pixelSize.width > 0, pixelSize.height > 0, !Task.isCancelled else { return nil }
        if let cachedFadeMask, cachedFadeMask.size == pixelSize { return cachedFadeMask.image }

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = .zero
        gradient.point1 = CGPoint(x: 0, y: pixelSize.height * 0.48)
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

    func prepare(_ image: UIImage, request: ArtistBackdropRequest) -> PreparedArtistBackdrop? {
        let width = request.width, displayScale = request.scale
        guard width > 0, !Task.isCancelled else { return nil }
        let key = "\(request.url?.absoluteString ?? ""):\(width):\(displayScale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
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
        // Core Image coordinates start at the bottom. Keep the upper artwork sharp,
        // then smoothly increase the radius through the image's lower edge.
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: (520 - 400) * displayScale)
        gradient.point1 = CGPoint(x: 0, y: (520 - 288) * displayScale)
        gradient.color0 = .white
        gradient.color1 = .black
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = input.clampedToExtent()
        blur.mask = gradient.outputImage
        blur.radius = Float(22 * displayScale)
        guard let output = blur.outputImage,
              let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        guard !Task.isCancelled else { return nil }
        let result = PreparedArtistBackdrop(
            image: UIImage(cgImage: rendered, scale: displayScale, orientation: .up),
            color: source.cgImage.flatMap { backgroundColor(from: $0) }
        )
        cache.setObject(result, forKey: key, cost: rendered.bytesPerRow * rendered.height)
        return result
    }

    private func backgroundColor(from source: CGImage) -> ArtistBackdropColor? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let image = CIImage(cgImage: source)
        let average = CIFilter.areaAverage()
        average.inputImage = image
        // Sample the lower quarter of the displayed crop, before mirroring or blur.
        average.extent = CGRect(x: 0, y: 0, width: image.extent.width, height: floor(image.extent.height / 4))
        guard let output = average.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4 * MemoryLayout<Float>.size,
                       bounds: output.extent, format: .RGBAf, colorSpace: colorSpace)
        guard pixel[3] > 0, pixel.allSatisfy(\.isFinite) else { return nil }
        let red = Double(max(0, pixel[0]))
        let green = Double(max(0, pixel[1]))
        let blue = Double(max(0, pixel[2]))
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        // Cap luminance for the song list's translucent white secondary text.
        let target = min(0.10, max(0.035, luminance))
        let chroma = max(red, green, blue) - min(red, green, blue)
        // Reduce very vivid colors toward neutral without changing their hue.
        let chromaScale = target / max(luminance, chroma / 0.8, 0.0001)
        return ArtistBackdropColor(
            red: target + (red - luminance) * chromaScale,
            green: target + (green - luminance) * chromaScale,
            blue: target + (blue - luminance) * chromaScale
        )
    }
}

