import SwiftUI
import Observation

@MainActor
final class DownloadMusicIntegration {
    private let account: NeteaseAccount
    private var byPath: [String: Int64] = [:]
    private struct Preparation {
        let id: UUID
        let songIDs: [Int64]?
        let task: Task<Void, Never>
    }
    private var resolving: [LibraryRoute: Preparation] = [:]
    private var publishing = false
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration = 0
    private var metadataPlan: MetadataPlan?
    private var needsAvailabilityRefresh = true
    private var removesMissingFiles = false
    private var availablePaths: [Int64: String] = [:]
    private var stateAliases: [Int64: Set<String>] = [:]
    private var progressAliases: [Int64: Set<String>] = [:]
    private var progressCollections: [Int64: Set<String>] = [:]
    private var progressPlaylists: [Int64: Set<String>] = [:]
    var requestLogin: (() -> Void)?

    init(account: NeteaseAccount) { self.account = account }

    func connect() {
        guard let store = account.downloads else { return }
        observeLocalPlaylists()
        store.onProgressChanged = { [weak self] in self?.publishProgress($0) }
        store.onFileCommitted = { [weak self] path in
            self?.scheduleMetadataPublication(revalidateFiles: true)
            Task { await LocalLibrary.runtime.importFile(path) }
        }
        store.onChange = { [weak self] in self?.publishStates() }
        store.onRecordsChanged = { [weak self] in
            self?.scheduleMetadataPublication(removeMissingFiles: true)
        }
        LocalLibrary.runtime.configureOfflineResolver { [weak self] id in
            guard let self, let songID = self.songID(id), let url = store.resource(songID: songID) else { return nil }
            return PlaybackResource(url: url, quality: store.records[songID]?.quality.rawValue)
        }
        LocalLibrary.player.configureOfflineSongs { [weak self] in self?.offlineSong($0) }
        LocalLibrary.playlistLibrary.configureOfflineSongs { [weak self] in self?.offlineSong($0) }
        LocalLibrary.runtime.onLibraryPublished = { [weak self] in
            self?.scheduleMetadataPublication(removeMissingFiles: true)
        }
        LocalLibrary.songLibrary.downloadedFileID = { [weak self] id in
            guard let self, let songID = self.songID(id) else { return nil }
            return self.availablePaths[songID]
        }
        LocalLibrary.catalog.downloadedOnlineSongID = { [weak self] id in
            guard let self, let songID = self.songID(id), store.records[songID] != nil else { return nil }
            return songID
        }
        LocalLibrary.songLibrary.downloadedFavoriteAction = { [weak self] song, liked, playsSuccessHaptic in
            guard let self, let id = self.songID(song.id), store.records[id] != nil else { return false }
            guard let music = self.account.music, let owner = music.userID else { self.requestLogin?(); return true }
            let revision = music.sessionRevision
            Task {
                do {
                    try await music.setLiked(songID: id, liked: liked)
                    await self.publishMetadataAsync()
                    guard revision == music.sessionRevision, music.userID == owner else { return }
                    if playsSuccessHaptic { LibraryHaptics.success() }
                    LocalLibrary.toasts.show(liked ? .favorited : .unfavorited)
                }
                catch is CancellationError { }
                catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
            }
            return true
        }
        LocalLibrary.prepareSongForLibraryAction = { [weak self] song in
            guard let self, let id = self.songID(song.id), store.records[id] != nil else { return song }
            guard let owner = self.account.music?.userID, let record = store.records[id] else { self.requestLogin?(); return nil }
            return self.song(record, id: OnlineSongIdentity.format(owner: owner, song: id))
        }
        LocalLibrary.collectionDownloads = CollectionDownloadHandling(
            download: { [weak self] route in self?.download(route) ?? false },
            remove: { [weak self] route in
                guard let self, let ids = self.removalIDs(route) else { return false }
                LocalLibrary.downloads.requestRemoval(ids.compactMap { store.records[$0].map { self.song($0, id: $0.relativePath) } })
                return true
            },
            downloadedState: { [weak self] route in
                guard let self else { return nil }
                guard let ids = self.collectionIDs(route), !ids.isEmpty else {
                    if case .album(let id) = route, !CatalogRouteIdentity.isCatalogID(id) { return nil }
                    return self.collectionKey(route) == nil ? nil : false
                }
                return ids.allSatisfy { self.availablePaths[$0] != nil }
            },
            canDownload: { [weak self] route in
                self?.collectionKey(route) != nil || self?.localPlaylistIDs(route)?.isEmpty == false
            },
            canRemoveDownload: { [weak self] route in
                guard let self, let ids = self.removalIDs(route) else { return false }
                return ids.contains { self.availablePaths[$0] != nil }
            },
            stop: { [weak self] route in
                guard let self else { return }
                let preparation = self.resolving[route]
                preparation?.task.cancel()
                if let key = self.collectionKey(route) { Task { await store.stopCollection(key: key) } }
                else if let ids = preparation?.songIDs ?? self.localPlaylistIDs(route) {
                    Task { await store.stopSongSelection(songIDs: ids) }
                }
            }
        )
        let facade = LocalLibrary.downloads
        facade.downloadAction = { [weak self] songs in
            guard let self else { return }
            self.enqueue { try await store.enqueue(songIDs: songs.compactMap { self.songID($0.id) }) }
        }
        facade.stopAction = { [weak self] songs in
            guard let self else { return }
            Task { await store.stopSongSelection(songIDs: songs.compactMap { self.songID($0.id) }) }
        }
        facade.removeAction = { [weak self] songs in
            guard let self else { return }
            Task {
                let ids = songs.compactMap { self.songID($0.id) }
                do { try await store.remove(songIDs: ids) }
                catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
            }
        }
        facade.isDownloadable = { [weak self] in self?.songID($0.id) != nil }
        facade.isRemovable = { [weak self] song in
            guard let self, let id = self.songID(song.id) else { return false }
            return self.availablePaths[id] != nil
        }
    }

