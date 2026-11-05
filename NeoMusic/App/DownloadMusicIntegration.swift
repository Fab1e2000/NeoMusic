import SwiftUI

/// Joins account-owned transfers to the existing local library and player.
@MainActor
final class DownloadMusicIntegration {
    private let account: NeteaseAccount
    private var byPath: [String: Int64] = [:]
    private var resolving: Set<LibraryRoute> = []
    private var publishing = false
    private var stateAliases: [Int64: Set<String>] = [:]
    var requestLogin: (() -> Void)?

    init(account: NeteaseAccount) { self.account = account }

    func connect() {
        guard let store = account.downloads else { return }
        store.onChange = { [weak self] in self?.publishStates() }
        store.onRecordsChanged = { [weak self] in
            guard let self else { return }
            self.publishMetadata()
            Task { await LocalLibrary.runtime.refresh() }
        }
        LocalLibrary.runtime.configureOfflineResolver { [weak self] id in
            guard let self, let songID = self.songID(id), let url = store.resource(songID: songID) else { return nil }
            return PlaybackResource(url: url, quality: store.records[songID]?.quality.rawValue)
        }
        LocalLibrary.player.configureOfflineSongs { [weak self] in self?.offlineSong($0) }
        LocalLibrary.playlistLibrary.configureOfflineSongs { [weak self] in self?.offlineSong($0) }
        LocalLibrary.runtime.onLibraryPublished = { [weak self] in
            self?.publishMetadata()
            Task { await store.reconcileFiles() }
        }
        LocalLibrary.songLibrary.downloadedFileID = { [weak self] id in
            guard let self, let songID = self.songID(id), store.resource(songID: songID) != nil else { return nil }
            return store.records[songID]?.relativePath
        }
        LocalLibrary.songLibrary.downloadedFavoriteAction = { [weak self] song, liked in
            guard let self, let id = self.songID(song.id), store.records[id] != nil else { return false }
            guard let music = self.account.music, music.userID != nil else { self.requestLogin?(); return true }
            Task {
                do { try await music.setLiked(songID: id, liked: liked); self.publishMetadata() }
                catch is CancellationError { }
                catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
            }
            return true
        }
        LocalLibrary.prepareSongForLibraryAction = { [weak self] song in
            guard let self, let id = self.songID(song.id), store.records[id] != nil else { return song }
            guard let owner = self.account.music?.userID, let record = store.records[id] else { self.requestLogin?(); return nil }
            return self.song(record, id: "netease:\(owner):\(id)")
        }
        LocalLibrary.downloadedAlbumID = { id in
            guard let album = Self.albumID(id),
                  let record = store.records.values.first(where: { $0.song.albumID == album && store.resource(songID: $0.songID) != nil }) else { return nil }
            return "folder:" + (record.relativePath as NSString).deletingLastPathComponent
        }
        LocalLibrary.collectionDownloadAction = { [weak self] route in self?.download(route) ?? false }
        LocalLibrary.collectionCanDownload = { [weak self] route in
            self?.collectionKey(route) != nil || self?.localPlaylistIDs(route)?.isEmpty == false
        }
        LocalLibrary.collectionCanRemoveDownload = { [weak self] route in
            guard let ids = self?.removalIDs(route) else { return false }
            return ids.contains { store.resource(songID: $0) != nil }
        }
        LocalLibrary.collectionStopDownload = { [weak self] route in
            guard let self else { return }
            if let key = self.collectionKey(route) { Task { await store.stopCollection(key: key) } }
            else if let ids = self.localPlaylistIDs(route) { Task { await store.stop(songIDs: ids) } }
        }
        LocalLibrary.collectionRemovalAction = { [weak self] route in
            guard let self, let ids = self.removalIDs(route) else { return false }
            LocalLibrary.downloads.requestRemoval(ids.compactMap { store.records[$0].map { self.song($0, id: $0.relativePath) } })
            return true
        }
        LocalLibrary.collectionDownloadedState = { [weak self] route in
            guard let self else { return nil }
            guard let ids = self.collectionIDs(route), !ids.isEmpty else {
                if case .album(let id) = route, !id.hasPrefix("catalog:") { return nil }
                return self.collectionKey(route) == nil ? nil : false
            }
            return ids.allSatisfy { store.resource(songID: $0) != nil }
        }
        let facade = LocalLibrary.downloads
        facade.downloadAction = { [weak self] songs in
            guard let self else { return }
            self.enqueue { try await store.enqueue(songIDs: songs.compactMap { self.songID($0.id) }) }
        }
        facade.stopAction = { [weak self] songs in
            guard let self else { return }
            Task { await store.stop(songIDs: songs.compactMap { self.songID($0.id) }) }
        }
        facade.removeAction = { [weak self] songs in
            guard let self else { return }
            Task {
                let ids = songs.compactMap { self.songID($0.id) }
                self.remapLocalReferences(ids: ids)
                do { try await store.remove(songIDs: ids) }
                catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
            }
        }
        facade.isDownloadable = { [weak self] in self?.songID($0.id) != nil }
        facade.isRemovable = { [weak self] song in
            guard let id = self?.songID(song.id) else { return false }
            return store.resource(songID: id) != nil
        }
    }

