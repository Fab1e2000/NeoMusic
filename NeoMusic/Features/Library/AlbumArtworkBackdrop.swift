import SwiftUI
import CryptoKit

/// The album's opaque sRGB background and the matching system foreground style.
struct AlbumArtworkBackdrop: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var colorScheme: ColorScheme {
        let brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return brightness < 0.58 ? .dark : .light
    }

    /// Runs away from the UI actor; the full artwork is passed to the system analyzer.
    static func extract(from data: Data) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            guard let image = UIImage(data: data), let color = SystemArtworkBackgroundColor(image),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
                  let components = converted.components, components.count >= 3 else { return nil }
            return AlbumArtworkBackdrop(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
        }
    }
}

/// Prepares the exact artwork-derived colors before publishing a library snapshot.
actor AlbumArtworkBackdropPreparer {
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

    func prepare(_ artworkByID: [String: Data]) throws -> [String: AlbumArtworkBackdrop] {
        try Task.checkCancellation()
        if !loaded {
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 {
                persisted = snapshot.colors
            }
            loaded = true
        }
        var nextCache: [Data: (key: String, color: AlbumArtworkBackdrop?)] = [:]
        var nextPersisted: [String: AlbumArtworkBackdrop?] = [:]
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
            if let data = try? JSONEncoder().encode(Snapshot(version: 1, colors: nextPersisted)),
               (try? data.write(to: cacheURL, options: .atomic)) != nil {
                persisted = nextPersisted
            }
        }
        cached = nextCache
        return results
    }
}
