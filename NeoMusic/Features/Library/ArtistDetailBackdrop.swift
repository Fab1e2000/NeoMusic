import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct ArtistDetailBackdrop: View {
    let artwork: Artwork?
    @State private var preparedImage: UIImage?
    private static let preparer = ArtistBackdropPreparer()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let y = geometry.frame(in: .scrollView).minY
            let upward = max(0, -y)
            // Blur and color loss are one image transition, independent of the page shade.
            let imageProgress = min(1, max(0, (upward - 150) / 330))
            let extent: CGFloat = 520
            let pull = max(0, y)
            let magnification = 1 + pull / 500

            ZStack(alignment: .top) {
                if let preparedImage {
                    Image(uiImage: preparedImage).resizable()
                        .frame(width: geometry.size.width, height: extent)
                }
            }
            .frame(width: geometry.size.width, height: extent, alignment: .top)
            .compositingGroup()
            .blur(radius: 60 * imageProgress)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.68),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .scaleEffect(magnification, anchor: .top)
            .offset(y: upward * 0.6 - pull)
            .opacity(1 - imageProgress)
            .task(id: String(describing: artwork) + String(describing: geometry.size.width)) {
                guard case .file(let url) = artwork else { preparedImage = nil; return }
                let image = await LocalArtworkImages.load(url, pixels: LocalArtworkImages.pixelSize(max(geometry.size.width, 520) * displayScale))
                guard !Task.isCancelled, let image else { return }
                let prepared = await Self.preparer.prepare(image, width: geometry.size.width, displayScale: displayScale)
                guard !Task.isCancelled else { return }
                preparedImage = prepared
            }
        }
        .allowsHitTesting(false)
    }

}

private actor ArtistBackdropPreparer {
    private let context = CIContext()

    func prepare(_ image: UIImage, width: CGFloat, displayScale: CGFloat) -> UIImage? {
        guard width > 0 else { return nil }
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
        return UIImage(cgImage: rendered, scale: displayScale, orientation: .up)
    }
}

