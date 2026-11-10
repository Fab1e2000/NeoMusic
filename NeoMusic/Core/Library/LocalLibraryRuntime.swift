import SwiftUI
import CryptoKit

@MainActor @Observable
final class LocalLibraryRuntime {
    private(set) var isScanning = false
    private(set) var status: String?
    private(set) var hasRestoredPlayback = false
    @ObservationIgnored private var onlineResolver: (@MainActor (String) async throws -> PlaybackResource)?
    @ObservationIgnored private var offlineResolver: (@MainActor (String) -> PlaybackResource?)?
    @ObservationIgnored var onLibraryRestored: (() -> Void)?
    @ObservationIgnored var onLibraryPublished: (() -> Void)?

    func configureOfflineResolver(_ resolver: @escaping @MainActor (String) -> PlaybackResource?) {
        offlineResolver = resolver
        if hasRestoredPlayback { configurePlayer() }
    }

    func configureOnlineResolver(_ resolver: @escaping @MainActor (String) async throws -> PlaybackResource) {
        onlineResolver = resolver
        if hasRestoredPlayback { configurePlayer() }
    }

    private func configurePlayer() {
        if onlineResolver == nil, offlineResolver == nil {
            player.configurePlayback(resolveURL: { [weak self, root] id in
                guard !id.hasPrefix("netease:"), self?.failedIDs.contains(id) != true else { return nil }
                let url = root.appending(path: id)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }, persistenceURL: store.appending(path: "playback.json"))
            return
        }
        player.configurePlayback(resolveResource: { [weak self, root] id in
            if let offline = self?.offlineResolver?(id) { return offline }
            if id.hasPrefix("netease:") {
                guard let resolver = self?.onlineResolver else { throw URLError(.userAuthenticationRequired) }
                return try await resolver(id)
            }
            guard self?.failedIDs.contains(id) != true else { throw CocoaError(.fileReadNoSuchFile) }
            let url = root.appending(path: id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return PlaybackResource(url: url)
        }, persistenceURL: store.appending(path: "playback.json"))
    }
    /// Release the initial shelf after restoration or a reported failure; cancellation can retry.
    private(set) var isInitialLibraryReady = false
    private(set) var isInitialPresentationReady = false
    private(set) var isInitialPlaybackReady = false
    private var refreshPending = false
    private var cacheWarning: String?
    private let scanner = LocalMusicScanner()
    private let cache = LocalLibraryTrackCache()
    let root: URL
    private let store: URL
    private let documents: URL
    private var failedIDs: Set<String> = []
    private let songLibrary: SongLibrary
    private let playlistLibrary: PlaylistLibrary
    private let player: NowPlayingModel
    private let favoriteAlbums: LibrarySelectionSet
    private let pinnedAlbums: LibrarySelectionSet
    private let deletedAlbums: LibrarySelectionSet
    private let defaults: UserDefaults
    @ObservationIgnored private let onLocalSongsApplied: @MainActor ([LibrarySongItem]) -> Void
    private var cachedTracks: [LocalTrack] = []

    init(documents: URL = .documentsDirectory,
         store: URL = URL.applicationSupportDirectory.appending(path: "LocalLibrary", directoryHint: .isDirectory),
         songLibrary: SongLibrary, playlistLibrary: PlaylistLibrary, player: NowPlayingModel,
         favoriteAlbums: LibrarySelectionSet, pinnedAlbums: LibrarySelectionSet,
         deletedAlbums: LibrarySelectionSet, defaults: UserDefaults = .standard,
         onLocalSongsApplied: @escaping @MainActor ([LibrarySongItem]) -> Void) {
        self.songLibrary = songLibrary
        self.playlistLibrary = playlistLibrary
        self.player = player
        self.favoriteAlbums = favoriteAlbums
        self.pinnedAlbums = pinnedAlbums
        self.deletedAlbums = deletedAlbums
        self.defaults = defaults
        self.onLocalSongsApplied = onLocalSongsApplied
        self.documents = documents
        self.root = documents.appending(path: "音乐", directoryHint: .isDirectory)
        self.store = store
    }

    var localSongs: [LibrarySongItem] {
        songLibrary.songs.filter { !deletedAlbums.ids.contains($0.albumID) }
    }

    var allSongs: [LibrarySongItem] {
        songLibrary.allSongs.filter { $0.isOnline || !deletedAlbums.ids.contains($0.albumID) }
    }

    static func setFlag(_ id: String, value: Bool, key: String, defaults: UserDefaults = .standard) {
        var ids = Set(defaults.stringArray(forKey: key) ?? [])
        if value { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: key)
    }

    /// Restore persisted local metadata without waiting for the directory scan.
    func restoreCachedState() async {
        guard !hasRestoredPlayback, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try await cache.prepare(documents: documents, store: store)
            try await restoreSavedState()
        } catch is CancellationError {
            // A later foreground refresh can resume the interrupted restoration.
        } catch {
            status = "读取资料库失败：\(error.localizedDescription)"
            isInitialLibraryReady = true
        }
    }

