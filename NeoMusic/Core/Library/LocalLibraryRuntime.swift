import SwiftUI
import CryptoKit

@MainActor @Observable
final class LocalLibraryRuntime {
    private(set) var isScanning = false
    private(set) var status: String?
    private var started = false
    /// Release the initial shelf after restoration or a reported failure; cancellation can retry.
    private(set) var isInitialLibraryReady = false
    private var refreshPending = false
    private var cacheWarning: String?
    private let scanner = LocalMusicScanner()
    private let cache = LocalLibraryTrackCache()
    private let artworkBackdrops: AlbumArtworkBackdropPreparer
    let root: URL
    private let store: URL
    private let documents: URL
    private var failedIDs: Set<String> = []
    private let playlistLibrary: PlaylistLibrary
    private let player: NowPlayingModel
    private var cachedTracks: [LocalTrack] = []

    init(documents: URL = .documentsDirectory,
         store: URL = URL.applicationSupportDirectory.appending(path: "LocalLibrary", directoryHint: .isDirectory),
         playlistLibrary: PlaylistLibrary = LocalLibrary.playlistLibrary,
         player: NowPlayingModel = LocalLibrary.player) {
        self.playlistLibrary = playlistLibrary
        self.player = player
        self.documents = documents
        self.root = documents.appending(path: "音乐", directoryHint: .isDirectory)
        self.store = store
        self.artworkBackdrops = AlbumArtworkBackdropPreparer(cacheURL: store.appending(path: "artwork-backdrops.json"))
    }

