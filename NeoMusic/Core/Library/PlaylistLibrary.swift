import SwiftUI

struct PlaylistFolder: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var parentID: String?
    var addedOrder = 0
}

@MainActor @Observable
final class PlaylistLibrary {
    private(set) var playlists: [LibraryPlaylistItem]
    private(set) var folders: [PlaylistFolder]
    private(set) var placement: [String: String] = [:]
    private var nextOrder = 1000
    @ObservationIgnored private var songEntriesByID: [String: [(playlistID: String, item: LibrarySongItem)]]?
    private var contents: [String: [LibrarySongItem]] = [:] { didSet { songEntriesByID = nil } }
    private var songAddedAt: [String: Date] = [:]
    private(set) var downloadedSnapshotItems: [LibraryPlaylistItem] = []
    private var downloadedContents: [String: [LibrarySongItem]] = [:]
    private var downloadedOnlineAliases: [String: String] = [:]
    @ObservationIgnored private var offlineSong: (@MainActor (String) -> LibrarySongItem?)?

    func configureOfflineSongs(_ resolver: @escaping @MainActor (String) -> LibrarySongItem?) {
        offlineSong = resolver
        reconcileOfflineAvailability()
    }

    func reconcileOfflineAvailability() {
        _ = transformContents { song in
            if let offline = offlineSong?(song.id) { return offline }
            if song.isOnline, song.onlineOwnerID != restoredOnlineOwnerID { return LibrarySongItem.unavailable(song.id) }
            return song
        }
    }

    @discardableResult
    private func transformContents(includingReadOnly: Bool = true,
                                   matching predicate: (String) -> Bool = { _ in true },
                                   map: (LibrarySongItem) -> LibrarySongItem) -> (changedAny: Bool, changedLocal: Bool) {
        let readOnlyByID = Dictionary(playlists.map { ($0.id, $0.isReadOnly) }, uniquingKeysWith: { first, _ in first })
        var changedAny = false
        var changedLocal = false
        let keys = Array(contents.keys)
        for id in keys {
            guard predicate(id) else { continue }
            let isReadOnly = readOnlyByID[id] ?? true
            if !includingReadOnly && isReadOnly { continue }
            guard let existing = contents[id] else { continue }
            var updated: [LibrarySongItem]?
            for index in existing.indices {
                let current = existing[index]
                let candidate = map(current)
                if candidate != current {
                    if updated == nil { updated = existing }
                    updated?[index] = candidate
                }
            }
            if let updated {
                contents[id] = updated
                changedAny = true
                if readOnlyByID[id] == false { changedLocal = true }
            }
        }
        return (changedAny, changedLocal)
    }

    func replaceDownloadedPlaylists(items: [LibraryPlaylistItem], songs: [String: [LibrarySongItem]],
                                    onlineAliases: [String: String] = [:]) {
        let oldIDs = Set(downloadedSnapshotItems.map(\.id))
        var seen = Set<String>()
        downloadedSnapshotItems = items.filter { seen.insert($0.id).inserted }.map { item in
            var item = item
            item.isDownloadedSnapshot = true
            item.sourceOwnerID = nil
            return item
        }
        downloadedContents = songs
        downloadedOnlineAliases = onlineAliases
        for id in oldIDs where !seen.contains(id) { contents[id] = nil }
        let base = playlists.filter { !oldIDs.contains($0.id) && !$0.isDownloadedSnapshot }
        publishDownloadedPlaylists(onto: base)
    }

    private func publishDownloadedPlaylists(onto base: [LibraryPlaylistItem]) {
        let onlineIDs = Set(base.filter { $0.sourceOwnerID != nil }.map(\.id))
        let visible = downloadedSnapshotItems.filter { item in
            guard let alias = downloadedOnlineAliases[item.id] else { return true }
            return !onlineIDs.contains(alias)
        }
        let updated = base + visible
        if playlists != updated { playlists = updated }
        for item in downloadedSnapshotItems {
            let values = downloadedContents[item.id, default: []]
            if contents[item.id] != values { contents[item.id] = values }
        }
    }
    private(set) var recentMove: RecentMove?
    var pendingDeletion: LibraryPlaylistItem?
    var pendingMove: LibraryPlaylistItem?
    var pendingEdit: LibraryPlaylistItem?
    var pendingAddition: PendingAddition?

