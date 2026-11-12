import SwiftUI
import CryptoKit
import CoreImage.CIFilterBuiltins

/// The album's opaque sRGB background and the matching system foreground style.
struct AlbumArtworkBackdrop: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    private static let imageContext = CIContext()
    var colorScheme: ColorScheme {
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? .dark : .light
    }

    private func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Runs away from the UI actor and chooses the most populated Core Image color cluster.
    static func extract(from data: Data) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            guard let input = CIImage(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let scale = min(1, 128 / max(input.extent.width, input.extent.height))
            let reduced = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let filter = CIFilter.kMeans()
            filter.inputImage = reduced
            filter.extent = reduced.extent
            filter.count = 8
            filter.passes = 10
            filter.perceptual = false
            guard let output = filter.outputImage else { return nil }
            let context = imageContext
            var weighted = [Float](repeating: 0, count: 32)
            context.render(output, toBitmap: &weighted, rowBytes: 128,
                           bounds: output.extent, format: .RGBAf, colorSpace: space)
            guard let dominant = (0..<8).max(by: { weighted[$0 * 4 + 3] < weighted[$1 * 4 + 3] }),
                  weighted[dominant * 4 + 3] > 0 else { return nil }
            // Core Image stores each cluster's population in alpha; the palette's
            // color is rendered opaque before choosing the largest cluster.
            var colors = [Float](repeating: 0, count: 32)
            context.render(output.settingAlphaOne(in: output.extent), toBitmap: &colors, rowBytes: 128,
                           bounds: output.extent, format: .RGBAf, colorSpace: space)
            let index = dominant * 4
            return AlbumArtworkBackdrop(red: Double(colors[index]), green: Double(colors[index + 1]), blue: Double(colors[index + 2]))
        }
    }
}

/// Prepares the exact artwork-derived colors before publishing a library snapshot.
actor AlbumArtworkBackdropPreparer {
    // Version 2 derives the palette through the public Core Image filter.
    static let cacheVersion = 2
    private struct Snapshot: Codable {
        let version: Int
        let colors: [String: AlbumArtworkBackdrop?]
    }
    private var cached: [Data: (key: String, color: AlbumArtworkBackdrop?)] = [:]
    private var persisted: [String: AlbumArtworkBackdrop?] = [:]
    private var loaded = false
    private let cacheURL: URL?
    private let extract: @Sendable (Data) -> AlbumArtworkBackdrop?

    init(cacheURL: URL? = nil,
         extract: @escaping @Sendable (Data) -> AlbumArtworkBackdrop? = { AlbumArtworkBackdrop.extract(from: $0) }) {
        self.cacheURL = cacheURL
        self.extract = extract
    }

    private func loadPersistedColors() throws {
        try Task.checkCancellation()
        if !loaded {
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == Self.cacheVersion {
                persisted = snapshot.colors
            }
            loaded = true
        }
    }

    func cachedColors(for keys: Set<String>) throws -> [String: AlbumArtworkBackdrop?] {
        try loadPersistedColors()
        return persisted.filter { keys.contains($0.key) }
    }

    func prepare(_ artworkByID: [String: Data]) throws -> [String: AlbumArtworkBackdrop] {
        try loadPersistedColors()
        return try prepare(artworkByID, retaining: [:])
    }

    /// File-backed images arrive individually; keep colors of previously prepared files.
    func prepareAdditionalArtwork(_ artworkByID: [String: Data]) throws -> [String: AlbumArtworkBackdrop] {
        try loadPersistedColors()
        return try prepare(artworkByID, retaining: persisted)
    }

    private func prepare(_ artworkByID: [String: Data], retaining colors: [String: AlbumArtworkBackdrop?]) throws -> [String: AlbumArtworkBackdrop] {
        var nextCache: [Data: (key: String, color: AlbumArtworkBackdrop?)] = [:]
        var nextPersisted = colors
        var results: [String: AlbumArtworkBackdrop] = [:]
        for (id, data) in artworkByID {
            try Task.checkCancellation()
            let prepared: (key: String, color: AlbumArtworkBackdrop?)
            if let existing = nextCache[data] ?? cached[data] {
                prepared = existing
            } else {
                let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                // A resolved nil is cached too, so invalid artwork is not analyzed on every launch.
                let color = persisted[key] ?? extract(data)
                prepared = (key, color)
            }
            try Task.checkCancellation()
            nextCache[data] = prepared
            nextPersisted.updateValue(prepared.color, forKey: prepared.key)
            if let color = prepared.color { results[id] = color }
        }
        try Task.checkCancellation()
        if let cacheURL, nextPersisted != persisted {
            // Derived colors are expendable. A missing, corrupt or unwritable cache
            // must never prevent the library from opening.
            if let data = try? JSONEncoder().encode(Snapshot(version: Self.cacheVersion, colors: nextPersisted)),
               (try? data.write(to: cacheURL, options: .atomic)) != nil {
                persisted = nextPersisted
            }
        }
        if cacheURL == nil { persisted = nextPersisted }
        cached = nextCache
        return results
    }
}