    struct MetadataPlan: Sendable {
        let byPath: [String: Int64]
        let availableSongIDs: Set<Int64>
        let missingPaths: [String]
        let unavailableRecordIDs: [Int64]
        let albumGroups: [(albumID: Int64, firstRecord: NeteaseDownloadRecord)]
        let collectionPlaylists: [(id: String, collection: NeteaseDownloadCollection)]
    }

    func restore() async {
        await account.downloads?.restore()
        await publishMetadataAsync()
    }

    func scheduleMetadataPublication(revalidateFiles: Bool = false, removeMissingFiles: Bool = false) {
        if revalidateFiles || removeMissingFiles {
            needsAvailabilityRefresh = true
            removesMissingFiles = removesMissingFiles || self.removesMissingFiles
        } else if metadataTask != nil {
            return
        }
        metadataTask?.cancel()
        metadataGeneration &+= 1
        let generation = metadataGeneration
        metadataTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.metadataGeneration == generation else { return }
            await self.runOffMainMetadataPublication(generation: generation)
            if self.metadataGeneration == generation { self.metadataTask = nil }
        }
    }

    func publishMetadataAsync() async {
        scheduleMetadataPublication()
        while let task = metadataTask, !Task.isCancelled {
            await task.value
        }
    }

    private func runOffMainMetadataPublication(generation: Int) async {
        guard let store = account.downloads else { return }
        if needsAvailabilityRefresh || metadataPlan == nil {
            let plan = await Self.prepareMetadataPlanInBackground(records: store.records, collections: store.collections,
                                                                  musicDirectory: store.musicDirectory)
            guard !Task.isCancelled, metadataGeneration == generation else { return }
            metadataPlan = plan
            needsAvailabilityRefresh = false
            store.reconcileFileAvailability(plan.availableSongIDs)
        }
        guard let plan = metadataPlan else { return }
        if removesMissingFiles, !plan.missingPaths.isEmpty {
            let paths = plan.missingPaths
            Task { await LocalLibrary.runtime.removeMissingFiles(paths) }
        }
        removesMissingFiles = false
        applyMetadataPlan(plan, store: store)
    }

    @concurrent private static func prepareMetadataPlanInBackground(records: [Int64: NeteaseDownloadRecord],
                                                                    collections: [String: NeteaseDownloadCollection],
                                                                    musicDirectory: URL) async -> MetadataPlan {
        prepareMetadataPlan(records: records, collections: collections, musicDirectory: musicDirectory)
    }

    nonisolated static func prepareMetadataPlan(records: [Int64: NeteaseDownloadRecord],
                                                collections: [String: NeteaseDownloadCollection],
                                                musicDirectory: URL) -> MetadataPlan {
        let root = musicDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var byPath: [String: Int64] = [:]
        byPath.reserveCapacity(records.count)
        var availableSongIDs = Set<Int64>()
        availableSongIDs.reserveCapacity(records.count)
        var missingPaths: [String] = []
        var unavailableRecordIDs: [Int64] = []
        var albumsByID: [Int64: NeteaseDownloadRecord] = [:]

        for record in records.values {
            if Task.isCancelled { break }
            byPath[record.relativePath] = record.songID
            let path = record.relativePath
            guard let url = try? NeteaseDownloadStore.ownedFile(path, resolvedRoot: root) else {
                unavailableRecordIDs.append(record.songID)
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                availableSongIDs.insert(record.songID)
                if let albumID = record.song.albumID, albumsByID[albumID] == nil {
                    albumsByID[albumID] = record
                }
            } else {
                missingPaths.append(path)
                unavailableRecordIDs.append(record.songID)
            }
        }
        let albumGroups = albumsByID.keys.sorted().compactMap { id in
            albumsByID[id].map { (albumID: id, firstRecord: $0) }
        }
        let collectionPlaylists = collections.values
            .filter { $0.kind == .playlist }
            .sorted { $0.key < $1.key }
            .map { (id: "downloaded:playlist:\($0.id)", collection: $0) }

        return MetadataPlan(
            byPath: byPath,
            availableSongIDs: availableSongIDs,
            missingPaths: missingPaths,
            unavailableRecordIDs: unavailableRecordIDs,
            albumGroups: albumGroups,
            collectionPlaylists: collectionPlaylists
        )
    }

    private func applyMetadataPlan(_ plan: MetadataPlan, store: NeteaseDownloadStore) {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        byPath = plan.byPath
        let previousPaths = availablePaths
        availablePaths = Dictionary(uniqueKeysWithValues: plan.availableSongIDs.compactMap { id in
            store.records[id].map { (id, $0.relativePath) }
        })
        remapLocalReferences(ids: plan.unavailableRecordIDs)
        stateAliases = [:]
        for item in LocalLibrary.player.queue + LocalLibrary.allSongs {
            if let id = songID(item.id) { stateAliases[id, default: []].insert(item.id) }
        }
        var local: [String: LibrarySongItem] = [:]
        local.reserveCapacity(plan.availableSongIDs.count)
        for songID in plan.availableSongIDs {
            guard let record = store.records[songID] else { continue }
            local[record.relativePath] = song(record, id: record.relativePath, isAvailable: true)
        }
        let updatedAlbums = makeDownloadedAlbums(albumGroups: plan.albumGroups, localSongs: local)
        if LocalLibrary.catalog.downloadedAlbums != updatedAlbums {
            LocalLibrary.catalog.downloadedAlbums = updatedAlbums
        }
        var referenced: [String: LibrarySongItem] = [:]
        if let owner = account.music?.userID {
            referenced.reserveCapacity(store.records.count)
            for record in store.records.values {
                let id = "netease:\(owner):\(record.songID)"
                referenced[id] = song(record, id: id, isAvailable: plan.availableSongIDs.contains(record.songID))
            }
        }
        for queued in LocalLibrary.player.queue where queued.isOnline {
            guard let id = songID(queued.id), plan.availableSongIDs.contains(id),
                  let record = store.records[id] else { continue }
            referenced[queued.id] = song(record, id: queued.id, isAvailable: true)
        }
        let sortedReferenced = referenced.values.sorted { $0.id < $1.id }
        let previousCatalogRevision = LocalLibrary.songLibrary.catalogRevision
        LocalLibrary.songLibrary.applyBatch(
            localMetadata: local,
            externalSongs: sortedReferenced,
            externalSource: "downloads",
            forceCatalogRefresh: previousPaths != availablePaths
        )
        var items: [LibraryPlaylistItem] = []
        var contents: [String: [LibrarySongItem]] = [:]
        var aliases: [String: String] = [:]
        items.reserveCapacity(plan.collectionPlaylists.count)
        contents.reserveCapacity(plan.collectionPlaylists.count)
        for entry in plan.collectionPlaylists {
            let collection = entry.collection
            let id = entry.id
            let songs = collection.orderedSongIDs.map { value -> LibrarySongItem in
                let owner = account.music?.userID ?? collection.ownerID
                let identity = "netease:\(owner):\(value)"
                stateAliases[value, default: []].insert(identity)
                guard let record = store.records[value] else { return .unavailable(identity) }
                return song(record, id: identity, isAvailable: plan.availableSongIDs.contains(value))
            }
            var item = LibraryPlaylistItem(id: id, title: collection.title, artwork: songs.first?.artwork ?? .playlist, subtitle: collection.artist)
            item.isDownloadedSnapshot = true
            items.append(item); contents[id] = songs
            if let owner = account.music?.userID, owner == collection.ownerID { aliases[id] = "netease-playlist:\(owner):\(collection.id)" }
        }
        LocalLibrary.playlistLibrary.replaceDownloadedPlaylists(items: items, songs: contents, onlineAliases: aliases)
        publishStates()
        LocalLibrary.refreshDownloadedPlaylistsPresentation()
        if LocalLibrary.songLibrary.catalogRevision != previousCatalogRevision {
            LocalLibrary.player.reconcileAvailability(songs: LocalLibrary.allSongs)
        } else {
            LocalLibrary.player.reconcileOfflineAvailability()
        }
    }

    private func offlineSong(_ id: String) -> LibrarySongItem? {
        guard let store = account.downloads, let value = songID(id), let record = store.records[value],
              availablePaths[value] == record.relativePath else { return nil }
        return song(record, id: id, isAvailable: true)
    }

    private func song(_ record: NeteaseDownloadRecord, id: String, isAvailable: Bool? = nil) -> LibrarySongItem {
        let local = LocalLibrary.songLibrary.song(id: record.relativePath)
        let value = record.song
        let hasFile = isAvailable ?? (availablePaths[value.id] == record.relativePath)
        return LibrarySongItem(id: id, title: value.title, artist: value.artist, album: value.album,
            albumArtist: record.metadata.albumArtist, trackNumber: record.metadata.trackNumber,
            artwork: local?.artwork ?? .missing, albumDirectory: (record.relativePath as NSString).deletingLastPathComponent,
            discNumber: record.metadata.discNumber, artworkData: local?.artworkData, artworkURL: local?.artworkURL,
            artworkBackdrop: local?.artworkBackdrop, duration: Int(value.duration), isPinned: local?.isPinned ?? false, addedOrder: local?.addedOrder ?? 0,
            isFavorite: account.music?.likedIDs.contains(value.id) == true,
            favoriteAddedAt: account.music?.likedAt[value.id],
            unavailabilityReason: !hasFile && account.music?.userID == nil ? "请登录网易云账号后重试" : nil,
            onlineAlbumID: value.albumID,
            artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }

    private func makeDownloadedAlbums(albumGroups: [(albumID: Int64, firstRecord: NeteaseDownloadRecord)],
                                      localSongs: [String: LibrarySongItem]) -> [LibraryShelfItem] {
        let catalogByID = Dictionary(uniqueKeysWithValues: LocalLibrary.catalog.albums.map { ($0.id, $0) })
        return albumGroups.map { albumID, first in
            let routeID = "catalog:album:\(albumID)"
            if let existing = catalogByID[routeID] { return existing }
            let local = localSongs[first.relativePath] ?? LocalLibrary.songLibrary.song(id: first.relativePath)
            let subtitle = first.metadata.albumArtist.isEmpty ? first.song.artist : first.metadata.albumArtist
            return LibraryShelfItem(
                id: routeID,
                title: first.song.album,
                subtitle: subtitle,
                artwork: local?.artwork ?? .missing,
                route: .album(routeID),
                addedOrder: local?.addedOrder ?? 0,
                albumBackdrop: local?.artworkBackdrop
            )
        }
    }

    private func songID(_ id: String) -> Int64? {
        if let value = byPath[id] { return value }
        return OnlineSongIdentity.parseOwnerAndSong(id)?.songID
    }

    private static func albumID(_ id: String) -> Int64? {
        CatalogRouteIdentity.parseAlbumID(id)
    }

    private func collectionKey(_ route: LibraryRoute) -> String? {
        switch route {
        case .album(let id):
            if let value = Self.albumID(id) { return "album:\(value)" }
        case .playlist(let id):
            let identity = PlaylistRouteIdentity(id)
            if identity == .favorites, let value = account.music?.playlists.first(where: \.isFavorites)?.id { return "playlist:\(value)" }
            if let value = identity.onlinePlaylistNumber { return "playlist:\(value)" }
        default: break
        }
        return nil
    }

    private func collectionIDs(_ route: LibraryRoute) -> [Int64]? {
        guard let key = collectionKey(route), let store = account.downloads else { return nil }
        if let collection = store.collections[key] { return collection.orderedSongIDs }
        return nil
    }

    private func localPlaylistIDs(_ route: LibraryRoute) -> [Int64]? {
        guard case .playlist(let id) = route, let playlist = LocalLibrary.playlistLibrary.playlist(id),
              !playlist.isReadOnly else { return nil }
        return LocalLibrary.playlistLibrary.songs(in: id).compactMap { songID($0.id) }
    }

    private func remapLocalReferences(ids: [Int64]) {
        guard let store = account.downloads else { return }
        let replacements = Self.removedFileReplacements(records: ids.compactMap { store.records[$0] }) {
            song($0, id: $1, isAvailable: false)
        }
        guard !replacements.isEmpty else { return }
        LocalLibrary.player.remapSongReferences(replacements)
        LocalLibrary.playlistLibrary.remapSongReferences(replacements)
    }

    static func removedFileReplacements(records: [NeteaseDownloadRecord],
                                        project: (NeteaseDownloadRecord, String) -> LibrarySongItem) -> [String: LibrarySongItem] {
        var replacements: [String: LibrarySongItem] = [:]
        for record in records {
            guard let owner = record.ownerID else { continue }
            let identity = OnlineSongIdentity.format(owner: owner, song: record.songID)
            replacements[record.relativePath] = project(record, identity)
        }
        return replacements
    }

    private func removalIDs(_ route: LibraryRoute) -> [Int64]? {
        if let ids = collectionIDs(route) { return ids }
        if let ids = localPlaylistIDs(route) { return ids }
        guard let key = collectionKey(route), let store = account.downloads else { return nil }
        if key.hasPrefix("album:"), let id = Int64(key.dropFirst(6)) {
            let ids = store.records.values.filter { $0.song.albumID == id }.map(\.songID)
            return ids.isEmpty ? nil : ids
        }
        return nil
    }

    private func download(_ route: LibraryRoute) -> Bool {
        guard let store = account.downloads else { return false }
        if collectionKey(route) == nil, let ids = localPlaylistIDs(route), !ids.isEmpty {
            enqueue(route: route, songIDs: ids) { try await store.enqueue(songIDs: ids) }
            return true
        }
        guard let key = collectionKey(route),
              let id = key.split(separator: ":").last.flatMap({ Int64($0) }) else { return false }
        enqueue(route: route) {
            if key.hasPrefix("album:") { try await store.enqueueAlbum(id: id) }
            else { try await store.enqueuePlaylist(id: id) }
        }
        return true
    }

    private func enqueue(route: LibraryRoute? = nil, songIDs: [Int64]? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        guard let store = account.downloads, store.userID != nil else { requestLogin?(); return }
        if let route, resolving[route] != nil { return }
        let id = UUID()
        let revision = store.sessionRevision
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if let route, self.resolving[route]?.id == id { self.resolving.removeValue(forKey: route) }
                self.publishStates()
            }
            do {
                try Task.checkCancellation()
                guard store.sessionRevision == revision else { return }
                try await operation()
            }
            catch is CancellationError { }
            catch {
                guard store.sessionRevision == revision, !Task.isCancelled else { return }
                LocalLibrary.toasts.show(.error(error.localizedDescription))
            }
        }
        if let route {
            resolving[route] = Preparation(id: id, songIDs: songIDs, task: task)
            publishStates()
        }
    }

    private func observeLocalPlaylists() {
        withObservationTracking {
            for playlist in LocalLibrary.playlistLibrary.playlists where !playlist.isReadOnly {
                _ = LocalLibrary.playlistLibrary.songs(in: playlist.id)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publishStates()
                self?.observeLocalPlaylists()
            }
        }
    }

    private func publishProgress(_ id: Int64) {
        guard let store = account.downloads, let state = store.states[id] else { return }
        let shown: LibraryDownloads.SongState
        switch state {
        case .downloading(let value): shown = .downloading(value)
        case .waiting: shown = .waiting
        default: publishStates(); return
        }
        var aliases = progressAliases[id, default: []]
        if let owner = store.userID { aliases.insert("netease:\(owner):\(id)") }
        if let record = store.records[id] { aliases.insert(record.relativePath) }
        LocalLibrary.downloads.update(states: Dictionary(uniqueKeysWithValues: aliases.map { ($0, shown) }), collections: [:])
        var values: [LibraryRoute: LibraryDownloads.CollectionState] = [:]
        for key in progressCollections[id, default: []] {
            guard let collection = store.collections[key] else { continue }
            var complete = 0, active = 0, failed = 0
            var progress = 0.0
            for songID in collection.orderedSongIDs {
                let state = store.states[songID]
                if state == .downloaded { complete += 1 }
                if state?.isActive == true { active += 1 }
                switch state {
                case .downloaded, .processing: progress += 1
                case .downloading(let value): progress += value
                case .failed: failed += 1
                default: break
                }
            }
            let summary = LibraryDownloads.CollectionState(totalCount: collection.orderedSongIDs.count,
                completedCount: complete, activeCount: active, failedCount: failed,
                progress: progress / Double(max(1, collection.orderedSongIDs.count)))
            if collection.kind == .album { values[.album("catalog:album:\(collection.id)")] = summary }
            else {
                for route in ["netease-playlist:\(collection.ownerID):\(collection.id)", "downloaded:playlist:\(collection.id)", "home:playlist:\(collection.id)"] { values[.playlist(route)] = summary }
            }
        }
        for playlist in progressPlaylists[id, default: []] {
            values[.playlist(playlist)] = progressSummary(LocalLibrary.playlistLibrary.songs(in: playlist))
        }
        for route in resolving.keys where values[route] != nil { values[route]?.isResolving = true }
        LocalLibrary.downloads.update(states: [:], collections: values)
    }

    private func progressSummary(_ songs: [LibrarySongItem]) -> LibraryDownloads.CollectionState {
        let states = songs.map { LocalLibrary.downloads.state(of: $0.id) }
        return .init(totalCount: songs.count, completedCount: states.filter { $0 == .downloaded }.count,
            activeCount: states.filter { $0?.isActive == true }.count,
            failedCount: states.filter { if case .failed = $0 { true } else { false } }.count,
            progress: LocalLibrary.downloads.progress(of: songs))
    }

    private func publishStates() {
        guard let store = account.downloads else { return }
        var values: [String: LibraryDownloads.SongState] = [:]
        var managed: Set<String> = []
        var aliases = stateAliases
        for record in store.records.values {
            aliases[record.songID, default: []].insert(record.relativePath)
            if let owner = record.ownerID { aliases[record.songID, default: []].insert("netease:\(owner):\(record.songID)") }
            if let owner = store.userID { aliases[record.songID, default: []].insert("netease:\(owner):\(record.songID)") }
            managed.formUnion(aliases[record.songID, default: []])
        }
        for (id, state) in store.states {
            if let owner = store.userID { aliases[id, default: []].insert("netease:\(owner):\(id)") }
            if let record = store.records[id] { aliases[id, default: []].insert(record.relativePath) }
            let shown: LibraryDownloads.SongState
            switch state {
            case .queued: shown = .queued
            case .waiting: shown = .waiting
            case .downloading(let progress): shown = .downloading(progress)
            case .processing: shown = .finishing
            case .downloaded: shown = .downloaded
            case .failed(let message): shown = .failed(message)
            }
            for alias in aliases[id, default: []] { values[alias] = shown; managed.insert(alias) }
        }
        progressAliases = aliases
        progressCollections = [:]; progressPlaylists = [:]
        LocalLibrary.downloads.publish(states: values, managedSongIDs: managed)
        var collections: [LibraryRoute: LibraryDownloads.CollectionState] = [:]
        for collection in store.collections.values {
            for id in collection.orderedSongIDs { progressCollections[id, default: []].insert(collection.key) }
            var complete = 0, active = 0, failed = 0
            var progress = 0.0
            for songID in collection.orderedSongIDs {
                switch store.states[songID] {
                case .downloaded:
                    complete += 1; progress += 1
                case .processing:
                    active += 1; progress += 1
                case .downloading(let value):
                    active += 1; progress += value
                case .queued, .waiting:
                    active += 1
                case .failed:
                    failed += 1
                case nil:
                    break
                }
            }
            let summary = LibraryDownloads.CollectionState(totalCount: collection.orderedSongIDs.count, completedCount: complete,
                activeCount: active, failedCount: failed, progress: progress / Double(max(1, collection.orderedSongIDs.count)))
            if collection.kind == .album { collections[.album("catalog:album:\(collection.id)")] = summary }
            else {
                collections[.playlist("netease-playlist:\(collection.ownerID):\(collection.id)")] = summary
                collections[.playlist("downloaded:playlist:\(collection.id)")] = summary
                collections[.playlist("home:playlist:\(collection.id)")] = summary
            }
        }
        for playlist in LocalLibrary.playlistLibrary.playlists where !playlist.isReadOnly {
            let songs = LocalLibrary.playlistLibrary.songs(in: playlist.id)
            guard songs.contains(where: { songID($0.id) != nil }) else { continue }
            for song in songs { if let id = songID(song.id) { progressPlaylists[id, default: []].insert(playlist.id) } }
            let states = songs.map { LocalLibrary.downloads.state(of: $0.id) }
            let completed = states.filter { $0 == .downloaded }.count
            let active = states.filter { $0?.isActive == true }.count
            let failed = states.filter { if case .failed = $0 { true } else { false } }.count
            let progress = LocalLibrary.downloads.progress(of: songs)
            collections[.playlist(playlist.id)] = .init(totalCount: songs.count, completedCount: completed,
                activeCount: active, failedCount: failed, progress: progress)
        }
        for route in resolving.keys {
            var value = collections[route] ?? .init(totalCount: 0, completedCount: 0, activeCount: 0, failedCount: 0, progress: 0)
            value.isResolving = true; collections[route] = value
        }
        LocalLibrary.downloads.publishCollections(collections)
    }
}

final class DownloadBackgroundDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        NeteaseDownloadTransport.handleEvents(identifier: identifier, completion: completionHandler)
    }
}
