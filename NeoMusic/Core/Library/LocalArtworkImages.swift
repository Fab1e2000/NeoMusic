import UIKit
import ImageIO

/// File-backed artwork is shared by the library and system media surfaces.
@MainActor enum LocalArtworkImages {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()
    private static let decoder = LocalArtworkDecoder()

    static func pixelSize(_ size: CGFloat) -> Int { max(64, Int(ceil(size / 64)) * 64) }

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        images.object(forKey: key(url, pixels)) ?? images.object(forKey: url.absoluteString as NSString)
    }

    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        let key = key(url, pixels)
        if let image = images.object(forKey: key) { return image }
        guard !Task.isCancelled, let image = await decoder.load(url, pixels: pixels), !Task.isCancelled else { return nil }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: key, cost: cost)
        images.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
        return image
    }

    private static func key(_ url: URL, _ pixels: Int) -> NSString { (url.absoluteString + ":" + String(pixels)) as NSString }
}

private actor LocalArtworkDecoder {
    func load(_ url: URL, pixels: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
    }
}
