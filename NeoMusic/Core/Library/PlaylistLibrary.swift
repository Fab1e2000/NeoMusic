import SwiftUI

struct PlaylistFolder: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var parentID: String?
    var addedOrder = 0
}

@MainActor @Observable
final class PlaylistLibrary {
    var playlists: [LibraryPlaylistItem]
    private(set) var folders: [PlaylistFolder]
    var placement: [String: String] = [:]
    private var nextOrder = 1000
    @ObservationIgnored private var songEntriesByID: [String: [(playlistID: String, item: LibrarySongItem)]]?
    var contents: [String: [LibrarySongItem]] = [:] { didSet { songEntriesByID = nil } }
    private var songAddedAt: [String: Date] = [:]
    var downloadedSnapshotItems: [LibraryPlaylistItem] = []
    var downloadedContents: [String: [LibrarySongItem]] = [:]
    var downloadedOnlineAliases: [String: String] = [:]
    @ObservationIgnored var offlineSong: (@MainActor (String) -> LibrarySongItem?)?

    private let presentation = PlaylistLibraryPresentation()
    private(set) var recentMove: RecentMove? {
        get { presentation.recentMove }
        set { presentation.recentMove = newValue }
    }
    var pendingDeletion: LibraryPlaylistItem? {
        get { presentation.pendingDeletion }
        set { presentation.pendingDeletion = newValue }
    }
    var pendingMove: LibraryPlaylistItem? {
        get { presentation.pendingMove }
        set { presentation.pendingMove = newValue }
    }
    var pendingEdit: LibraryPlaylistItem? {
        get { presentation.pendingEdit }
        set { presentation.pendingEdit = newValue }
    }
    var pendingAddition: PendingAddition? {
        get { presentation.pendingAddition }
        set { presentation.pendingAddition = newValue }
    }

    @ObservationIgnored var loadOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var loadMoreOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var completeOnlinePlaylist: (@MainActor (String) async -> Bool)?
    @ObservationIgnored var unsubscribeOnlinePlaylist: (@MainActor (String) -> Void)?
    var receivedPlaylistDetails: Set<String> = []
    var onlineHasMore: Set<String> = []
    var onlineTrackCounts: [String: Int] = [:]
    var loadedOnlinePlaylistIDs: Set<String> = []
    var loadingPlaylistIDs: Set<String> = []
    var onlineErrors: [String: String] = [:]
    var onlineOwnerID: String?
    @ObservationIgnored var restoredOnlineOwnerID: String?
    @ObservationIgnored var savedOnlineSongs: [String: PlaybackSongSnapshot] = [:]
    @ObservationIgnored var restoredMetadataNeedsSave = false
    @ObservationIgnored var restoredMetadataRevision = 0
    struct OnlinePreference: Codable, Sendable, Equatable {
        var favorite: Bool
        var pinned: Bool
        var folder: String?
        var firstSeen: Date?
        var lastPlayed: Date?
        var retained: RetainedOnlinePlaylist? = nil
    }
    struct RetainedOnlinePlaylist: Codable, Sendable, Equatable {
        var title: String
        var subtitle: String?
        var artworkFile: URL?
        var songIDs: [String]
    }
    var onlinePreferences: [String: OnlinePreference] = [:]
    @ObservationIgnored var preferencesByOwner: [String: [String: OnlinePreference]] = [:]

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

    init(playlists: [LibraryPlaylistItem], folders: [PlaylistFolder] = []) {
        self.playlists = playlists
        self.folders = folders
    }

    var persistenceURL: URL?
    private var loadingPersistence = false
    private(set) var persistenceError: String?
    @ObservationIgnored private let persistenceQueue = BackgroundTaskPersistenceQueue()
    @ObservationIgnored private var needsLocalSnapshot = false
    @ObservationIgnored private var pendingWrites: [URL: PendingWrite] = [:]
    @ObservationIgnored var persistenceFailures: [URL: String] = [:]
    @ObservationIgnored private var savedArtwork: [String: (image: Image, data: Data)] = [:]

    private struct PendingWrite {
        let metadataRevision: Int
        let failureMessage: String
        let save: @Sendable (URL) async throws -> Void
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
                else { snapshot = try AtomicJSONStore.read(Snapshot.self, from: url) }
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
                AppLogger.failure(AppLogger.library, "playlist.snapshot.restore", error: error)
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

    func persist() {
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

    func enqueuePersistence<Value: Encodable & Sendable>(_ value: Value, to url: URL, failureMessage: String) {
        pendingWrites[url] = PendingWrite(metadataRevision: restoredMetadataRevision, failureMessage: failureMessage) {
            try await AtomicJSONStore.writeInBackground(value, to: $0)
        }
        startPersistence()
    }

    private func startPersistence() {
        persistenceQueue.startIfIdle { [self] in
            while needsLocalSnapshot || !pendingWrites.isEmpty {
                if needsLocalSnapshot, let url = persistenceURL {
                    needsLocalSnapshot = false
                    saveLocalSnapshot(to: url)
                }
                guard let url = pendingWrites.keys.min(by: { $0.path < $1.path }),
                      let write = pendingWrites.removeValue(forKey: url) else { break }
                do {
                    try await write.save(url)
                    persistenceFailures[url] = nil
                    if url == persistenceURL, write.metadataRevision == restoredMetadataRevision {
                        restoredMetadataNeedsSave = false
                    }
                } catch {
                    AppLogger.failure(AppLogger.library, "playlist.snapshot.write", error: error)
                    persistenceFailures[url] = "\(write.failureMessage)：\(error.localizedDescription)"
                }
                persistenceError = persistenceFailures.sorted { $0.key.path < $1.key.path }.first?.value
            }
        }
    }

    func flushPersistence() async {
        await persistenceQueue.flush()
    }

    func saveForBackground() {
        persistenceQueue.saveInBackground(named: "Save playlists") {
            persistRestoredMetadata()
        }
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

    func consumeRecentMove(_ move: RecentMove) -> PlaylistFolder? {
        guard recentMove == move else { return nil }
        recentMove = nil
        return folder(move.folderID)
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