    static func setFlag(_ id: String, value: Bool, key: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if value { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    func refresh() async {
        guard !isScanning else { refreshPending = true; return }
        isScanning = true
        defer { isScanning = false }
        repeat {
        refreshPending = false
        var initialCache: [LocalTrack]?
        do {
            try await cache.prepare(documents: documents, store: store)
            if !started {
                do {
                    if let tracks = try await cache.read(from: store.appending(path: "tracks.json")) {
                        try Task.checkCancellation()
                        initialCache = tracks
                        cachedTracks = tracks
                        // Existing legacy IDs still need the verified scan repair below.
                        // Otherwise restore the complete shelf before awaiting directory I/O.
                        if !tracks.contains(where: { $0.id.hasPrefix("ents/音乐/") }) {
                            try await apply(tracks)
                            if restoreStores(requireCompleteLibrary: true) {
                                isInitialLibraryReady = true
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    cacheWarning = "资料库缓存无法读取，已重新扫描：\(error.localizedDescription)"
                }
            }
            let result = try await scanner.scan(root: root, previousTracks: cachedTracks)
            try Task.checkCancellation()
            if !started {
                try Self.repairLegacyIdentities(cached: cachedTracks, scanned: result.tracks, store: store)
            }
            // A file that failed decoding still exists: retain its library identity and playlist references.
            let failed = Set(result.failures).union(result.tracks.filter { track in
                result.failedDirectoryPaths.contains { path in path.isEmpty || track.id.hasPrefix(path + "/") }
            }.map(\.id))
            let tracks = result.tracks
            migrateAlbumSelections(from: cachedTracks, to: tracks)
            try await cache.write(tracks, to: store.appending(path: "tracks.json"))
            try Task.checkCancellation()
            if !started || tracks != cachedTracks {
                try await apply(tracks, failedIDs: failed)
            } else {
                failedIDs = failed
            }
            // Resolve persisted identities only after a successful scan, including when the cache is missing.
            if !started {
                restoreStores()
            }
            playlistLibrary.reconcileSongs(LocalLibrary.songs)
            player.reconcileAvailability(songs: LocalLibrary.songs.filter { !failed.contains($0.id) })
            var messages = result.issues
            if result.unsupportedCount > 0 { messages.insert("跳过 \(result.unsupportedCount) 个不支持的音频文件。", at: 0) }
            status = messages.isEmpty ? cacheWarning : messages.joined(separator: "\n")
            isInitialLibraryReady = true
        } catch is CancellationError {
            // Cancellation leaves the current shelf and its readiness unchanged.
        } catch {
            guard !Task.isCancelled else { return }
            if !started, let initialCache {
                // A failed initial refresh may still display its last saved library,
                // but must not resolve or rewrite playlists and playback from that cache.
                do { try await apply(initialCache) }
                catch { return }
            }
            status = "读取资料库失败：\(error.localizedDescription)"
            isInitialLibraryReady = true
        }
        } while refreshPending && !Task.isCancelled
    }

    @discardableResult
    private func restoreStores(requireCompleteLibrary: Bool = false) -> Bool {
        let songs = LocalLibrary.songs
        let playlistsRestored = playlistLibrary.configurePersistence(
            url: store.appending(path: "playlists.json"), songs: songs, requireCompleteLibrary: requireCompleteLibrary)
        if requireCompleteLibrary, !playlistsRestored { return false }
        player.configurePlayback(resolveURL: { [weak self, root] id in
            guard self?.failedIDs.contains(id) != true else { return nil }
            let url = root.appending(path: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }, persistenceURL: store.appending(path: "playback.json"))
        let queueRestored = player.restoreQueue(songs: songs, requireCompleteLibrary: requireCompleteLibrary)
        if requireCompleteLibrary, !queueRestored { return false }
        started = true
        return true
    }

    /// Repairs only the known /var versus /private/var truncation from the first local scanner.
    /// The old cache remains untouched until all stores succeed, so interrupted repairs are retryable.
    static func repairLegacyIdentities(cached: [LocalTrack], scanned: [LocalTrack], store: URL,
                                       defaults: UserDefaults = .standard) throws {
        let oldCounts = Dictionary(grouping: cached, by: \.id)
        let newCounts = Dictionary(grouping: scanned, by: \.id)
        var mapping: [String: String] = [:]
        for (id, tracks) in newCounts where tracks.count == 1 {
            let legacy = "ents/音乐/" + id
            guard oldCounts[legacy]?.count == 1, newCounts[legacy] == nil,
                  oldCounts[id] == nil else { continue }
            mapping[legacy] = id
        }
        guard !mapping.isEmpty else { return }
        func repaired(_ ids: [String]) -> [String] { ids.map { mapping[$0] ?? $0 } }
        // Read and validate both documents before writing either; retain unrelated JSON fields verbatim.
        var writes: [(URL, Data)] = []
        for name in ["playlists.json", "playback.json"] {
            let url = store.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var changed = false
            if name == "playlists.json" {
                guard var playlists = object["playlists"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                for i in playlists.indices {
                    guard let ids = playlists[i]["songs"] as? [String] else { throw CocoaError(.fileReadCorruptFile) }
                    let updated = repaired(ids)
                    if updated != ids { playlists[i]["songs"] = updated; changed = true }
                }
                object["playlists"] = playlists
            } else {
                guard let ids = object["ids"] as? [String] else { throw CocoaError(.fileReadCorruptFile) }
                let updated = repaired(ids)
                if updated != ids { object["ids"] = updated; changed = true }
            }
            if changed { writes.append((url, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))) }
        }
        for (url, data) in writes { try data.write(to: url, options: .atomic) }
        for key in ["favoriteSongs", "pinnedSongs", "hiddenSongs"] {
            guard let ids = defaults.stringArray(forKey: key) else { continue }
            let updated = repaired(ids)
            if updated != ids { defaults.set(updated, forKey: key) }
        }
    }

    func migrateAlbumSelections(from old: [LocalTrack], to new: [LocalTrack]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in new {
            guard let directory = track.albumDirectory, let previous = oldByID[track.id], previous.albumDirectory == nil else { continue }
            let oldID = previous.albumArtist + "\u{001F}" + previous.album
            let newID = "folder:" + directory
            if LocalLibrary.favoriteAlbums.ids.contains(oldID) { LocalLibrary.favoriteAlbums.insert(newID) }
            if LocalLibrary.pinnedAlbums.ids.contains(oldID) { LocalLibrary.pinnedAlbums.insert(newID) }
            // Preserve deletion of these exact songs; do not hide unrelated tracks now sharing their folder.
            if LocalLibrary.deletedAlbums.ids.contains(oldID) { Self.setFlag(track.id, value: true, key: "hiddenSongs") }
        }
    }

    private func apply(_ tracks: [LocalTrack], failedIDs newFailedIDs: Set<String>? = nil) async throws {
        let artworkByID = Dictionary(tracks.compactMap { track in
            track.artworkData.map { (track.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let backdrops = try await artworkBackdrops.prepare(artworkByID)
        try Task.checkCancellation()
        // Publish the cover and its derived appearance together. Opening an album
        // must not display a system-colored frame while its background is computed.
        if let newFailedIDs { failedIDs = newFailedIDs }
        cachedTracks = tracks
        let favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteSongs") ?? [])
        let pins = Set(UserDefaults.standard.stringArray(forKey: "pinnedSongs") ?? [])
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenSongs") ?? [])
        LocalLibrary.songLibrary.replace(tracks.filter { !hidden.contains($0.id) }.map { track in
            let artwork = track.artworkData.flatMap(UIImage.init(data:)).map { Artwork.image(Image(uiImage: $0)) } ?? .missing
            return LibrarySongItem(id: track.id, title: track.title, artist: track.artist, album: track.album,
                albumArtist: track.albumArtist, trackNumber: track.trackNumber, artwork: artwork, albumDirectory: track.albumDirectory, discNumber: track.discNumber ?? 1, artworkData: track.artworkData, artworkBackdrop: backdrops[track.id],
                duration: Int(track.duration), isPinned: pins.contains(track.id),
                addedOrder: Int(track.addedDate.timeIntervalSince1970), isFavorite: favorites.contains(track.id))
        })
        LocalLibrary.downloads.setLocalSongs(LocalLibrary.songs)
    }
}

/// Keep the original track store intact. A disposable startup snapshot avoids
/// decoding the same embedded cover once per song on every process launch.
actor LocalLibraryTrackCache {
    private struct Fingerprint: Codable, Equatable {
        let size: Int?
        let modified: Date?

        init(_ url: URL) throws {
            // URL resource values are cached on the URL instance. Read fresh
            // attributes so an atomic replacement invalidates the startup index.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = attributes[.size] as? Int
            modified = attributes[.modificationDate] as? Date
        }
    }
    private struct StartupTrack: Codable {
        var metadata: LocalTrack
        let artworkKey: String?
    }
    private struct StartupSnapshot: Codable {
        let version: Int
        let source: Fingerprint
        let tracks: [StartupTrack]
    }
    private var saved: (url: URL, tracks: [LocalTrack])?
    private var startupSnapshotIsCurrent = false
    func prepare(documents: URL, store: URL) throws {
        try Task.checkCancellation()
        _ = try LocalMusicScanner.prepareDirectory(documents: documents)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    }

    func read(from url: URL) throws -> [LocalTrack]? {
        try Task.checkCancellation()
        saved = nil
        startupSnapshotIsCurrent = false
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let tracks: [LocalTrack]
        if let restored = try? readStartupSnapshot(for: url) {
            tracks = restored
            startupSnapshotIsCurrent = true
        } else {
            try Task.checkCancellation()
            tracks = try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url))
        }
        try Task.checkCancellation()
        saved = (url, tracks)
        return tracks
    }

    func write(_ tracks: [LocalTrack], to url: URL) throws {
        try Task.checkCancellation()
        if saved?.url != url || saved?.tracks != tracks {
            let data = try JSONEncoder().encode(tracks)
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            saved = (url, tracks)
            startupSnapshotIsCurrent = false
        }
        guard !startupSnapshotIsCurrent else { return }
        do {
            try writeStartupSnapshot(tracks, for: url)
            startupSnapshotIsCurrent = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // An optional acceleration cache must not turn a successful library save into a failure.
        }
    }

    private func readStartupSnapshot(for url: URL) throws -> [LocalTrack] {
        let directory = url.appendingPathExtension("startup")
        let snapshot = try JSONDecoder().decode(StartupSnapshot.self,
            from: Data(contentsOf: directory.appending(path: "snapshot.json")))
        guard snapshot.version == 1, snapshot.source == (try Fingerprint(url)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var artwork: [String: Data] = [:]
        return try snapshot.tracks.map { entry in
            try Task.checkCancellation()
            var track = entry.metadata
            if let key = entry.artworkKey {
                if let data = artwork[key] {
                    track.artworkData = data
                } else {
                    let data = try Data(contentsOf: directory.appending(path: key + ".image"))
                    artwork[key] = data
                    track.artworkData = data
                }
            }
            return track
        }
    }

    private func writeStartupSnapshot(_ tracks: [LocalTrack], for url: URL) throws {
        try Task.checkCancellation()
        let directory = url.appendingPathExtension("startup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keys: [Data: String] = [:]
        let entries = try tracks.map { track -> StartupTrack in
            try Task.checkCancellation()
            var metadata = track
            metadata.artworkData = nil
            var key: String?
            if let data = track.artworkData {
                if let existing = keys[data] {
                    key = existing
                } else {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    try data.write(to: directory.appending(path: digest + ".image"), options: .atomic)
                    keys[data] = digest
                    key = digest
                }
            }
            return StartupTrack(metadata: metadata, artworkKey: key)
        }
        let snapshot = StartupSnapshot(version: 1, source: try Fingerprint(url), tracks: entries)
        let data = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        try data.write(to: directory.appending(path: "snapshot.json"), options: .atomic)
        // Prune only derived covers, after the complete replacement snapshot is committed.
        let filenames = Set(keys.values.map { $0 + ".image" })
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "image" && !filenames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
