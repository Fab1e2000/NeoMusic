import SwiftUI
import Observation

/// Projects account-owned search results into the existing library and playback UI.
@MainActor @Observable
final class SearchMusicIntegration {
    let model = SearchPageModel()
    var showsLogin = false
    @ObservationIgnored private let account: NeteaseAccount
    @ObservationIgnored private let player: NowPlayingModel
    @ObservationIgnored private let playlistLibrary: PlaylistLibrary
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queryID = UUID()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var resources: [String: NeteaseSearchResource] = [:]
    @ObservationIgnored private var libraryResults: [NeteaseSearchResource] = []
    @ObservationIgnored private var artworkURLs: [String: URL] = [:]
    @ObservationIgnored private var publishedSongs: [String: LibrarySongItem] = [:]
    @ObservationIgnored private var lastPublished: [LibrarySongItem] = []
    @ObservationIgnored private var displayedQuery = ""
    @ObservationIgnored private var indexedRevision: Int?
    @ObservationIgnored private let libraryMatcher = LibrarySearchMatcher()
    @ObservationIgnored private var libraryPublicationTask: Task<Void, Never>?
    @ObservationIgnored private var libraryPublicationID = UUID()
    @ObservationIgnored private var libraryItems: [MusicSearchItem]?

    @ObservationIgnored var prepareNavigation: ((LibraryNavigationPreview) -> Void)?
    @ObservationIgnored var onPublication: (() -> Void)?

    init(account: NeteaseAccount, player: NowPlayingModel = LocalLibrary.player,
         playlistLibrary: PlaylistLibrary = LocalLibrary.playlistLibrary) {
        self.account = account; self.player = player; self.playlistLibrary = playlistLibrary
    }
    private var store: NeteaseSearchStore? { account.search }
    private var scopeKey: String { model.scope == .online ? "online" : "library" }

    func connect() {
        guard !connected else { return }; connected = true
        model.onQuery = { [weak self] in self?.runQuery() }
        model.onSubmit = { [weak self] in
            guard let self else { return }
            store?.record(model.query, scope: scopeKey); runQuery()
        }
        model.onScope = { [weak self] in self?.model.cachedGroups = [:]; self?.runQuery() }
        model.onKind = { [weak self] in self?.runQuery() }
        model.onRetry = { [weak self] in Task { await self?.refresh() } }
        model.onRefresh = { [weak self] in await self?.refresh() }
        model.onMore = { [weak self] in Task { await self?.store?.loadMore() } }
        model.onCategory = { [weak self] name in
            guard let self else { return }
            model.category = name; model.categoryItems = []; model.categoryLoading = true
            Task { await self.store?.openCategory(name) }
        }
        model.onCategoryRefresh = { [weak self] in
            guard let self, let name = model.category else { return }
            await store?.openCategory(name, force: true)
        }
        model.onCategoryMore = { [weak self] in Task { await self?.store?.loadMoreCategory() } }
        model.onArtwork = { [weak self] in self?.requestArtwork(for: $0) }
        model.onPrepareNavigation = { [weak self] in self?.prepareNavigation?($0) }
        model.onOpen = { [weak self] in self?.play($0) }
        model.onRemoveHistory = { [weak self] query in
            guard let self else { return }
            store?.removeHistory(query, scope: scopeKey); model.history = store?.recent(scope: scopeKey) ?? []
        }
        store?.onArtworkChange = { [weak self] in self?.publishArtwork($0) }
        observeSearch()
        observeLibrary()
        Task { await store?.loadCategories() }
    }

