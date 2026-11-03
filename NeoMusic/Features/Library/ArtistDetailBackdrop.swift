import SwiftUI
import UIKit

struct ArtistDetailBackdrop: View {
    let artwork: Artwork?
    @State private var sourceImage: UIImage?
    @State private var diffuseImage: UIImage?
    @State private var sharpImage: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let y = geometry.frame(in: .scrollView).minY
            let upward = max(0, -y)
            // Blur and color loss are one image transition, independent of the page shade.
            let imageProgress = min(1, max(0, (upward - 150) / 330))
            let imageHeight: CGFloat = 400
            let extent: CGFloat = 520
            let pull = max(0, y)
            let magnification = 1 + pull / 500

            ZStack(alignment: .top) {
                // The diffuse image extends behind the title, buttons and release card.
                if let diffuseImage {
                    Image(uiImage: diffuseImage).resizable()
                        .frame(width: geometry.size.width, height: extent)
                        .blur(radius: 22, opaque: true)
                    Image(uiImage: diffuseImage).resizable()
                        .frame(width: geometry.size.width, height: extent)
                        .blur(radius: 7, opaque: true)
                        .mask(LinearGradient(stops: [
                            .init(color: .black, location: 0.59),
                            .init(color: .clear, location: 0.76)
                        ], startPoint: .top, endPoint: .bottom))
                }
                Image(uiImage: sharpImage ?? UIImage()).resizable()
                    .frame(width: geometry.size.width, height: imageHeight)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 0.86)
                        ], startPoint: .top, endPoint: .bottom)
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
                if case .file(let url) = artwork {
                    sourceImage = await LocalArtworkImages.load(url, pixels: LocalArtworkImages.pixelSize(max(geometry.size.width, 520) * displayScale))
                }
                guard !Task.isCancelled else { return }
                let images = makeImages(width: geometry.size.width)
                sharpImage = images?.sharp
                diffuseImage = images?.diffuse
            }
        }
        .allowsHitTesting(false)
    }

    private func makeImages(width: CGFloat) -> (sharp: UIImage, diffuse: UIImage)? {
        guard width > 0, let image = sourceImage else { return nil }
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
        return (source, extended)
    }
}

