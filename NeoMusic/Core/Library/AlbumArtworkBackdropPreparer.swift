import FrontAMCore
import Foundation
import CryptoKit

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
