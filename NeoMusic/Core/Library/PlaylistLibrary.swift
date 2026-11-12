import SwiftUI

/// 播放列表文件夹；文件夹里可以再放文件夹。
struct PlaylistFolder: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var parentID: String?
    var addedOrder = 0
}

/// 资料库中的播放列表与文件夹；保存条目身份及引用歌曲的显示资料，不触碰音乐文件。
@MainActor @Observable
final class PlaylistLibrary {
    private(set) var playlists: [LibraryPlaylistItem]
    private(set) var folders: [PlaylistFolder]
    /// 播放列表所在文件夹；不在表中即在最外层。
    private(set) var placement: [String: String] = [:]
    private var nextOrder = 1000
    private var contents: [String: [LibrarySongItem]] = [:]
    /// 歌曲加入某个自建播放列表的时间。已在列表中的旧歌没有这项记录。
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
        for (id, existing) in contents {
            let updated = existing.map { song in
                if let offline = offlineSong?(song.id) { return offline }
                if song.isOnline, song.onlineOwnerID != restoredOnlineOwnerID { return LibrarySongItem.unavailable(song.id) }
                return song
            }
            if existing != updated { contents[id] = updated }
        }
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
    /// 最近一次移入文件夹，页面据此显示“已移至”提示。
    private(set) var recentMove: RecentMove?
    /// 等待确认删除的播放列表，由宿主弹出确认框。
    var pendingDeletion: LibraryPlaylistItem?
    /// 等待移到文件夹的播放列表，由宿主弹出文件夹选择页。
    var pendingMove: LibraryPlaylistItem?
    /// 等待编辑的播放列表，由宿主弹出编辑页（例如从长按菜单进入）。
    var pendingEdit: LibraryPlaylistItem?
    /// 等待选择目标播放列表的歌曲，由宿主弹出“添加到播放列表”。
    var pendingAddition: PendingAddition?

    @ObservationIgnored var loadOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var loadMoreOnlinePlaylist: (@MainActor (String) async -> Void)?
    @ObservationIgnored var completeOnlinePlaylist: (@MainActor (String) async -> Bool)?
    /// 取消网易云收藏。成功后由账号歌单名单决定这张卡片是否还在。
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