    /// The local shelf can be presented independently of account-owned content.
    func completeInitialPresentation(songs: [LibrarySongItem]) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            playlistLibrary.reconcileOnlineSongs(songs)
            player.reconcileAvailability(songs: songs)
            isInitialPresentationReady = true
        }
        PerformanceDiagnostics.event("LibraryContentPresented")
    }

    /// Online queue and mixed-playlist metadata are exposed only after the saved
    /// account identity has been read; page and home caches are not required.
    func completeInitialPlaybackRestoration(ownerID: String?, songs: [LibrarySongItem]) {
        guard hasRestoredPlayback || player.hasCurrent, !isInitialPlaybackReady else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            playlistLibrary.restoreOnlineIdentity(ownerID: ownerID)
            player.restoreOnlineIdentity(ownerID: ownerID)
            playlistLibrary.reconcileOnlineSongs(songs)
            player.reconcileAvailability(songs: songs)
            isInitialPlaybackReady = true
        }
        PerformanceDiagnostics.event("InitialPlaybackReady")
        PerformanceDiagnostics.restoration("player.ready current=\(player.hasCurrent) count=\(player.queue.count) signedIn=\(ownerID != nil)")
    }

    func refresh() async {
        guard !isScanning else { refreshPending = true; return }
        isScanning = true
        defer { isScanning = false }
        repeat {
            refreshPending = false
            do {
                try await cache.prepare(documents: documents, store: store)
                if !hasRestoredPlayback { try await restoreSavedState() }
                try await refreshFromDisk()
            } catch is CancellationError {
                // Keep the displayed snapshot and retry at the next refresh.
            } catch {
                guard !Task.isCancelled else { return }
                status = "读取资料库失败：\(error.localizedDescription)"
                isInitialLibraryReady = true
            }
        } while refreshPending && !Task.isCancelled
    }

    private func restoreSavedState() async throws {
        let interval = PerformanceDiagnostics.begin("LocalCacheRestore")
        defer { PerformanceDiagnostics.end("LocalCacheRestore", interval) }
        do {
            if let tracks = try await cache.read(from: store.appending(path: "tracks.json")) {
                try Task.checkCancellation()
                PerformanceDiagnostics.event("LocalCacheHit")
                apply(tracks)
            } else {
                PerformanceDiagnostics.event("LocalCacheMiss")
                apply([])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            cacheWarning = "资料库缓存无法读取，已重新扫描：\(error.localizedDescription)"
            apply([])
        }
        try Task.checkCancellation()
        // The one known identity repair must finish before resolving saved references.
        guard !cachedTracks.contains(where: { $0.id.hasPrefix("ents/音乐/") }) else { return }
        try await restoreStores()
        isInitialLibraryReady = true
        PerformanceDiagnostics.event("LocalContentReady")
    }

    private func refreshFromDisk() async throws {
        let reusable = await cache.reusableTracks(cachedTracks, at: store.appending(path: "tracks.json"))
        let result = try await scanner.scan(root: root, previousTracks: reusable)
        try Task.checkCancellation()
        if !hasRestoredPlayback {
            try Self.repairLegacyIdentities(cached: cachedTracks, scanned: result.tracks, store: store, defaults: defaults)
        }
        let failed = Set(result.failures).union(result.tracks.filter { track in
            result.failedDirectoryPaths.contains { path in path.isEmpty || track.id.hasPrefix(path + "/") }
        }.map(\.id))
        migrateAlbumSelections(from: cachedTracks, to: result.tracks)
        let tracks = try await cache.write(result.tracks, to: store.appending(path: "tracks.json"))
        try Task.checkCancellation()
        failedIDs = failed
        if tracks != cachedTracks { apply(tracks) }
        if !hasRestoredPlayback { try await restoreStores() }
        playlistLibrary.reconcileSongs(localSongs, failedIDs: failed, failedDirectories: result.failedDirectoryPaths)
        player.reconcileAvailability(songs: allSongs.filter { !failed.contains($0.id) })
        var messages = result.issues
        if result.unsupportedCount > 0 { messages.insert("跳过 \(result.unsupportedCount) 个不支持的音频文件。", at: 0) }
        status = messages.isEmpty ? cacheWarning : messages.joined(separator: "\n")
        isInitialLibraryReady = true
    }

    private func restoreStores() async throws {
        async let savedPlaylists = cache.restore(PlaylistLibrary.Snapshot.self, from: store.appending(path: "playlists.json"))
        async let savedQueue = cache.restore(NowPlayingModel.SavedQueue.self, from: store.appending(path: "playback.json"))
        let (playlists, queue) = await (savedPlaylists, savedQueue)
        try Task.checkCancellation()
        let songs = localSongs
        playlistLibrary.configurePersistence(url: store.appending(path: "playlists.json"), songs: songs, restoredState: playlists)
        configurePlayer()
        // A chosen queue takes precedence over a delayed restoration. Transport
        // remains available after a read failure; the player suspends automatic
        // persistence until restoration or an explicit replacement succeeds.
        let keepsChosenQueue = player.hasCurrent
        if !keepsChosenQueue {
            guard player.restoreQueue(songs: songs, restoredState: queue) else {
                PerformanceDiagnostics.restoration("queue.read.failed")
                _ = try queue.get()
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        hasRestoredPlayback = true
        PerformanceDiagnostics.restoration("queue.ready current=\(player.hasCurrent) count=\(player.queue.count) keptChosenQueue=\(keepsChosenQueue)")
        onLibraryRestored?()
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for track in new {
                guard let directory = track.albumDirectory, let previous = oldByID[track.id], previous.albumDirectory == nil else { continue }
                let oldID = previous.albumArtist + "\u{001F}" + previous.album
                let newID = "folder:" + directory
                if favoriteAlbums.ids.contains(oldID) { favoriteAlbums.insert(newID) }
                if pinnedAlbums.ids.contains(oldID) { pinnedAlbums.insert(newID) }
                // Preserve deletion of these exact songs; do not hide unrelated tracks now sharing their folder.
                if deletedAlbums.ids.contains(oldID) { Self.setFlag(track.id, value: true, key: "hiddenSongs", defaults: defaults) }
            }
        }
    }

    private func apply(_ tracks: [LocalTrack]) {
        cachedTracks = tracks
        let favorites = Set(defaults.stringArray(forKey: "favoriteSongs") ?? [])
        let pins = Set(defaults.stringArray(forKey: "pinnedSongs") ?? [])
        let hidden = Set(defaults.stringArray(forKey: "hiddenSongs") ?? [])
        let artworkDirectory = store.appending(path: "tracks.json.startup", directoryHint: .isDirectory)
        songLibrary.replace(tracks.filter { !hidden.contains($0.id) }.map { track in
            let url = track.artworkKey.map { artworkDirectory.appending(path: $0 + ".image") }
            return LibrarySongItem(id: track.id, title: track.title, artist: track.artist, album: track.album,
                albumArtist: track.albumArtist, trackNumber: track.trackNumber, artwork: url.map(Artwork.file) ?? .missing,
                albumDirectory: track.albumDirectory, discNumber: track.discNumber ?? 1, artworkURL: url,
                artworkBackdrop: track.artworkBackdrop, duration: Int(track.duration), isPinned: pins.contains(track.id),
                addedOrder: Int(track.addedDate.timeIntervalSince1970), isFavorite: favorites.contains(track.id))
        })
        onLocalSongsApplied(localSongs)
        onLibraryPublished?()
    }
}

/// One metadata index with shared immutable image files; no image bytes are read on a normal launch.
actor LocalLibraryTrackCache {
    private struct Fingerprint: Codable, Equatable {
        let size: Int?
        let modified: Date?
        init(_ url: URL) throws {
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
    private struct SavedColors: Decodable {
        let version: Int
        let colors: [String: AlbumArtworkBackdrop?]
    }
    private var saved: (url: URL, tracks: [LocalTrack])?
    private var backdropPreparer: AlbumArtworkBackdropPreparer?

    func restore<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) -> Result<Value?, Error> {
        do {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
            return .success(try JSONDecoder().decode(type, from: Data(contentsOf: url)))
        } catch { return .failure(error) }
    }

    func prepare(documents: URL, store: URL) throws {
        try Task.checkCancellation()
        _ = try LocalMusicScanner.prepareDirectory(documents: documents)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    }

    func read(from url: URL) async throws -> [LocalTrack]? {
        try Task.checkCancellation()
        saved = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = url.appendingPathExtension("startup")
        // Import the existing lightweight cache once, preserving its image files and colors.
        if let data = try? Data(contentsOf: directory.appending(path: "snapshot.json")),
           let snapshot = try? JSONDecoder().decode(StartupSnapshot.self, from: data),
           snapshot.version == 1, snapshot.source == (try Fingerprint(url)) {
            let colorURL = url.deletingLastPathComponent().appending(path: "artwork-backdrops.json")
            let colors = (try? JSONDecoder().decode(SavedColors.self, from: Data(contentsOf: colorURL)))?.colors ?? [:]
            do {
                let tracks = try snapshot.tracks.map { entry in
                try Task.checkCancellation()
                var track = entry.metadata
                track.artworkKey = entry.artworkKey
                if let key = entry.artworkKey {
                    if let color = colors[key] { track.artworkBackdrop = color }
                    else { track.artworkData = try Data(contentsOf: directory.appending(path: key + ".image")) }
                }
                return track
            }
                return try await externalizeArtwork(tracks, at: url)
            } catch is CancellationError { throw CancellationError() }
            catch { /* The original index still contains artwork if the old sidecar is incomplete. */ }
        }
        let tracks = try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url))
        saved = (url, tracks)
        return try await externalizeArtwork(tracks, at: url)
    }

    /// Missing derived artwork invalidates only the affected tracks during background verification.
    func reusableTracks(_ tracks: [LocalTrack], at url: URL) -> [LocalTrack] {
        let directory = url.appendingPathExtension("startup")
        var available: [String: Bool] = [:]
        return tracks.map { track in
            guard let key = track.artworkKey else { return track }
            let exists = available[key] ?? FileManager.default.fileExists(atPath: directory.appending(path: key + ".image").path)
            available[key] = exists
            var track = track
            if !exists { track.fingerprint = nil }
            return track
        }
    }

    @discardableResult
    func write(_ tracks: [LocalTrack], to url: URL) async throws -> [LocalTrack] {
        let normalized = try await externalizeArtwork(tracks, at: url)
        try Task.checkCancellation()
        if saved?.url != url || saved?.tracks != normalized {
            let data = try JSONEncoder().encode(normalized)
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            saved = (url, normalized)
        }
        // The metadata file is now authoritative. Retain images still referenced by live views.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("startup").appending(path: "snapshot.json"))
        return normalized
    }

    private func externalizeArtwork(_ tracks: [LocalTrack], at url: URL) async throws -> [LocalTrack] {
        try Task.checkCancellation()
        let pending = Dictionary(tracks.compactMap { track in track.artworkData.map { (track.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        guard !pending.isEmpty else { return tracks }
        if backdropPreparer == nil {
            backdropPreparer = AlbumArtworkBackdropPreparer(cacheURL: url.deletingLastPathComponent().appending(path: "artwork-backdrops.json"))
        }
        let colors = try await backdropPreparer!.prepare(pending)
        let directory = url.appendingPathExtension("startup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keys: [Data: String] = [:]
        return try tracks.map { track in
            try Task.checkCancellation()
            guard let data = track.artworkData else { return track }
            var track = track
            let key: String
            if let existing = keys[data] { key = existing }
            else {
                key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let file = directory.appending(path: key + ".image")
                if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                keys[data] = key
            }
            track.artworkData = nil
            track.artworkKey = key
            track.artworkBackdrop = colors[track.id]
            return track
        }
    }
}
