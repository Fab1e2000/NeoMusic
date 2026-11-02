import SwiftUI

/// The album's opaque sRGB background and the matching system foreground style.
struct AlbumArtworkBackdrop: Equatable, Sendable {
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
    private var cached: [Data: AlbumArtworkBackdrop?] = [:]
    private let extract: @Sendable (Data) -> AlbumArtworkBackdrop?

    init(extract: @escaping @Sendable (Data) -> AlbumArtworkBackdrop? = { AlbumArtworkBackdrop.extract(from: $0) }) {
        self.extract = extract
    }

    func prepare(_ artworkByID: [String: Data]) throws -> [String: AlbumArtworkBackdrop] {
        try Task.checkCancellation()
        var nextCache: [Data: AlbumArtworkBackdrop?] = [:]
        var results: [String: AlbumArtworkBackdrop] = [:]
        for (id, data) in artworkByID {
            try Task.checkCancellation()
            let backdrop: AlbumArtworkBackdrop?
            if let prepared = nextCache[data] {
                backdrop = prepared
            } else if let prepared = cached[data] {
                backdrop = prepared
            } else {
                backdrop = extract(data)
            }
            try Task.checkCancellation()
            // updateValue keeps a resolved nil entry; subscript assignment would remove it.
            nextCache.updateValue(backdrop, forKey: data)
            if let backdrop { results[id] = backdrop }
        }
        try Task.checkCancellation()
        cached = nextCache
        return results
    }
}
