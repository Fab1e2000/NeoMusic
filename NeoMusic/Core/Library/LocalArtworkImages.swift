import UIKit

@MainActor enum LocalArtworkImages {
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
    private static let images: NSCache<NSURL, Variants> = {
        let cache = NSCache<NSURL, Variants>()
        cache.totalCostLimit = 192 * 1_024 * 1_024
        return cache
    }()
    private struct Request: Hashable {
        let url: URL
        let size: ImageSourceThumbnail.Size
    }
    private static var loading: [Request: Task<UIImage?, Never>] = [:]
    private static let decoder = LocalArtworkDecoder()

    static func pixelSize(_ size: CGFloat) -> Int { max(64, Int(ceil(size / 64)) * 64) }

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        cached(url, size: .maximumDimension(pixels), allowingSmaller: true)
    }

    static func cached(_ url: URL, size: ImageSourceThumbnail.Size, allowingSmaller: Bool = false) -> UIImage? {
        images.object(forKey: url as NSURL)?.image(for: size, allowingSmaller: allowingSmaller)
    }

    private static var resolvedArtwork: [String: URL] = [:]

    static func registerResolvedArtwork(_ id: String, url: URL) { resolvedArtwork[id] = url }

    static func cachedResolved(_ id: String, pixels: Int) -> UIImage? {
        guard let url = resolvedArtwork[id] else { return nil }
        return cached(url, pixels: pixels)
    }

    static func resolvedURL(for id: String) -> URL? { resolvedArtwork[id] }

    static func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop? {
        guard let url = artwork.resolvedFileURL else { return nil }
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

    /// Wait for the visible covers or the deadline. A slow disk read can still warm the
    /// same image cache the visible views use after the deadline.
    static func prepareFirstShelf(_ artworks: [Artwork], timeout: Duration = .milliseconds(275),
                                  preparePortraits: @escaping @MainActor () async -> Void = {},
                                  resolveCached: @escaping @MainActor (String) async -> URL?) async {
        guard !Task.isCancelled else { return }
        let (finished, completion) = AsyncStream<Void>.makeStream()
        let work = Task {
            async let portraits: Void = preparePortraits()
            await prepare(artworks, resolveCached: resolveCached)
            await portraits
            completion.finish()
        }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            completion.finish()
        }
        for await _ in finished {}
        deadline.cancel()
        if Task.isCancelled { work.cancel() }
    }

    private enum Source: Hashable {
        case file(URL)
        case deferred(String)
    }

    static func prepare(_ artworks: [Artwork], pixels: Int = 512, limit: Int = .max,
                        resolveCached: @escaping @MainActor (String) async -> URL? = { _ in nil }) async {
        guard limit > 0, !Task.isCancelled else { return }
        var requests: [Source: Int] = [:]
        func collect(_ artwork: Artwork, pixels: Int) {
            let source: Source
            switch artwork {
            case .file(let url) where url.isFileURL: source = .file(url)
            case .deferred(let id, _): source = .deferred(id)
            case .folder(let children):
                for child in children.prefix(4) { collect(child, pixels: pixelSize(CGFloat(pixels) * 0.36)) }
                return
            default: return
            }
            guard requests[source] != nil || requests.count < limit else { return }
            requests[source] = max(requests[source] ?? 0, pixels)
        }
        for artwork in artworks { collect(artwork, pixels: pixels) }
        await withTaskGroup(of: Void.self) { group in
            for (source, size) in requests {
                group.addTask { await prepare(source, pixels: size, resolveCached: resolveCached) }
            }
        }
    }

    private static func prepare(_ source: Source, pixels: Int,
                                resolveCached: @MainActor (String) async -> URL?) async {
        guard !Task.isCancelled else { return }
        let url: URL
        switch source {
        case .file(let file): url = file
        case .deferred(let id):
            guard let file = await resolveCached(id), file.isFileURL, !Task.isCancelled else { return }
            registerResolvedArtwork(id, url: file)
            url = file
        }
        _ = await load(url, pixels: pixels)
    }

    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, size: .maximumDimension(pixels))
    }

    static func loadThumbnail(_ url: URL, pixels: Int) async -> UIImage? {
        await load(url, pixels: pixels)
    }

    static func load(_ url: URL, size: ImageSourceThumbnail.Size) async -> UIImage? {
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
                guard let prepared = await LocalArtworkDecoder.load(url, size: requestedSize) else { return nil }
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

private actor LocalArtworkDecoder {
    struct Prepared: Sendable {
        let image: UIImage
        let pixels: Int
        let sourceSize: CGSize?
    }
    private let backdrops = AlbumArtworkBackdropPreparer.shared

    func loadBackdrop(_ url: URL) async -> AlbumArtworkBackdrop? {
        guard !Task.isCancelled else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let colors = try? await backdrops.prepareAdditionalArtwork([url.absoluteString: data])
        guard !Task.isCancelled else { return nil }
        return colors?[url.absoluteString]
    }

    @concurrent static func load(_ url: URL, size: ImageSourceThumbnail.Size) async -> Prepared? {
        guard !Task.isCancelled else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return autoreleasepool {
            guard let thumbnail = ImageSourceThumbnail.decode(data, size: size) else { return nil }
            return Prepared(image: UIImage(cgImage: thumbnail.image),
                            pixels: max(thumbnail.image.width, thumbnail.image.height), sourceSize: thumbnail.sourceSize)
        }
    }
}
