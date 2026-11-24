import SwiftUI
import CryptoKit
import CoreImage.CIFilterBuiltins

struct AlbumArtworkBackdrop: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    private static let imageContext = CIContext()
    var colorScheme: ColorScheme {
        let (r, g, b) = linearRGB
        let okL = ArtworkColorSpace.linearToOKLab(r: r, g: g, b: b, cubeRoot: cbrt).l
        return okL <= 0.65 ? .dark : .light
    }

    var linearRGB: (Double, Double, Double) {
        (ArtworkColorSpace.sRGBToLinear(red, power: pow),
         ArtworkColorSpace.sRGBToLinear(green, power: pow),
         ArtworkColorSpace.sRGBToLinear(blue, power: pow))
    }

    static func extract(from data: Data) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            guard let input = CIImage(data: data) else { return nil }
            return extract(from: input)
        }
    }

    static func extract(from cgImage: CGImage) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            extract(from: CIImage(cgImage: cgImage))
        }
    }

    private static func extract(from input: CIImage) -> AlbumArtworkBackdrop? {
        candidates(from: input).max { $0.weight < $1.weight }?.color
    }

    struct Candidate: Sendable {
        let color: AlbumArtworkBackdrop
        let weight: Double

        var chroma: Double {
            max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        }
    }

    static func candidates(from input: CIImage) -> [Candidate] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let scale = min(1, 128 / max(input.extent.width, input.extent.height))
        let reduced = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.kMeans()
        filter.inputImage = reduced
        filter.extent = reduced.extent
        filter.count = 8
        filter.passes = 10
        filter.perceptual = false
        guard let output = filter.outputImage else { return [] }
        let context = imageContext
        var weighted = [Float](repeating: 0, count: 32)
        context.render(output, toBitmap: &weighted, rowBytes: 128,
                       bounds: output.extent, format: .RGBAf, colorSpace: space)
        var colors = [Float](repeating: 0, count: 32)
        context.render(output.settingAlphaOne(in: output.extent), toBitmap: &colors, rowBytes: 128,
                       bounds: output.extent, format: .RGBAf, colorSpace: space)
        return (0..<8).compactMap { cluster in
            let i = cluster * 4
            let weight = Double(weighted[i + 3])
            guard weight > 0 else { return nil }
            let color = AlbumArtworkBackdrop(red: Double(colors[i]), green: Double(colors[i + 1]), blue: Double(colors[i + 2]))
            return Candidate(color: color, weight: weight)
        }
    }
}

actor AlbumArtworkBackdropPreparer {
    static let shared = AlbumArtworkBackdropPreparer(cacheURL: AppStoragePaths.artworkBackdrops)
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
            if let cacheURL, let snapshot = try? AtomicJSONStore.read(Snapshot.self, from: cacheURL),
               snapshot.version == Self.cacheVersion {
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
            if (try? AtomicJSONStore.write(Snapshot(version: Self.cacheVersion, colors: nextPersisted), to: cacheURL)) != nil {
                AppStoragePaths.excludeFromBackup(cacheURL)
                persisted = nextPersisted
            }
        }
        if cacheURL == nil { persisted = nextPersisted }
        cached = nextCache
        return results
    }
}
