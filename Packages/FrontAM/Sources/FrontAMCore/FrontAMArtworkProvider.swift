import UIKit

@MainActor public protocol FrontAMArtworkProvider: AnyObject {
    func cached(_ url: URL, pixels: Int) -> UIImage?
    func load(_ url: URL, pixels: Int) async -> UIImage?
    func resolvedURL(for id: String) -> URL?
    func registerResolvedArtwork(_ id: String, url: URL)
    func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop?
    func loadBackdrop(for url: URL) async -> AlbumArtworkBackdrop?
}

public extension FrontAMArtworkProvider {
    func cachedResolved(_ id: String, pixels: Int) -> UIImage? {
        resolvedURL(for: id).flatMap { cached($0, pixels: pixels) }
    }
    func loadThumbnail(_ url: URL, pixels: Int) async -> UIImage? { await load(url, pixels: pixels) }
}

public enum FrontAMArtworkSize {
    public static func pixelSize(_ size: CGFloat) -> Int { max(64, Int(ceil(size / 64)) * 64) }
}

@MainActor public final class FrontAMLocalArtworkProvider: FrontAMArtworkProvider {
    public static let shared = FrontAMLocalArtworkProvider()
    public init() {}
    private final class Variants {
        var images: [Int: UIImage] = [:]
        var sourceSize: CGSize?
        var backdrop: AlbumArtworkBackdrop?
        var cost: Int { images.values.reduce(0) { $0 + ($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0) } }

        func requiredPixels(for size: ImageSourceThumbnail.Size) -> Int {
            let pixels = size.maximumDimension(for: sourceSize)
            guard let sourceSize else { return pixels }
            return min(pixels, Int(max(sourceSize.width, sourceSize.height)))
        }

        func image(for size: ImageSourceThumbnail.Size, allowingSmaller: Bool) -> UIImage? {
            let required = requiredPixels(for: size)
            if case .target = size, !allowingSmaller { return images[required] }
            if let size = images.keys.filter({ $0 >= required }).min() { return images[size] }
            return allowingSmaller ? images.keys.max().flatMap { images[$0] } : nil
        }
    }
    private let images: NSCache<NSURL, Variants> = {
        let cache = NSCache<NSURL, Variants>()
        cache.totalCostLimit = 192 * 1_024 * 1_024
        return cache
    }()
    private struct Request: Hashable {
        let url: URL
        let size: ImageSourceThumbnail.Size
    }
    private var loading: [Request: Task<UIImage?, Never>] = [:]

    public func cached(_ url: URL, pixels: Int) -> UIImage? {
        cached(url, size: .maximumDimension(pixels), allowingSmaller: true)
    }

    public func cached(_ url: URL, size: ImageSourceThumbnail.Size, allowingSmaller: Bool = false) -> UIImage? {
        images.object(forKey: url as NSURL)?.image(for: size, allowingSmaller: allowingSmaller)
    }

    private var resolvedArtwork: [String: URL] = [:]

    public func registerResolvedArtwork(_ id: String, url: URL) { resolvedArtwork[id] = url }

    public func cachedResolved(_ id: String, pixels: Int) -> UIImage? {
        guard let url = resolvedArtwork[id] else { return nil }
        return cached(url, pixels: pixels)
    }

    public func resolvedURL(for id: String) -> URL? { resolvedArtwork[id] }

    public func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop? {
        guard let url = artwork.resolvedFileURL(using: self) else { return nil }
        return images.object(forKey: url as NSURL)?.backdrop
    }

    public func loadBackdrop(for url: URL) async -> AlbumArtworkBackdrop? {
        await loadBackdrop(for: url, prepare: ArtworkDecoder.loadBackdrop)
    }

    public func loadBackdrop(for url: URL,
                             prepare: @MainActor (URL) async -> AlbumArtworkBackdrop?) async -> AlbumArtworkBackdrop? {
        guard !Task.isCancelled else { return nil }
        if let cached = images.object(forKey: url as NSURL)?.backdrop { return cached }
        guard let backdrop = await prepare(url), !Task.isCancelled else { return nil }
        let variants = images.object(forKey: url as NSURL) ?? Variants()
        variants.backdrop = backdrop
        images.setObject(variants, forKey: url as NSURL, cost: variants.cost)
        return backdrop
    }

    public func load(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, size: .maximumDimension(pixels))
    }

    public func loadThumbnail(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, pixels: pixels)
    }

    public func load(_ url: URL, size: ImageSourceThumbnail.Size) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cached(url, size: size) { return image }
        let requestedSize = images.object(forKey: url as NSURL).flatMap { variants in
            variants.sourceSize.map { _ in ImageSourceThumbnail.Size.maximumDimension(variants.requiredPixels(for: size)) }
        } ?? size
        let request = Request(url: url, size: requestedSize)
        let task: Task<UIImage?, Never>
        if let pending = loading[request] {
            task = pending
        } else {
            task = Task {
                defer { loading[request] = nil }
                guard let prepared = await ArtworkDecoder.load(url, size: requestedSize) else { return nil }
                let variants = images.object(forKey: url as NSURL) ?? Variants()
                variants.images[prepared.pixels] = prepared.image
                if let sourceSize = prepared.sourceSize { variants.sourceSize = sourceSize }
                images.setObject(variants, forKey: url as NSURL, cost: variants.cost)
                return prepared.image
            }
            loading[request] = task
        }
        let image = await task.value
        return Task.isCancelled ? nil : image
    }
}

private actor ArtworkDecoder {
    struct Prepared: Sendable {
        let image: UIImage
        let pixels: Int
        let sourceSize: CGSize?
    }
    @concurrent static func loadBackdrop(_ url: URL) async -> AlbumArtworkBackdrop? {
        guard url.isFileURL, !Task.isCancelled, let data = try? Data(contentsOf: url) else { return nil }
        return AlbumArtworkBackdrop.extract(from: data)
    }

    @concurrent static func load(_ url: URL, size: ImageSourceThumbnail.Size) async -> Prepared? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return autoreleasepool {
            guard let thumbnail = ImageSourceThumbnail.decode(data, size: size) else { return nil }
            return Prepared(image: UIImage(cgImage: thumbnail.image),
                            pixels: max(thumbnail.image.width, thumbnail.image.height), sourceSize: thumbnail.sourceSize)
        }
    }
}