    private func observeSearch() {
        withObservationTracking {
            _ = account.profile
            _ = store?.sessionID; _ = store?.page; _ = store?.suggestions; _ = store?.history
            _ = store?.isLoading; _ = store?.isLoadingMore; _ = store?.error; _ = store?.moreError; _ = store?.suggestionError
            _ = store?.categories; _ = store?.isLoadingCategories; _ = store?.categoriesError
            _ = store?.categoryPage; _ = store?.isLoadingCategory; _ = store?.isLoadingMoreCategory
            _ = store?.categoryError; _ = store?.categoryMoreError
        } onChange: { [weak self] in Task { @MainActor in self?.observeSearch() } }
        if sessionID != store?.sessionID {
            sessionID = store?.sessionID
            queryTask?.cancel(); queryID = UUID()
            libraryPublicationTask?.cancel(); libraryPublicationID = UUID(); libraryItems = nil
            resources = [:]; artworkURLs = [:]; libraryResults = []; publishedSongs = [:]
            lastPublished = []
            LocalLibrary.songLibrary.replaceExternalSongs([], source: "search")
            model.cachedGroups = [:]; model.groups = []; model.suggestions = []; model.categoryItems = []
            showsLogin = false
            Task { await store?.loadCategories() }
            if let category = model.category { Task { await store?.openCategory(category) } }
            if !model.query.isEmpty { runQuery() }
        }
        publish()
    }

    private func observeLibrary() {
        observeLibraryIndex()
        observeLibraryPresentation()
    }

    /// Sync progress only updates the status line. Requery when the index revision changes.
    private func observeLibraryIndex() {
        withObservationTracking {
            _ = account.librarySearch?.revision; _ = account.librarySearch?.isSyncing
            _ = account.librarySearch?.completed; _ = account.librarySearch?.total
            _ = account.librarySearch?.failedCollections; _ = account.librarySearch?.error
        } onChange: { [weak self] in Task { @MainActor in self?.observeLibraryIndex() } }
        publishSync()
        let revision = account.librarySearch?.revision
        guard revision != indexedRevision else { return }
        indexedRevision = revision
        if model.scope == .library, !model.query.isEmpty { runQuery() }
    }

    /// The full local catalog is read only while library results are on screen.
    private func observeLibraryPresentation() {
        withObservationTracking {
            _ = model.scope
            if model.scope == .library {
                _ = LocalLibrary.songLibrary.songs
                _ = LocalLibrary.albums
                _ = LocalLibrary.artists
                for playlist in playlistLibrary.playlists where playlist.sourceOwnerID == nil {
                    _ = playlistLibrary.songs(in: playlist.id)
                }
            }
            _ = account.downloads?.records
            _ = account.music?.likedIDs
        } onChange: { [weak self] in Task { @MainActor in self?.observeLibraryPresentation() } }
        libraryItems = nil
        if model.scope == .library, !model.query.isEmpty { runQuery() }
        else { publish() }
    }

    private func publishSync() {
        guard let index = account.librarySearch else { return }
        assign(\.syncFailed, !index.failedCollections.isEmpty || index.error != nil)
        let status: String?
        if index.isSyncing { status = "正在同步资料库 · \(index.completed)/\(index.total) 个集合" }
        else if let error = index.error { status = error }
        else if !index.failedCollections.isEmpty { status = "\(index.failedCollections.count) 个集合尚未同步" }
        else { status = nil }
        assign(\.syncStatus, status)
    }

    private func runQuery(force: Bool = false) {
        queryTask?.cancel()
        libraryPublicationTask?.cancel(); libraryPublicationID = UUID()
        let id = UUID(); queryID = id
        let query = model.query, scope = model.scope, kind = model.kind, submitted = model.submitted
        if displayedQuery != query {
            displayedQuery = query
            model.cachedGroups = [:]; model.groups = []
            let playlistSongs = playlistLibrary.playlists.filter { !$0.isReadOnly && !$0.isSystem }
                .flatMap { playlistLibrary.songs(in: $0.id) }
            let referenced = player.queue + playlistSongs
            let ids = Set(referenced.map(\.id))
            let onlineIDs = Set(referenced.filter { $0.onlineOwnerID == account.profile.map({ String($0.userID) }) }.compactMap(\.onlineSongID))
            publishedSongs = publishedSongs.filter { ids.contains($0.key) }
            resources = resources.filter { $0.value.song.map { onlineIDs.contains($0.id) } == true }
            libraryResults = []
        }
        model.history = store?.recent(scope: scopeKey) ?? []
        model.error = nil; model.moreError = nil; model.hasMore = false
        if !submitted { model.keywords = []; model.suggestions = [] }
        model.isLoading = !query.isEmpty
        queryTask = Task {
            await store?.cancelQuery()
            guard !Task.isCancelled, queryID == id else { return }
            guard !query.isEmpty else { model.isLoading = false; publish(); return }
            if scope == .online {
                if submitted { await store?.search(query, kind: NeteaseSearchKind(rawValue: kind.rawValue) ?? .combined, force: force) }
                else { await store?.suggest(query) }
            } else {
                do {
                    let result = try await account.librarySearch?.search(query) ?? []
                    guard !Task.isCancelled, queryID == id else { return }
                    libraryResults = result
                } catch is CancellationError { return }
                catch { if queryID == id { model.error = error.localizedDescription } }
            }
            guard !Task.isCancelled, queryID == id else { return }
            model.isLoading = false; publish()
        }
    }

