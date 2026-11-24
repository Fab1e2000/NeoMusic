import Foundation
import ImageIO

enum ImageSourceThumbnail {
    enum Size: Hashable, Sendable {
        case maximumDimension(Int)
        case target(width: Int, height: Int, fits: Bool)

        func maximumDimension(for source: CGSize?) -> Int {
            switch self {
            case .maximumDimension(let pixels):
                return max(1, pixels)
            case .target(let width, let height, let fits):
                guard let source else { return max(1, width, height) }
                let x = CGFloat(width) / source.width
                let y = CGFloat(height) / source.height
                let scale = fits ? min(x, y) : max(x, y)
                return max(1, Int((max(source.width, source.height) * scale).rounded()))
            }
        }
    }

    struct Decoded: Sendable {
        let image: CGImage
        let sourceSize: CGSize?
    }

    static func decode(_ data: Data, size: Size) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let dimensions = orientedSize(of: source)
        guard let image = image(from: source, maxPixels: size.maximumDimension(for: dimensions)) else { return nil }
        return Decoded(image: image, sourceSize: dimensions)
    }

    static func image(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return image(from: source, maxPixels: maxPixels)
    }

    static func image(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return image(from: source, maxPixels: maxPixels)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    private static func image(from source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels)
        ] as CFDictionary)
    }

    private static func orientedSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return CGSize(width: height, height: width)
        default: return CGSize(width: width, height: height)
        }
    }
}