    func restore() async {
        await account.downloads?.restore()
        publishMetadata()
    }

    func publishMetadata() {
        guard !publishing, let store = account.downloads else { return }
        publishing = true
        defer { publishing = false }
        byPath = Dictionary(store.records.values.map { ($0.relativePath, $0.songID) }, uniquingKeysWith: { first, _ in first })
        remapLocalReferences(ids: store.records.keys.filter { store.resource(songID: $0) == nil })
        stateAliases = [:]
        for item in LocalLibrary.player.queue + LocalLibrary.allSongs {
            if let id = songID(item.id) { stateAliases[id, default: []].insert(item.id) }
        }
        let local = Dictionary(store.records.values.filter { store.resource(songID: $0.songID) != nil }.map {
            ($0.relativePath, song($0, id: $0.relativePath))
        }, uniquingKeysWith: { first, _ in first })
        LocalLibrary.songLibrary.updateLocalMetadata(local)
        var referenced: [String: LibrarySongItem] = [:]
        if let owner = account.music?.userID {
            for record in store.records.values {
                let id = "netease:\(owner):\(record.songID)"
                referenced[id] = song(record, id: id)
            }
        }
        for queued in LocalLibrary.player.queue where queued.isOnline {
            guard let id = songID(queued.id), let record = store.records[id], store.resource(songID: id) != nil else { continue }
            referenced[queued.id] = song(record, id: queued.id)
        }
        LocalLibrary.songLibrary.replaceExternalSongs(referenced.values.sorted { $0.id < $1.id }, source: "downloads")
        var items: [LibraryPlaylistItem] = []
        var contents: [String: [LibrarySongItem]] = [:]
        var aliases: [String: String] = [:]
        for collection in store.collections.values.sorted(by: { $0.key < $1.key }) where collection.kind == .playlist {
            let id = "downloaded:playlist:\(collection.id)"
            let songs = collection.orderedSongIDs.map { value -> LibrarySongItem in
                let owner = account.music?.userID ?? collection.ownerID
                let identity = "netease:\(owner):\(value)"
                stateAliases[value, default: []].insert(identity)
                guard let record = store.records[value] else { return .unavailable(identity) }
                return song(record, id: identity)
            }
            var item = LibraryPlaylistItem(id: id, title: collection.title, artwork: songs.first?.artwork ?? .playlist, subtitle: collection.artist)
            item.isDownloadedSnapshot = true
            items.append(item); contents[id] = songs
            if let owner = account.music?.userID, owner == collection.ownerID { aliases[id] = "netease-playlist:\(owner):\(collection.id)" }
        }
        LocalLibrary.playlistLibrary.replaceDownloadedPlaylists(items: items, songs: contents, onlineAliases: aliases)
        publishStates()
        LocalLibrary.refreshDownloadPresentation()
        LocalLibrary.playlistLibrary.reconcileOfflineAvailability()
        LocalLibrary.player.reconcileOfflineAvailability()
        LocalLibrary.player.reconcileAvailability(songs: LocalLibrary.allSongs)
    }

    private func offlineSong(_ id: String) -> LibrarySongItem? {
        guard let store = account.downloads, let value = songID(id), let record = store.records[value], store.resource(songID: value) != nil else { return nil }
        return song(record, id: id)
    }