    @ObservationIgnored var loadOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var loadMoreOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var completeOnlinePlaylist: (@MainActor (String) async -> Bool)?
    @ObservationIgnored var unsubscribeOnlinePlaylist: (@MainActor (String) -> Void)?
    private(set) var onlineHasMore: Set<String> = []
    private(set) var onlineTrackCounts: [String: Int] = [:]
    private(set) var loadedOnlinePlaylistIDs: Set<String> = []
    private(set) var loadingPlaylistIDs: Set<String> = []
    private(set) var onlineErrors: [String: String] = [:]
    private var onlineOwnerID: String?
    @ObservationIgnored private var restoredOnlineOwnerID: String?
    @ObservationIgnored private var savedOnlineSongs: [String: PlaybackSongSnapshot] = [:]
    @ObservationIgnored private var restoredMetadataNeedsSave = false
    @ObservationIgnored private var restoredMetadataRevision = 0
    private struct OnlinePreference: Codable, Sendable, Equatable {
        var favorite: Bool
        var pinned: Bool
        var folder: String?
        var firstSeen: Date?
        var lastPlayed: Date?
        var retained: RetainedOnlinePlaylist? = nil
    }
    private struct RetainedOnlinePlaylist: Codable, Sendable, Equatable {
        var title: String
        var subtitle: String?
        var artworkFile: URL?
        var songIDs: [String]
    }
    private var onlinePreferences: [String: OnlinePreference] = [:]
    @ObservationIgnored private var preferencesByOwner: [String: [String: OnlinePreference]] = [:]

    func setOnlineHasMore(_ id: String, _ hasMore: Bool, totalCount: Int? = nil) {
        if hasMore { if !onlineHasMore.contains(id) { onlineHasMore.insert(id) } }
        else if onlineHasMore.contains(id) { onlineHasMore.remove(id) }
        if let totalCount, onlineTrackCounts[id] != totalCount { onlineTrackCounts[id] = totalCount }
    }

    func prepareCompleteCollection(_ id: String) async -> Bool {
        guard onlineHasMore.contains(id) else { return true }
        guard let completeOnlinePlaylist else { return false }
        let owner = onlineOwnerID
        let sourceOwner = playlist(id)?.sourceOwnerID
        let completed = await completeOnlinePlaylist(id)
        return completed && !Task.isCancelled && onlineOwnerID == owner
            && playlist(id)?.sourceOwnerID == sourceOwner && !onlineHasMore.contains(id)
    }

    func setExternalCollection(item: LibraryPlaylistItem, songs: [LibrarySongItem], error: String? = nil) {
        guard persistenceURL == nil else { return }
        if let index = playlists.firstIndex(where: { $0.id == item.id }) {
            if playlists[index] != item { playlists[index] = item }
        } else { playlists.append(item) }
        if contents[item.id] != songs { contents[item.id] = songs }
        if onlineErrors[item.id] != error { onlineErrors[item.id] = error }
        if error == nil, !loadedOnlinePlaylistIDs.contains(item.id) { loadedOnlinePlaylistIDs.insert(item.id) }
        else if error != nil, loadedOnlinePlaylistIDs.contains(item.id) { loadedOnlinePlaylistIDs.remove(item.id) }
    }

    func retainOnlinePlaylist(_ item: LibraryPlaylistItem, songs: [LibrarySongItem]) {
        guard let owner = onlineOwnerID, item.sourceOwnerID == owner else { return }
        var artworkFile: URL?
        if case .file(let url) = item.artwork { artworkFile = url }
        let retained = RetainedOnlinePlaylist(title: item.title, subtitle: item.subtitle,
                                             artworkFile: artworkFile, songIDs: songs.map(\.id))
        var preference = onlinePreferences[item.id] ?? OnlinePreference(favorite: item.isFavorite,
            pinned: item.isPinned, folder: nil, firstSeen: item.addedAt ?? Date(), lastPlayed: item.lastPlayedAt)
        preference.retained = retained
        onlinePreferences[item.id] = preference
        if !playlists.contains(where: { $0.id == item.id }) { playlists.append(item) }
        contents[item.id] = songs
        saveOnlinePreferences(force: true)
    }

