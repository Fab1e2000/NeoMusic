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
                _ = playlistLibrary.playlists
            }
            _ = account.downloads?.records
            _ = account.music?.likedIDs
        } onChange: { [weak self] in Task { @MainActor in self?.observeLibraryPresentation() } }
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
        func update(_ items: inout [MusicSearchItem]) {
            for i in items.indices {
                if let replacement = replacements[items[i].id] { items[i] = replacement }
            }
        }
        update(&model.suggestions); update(&model.categoryItems)
        for i in model.groups.indices { update(&model.groups[i].items) }
        for kind in model.cachedGroups.keys {
            guard var groups = model.cachedGroups[kind] else { continue }
            for i in groups.indices { update(&groups[i].items) }
            model.cachedGroups[kind] = groups
        }
        publishSongs()
        let songs = Dictionary(replacements.values.compactMap(\.song).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistLibrary.updateArtwork(songs: songs)
        player.updateArtwork(songs)
    }
    private func publishSongs() {
        let values = publishedSongs.values.sorted { $0.id < $1.id }
        guard values != lastPublished else { return }
        lastPublished = values
        LocalLibrary.songLibrary.replaceExternalSongs(values, source: "search")
        onPublication?()
    }

    private func publishLibrary() {
        var items = libraryResults.map(mapItem)
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
        let matched = Self.matchLibrary(items, query: model.query)
        if model.submitted {
            let groups: [MusicSearchGroup] = MusicSearchKind.allCases.filter { $0 != .combined && (model.kind == .combined || model.kind == $0) }.compactMap { kind in
                let values = matched.filter { $0.kind == kind }
                return values.isEmpty ? nil : .init(kind: kind, items: values, hasMore: values.count > 3)
            }
            assign(\.groups, groups)
            if model.cachedGroups[model.kind] != groups { model.cachedGroups[model.kind] = groups }
        } else { assign(\.keywords, []); assign(\.suggestions, matched) }
        assign(\.hasMore, false); assign(\.isLoadingMore, false); assign(\.moreError, nil)
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