    private func song(_ record: NeteaseDownloadRecord, id: String) -> LibrarySongItem {
        let local = LocalLibrary.songLibrary.song(id: record.relativePath)
        let value = record.song
        return LibrarySongItem(id: id, title: value.title, artist: value.artist, album: value.album,
            albumArtist: record.metadata.albumArtist, trackNumber: record.metadata.trackNumber,
            artwork: local?.artwork ?? .missing, albumDirectory: (record.relativePath as NSString).deletingLastPathComponent,
            discNumber: record.metadata.discNumber, artworkData: local?.artworkData, artworkURL: local?.artworkURL,
            artworkBackdrop: local?.artworkBackdrop, duration: Int(value.duration), isPinned: local?.isPinned ?? false, addedOrder: local?.addedOrder ?? 0,
            isFavorite: account.music?.likedIDs.contains(value.id) == true,
            favoriteAddedAt: account.music?.likedAt[value.id],
            unavailabilityReason: account.downloads?.resource(songID: value.id) == nil && account.music?.userID == nil ? "请登录网易云账号后重试" : nil,
            onlineAlbumID: id.hasPrefix("netease:") ? value.albumID : nil,
            artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }

    private func songID(_ id: String) -> Int64? {
        if let value = byPath[id] { return value }
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "netease" else { return nil }
        return Int64(parts[2])
    }

    private static func albumID(_ id: String) -> Int64? {
        let prefix = "catalog:album:"
        return id.hasPrefix(prefix) ? Int64(id.dropFirst(prefix.count)) : nil
    }

    private func collectionKey(_ route: LibraryRoute) -> String? {
        switch route {
        case .album(let id):
            if let value = Self.albumID(id) { return "album:\(value)" }
            if let store = account.downloads, let record = store.records.values.first(where: { "folder:" + ($0.relativePath as NSString).deletingLastPathComponent == id }), let value = record.song.albumID { return "album:\(value)" }
        case .playlist(let id):
            if id == "favorites", let value = account.music?.playlists.first(where: \.isFavorites)?.id { return "playlist:\(value)" }
            if id.hasPrefix("netease-playlist:") || id.hasPrefix("downloaded:playlist:") || id.hasPrefix("home:playlist:"), let value = id.split(separator: ":").last.flatMap({ Int64($0) }) { return "playlist:\(value)" }
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
        var replacements: [String: LibrarySongItem] = [:]
        for id in ids {
            guard let record = store.records[id], let owner = account.music?.userID ?? record.ownerID else { continue }
            let replacement = song(record, id: "netease:\(owner):\(id)")
            replacements[record.relativePath] = replacement
            for queued in LocalLibrary.player.queue where queued.isOnline && songID(queued.id) == id && queued.id != replacement.id {
                replacements[queued.id] = replacement
            }
        }
        LocalLibrary.player.remapSongReferences(replacements)
        LocalLibrary.playlistLibrary.remapSongReferences(replacements)
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
            enqueue(route: route) { try await store.enqueue(songIDs: ids) }
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

    private func enqueue(route: LibraryRoute? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        guard account.downloads?.userID != nil else { requestLogin?(); return }
        if let route { resolving.insert(route); publishStates() }
        Task {
            defer { if let route { resolving.remove(route) }; publishStates() }
            do { try await operation() }
            catch is CancellationError { }
            catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
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
        LocalLibrary.downloads.publish(states: values, managedSongIDs: managed)
        var collections: [LibraryRoute: LibraryDownloads.CollectionState] = [:]
        for collection in store.collections.values {
            let states = collection.orderedSongIDs.map { store.states[$0] }
            let complete = states.filter { $0 == .downloaded }.count
            let active = states.filter { $0?.isActive == true }.count
            let failed = states.filter { if case .failed = $0 { true } else { false } }.count
            let progress = states.reduce(0.0) { total, state in
                switch state { case .downloaded, .processing: total + 1; case .downloading(let value): total + value; default: total }
            } / Double(max(1, states.count))
            let summary = LibraryDownloads.CollectionState(totalCount: states.count, completedCount: complete, activeCount: active, failedCount: failed, progress: progress)
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
            let states = songs.map { LocalLibrary.downloads.state(of: $0.id) }
            let completed = states.filter { $0 == .downloaded }.count
            let active = states.filter { $0?.isActive == true }.count
            let failed = states.filter { if case .failed = $0 { true } else { false } }.count
            let progress = LocalLibrary.downloads.progress(of: songs)
            collections[.playlist(playlist.id)] = .init(totalCount: songs.count, completedCount: completed,
                activeCount: active, failedCount: failed, progress: progress)
        }
        for route in resolving {
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