    func replaceOnlinePlaylists(items: [LibraryPlaylistItem], songs: [String: [LibrarySongItem]], ownerID: String?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            restoreOnlineIdentity(ownerID: ownerID)
            let sameOwner = onlineOwnerID == ownerID
            let previousItems = sameOwner ? Dictionary(uniqueKeysWithValues: playlists.filter { $0.sourceOwnerID == ownerID && $0.isReadOnly }.map { ($0.id, $0) }) : [:]
            if onlineOwnerID != ownerID {
                saveOnlinePreferences()
                onlinePreferences = [:]
                onlineOwnerID = ownerID
                if let ownerID, let saved = preferencesByOwner[ownerID] {
                    onlinePreferences = saved
                } else if let url = onlinePreferencesURL, let data = try? Data(contentsOf: url),
                   let saved = try? JSONDecoder().decode([String: OnlinePreference].self, from: data) { onlinePreferences = saved }
                loadedOnlinePlaylistIDs = []
                loadingPlaylistIDs = []
                onlineErrors = [:]
                onlineHasMore = []
                onlineTrackCounts = [:]
            }
            let oldOnline = Set(playlists.filter { $0.isReadOnly && !$0.isDownloadedSnapshot }.map(\.id))
            var updatedPlacement = placement
            for id in oldOnline { updatedPlacement[id] = nil }
            var updatedPlaylists = playlists.filter { !$0.isReadOnly }
            let discoveredAt = Date()
            var visible = items
            let supplied = Set(items.map(\.id))
            if let ownerID {
                for (id, preference) in onlinePreferences.sorted(by: { $0.key < $1.key }) where !supplied.contains(id) {
                    guard let retained = preference.retained else { continue }
                    let cover: Artwork
                    if let previous = previousItems[id], case .file = previous.artwork { cover = previous.artwork }
                    else { cover = retained.artworkFile.map(Artwork.file) ?? .playlist }
                    visible.append(LibraryPlaylistItem(id: id, title: retained.title, artwork: cover,
                        sourceOwnerID: ownerID, subtitle: retained.subtitle))
                }
            }
            var newOnlineContents: [String: [LibrarySongItem]] = [:]
            var inserted = Set<String>()
            for var item in visible where item.sourceOwnerID == ownerID && ownerID != nil && inserted.insert(item.id).inserted {
                if let preference = onlinePreferences[item.id] {
                    item.addedAt = preference.firstSeen
                    item.lastPlayedAt = preference.lastPlayed
                    item.isFavorite = preference.favorite
                    item.isPinned = preference.pinned
                    if let folder = preference.folder, folders.contains(where: { $0.id == folder }) { updatedPlacement[item.id] = folder }
                }
                if item.addedAt == nil { item.addedAt = discoveredAt }
                updatedPlaylists.append(item)
                let retainedSongs = onlinePreferences[item.id]?.retained.map { retained in
                    (sameOwner ? contents[item.id] : nil) ?? retained.songIDs.map(LibrarySongItem.unavailable)
                }
                newOnlineContents[item.id] = songs[item.id] ?? retainedSongs ?? []
            }
            for id in oldOnline where newOnlineContents[id] == nil {
                contents[id] = nil
            }
            for (id, nextSongs) in newOnlineContents where contents[id] != nextSongs {
                contents[id] = nextSongs
            }
            _ = transformContents(matching: { !oldOnline.contains($0) && newOnlineContents[$0] == nil }) { song in
                if let offline = offlineSong?(song.id) { return offline }
                guard song.isOnline else { return song }
                return song.onlineOwnerID == ownerID ? song : LibrarySongItem.unavailable(song.id)
            }
            publishDownloadedPlaylists(onto: updatedPlaylists)
            if placement != updatedPlacement { placement = updatedPlacement }
            saveOnlinePreferences()
        }
    }

    func updateArtwork(songs: [String: LibrarySongItem], playlists artwork: [String: Artwork] = [:]) {
        if !artwork.isEmpty {
            for index in playlists.indices {
                if let cover = artwork[playlists[index].id], cover != playlists[index].artwork {
                    playlists[index].$artwork.update(cover)
                }
            }
        }
        guard !songs.isEmpty else { return }
        let entries = indexedSongEntries()
        var playlistsByID: [String: LibraryPlaylistItem]?
        var changedLocalContent = false
        for (songID, songReplacement) in songs {
            guard let targets = entries[songID], !targets.isEmpty else { continue }
            let offline = offlineSong?(songID)
            var resolvedOffline: LibrarySongItem?
            if let offline {
                let file: URL?
                if let url = offline.artworkURL { file = url }
                else if case .file(let url) = offline.artwork { file = url }
                else { file = nil }
                if let file, file.isFileURL, FileManager.default.fileExists(atPath: file.path) {
                    resolvedOffline = offline
                }
            }
            let byID = playlistsByID ?? {
                let map = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                playlistsByID = map
                return map
            }()
            let replacement = resolvedOffline ?? songReplacement
            for (id, item) in targets {
                let meta = byID[id]
                let isReadOnly = meta?.isReadOnly ?? false
                guard !item.isOnline || offline != nil || isReadOnly || item.onlineOwnerID == restoredOnlineOwnerID else { continue }
                if item.publishArtwork(from: replacement), meta?.isReadOnly == false, item.isOnline {
                    changedLocalContent = true
                }
            }
        }
        if changedLocalContent { markRestoredMetadataChanged() }
    }

    private func indexedSongEntries() -> [String: [(playlistID: String, item: LibrarySongItem)]] {
        if let songEntriesByID { return songEntriesByID }
        var index: [String: [(playlistID: String, item: LibrarySongItem)]] = [:]
        for (playlistID, items) in contents {
            for item in items {
                index[item.id, default: []].append((playlistID, item))
            }
        }
        songEntriesByID = index
        return index
    }

    var onlineStatus: String?
    var isRefreshingOnline = false
    @ObservationIgnored var retryOnline: (@MainActor () async -> Void)?

    func updateSongFavorites(_ replacements: [String: LibrarySongItem]) {
        guard !replacements.isEmpty else { return }
        let result = transformContents { song in
            guard let replacement = replacements[song.id],
                  song.isFavorite != replacement.isFavorite || song.favoriteAddedAt != replacement.favoriteAddedAt else {
                return song
            }
            var updated = song
            updated.isFavorite = replacement.isFavorite
            updated.favoriteAddedAt = replacement.favoriteAddedAt
            return updated
        }
        if result.changedLocal { markRestoredMetadataChanged() }
    }

    func reconcileOnlineSongs(_ songs: [LibrarySongItem], excludingReadOnly: Bool = false) {
        guard !contents.isEmpty else { return }
        var lookup: [String: LibrarySongItem] = [:]
        for song in songs where song.isOnline && song.onlineOwnerID == restoredOnlineOwnerID {
            if lookup[song.id] == nil { lookup[song.id] = song }
        }
        let result = transformContents(includingReadOnly: !excludingReadOnly) { song in
            if let offline = offlineSong?(song.id) { return offline }
            guard song.isOnline else { return song }
            guard song.onlineOwnerID == restoredOnlineOwnerID else { return LibrarySongItem.unavailable(song.id) }
            return lookup[song.id] ?? song
        }
        if result.changedLocal { markRestoredMetadataChanged() }
    }

    func remapSongReferences(_ replacements: [String: LibrarySongItem]) {
        guard !replacements.isEmpty else { return }
        var changedLocalContent = false
        for (id, existing) in contents {
            let updated = existing.map { replacements[$0.id] ?? $0 }
            guard existing != updated else { continue }
            contents[id] = updated
            if playlist(id)?.isReadOnly == false { changedLocalContent = true }
        }
        for (id, existing) in downloadedContents {
            let updated = existing.map { replacements[$0.id] ?? $0 }
            if existing != updated { downloadedContents[id] = updated }
        }
        for (id, replacement) in replacements where savedOnlineSongs[id] != nil {
            savedOnlineSongs.removeValue(forKey: id)
            if replacement.isOnline, replacement != .unavailable(replacement.id) {
                savedOnlineSongs[replacement.id] = PlaybackSongSnapshot(replacement)
            }
        }
        if changedLocalContent { persist() }
    }

    func persistRestoredMetadata() {
        guard restoredMetadataNeedsSave else {
            saveOnlinePreferences()
            return
        }
        persist()
    }

    private func markRestoredMetadataChanged() {
        restoredMetadataRevision += 1
        restoredMetadataNeedsSave = true
    }

    func restoreOnlineIdentity(ownerID: String?) {
        guard restoredOnlineOwnerID != ownerID else { return }
        captureReferencedOnlineSongs()
        restoredOnlineOwnerID = ownerID
        for playlist in playlists where !playlist.isReadOnly {
            let current = contents[playlist.id, default: []]
            let updated = current.map { song in
                if let offline = offlineSong?(song.id) { return offline }
                guard song.isOnline else { return song }
                guard let ownerID, song.onlineOwnerID == ownerID else { return LibrarySongItem.unavailable(song.id) }
                return song == LibrarySongItem.unavailable(song.id) ? savedOnlineSongs[song.id]?.song ?? song : song
            }
            if current != updated { contents[playlist.id] = updated }
        }
    }

    private func captureReferencedOnlineSongs() {
        let referenced = playlists.filter { !$0.isReadOnly }.flatMap { contents[$0.id, default: []] }.filter(\.isOnline)
        let ids = Set(referenced.map(\.id))
        savedOnlineSongs = savedOnlineSongs.filter { ids.contains($0.key) }
        for song in referenced where song != LibrarySongItem.unavailable(song.id) {
            savedOnlineSongs[song.id] = PlaybackSongSnapshot(song)
        }
    }

    func updateOnlineSongs(playlistID: String, songs: [LibrarySongItem], error: String?, loading: Bool) {
        guard playlist(playlistID)?.sourceOwnerID == onlineOwnerID, playlist(playlistID)?.isReadOnly == true else { return }
        if contents[playlistID] != songs { contents[playlistID] = songs }
        if onlineErrors[playlistID] != error { onlineErrors[playlistID] = error }
        if loading && !loadingPlaylistIDs.contains(playlistID) { loadingPlaylistIDs.insert(playlistID) }
        else if !loading && loadingPlaylistIDs.contains(playlistID) { loadingPlaylistIDs.remove(playlistID) }
        let loaded = !loading && error == nil
        if loaded && !loadedOnlinePlaylistIDs.contains(playlistID) { loadedOnlinePlaylistIDs.insert(playlistID) }
        else if !loaded && loadedOnlinePlaylistIDs.contains(playlistID) { loadedOnlinePlaylistIDs.remove(playlistID) }
    }

    private var onlinePreferencesURL: URL? {
        guard let owner = onlineOwnerID, owner.allSatisfy(\.isNumber), let persistenceURL else { return nil }
        return persistenceURL.deletingLastPathComponent().appendingPathComponent("online-playlist-preferences-\(owner).json", isDirectory: false)
    }

    private func saveOnlinePreferences(force: Bool = false) {
        let previous = onlinePreferences
        for item in playlists where item.sourceOwnerID == onlineOwnerID && onlineOwnerID != nil {
            onlinePreferences[item.id] = OnlinePreference(favorite: item.isFavorite, pinned: item.isPinned, folder: placement[item.id], firstSeen: item.addedAt, lastPlayed: item.lastPlayedAt, retained: onlinePreferences[item.id]?.retained)
        }
        guard let owner = onlineOwnerID else { return }
        preferencesByOwner[owner] = onlinePreferences
        guard let url = onlinePreferencesURL,
              force || previous != onlinePreferences || persistenceFailures[url] != nil else { return }
        enqueuePersistence(onlinePreferences, to: url, failureMessage: "无法保存播放列表整理")
    }

    struct PendingAddition: Identifiable {
        let songs: [LibrarySongItem]
        let id = UUID()
    }

    struct RecentMove: Equatable {
        let folderID: String
        let id = UUID()
    }

    init(playlists: [LibraryPlaylistItem], folders: [PlaylistFolder] = []) {
        self.playlists = playlists
        self.folders = folders
    }

    private var persistenceURL: URL?
    private var loadingPersistence = false
    private(set) var persistenceError: String?
    @ObservationIgnored private let persistence = PlaylistPersistence()
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var needsLocalSnapshot = false
    @ObservationIgnored private var pendingWrites: [URL: PendingWrite] = [:]
    @ObservationIgnored private var persistenceFailures: [URL: String] = [:]
    @ObservationIgnored private var persistenceBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var savedArtwork: [String: (image: Image, data: Data)] = [:]

    private struct PendingWrite {
        let metadataRevision: Int
        let failureMessage: String
        let save: @Sendable (PlaylistPersistence, URL) async throws -> Void
    }

    struct SavedPlaylist: Codable, Sendable {
        let id: String
        let title: String
        let description: String
        let showsOnProfile: Bool
        let isFavorite: Bool
        let isPinned: Bool
        let isSystem: Bool
        let addedOrder: Int
        let lastPlayedOrder: Int
        let updatedOrder: Int
        let artworkData: Data?
        var addedAt: Date? = nil
        var lastPlayedAt: Date? = nil
        var updatedAt: Date? = nil
        let songs: [String]
    }
    struct Snapshot: Codable, Sendable {
        let playlists: [SavedPlaylist]
        let folders: [PlaylistFolder]
        let placement: [String: String]
        let nextOrder: Int
        var onlineSongs: [String: PlaybackSongSnapshot]? = nil
        var songAddedAt: [String: Date]? = nil
    }

    @discardableResult
    func configurePersistence(url: URL, songs: [LibrarySongItem], restoredState: Result<Snapshot?, Error>? = nil) -> Bool {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction) {
            guard persistenceURL == nil else { return true }
            loadingPersistence = true
            defer { loadingPersistence = false }
            do {
                let snapshot: Snapshot?
                if let restoredState { snapshot = try restoredState.get() }
                else { snapshot = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)) : nil }
                if let saved = snapshot {
                    let lookup = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    var restoredArtwork: [String: (image: Image, data: Data)] = [:]
                    playlists = saved.playlists.map { item in
                        let artwork: Artwork
                        if let data = item.artworkData, let uiImage = UIImage(data: data) {
                            let image = Image(uiImage: uiImage)
                            restoredArtwork[item.id] = (image, data)
                            artwork = .image(image)
                        } else { artwork = item.isSystem ? .favorites : .playlist }
                        return LibraryPlaylistItem(id: item.id, title: item.title, artwork: artwork,
                            description: item.description, showsOnProfile: item.showsOnProfile,
                            isFavorite: item.isFavorite, isPinned: item.isPinned, isSystem: item.isSystem,
                            addedOrder: item.addedOrder, lastPlayedOrder: item.lastPlayedOrder, updatedOrder: item.updatedOrder, addedAt: item.addedAt, lastPlayedAt: item.lastPlayedAt, updatedAt: item.updatedAt)
                    }
                    folders = saved.folders
                    placement = saved.placement
                    nextOrder = saved.nextOrder
                    songAddedAt = saved.songAddedAt ?? [:]
                    let referencedIDs = Set(saved.playlists.flatMap(\.songs))
                    savedOnlineSongs = (saved.onlineSongs ?? [:]).filter {
                        referencedIDs.contains($0.key) && $0.key == $0.value.id && $0.value.onlineOwnerID != nil
                    }
                    contents = Dictionary(saved.playlists.map { item in
                        (item.id, item.songs.map { id in
                            if let offline = offlineSong?(id) { return offline }
                            let song = lookup[id] ?? LibrarySongItem.unavailable(id)
                            guard song.isOnline else { return song }
                            guard song.onlineOwnerID == restoredOnlineOwnerID else { return LibrarySongItem.unavailable(id) }
                            return lookup[id] ?? savedOnlineSongs[id]?.song ?? song
                        })
                    }, uniquingKeysWith: { first, _ in first })
                    savedArtwork = restoredArtwork
                }
                publishDownloadedPlaylists(onto: playlists.filter { !$0.isDownloadedSnapshot })
                persistenceURL = url
                persistenceError = nil
                return true
            } catch {
                persistenceError = "无法读取播放列表：\(error.localizedDescription)"
                return false
            }
        }
    }

    func reconcileSongs(_ songs: [LibrarySongItem], failedIDs: Set<String> = [], failedDirectories: [String] = []) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let lookup = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var removedReferences = false
            for id in contents.keys {
                let previous = contents[id, default: []]
                let updated = previous.compactMap { song in
                    if let offline = offlineSong?(song.id) { return offline }
                    if song.isOnline {
                        guard song.onlineOwnerID == restoredOnlineOwnerID else { return LibrarySongItem.unavailable(song.id) }
                        return lookup[song.id] ?? song
                    }
                    return lookup[song.id] ?? (failedIDs.contains(song.id) || failedDirectories.contains {
                        $0.isEmpty || song.id.hasPrefix($0 + "/")
                    } ? song : nil)
                }
                if previous.map(\.id) != updated.map(\.id) { removedReferences = true }
                if updated != previous { contents[id] = updated }
            }
            if removedReferences { persist() }
        }
    }

    private func persist() {
        guard !loadingPersistence, persistenceURL != nil else { return }
        saveOnlinePreferences()
        markRestoredMetadataChanged()
        needsLocalSnapshot = true
        startPersistence()
    }

    private func saveLocalSnapshot(to url: URL) {
        captureReferencedOnlineSongs()
        var nextArtwork: [String: (image: Image, data: Data)] = [:]
        let items = playlists.filter { !$0.isReadOnly }.map { item -> SavedPlaylist in
            let data: Data?
            if case .image(let image) = item.artwork {
                if let cached = savedArtwork[item.id], cached.image == image {
                    data = cached.data
                } else {
                    let renderer = ImageRenderer(content: image.resizable().scaledToFill().frame(width: 512, height: 512).clipped())
                    data = renderer.uiImage?.pngData()
                }
                if let data { nextArtwork[item.id] = (image, data) }
            } else { data = nil }
            return SavedPlaylist(id: item.id, title: item.title, description: item.description,
                showsOnProfile: item.showsOnProfile, isFavorite: item.isFavorite, isPinned: item.isPinned,
                isSystem: item.isSystem, addedOrder: item.addedOrder, lastPlayedOrder: item.lastPlayedOrder,
                updatedOrder: item.updatedOrder, artworkData: data, addedAt: item.addedAt, lastPlayedAt: item.lastPlayedAt, updatedAt: item.updatedAt, songs: contents[item.id, default: []].map(\.id))
        }
        let presentSongs = Set(items.flatMap(\.songs))
        let localPlaylistIDs = Set(items.map(\.id))
        let snapshot = Snapshot(playlists: items, folders: folders, placement: placement.filter { localPlaylistIDs.contains($0.key) },
                                nextOrder: nextOrder, onlineSongs: savedOnlineSongs, songAddedAt: songAddedAt.filter { presentSongs.contains($0.key) })
        savedArtwork = nextArtwork
        enqueuePersistence(snapshot, to: url, failureMessage: "无法保存播放列表")
    }

    private func enqueuePersistence<Value: Encodable & Sendable>(_ value: Value, to url: URL, failureMessage: String) {
        pendingWrites[url] = PendingWrite(metadataRevision: restoredMetadataRevision, failureMessage: failureMessage) {
            try await $0.save(value, to: $1)
        }
        startPersistence()
    }

    private func startPersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task {
            while needsLocalSnapshot || !pendingWrites.isEmpty {
                if needsLocalSnapshot, let url = persistenceURL {
                    needsLocalSnapshot = false
                    saveLocalSnapshot(to: url)
                }
                guard let url = pendingWrites.keys.min(by: { $0.path < $1.path }),
                      let write = pendingWrites.removeValue(forKey: url) else { break }
                do {
                    try await write.save(persistence, url)
                    persistenceFailures[url] = nil
                    if url == persistenceURL, write.metadataRevision == restoredMetadataRevision {
                        restoredMetadataNeedsSave = false
                    }
                } catch {
                    persistenceFailures[url] = "\(write.failureMessage)：\(error.localizedDescription)"
                }
                persistenceError = persistenceFailures.sorted { $0.key.path < $1.key.path }.first?.value
            }
            persistenceTask = nil
        }
    }

    func flushPersistence() async {
        while let task = persistenceTask { await task.value }
    }

    func saveForBackground() {
        if persistenceBackgroundTask == .invalid {
            persistenceBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save playlists") { [weak self] in
                self?.endPersistenceBackgroundTask()
            }
        }
        persistRestoredMetadata()
        Task {
            await flushPersistence()
            endPersistenceBackgroundTask()
        }
    }

    private func endPersistenceBackgroundTask() {
        guard persistenceBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(persistenceBackgroundTask)
        persistenceBackgroundTask = .invalid
    }

    func playlist(_ id: String) -> LibraryPlaylistItem? {
        playlists.first { $0.id == id } ?? downloadedSnapshotItems.first { $0.id == id }
    }
    func songs(in id: String) -> [LibrarySongItem] { contents[id] ?? [] }

    func recentlyAddedSongs() -> [String: (song: LibrarySongItem, addedAt: Date)] {
        guard !songAddedAt.isEmpty else { return [:] }
        var songs: [String: (song: LibrarySongItem, addedAt: Date)] = [:]
        for playlist in playlists where !playlist.isSystem {
            for song in contents[playlist.id, default: []] {
                if let date = songAddedAt[song.id] { songs[song.id] = (song, date) }
            }
        }
        return songs
    }

    func containedSong(_ id: String) -> LibrarySongItem? {
        for songs in contents.values {
            if let song = songs.first(where: { $0.id == id }) { return song }
        }
        return nil
    }

    @discardableResult
    func addSongs(_ songs: [LibrarySongItem], to id: String) -> Int {
        defer { persist() }
        guard canDelete(id) else { return 0 }
        var current = contents[id] ?? []
        var known = Set(current.map(\.id))
        let addedAt = Date()
        for song in songs where known.insert(song.id).inserted {
            current.append(song)
            songAddedAt[song.id] = addedAt
        }
        let added = current.count - contents[id, default: []].count
        guard added > 0 else { return 0 }
        contents[id] = current
        markUpdated(id)
        return added
    }

    func displayArtwork(of playlist: LibraryPlaylistItem) -> Artwork {
        if case .playlist = playlist.artwork, let first = contents[playlist.id]?.first { return first.artwork }
        return playlist.artwork
    }

    func removeSongsEverywhere(_ songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        var changed = false
        let readOnlyIDs = Set((playlists + downloadedSnapshotItems).filter(\.isReadOnly).map(\.id))
        for (id, songs) in contents where !readOnlyIDs.contains(id) {
            let remaining = songs.filter { !songIDs.contains($0.id) }
            guard remaining.count != songs.count else { continue }
            contents[id] = remaining
            changed = true
            markUpdated(id)
        }
        if changed { persist() }
    }

    func removeSong(_ songID: String, from id: String) {
        defer { persist() }
        guard canDelete(id), contents[id]?.contains(where: { $0.id == songID }) == true else { return }
        contents[id]?.removeAll { $0.id == songID }
        markUpdated(id)
    }

    func renamePlaylist(_ id: String, to name: String) {
        defer { persist() }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, canDelete(id), let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = title
        markUpdated(id)
    }

    func savePlaylist(_ id: String, title: String, description: String, showsOnProfile: Bool,
                      artwork: Artwork, songs: [LibrarySongItem]) {
        defer { persist() }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canDelete(id), let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = name
        playlists[index].description = description
        playlists[index].showsOnProfile = showsOnProfile
        playlists[index].artwork = artwork
        var seen = Set<String>()
        contents[id] = songs.filter { seen.insert($0.id).inserted }
        markUpdated(id)
    }

    func reorderSongs(in id: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        defer { persist() }
        guard canDelete(id), var songs = contents[id],
              offsets.allSatisfy({ songs.indices.contains($0) }),
              (0...songs.count).contains(destination) else { return }
        songs.move(fromOffsets: offsets, toOffset: destination)
        contents[id] = songs
        markUpdated(id)
    }

    func toggleFavorite(_ id: String) {
        defer { persist() }
        guard let index = playlists.firstIndex(where: { $0.id == id }), !playlists[index].isSystem else { return }
        playlists[index].isFavorite.toggle()
    }

    func togglePin(_ id: String) {
        defer { persist() }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isPinned.toggle()
    }

    func markPlayed(_ id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].lastPlayedAt = Date()
        nextOrder += 1
        playlists[index].lastPlayedOrder = nextOrder
        if playlists[index].sourceOwnerID != nil { saveOnlinePreferences() }
        else { persist() }
    }

    private func markUpdated(_ id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        nextOrder += 1
        playlists[index].updatedOrder = nextOrder
        playlists[index].updatedAt = Date()
    }

    func folder(_ id: String) -> PlaylistFolder? { folders.first { $0.id == id } }
    func folders(in parentID: String?) -> [PlaylistFolder] { folders.filter { $0.parentID == parentID } }
    func playlists(in folderID: String?) -> [LibraryPlaylistItem] { playlists.filter { placement[$0.id] == folderID } }
    func folderID(of playlistID: String) -> String? { placement[playlistID] }

    func playlistCount(in folderID: String) -> Int { playlists(in: folderID).count }

    @discardableResult
    func createPlaylist(named name: String, artwork: Artwork, in folderID: String?) -> LibraryPlaylistItem? {
        defer { persist() }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        nextOrder += 1
        let playlist = LibraryPlaylistItem(id: UUID().uuidString, title: title, artwork: artwork,
                                          addedOrder: nextOrder, updatedOrder: nextOrder, addedAt: Date(), updatedAt: Date())
        playlists.append(playlist)
        placement[playlist.id] = folderID
        return playlist
    }

    @discardableResult
    func createFolder(named name: String, in parentID: String?) -> PlaylistFolder {
        defer { persist() }
        nextOrder += 1
        let folder = PlaylistFolder(id: UUID().uuidString, name: name, parentID: parentID, addedOrder: nextOrder)
        folders.append(folder)
        return folder
    }

    func move(playlistID: String, to folderID: String?) {
        defer { persist() }
        guard placement[playlistID] != folderID else { return }
        placement[playlistID] = folderID
        recentMove = folderID.map { RecentMove(folderID: $0) }
    }

    func clearRecentMove(_ move: RecentMove) {
        if recentMove == move { recentMove = nil }
    }

    func canDelete(_ playlistID: String) -> Bool {
        playlists.contains { $0.id == playlistID && !$0.isSystem && !$0.isReadOnly }
    }

    func canUnsubscribe(_ playlistID: String) -> Bool {
        playlists.contains { $0.id == playlistID && $0.isSubscribed }
    }

    func deletePlaylist(_ id: String) {
        if playlist(id)?.isSubscribed == true {
            unsubscribeOnlinePlaylist?(id)
            return
        }
        defer { persist() }
        guard canDelete(id) else { return }
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }

    func releaseRetainedOnlinePlaylist(_ id: String) {
        let hadPreference = onlinePreferences.removeValue(forKey: id) != nil
        if hadPreference { saveOnlinePreferences(force: true) }
        guard playlist(id)?.isReadOnly == true else { return }
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }

    func deleteFolder(_ id: String) {
        defer { persist() }
        let removed = Set(folders.map(\.id).filter { isDescendant($0, of: id) })
        let contained = Set(placement.filter { removed.contains($0.value) }.map(\.key))
        playlists.removeAll { contained.contains($0.id) && !$0.isSystem && !$0.isReadOnly }
        for playlistID in contained {
            placement[playlistID] = nil
            if !playlists.contains(where: { $0.id == playlistID }) { contents[playlistID] = nil }
        }
        folders.removeAll { removed.contains($0.id) }
    }

    func renameFolder(_ id: String, to name: String) {
        defer { persist() }
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    func move(folderID: String, to parentID: String?) {
        defer { persist() }
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              !(parentID.map { isDescendant($0, of: folderID) } ?? false) else { return }
        folders[index].parentID = parentID
    }

    func isDescendant(_ id: String, of ancestorID: String) -> Bool {
        var current: String? = id
        while let value = current {
            if value == ancestorID { return true }
            current = folder(value)?.parentID
        }
        return false
    }
}