    private func refresh() async {
        if model.scope == .library, model.isSearching || model.submitted {
            await account.librarySearch?.synchronize(force: true)
            runQuery(); await queryTask?.value
        } else if !model.isSearching && !model.submitted { await store?.loadCategories(force: true) }
        else { runQuery(force: true); await queryTask?.value }
    }

    private func publish() {
        guard let store else { return }
        assign(\.ownerID, account.profile.map { String($0.userID) })
        assign(\.categories, Self.categoryItems(store.categories))
        assign(\.history, store.recent(scope: scopeKey))
        if !model.isSearching && !model.submitted { assign(\.isLoading, store.isLoadingCategories); assign(\.error, store.categoriesError) }
        else if model.scope == .online {
            if model.submitted {
                let matches = store.request?.query == model.query && store.request?.kind.rawValue == model.kind.rawValue
                let groups = matches ? (store.page?.groups.map(mapGroup) ?? []) : []
                assign(\.groups, groups)
                assign(\.isLoading, matches ? store.isLoading : model.isLoading)
                assign(\.error, matches ? store.error : nil)
                assign(\.moreError, matches ? store.moreError : nil)
                assign(\.hasMore, matches && store.page?.hasMore == true && model.kind != .combined)
                assign(\.isLoadingMore, store.isLoadingMore)
                if model.cachedGroups[model.kind] != groups { model.cachedGroups[model.kind] = groups }
            } else {
                assign(\.keywords, store.suggestions.keywords)
                assign(\.suggestions, store.suggestions.resources.map(mapItem))
                assign(\.error, store.suggestionError)
            }
        } else { publishLibrary() }
        if store.category == model.category {
            assign(\.categoryItems, store.categoryPage?.groups.flatMap(\.items).map(mapItem) ?? [])
            assign(\.categoryLoading, store.isLoadingCategory)
            assign(\.categoryMoreLoading, store.isLoadingMoreCategory)
            assign(\.categoryHasMore, store.categoryPage?.hasMore == true)
            assign(\.categoryError, store.categoryError)
            assign(\.categoryMoreError, store.categoryMoreError)
        }
        publishSongs()
    }

    static func categoryItems(_ categories: [NeteaseSearchCategory]) -> [MusicSearchCategory] {
        categories.enumerated().map { index, item in
            .init(id: item.id, title: item.name, colorIndex: index, group: item.group, isHot: item.isHot)
        }
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SearchPageModel, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }

    private func mapGroup(_ group: NeteaseSearchGroup) -> MusicSearchGroup {
        .init(kind: MusicSearchKind(rawValue: group.kind.rawValue) ?? .song, items: group.items.map(mapItem), hasMore: group.hasMore)
    }
    private func mapItem(_ resource: NeteaseSearchResource) -> MusicSearchItem {
        mapItem(resource, retainingPreviousArtwork: true)
    }
    private func mapItem(_ resource: NeteaseSearchResource, retainingPreviousArtwork: Bool) -> MusicSearchItem {
        resources[resource.id] = resource
        let kind = MusicSearchKind(rawValue: resource.kind.rawValue) ?? .song
        let cover = resource.kind == .playlist ? HomeMusicIntegration.playlistArtwork(id: resource.resourceID, home: account.home) : artwork(resource.artworkURL, id: resource.id)
        var song: LibrarySongItem?
        if let value = resource.song {
            let id = "netease:\(account.profile.map { String($0.userID) } ?? "search-guest"):\(value.id)"
            song = LibrarySongItem(id: id, title: value.title, artist: value.artist, album: value.album,
                albumArtist: value.artist, trackNumber: value.trackNumber ?? 0, artwork: cover, discNumber: value.discNumber ?? 1,
                artworkURL: value.artworkURL.flatMap { store?.cachedArtwork($0) }, duration: Int(value.duration),
                isFavorite: account.music?.likedIDs.contains(value.id) == true, favoriteAddedAt: account.music?.likedAt[value.id],
                unavailabilityReason: value.unavailable ? "暂无完整音源" : nil, onlineAlbumID: value.albumID,
                artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
            if retainingPreviousArtwork {
                song = song?.retainingArtwork(from: publishedSongs[id] ?? LocalLibrary.songLibrary.song(id: id))
            }
            if let record = account.downloads?.records[value.id], account.downloads?.resource(songID: value.id) != nil,
               let local = LocalLibrary.songLibrary.song(id: record.relativePath) { song = local }
            if let song { publishedSongs[song.id] = song }
        }
        let route: LibraryRoute?
        switch resource.kind {
        case .album: route = .album("catalog:album:\(resource.resourceID)")
        case .artist: route = .artist("catalog:artist:\(resource.resourceID)")
        case .playlist: route = .playlist("home:playlist:\(resource.resourceID)")
        default: route = nil
        }
        return .init(id: resource.id, kind: kind, title: resource.title, subtitle: resource.subtitle,
                     artwork: song?.artwork ?? cover, song: song, route: route)
    }

    private func artwork(_ remote: URL?, id: String) -> Artwork {
        guard let remote else { return .missing }
        let key = "search-artwork:\(sessionID?.uuidString ?? "guest"):\(id)"
        artworkURLs[key] = remote
        if let file = store?.cachedArtwork(remote) { return .file(file) }
        return .deferred(id: key, placeholder: .missing)
    }
    func requestArtwork(for id: String) {
        guard let url = artworkURLs[id] else { return }
        store?.requestArtwork(url)
    }
    private func publishArtwork(_ urls: Set<URL>) {
        guard sessionID == store?.sessionID else { return }
        let affected = resources.values.filter { $0.artworkURL.map(urls.contains) == true }
        let replacements = Dictionary(uniqueKeysWithValues: affected.map { ($0.id, mapItem($0, retainingPreviousArtwork: false)) })
        let songs = Dictionary(replacements.values.compactMap(\.song).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        player.updateArtwork(songs)
        func update(_ items: [MusicSearchItem]) {
            for item in items {
                guard let replacement = replacements[item.id] else { continue }
                item.$artwork.update(replacement.artwork)
                if let song = replacement.song { item.song?.publishArtwork(from: song) }
            }
        }
        update(model.suggestions); update(model.categoryItems)
        for group in model.groups { update(group.items) }
        for groups in model.cachedGroups.values {
            for group in groups { update(group.items) }
        }
        LocalLibrary.songLibrary.updateOnlineArtwork(songs, source: "search")
        playlistLibrary.updateArtwork(songs: songs)
    }

    private func publishSongs() {
        let values = publishedSongs.values.sorted { $0.id < $1.id }
        guard values != lastPublished else { return }
        lastPublished = values
        LocalLibrary.songLibrary.replaceExternalSongs(values, source: "search")
        onPublication?()
    }

    private func makeLibraryItems() -> [MusicSearchItem] {
        if let libraryItems { return libraryResults.map(mapItem) + libraryItems }
        var items: [MusicSearchItem] = []
        let downloads = account.downloads?.records.values ?? Dictionary<Int64, NeteaseDownloadRecord>().values
        let paths = Dictionary(downloads.map { ($0.relativePath, $0.songID) }, uniquingKeysWith: { a, _ in a })
        for song in LocalLibrary.songs {
            let id = paths[song.id].map { "1:\($0)" } ?? "local-song:\(song.id)"
            items.append(.init(id: id, kind: .song, title: song.title, subtitle: song.artist, artwork: song.artwork, song: song))
        }
        for playlist in playlistLibrary.playlists where playlist.sourceOwnerID == nil {
            items.append(.init(id: "local-playlist:\(playlist.id)", kind: .playlist, title: playlist.title,
                subtitle: playlist.subtitle ?? "我", artwork: playlistLibrary.displayArtwork(of: playlist), route: .playlist(playlist.id)))
            for song in playlistLibrary.songs(in: playlist.id) {
                let onlineID = song.onlineSongID ?? paths[song.id]
                let id = onlineID.map { "1:\($0)" } ?? "local-song:\(song.id)"
                items.append(.init(id: id, kind: .song, title: song.title, subtitle: song.artist, artwork: song.artwork, song: song))
            }
        }
        for album in LocalLibrary.albums where !album.id.hasPrefix("catalog:") {
            items.append(.init(id: "local-album:\(album.id)", kind: .album, title: album.title,
                subtitle: album.subtitle ?? "", artwork: album.artwork, route: .album(album.id)))
        }
        for artist in LocalLibrary.artists where !artist.id.hasPrefix("catalog:") {
            items.append(.init(id: "local-artist:\(artist.id)", kind: .artist, title: artist.name,
                subtitle: "艺人", artwork: artist.artwork ?? .missing, route: .artist(artist.id)))
        }
        // Bind the cached cards to the source resources without observing images in the index.
        let playlistByID = Dictionary(playlistLibrary.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumByID = Dictionary(LocalLibrary.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let artistByID = Dictionary(LocalLibrary.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            if let song = item.song { observeLibraryArtwork(item, read: { song.artwork }) }
            else if case .playlist(let id) = item.route,
                    let playlist = playlistByID[id] {
                observeLibraryArtwork(item, read: { [playlistLibrary] in playlistLibrary.displayArtwork(of: playlist) })
            } else if case .album(let id) = item.route,
                      let album = albumByID[id] {
                observeLibraryArtwork(item, read: { album.artwork })
            } else if case .artist(let id) = item.route,
                      let artist = artistByID[id] {
                observeLibraryArtwork(item, read: { artist.artwork ?? .missing })
            }
        }
        libraryItems = items
        return libraryResults.map(mapItem) + items
    }

    @MainActor private final class LibraryArtworkBinding {
        let item: MusicSearchItem
        let read: @MainActor () -> Artwork
        init(item: MusicSearchItem, read: @escaping @MainActor () -> Artwork) {
            self.item = item; self.read = read
        }
    }

    private func observeLibraryArtwork(_ item: MusicSearchItem, read: @escaping @MainActor () -> Artwork) {
        observeLibraryArtwork(LibraryArtworkBinding(item: item, read: read))
    }

    private func observeLibraryArtwork(_ binding: LibraryArtworkBinding) {
        let value = withObservationTracking { binding.read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.libraryItems?.contains(where: { $0.$artwork === binding.item.$artwork }) == true else { return }
                self.observeLibraryArtwork(binding)
            }
        }
        binding.item.$artwork.update(value)
    }

    private func publishLibrary() {
        libraryPublicationTask?.cancel()
        let id = UUID(); libraryPublicationID = id
        let items = makeLibraryItems()
        let candidates = items.map { LibrarySearchMatcher.Candidate(id: $0.id, title: $0.title,
            subtitle: $0.subtitle, album: $0.song?.album ?? "", prefersLocal: $0.song?.isOnline == false) }
        let query = model.query, owner = sessionID, kind = model.kind, submitted = model.submitted
        libraryPublicationTask = Task {
            let indices = await libraryMatcher.match(candidates, query: query)
            guard !Task.isCancelled, libraryPublicationID == id, sessionID == owner,
                  model.scope == .library, model.query == query else { return }
            let matched = indices.map { items[$0] }
            if submitted {
                let groups: [MusicSearchGroup] = MusicSearchKind.allCases.filter { $0 != .combined && (kind == .combined || kind == $0) }.compactMap { kind in
                    let values = matched.filter { $0.kind == kind }
                    return values.isEmpty ? nil : .init(kind: kind, items: values, hasMore: values.count > 3)
                }
                assign(\.groups, groups)
                if model.cachedGroups[kind] != groups { model.cachedGroups[kind] = groups }
            } else { assign(\.keywords, []); assign(\.suggestions, matched) }
            assign(\.hasMore, false); assign(\.isLoadingMore, false); assign(\.moreError, nil)
        }
    }

    static func matchLibrary(_ items: [MusicSearchItem], query: String) -> [MusicSearchItem] {
        let query = NeteaseLibrarySearchIndex.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        var unique: [String: MusicSearchItem] = [:]
        for item in items {
            let text = [item.title, item.subtitle, item.song?.album ?? ""].joined(separator: "\n")
            guard NeteaseLibrarySearchIndex.normalized(text).contains(query) else { continue }
            if unique[item.id] == nil || item.song?.isOnline == false { unique[item.id] = item }
        }
        func rank(_ title: String) -> Int { title == query ? 0 : (title.hasPrefix(query) ? 1 : 2) }
        return unique.values.sorted {
            let a = NeteaseLibrarySearchIndex.normalized($0.title), b = NeteaseLibrarySearchIndex.normalized($1.title)
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a == b ? $0.id < $1.id : a < b
        }
    }

    func play(_ item: MusicSearchItem) {
        guard let target = item.song else { return }
        let candidates = model.submitted ? model.groups.flatMap(\.items) : model.suggestions
        let songs = candidates.compactMap(\.song)
        guard let index = songs.firstIndex(where: { $0.id == target.id }) else { return }
        if target.isOnline, account.profile == nil { showsLogin = true; return }
        player.requestPlay(songs, startingAt: index, from: model.query)
    }

    var songActions: SongMenuActions {
        var actions = LocalLibrary.songActions(for: .category(.songs))
        let next = actions.playNext, later = actions.playLater, favorite = actions.toggleFavorite, add = actions.addToPlaylist
        func authorized(_ song: LibrarySongItem, _ action: (LibrarySongItem) -> Void) {
            if song.isOnline, account.profile == nil { showsLogin = true } else { action(song) }
        }
        actions.playNext = { authorized($0, next) }; actions.playLater = { authorized($0, later) }
        actions.toggleFavorite = { authorized($0, favorite) }; actions.addToPlaylist = { authorized($0, add) }
        return actions
    }
}

/// Only value snapshots cross the actor boundary; artwork and UI state stay on MainActor.
actor LibrarySearchMatcher {
    struct Candidate: Sendable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let album: String
        let prefersLocal: Bool
    }
    private struct Entry {
        let candidate: Candidate
        let title: String
        let text: String
    }
    private var entries: [Entry] = []

    func match(_ candidates: [Candidate], query: String) -> [Int] {
        var updated: [Entry] = []
        updated.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if entries.indices.contains(index), entries[index].candidate == candidate {
                updated.append(entries[index])
            } else {
                updated.append(Entry(candidate: candidate,
                    title: NeteaseLibrarySearchIndex.normalized(candidate.title),
                    text: NeteaseLibrarySearchIndex.normalized([candidate.title, candidate.subtitle, candidate.album].joined(separator: "\n"))))
            }
        }
        entries = updated
        let query = NeteaseLibrarySearchIndex.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        var unique: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where entry.text.contains(query) {
            if unique[entry.candidate.id] == nil || entry.candidate.prefersLocal { unique[entry.candidate.id] = index }
        }
        func rank(_ title: String) -> Int { title == query ? 0 : (title.hasPrefix(query) ? 1 : 2) }
        return unique.values.sorted {
            let a = entries[$0], b = entries[$1]
            if rank(a.title) != rank(b.title) { return rank(a.title) < rank(b.title) }
            return a.title == b.title ? a.candidate.id < b.candidate.id : a.title < b.title
        }
    }
}