    /// Explicit local organization retains a reference without subscribing in the cloud.
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
            let previousContents = sameOwner ? contents : [:]
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
            var updatedContents = contents
            var updatedPlacement = placement
            for id in oldOnline { updatedContents[id] = nil; updatedPlacement[id] = nil }
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
                    previousContents[item.id] ?? retained.songIDs.map(LibrarySongItem.unavailable)
                }
                updatedContents[item.id] = songs[item.id] ?? retainedSongs ?? []
            }
            for id in updatedContents.keys where !oldOnline.contains(id) {
                updatedContents[id] = updatedContents[id]?.map { song in
                    if let offline = offlineSong?(song.id) { return offline }
                    guard song.id.hasPrefix("netease:") else { return song }
                    let owner = song.id.split(separator: ":").dropFirst().first.map(String.init)
                    return owner == ownerID ? song : LibrarySongItem.unavailable(song.id)
                }
            }
            if contents != updatedContents { contents = updatedContents }
            publishDownloadedPlaylists(onto: updatedPlaylists)
            if placement != updatedPlacement { placement = updatedPlacement }
            saveOnlinePreferences()
        }
    }

    /// Publish only changed covers; collection identity, load state and organization stay stable.
    func updateArtwork(songs: [String: LibrarySongItem], playlists artwork: [String: Artwork] = [:]) {
        for index in playlists.indices {
            if let cover = artwork[playlists[index].id], cover != playlists[index].artwork {
                playlists[index].artwork = cover
            }
        }
        guard !songs.isEmpty else { return }
        var changedLocalContent = false
        for (id, existing) in contents where existing.contains(where: { songs[$0.id] != nil }) {
            let updated = existing.map { item in
                let offline = offlineSong?(item.id)
                guard !item.isOnline || offline != nil || playlist(id)?.isReadOnly == true || item.onlineOwnerID == restoredOnlineOwnerID,
                      var replacement = songs[item.id] else { return item }
                if let offline {
                    let file: URL?
                    if let url = offline.artworkURL { file = url }
                    else if case .file(let url) = offline.artwork { file = url }
                    else { file = nil }
                    if let file, file.isFileURL, FileManager.default.fileExists(atPath: file.path) {
                        replacement = offline
                    }
                }
                return item.replacingArtwork(from: replacement)
            }
            if existing != updated {
                contents[id] = updated
                if playlist(id)?.isReadOnly == false, updated.contains(where: \.isOnline) { changedLocalContent = true }
            }
        }
        if changedLocalContent { markRestoredMetadataChanged() }
    }

    var onlineStatus: String?
    var isRefreshingOnline = false
    @ObservationIgnored var retryOnline: (@MainActor () async -> Void)?

    /// Online refreshes update only online metadata; local scan owns local availability.
    func reconcileOnlineSongs(_ songs: [LibrarySongItem]) {
        let lookup = Dictionary(songs.filter { $0.isOnline && $0.onlineOwnerID == restoredOnlineOwnerID }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changedLocalContent = false
        for id in contents.keys {
            let updated = contents[id]?.map { song in
                if let offline = offlineSong?(song.id) { return offline }
                guard song.id.hasPrefix("netease:") else { return song }
                guard song.onlineOwnerID == restoredOnlineOwnerID else { return LibrarySongItem.unavailable(song.id) }
                return lookup[song.id] ?? song
            }
            if contents[id] != updated {
                contents[id] = updated
                if playlist(id)?.isReadOnly == false { changedLocalContent = true }
            }
        }
        if changedLocalContent { markRestoredMetadataChanged() }
    }

    /// File removal changes the resource reference without removing a playlist entry.
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

    /// The background lifecycle flushes metadata arrivals together; user edits also save them.
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

    /// Local playlists restore independently; reveal their saved online metadata only for the restored owner.
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
    @ObservationIgnored private var persistenceRevision = 0
    @ObservationIgnored private var persistenceFailures: [URL: String] = [:]
    @ObservationIgnored private var persistenceBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Metadata edits reuse the exact stored PNG instead of rasterizing every cover again.
    @ObservationIgnored private var savedArtwork: [String: (image: Image, data: Data)] = [:]

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

    /// Restore stable identities immediately; the verified scan resolves missing metadata.
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
                // Leave an unreadable store untouched; do not overwrite it with an empty library.
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
        guard !loadingPersistence, let url = persistenceURL else { return }
        saveOnlinePreferences()
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
        markRestoredMetadataChanged()
        enqueuePersistence(snapshot, to: url, failureMessage: "无法保存播放列表")
    }

    private func enqueuePersistence<Value: Encodable & Sendable>(_ value: Value, to url: URL, failureMessage: String) {
        let previous = persistenceTask
        let persistence = persistence
        persistenceRevision += 1
        let revision = persistenceRevision
        let metadataRevision = restoredMetadataRevision
        persistenceTask = Task {
            await previous?.value
            do {
                try await persistence.save(value, to: url)
                persistenceFailures[url] = nil
                if url == persistenceURL, metadataRevision == restoredMetadataRevision {
                    restoredMetadataNeedsSave = false
                }
            } catch {
                persistenceFailures[url] = "\(failureMessage)：\(error.localizedDescription)"
            }
            persistenceError = persistenceFailures.sorted { $0.key.path < $1.key.path }.first?.value
            if persistenceRevision == revision { persistenceTask = nil }
        }
    }

    /// Wait for every submitted snapshot, including writes added while suspended.
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

    /// 仍在某个自建播放列表中的歌曲，及其最近一次被加入的时间。
    func playlistSongAddedDates() -> [String: Date] {
        let present = Set(playlists.filter { !$0.isSystem }.flatMap { contents[$0.id, default: []].map(\.id) })
        return songAddedAt.filter { present.contains($0.key) }
    }

    func songsAddedToPlaylists() -> [LibrarySongItem] {
        let dates = playlistSongAddedDates()
        var songs: [String: LibrarySongItem] = [:]
        for playlist in playlists where !playlist.isSystem {
            for song in contents[playlist.id, default: []] where dates[song.id] != nil {
                songs[song.id] = song
            }
        }
        return Array(songs.values)
    }

    func containedSong(_ id: String) -> LibrarySongItem? {
        for songs in contents.values {
            if let song = songs.first(where: { $0.id == id }) { return song }
        }
        return nil
    }

    /// 单次选择确认后才提交，保留选择顺序；已有歌曲不重复加入。
    /// 按顺序加到播放列表末尾，已在列表中的歌曲跳过；返回实际加入的数量。
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

    /// 没有自定封面的播放列表用第一首歌的封面，与 Apple Music 一致。
    func displayArtwork(of playlist: LibraryPlaylistItem) -> Artwork {
        if case .playlist = playlist.artwork, let first = contents[playlist.id]?.first { return first.artwork }
        return playlist.artwork
    }

    /// 歌曲从资料库删除时，也从所有播放列表移除。
    func removeSongEverywhere(_ songID: String) {
        defer { persist() }
        for id in contents.keys where playlist(id)?.isReadOnly != true && contents[id]?.contains(where: { $0.id == songID }) == true {
            contents[id]?.removeAll { $0.id == songID }
            markUpdated(id)
        }
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
        persist()
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

    /// 文件夹中直接包含的播放列表数量。
    func playlistCount(in folderID: String) -> Int { playlists(in: folderID).count }

    /// 创建播放列表并保存。
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

    /// 把播放列表移到某个文件夹；`nil` 为最外层。
    func move(playlistID: String, to folderID: String?) {
        defer { persist() }
        guard placement[playlistID] != folderID else { return }
        placement[playlistID] = folderID
        recentMove = folderID.map { RecentMove(folderID: $0) }
    }

    func clearRecentMove(_ move: RecentMove) {
        if recentMove == move { recentMove = nil }
    }

    /// 用户自己的播放列表可以删除；“喜爱歌曲”等系统播放列表不能删除。
    func canDelete(_ playlistID: String) -> Bool {
        playlists.contains { $0.id == playlistID && !$0.isSystem && !$0.isReadOnly }
    }

    /// 网易云收藏的歌单可以取消收藏。
    func canUnsubscribe(_ playlistID: String) -> Bool {
        playlists.contains { $0.id == playlistID && $0.isSubscribed }
    }

    /// 从资料库删除播放列表，只删记录，不碰音乐文件。收藏歌单改为请求网易云取消收藏。
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

    /// 取消收藏后丢掉本地留下的引用，避免卡片在下次同步时又出现。
    func releaseRetainedOnlinePlaylist(_ id: String) {
        let hadPreference = onlinePreferences.removeValue(forKey: id) != nil
        if hadPreference { saveOnlinePreferences(force: true) }
        guard playlist(id)?.isReadOnly == true else { return }
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }

    /// 删除文件夹及其中的子文件夹与播放列表，对照 Apple Music。只删资料库记录，不碰音乐文件；
    /// “喜爱歌曲”等系统播放列表不能删除，移回最外层。
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

    /// 把文件夹移到另一个文件夹；`nil` 为最外层。不能移进自己或自己的子文件夹。
    func move(folderID: String, to parentID: String?) {
        defer { persist() }
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              !(parentID.map { isDescendant($0, of: folderID) } ?? false) else { return }
        folders[index].parentID = parentID
    }

    /// `id` 是否为 `ancestorID` 本身或其子孙文件夹。
    func isDescendant(_ id: String, of ancestorID: String) -> Bool {
        var current: String? = id
        while let value = current {
            if value == ancestorID { return true }
            current = folder(value)?.parentID
        }
        return false
    }
}
