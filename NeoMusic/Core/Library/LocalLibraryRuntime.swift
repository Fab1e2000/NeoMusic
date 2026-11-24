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
                guard !OnlineSongIdentity.hasReservedPrefix(id), self?.failedIDs.contains(id) != true else { return nil }
                let url = root.appending(path: id)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }, persistenceURL: store.appending(path: "playback.json"))
            return
        }
        player.configurePlayback(resolveResource: { [weak self, root] id in
            if let offline = self?.offlineResolver?(id) { return offline }
            if OnlineSongIdentity.hasReservedPrefix(id) {
                guard let resolver = self?.onlineResolver else { throw URLError(.userAuthenticationRequired) }
                return try await resolver(id)
            }
            guard self?.failedIDs.contains(id) != true else { throw CocoaError(.fileReadNoSuchFile) }
            let url = root.appending(path: id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return PlaybackResource(url: url)
        }, persistenceURL: store.appending(path: "playback.json"))
    }
    private(set) var isInitialLibraryReady = false
    private(set) var isInitialPresentationReady = false
    private(set) var isInitialPlaybackReady = false
    private var refreshPending = false
    private var pendingImports: Set<String> = []
    private var cacheWarning: String?
    private let scanner = LocalMusicScanner()
    private let cache: LocalLibraryTrackCache
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
         store: URL = AppStoragePaths.library,
         songLibrary: SongLibrary, playlistLibrary: PlaylistLibrary, player: NowPlayingModel,
         favoriteAlbums: LibrarySelectionSet, pinnedAlbums: LibrarySelectionSet,
         deletedAlbums: LibrarySelectionSet, defaults: UserDefaults = .standard,
         backdropPreparer: AlbumArtworkBackdropPreparer = .shared,
         onLocalSongsApplied: @escaping @MainActor ([LibrarySongItem]) -> Void) {
        self.songLibrary = songLibrary
        self.playlistLibrary = playlistLibrary
        self.player = player
        self.favoriteAlbums = favoriteAlbums
        self.pinnedAlbums = pinnedAlbums
        self.deletedAlbums = deletedAlbums
        self.defaults = defaults
        self.cache = LocalLibraryTrackCache(backdropPreparer: backdropPreparer)
        self.onLocalSongsApplied = onLocalSongsApplied
        self.documents = documents
        self.root = AppStoragePaths.musicDirectory(in: documents)
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

    func restoreCachedState() async {
        guard !hasRestoredPlayback, !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            if !pendingImports.isEmpty { Task { await self.importPendingFiles() } }
        }
        do {
            try await cache.prepare(documents: documents, store: store)
            try await restoreSavedState()
        } catch is CancellationError {
        } catch {
            AppLogger.failure(AppLogger.library, "library.startup.restore", error: error)
            status = "读取资料库失败：\(error.localizedDescription)"
            isInitialLibraryReady = true
        }
    }

    func completeInitialPresentation(songs: [LibrarySongItem]) {
        playlistLibrary.reconcileOnlineSongs(songs)
        player.reconcileAvailability(songs: songs)
        isInitialPresentationReady = true
        PerformanceDiagnostics.event("LibraryContentPresented")
    }

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
        defer {
            isScanning = false
            if !pendingImports.isEmpty { Task { await self.importPendingFiles() } }
        }
        repeat {
            refreshPending = false
            do {
                try await cache.prepare(documents: documents, store: store)
                if !hasRestoredPlayback { try await restoreSavedState() }
                try await refreshFromDisk()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.failure(AppLogger.library, "library.refresh.failed", error: error)
                status = "读取资料库失败：\(error.localizedDescription)"
                isInitialLibraryReady = true
            }
        } while refreshPending && !Task.isCancelled
    }

    func removeMissingFiles(_ paths: [String]) async {
        for path in paths { pendingImports.insert(path) }
        await importPendingFiles()
    }

    func importFile(_ path: String) async {
        pendingImports.insert(path)
        await importPendingFiles()
    }

    private func importPendingFiles() async {
        guard !isScanning, !pendingImports.isEmpty else { return }
        isScanning = true
        var succeeded = false
        let paths = pendingImports
        pendingImports.subtract(paths)
        defer {
            isScanning = false
            if refreshPending { Task { await self.refresh() } }
            else if succeeded && !pendingImports.isEmpty { Task { await self.importPendingFiles() } }
        }
        do {
            try await cache.prepare(documents: documents, store: store)
            if !hasRestoredPlayback { try await restoreSavedState() }
            let existing = paths.map { root.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let result = try await scanner.scan(root: root, files: existing)
            try Task.checkCancellation()
            let imported = Set(result.tracks.map(\.id))
            let absent = Set(paths.filter { !FileManager.default.fileExists(atPath: root.appending(path: $0).path) })
            let merged = cachedTracks.filter { !imported.contains($0.id) && !absent.contains($0.id) } + result.tracks
            let tracks = try await cache.write(merged, to: store.appending(path: "tracks.json"))
            try Task.checkCancellation()
            failedIDs.subtract(imported.union(absent))
            failedIDs.formUnion(result.failures)
            if tracks != cachedTracks { apply(tracks) }
            playlistLibrary.reconcileSongs(localSongs, failedIDs: failedIDs)
            player.reconcileAvailability(songs: allSongs.filter { !failedIDs.contains($0.id) })
            if !result.issues.isEmpty { status = result.issues.joined(separator: "\n") }
            succeeded = true
        } catch {
            AppLogger.failure(AppLogger.library, "library.import.failed", error: error)
            pendingImports.formUnion(paths)
            status = "读取下载文件失败：\(error.localizedDescription)"
            isScanning = false
            return
        }
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
            AppLogger.failure(AppLogger.library, "library.cache.rebuild", error: error)
            cacheWarning = "资料库缓存无法读取，已重新扫描：\(error.localizedDescription)"
            apply([])
        }
        try Task.checkCancellation()
        try await restoreStores()
        isInitialLibraryReady = true
        PerformanceDiagnostics.event("LocalContentReady")
    }

    private func refreshFromDisk() async throws {
        let reusable = await cache.reusableTracks(cachedTracks, at: store.appending(path: "tracks.json"))
        let result = try await scanner.scan(root: root, previousTracks: reusable)
        try Task.checkCancellation()
        let failed = Set(result.failures).union(result.tracks.filter { track in
            result.failedDirectoryPaths.contains { path in path.isEmpty || track.id.hasPrefix(path + "/") }
        }.map(\.id))
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
        async let savedQueue = cache.restoreQueue(from: store.appending(path: "playback.json"))
        let (playlists, queue) = await (savedPlaylists, savedQueue)
        try Task.checkCancellation()
        let songs = localSongs
        playlistLibrary.configurePersistence(url: store.appending(path: "playlists.json"), songs: songs, restoredState: playlists)
        configurePlayer()
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

    private func apply(_ tracks: [LocalTrack]) {
        cachedTracks = tracks
        let favorites = Set(defaults.stringArray(forKey: AppDefaultsKey.favoriteSongs) ?? [])
        let pins = Set(defaults.stringArray(forKey: AppDefaultsKey.pinnedSongs) ?? [])
        let hidden = Set(defaults.stringArray(forKey: AppDefaultsKey.hiddenSongs) ?? [])
        let artworkDirectory = store.appending(path: "tracks.json.startup", directoryHint: .isDirectory)
        songLibrary.replace(tracks.filter { !hidden.contains($0.id) }.map { track in
            let url = track.artworkKey.map { artworkDirectory.appending(path: $0 + ".image") }
            return LibrarySongItem(id: track.id, title: track.title, artist: track.artist, album: track.album,
                albumArtist: track.albumArtist, trackNumber: track.trackNumber, artwork: url.map(Artwork.file) ?? .missing,
                albumDirectory: track.albumDirectory, discNumber: track.discNumber ?? 1, artworkURL: url,
                artworkBackdrop: track.artworkBackdrop, duration: Int(track.duration), isPinned: pins.contains(track.id),
                addedOrder: Int(track.addedDate.timeIntervalSince1970), isFavorite: favorites.contains(track.id), year: track.year)
        })
        onLocalSongsApplied(localSongs)
        onLibraryPublished?()
    }
}

