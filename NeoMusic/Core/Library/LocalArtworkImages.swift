import FrontAMCore
import UIKit

@MainActor final class NeoMusicArtworkProvider: FrontAMArtworkProvider {
    static let shared = NeoMusicArtworkProvider()
    private let memory = FrontAMLocalArtworkProvider.shared
    private let backdropDecoder = NeoMusicArtworkBackdropDecoder()

    func cached(_ url: URL, pixels: Int) -> UIImage? { memory.cached(url, pixels: pixels) }
    func load(_ url: URL, pixels: Int) async -> UIImage? { await memory.load(url, pixels: pixels) }
    func resolvedURL(for id: String) -> URL? { memory.resolvedURL(for: id) }
    func registerResolvedArtwork(_ id: String, url: URL) { memory.registerResolvedArtwork(id, url: url) }
    func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop? { memory.cachedBackdrop(for: artwork) }
    func loadBackdrop(for url: URL) async -> AlbumArtworkBackdrop? {
        await memory.loadBackdrop(for: url) { url in await self.backdropDecoder.load(url) }
    }
}

private actor NeoMusicArtworkBackdropDecoder {
    func load(_ url: URL) async -> AlbumArtworkBackdrop? {
        guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { return nil }
        let key = url.absoluteString
        return try? await AlbumArtworkBackdropPreparer.shared.prepareAdditionalArtwork([key: data])[key]
    }
}

@MainActor enum LocalArtworkImages {
    static let provider = NeoMusicArtworkProvider.shared
    private static let memory = FrontAMLocalArtworkProvider.shared

    static func pixelSize(_ size: CGFloat) -> Int { FrontAMArtworkSize.pixelSize(size) }
    static func cached(_ url: URL, pixels: Int) -> UIImage? { provider.cached(url, pixels: pixels) }
    static func cached(_ url: URL, size: ImageSourceThumbnail.Size, allowingSmaller: Bool = false) -> UIImage? {
        memory.cached(url, size: size, allowingSmaller: allowingSmaller)
    }
    static func registerResolvedArtwork(_ id: String, url: URL) { provider.registerResolvedArtwork(id, url: url) }
    static func cachedResolved(_ id: String, pixels: Int) -> UIImage? { provider.cachedResolved(id, pixels: pixels) }
    static func resolvedURL(for id: String) -> URL? { provider.resolvedURL(for: id) }
    static func cachedBackdrop(for artwork: Artwork) -> AlbumArtworkBackdrop? { provider.cachedBackdrop(for: artwork) }
    static func loadBackdrop(for url: URL) async -> AlbumArtworkBackdrop? { await provider.loadBackdrop(for: url) }
    static func load(_ url: URL, pixels: Int) async -> UIImage? { await provider.load(url, pixels: pixels) }
    static func loadThumbnail(_ url: URL, pixels: Int) async -> UIImage? { await provider.loadThumbnail(url, pixels: pixels) }
    static func load(_ url: URL, size: ImageSourceThumbnail.Size) async -> UIImage? { await memory.load(url, size: size) }

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
}
