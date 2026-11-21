import UIKit
import ImageIO

@MainActor enum LocalArtworkImages {
    private final class Variants {
        var images: [Int: UIImage] = [:]
        var backdrop: AlbumArtworkBackdrop?
        var cost: Int { images.values.reduce(0) { $0 + ($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0) } }

        func image(for pixels: Int, allowingSmaller: Bool) -> UIImage? {
            if let size = images.keys.filter({ $0 >= pixels }).min() { return images[size] }
            return allowingSmaller ? images.keys.max().flatMap { images[$0] } : nil
        }
    }
    private static let images: NSCache<NSURL, Variants> = {
        let cache = NSCache<NSURL, Variants>()
        cache.totalCostLimit = 192 * 1_024 * 1_024
        return cache
    }()
    private struct Request: Hashable {
        let url: URL
        let pixels: Int
        let prepareBackdrop: Bool
    }
    private static var loading: [Request: Task<UIImage?, Never>] = [:]
    private static let decoder = LocalArtworkDecoder()

    static func pixelSize(_ size: CGFloat) -> Int { max(64, Int(ceil(size / 64)) * 64) }

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        images.object(forKey: url as NSURL)?.image(for: pixels, allowingSmaller: true)
    }

    private static var resolvedArtwork: [String: URL] = [:]

    static func registerResolvedArtwork(_ id: String, url: URL) { resolvedArtwork[id] = url }

    static func cachedResolved(_ id: String, pixels: Int) -> UIImage? {
        guard let url = resolvedArtwork[id] else { return nil }
        return cached(url, pixels: pixels)
    }

    static func resolvedURL(for id: String) -> URL? { resolvedArtwork[id] }

    static func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop? {
        let url: URL
        switch artwork {
        case .file(let file): url = file
        case .deferred(let id, _): guard let file = resolvedArtwork[id] else { return nil }; url = file
        default: return nil
        }
        return images.object(forKey: url as NSURL)?.backdrop
    }

    static func loadBackdrop(for url: URL) async -> AlbumArtworkBackdrop? {
        guard !Task.isCancelled else { return nil }
        if let cached = images.object(forKey: url as NSURL)?.backdrop { return cached }
        guard let backdrop = await decoder.loadBackdrop(url), !Task.isCancelled else { return nil }
        let variants = images.object(forKey: url as NSURL) ?? Variants()
        variants.backdrop = backdrop
        images.setObject(variants, forKey: url as NSURL, cost: variants.cost)
        return backdrop
    }

    static func prepare(_ artworks: [Artwork], pixels: Int = 512, limit: Int = 10) async {
        guard limit > 0, !Task.isCancelled else { return }
        var requests: [URL: Int] = [:]
        func collect(_ artwork: Artwork, pixels: Int) {
            switch artwork {
            case .file(let url):
                guard url.isFileURL, requests[url] != nil || requests.count < limit else { return }
                requests[url] = max(requests[url] ?? 0, pixels)
            case .folder(let children):
                for child in children.prefix(4) { collect(child, pixels: pixelSize(CGFloat(pixels) * 0.36)) }
            default: break
            }
        }
        for artwork in artworks { collect(artwork, pixels: pixels) }
        await withTaskGroup(of: Void.self) { group in
            for (url, size) in requests {
                group.addTask { _ = await load(url, pixels: size) }
            }
        }
    }

    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, pixels: pixels, prepareBackdrop: true)
    }

    static func loadThumbnail(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, pixels: pixels, prepareBackdrop: false)
    }

    private static func load(_ url: URL, pixels: Int, prepareBackdrop: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let variants = images.object(forKey: url as NSURL),
           let image = variants.image(for: pixels, allowingSmaller: false),
           (!prepareBackdrop || variants.backdrop != nil) {
            return image
        }
        let request = Request(url: url, pixels: pixels, prepareBackdrop: prepareBackdrop)
        let task: Task<UIImage?, Never>
        if let pending = loading[request] {
            task = pending
        } else {
            task = Task {
                defer { loading[request] = nil }
                guard let prepared = await decoder.load(url, pixels: pixels, prepareBackdrop: prepareBackdrop) else { return nil }
                let variants = images.object(forKey: url as NSURL) ?? Variants()
                variants.images[pixels] = prepared.image
                if let backdrop = prepared.backdrop { variants.backdrop = backdrop }
                images.setObject(variants, forKey: url as NSURL, cost: variants.cost)
                return prepared.image
            }
            loading[request] = task
        }
        let image = await task.value
        return Task.isCancelled ? nil : image
    }
}

private actor LocalArtworkDecoder {
    struct Prepared: Sendable {
        let image: UIImage
        let backdrop: AlbumArtworkBackdrop?
    }
    private let backdrops = AlbumArtworkBackdropPreparer(
        cacheURL: URL.cachesDirectory.appending(path: "ArtworkBackdrops.json"))

    func loadBackdrop(_ url: URL) async -> AlbumArtworkBackdrop? {
        guard !Task.isCancelled else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let colors = try? await backdrops.prepareAdditionalArtwork([url.absoluteString: data])
        guard !Task.isCancelled else { return nil }
        return colors?[url.absoluteString]
    }

    func load(_ url: URL, pixels: Int, prepareBackdrop: Bool) async -> Prepared? {
        guard !Task.isCancelled else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let colors = prepareBackdrop ? (try? await backdrops.prepareAdditionalArtwork([url.absoluteString: data])) : nil
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels
                  ] as CFDictionary) else { return nil }
            return Prepared(image: UIImage(cgImage: thumbnail), backdrop: colors?[url.absoluteString])
        }
    }
}