actor LocalLibraryTrackCache {
    private var saved: (url: URL, tracks: [LocalTrack])?
    private let backdropPreparer: AlbumArtworkBackdropPreparer

    init(backdropPreparer: AlbumArtworkBackdropPreparer = AlbumArtworkBackdropPreparer()) {
        self.backdropPreparer = backdropPreparer
    }

    func restoreQueue(from url: URL) -> Result<NowPlayingModel.SavedQueue?, Error> {
        Result { try Task.checkCancellation(); return try PlaybackQueuePersistence.load(from: url) }
    }

    func restore<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) -> Result<Value?, Error> {
        Result { try AtomicJSONStore.read(type, from: url) }
    }

    func prepare(documents: URL, store: URL) throws {
        try Task.checkCancellation()
        _ = try LocalMusicScanner.prepareDirectory(documents: documents)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    }

    func read(from url: URL) async throws -> [LocalTrack]? {
        try Task.checkCancellation()
        saved = nil
        guard let tracks = try AtomicJSONStore.read([LocalTrack].self, from: url) else { return nil }
        saved = (url, tracks)
        return try await externalizeArtwork(tracks, at: url)
    }

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
            try AtomicJSONStore.write(normalized, to: url)
            saved = (url, normalized)
        }
        return normalized
    }

    private func externalizeArtwork(_ tracks: [LocalTrack], at url: URL) async throws -> [LocalTrack] {
        try Task.checkCancellation()
        var pending = Dictionary(tracks.compactMap { track in track.artworkData.map { (track.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let artworkKeys = Set(tracks.compactMap(\.artworkKey))
        guard !pending.isEmpty || !artworkKeys.isEmpty else { return tracks }
        let directory = url.appendingPathExtension("startup")
        let restoredColors = try await backdropPreparer.cachedColors(for: artworkKeys)
        var restoredArtwork: [String: Data] = [:]
        for key in artworkKeys where restoredColors.index(forKey: key) == nil {
            try Task.checkCancellation()
            restoredArtwork[key] = try? Data(contentsOf: directory.appending(path: key + ".image"))
        }
        for track in tracks where track.artworkData == nil {
            try Task.checkCancellation()
            if let key = track.artworkKey, let data = restoredArtwork[key] { pending[track.id] = data }
        }
        let colors = try await backdropPreparer.prepareAdditionalArtwork(pending)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keys: [Data: String] = [:]
        return try tracks.map { track in
            try Task.checkCancellation()
            var track = track
            guard let data = pending[track.id] else {
                if let key = track.artworkKey, let restored = restoredColors[key] {
                    track.artworkBackdrop = restored
                }
                return track
            }
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
