import SwiftUI

extension PlaylistLibrary {
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

    func publishDownloadedPlaylists(onto base: [LibraryPlaylistItem]) {
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

    func hasReceivedPlaylistDetail(for id: String) -> Bool {
        receivedPlaylistDetails.contains(id)
    }

    func isAwaitingInitialOnlineDetail(for item: LibraryPlaylistItem) -> Bool {
        item.isReadOnly && !item.isDownloadedSnapshot
            && onlineErrors[item.id] == nil && !hasReceivedPlaylistDetail(for: item.id)
    }

    func setPlaylistDetailReceived(_ received: Bool, for id: String) {
        guard receivedPlaylistDetails.contains(id) != received else { return }
        if received { receivedPlaylistDetails.insert(id) }
        else { receivedPlaylistDetails.remove(id) }
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
                } else if let url = onlinePreferencesURL,
                          let saved = try? AtomicJSONStore.read([String: OnlinePreference].self, from: url) {
                    onlinePreferences = saved
                }
                loadedOnlinePlaylistIDs = []
                receivedPlaylistDetails = []
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

    func markRestoredMetadataChanged() {
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

    func captureReferencedOnlineSongs() {
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

    func saveOnlinePreferences(force: Bool = false) {
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

    func releaseRetainedOnlinePlaylist(_ id: String) {
        let hadPreference = onlinePreferences.removeValue(forKey: id) != nil
        if hadPreference { saveOnlinePreferences(force: true) }
        guard playlist(id)?.isReadOnly == true else { return }
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }
}
