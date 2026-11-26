import SwiftUI
import Observation

@MainActor @Observable
final class SearchMusicIntegration {
    static let searchPrompt = "网易云音乐中的歌曲、艺人、专辑及歌单"
    let model = SearchPageModel(searchPrompt: SearchMusicIntegration.searchPrompt)
    var showsLogin = false
    @ObservationIgnored private let account: NeteaseAccount
    private let container: AppContainer
    @ObservationIgnored private let player: NowPlayingModel
    @ObservationIgnored private let playlistLibrary: PlaylistLibrary
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queryID = UUID()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var resources: [String: NeteaseSearchResource] = [:]
    @ObservationIgnored private var artworkURLs: [String: URL] = [:]
    @ObservationIgnored private var publishedSongs: [String: LibrarySongItem] = [:]
    @ObservationIgnored private var lastPublished: [LibrarySongItem] = []
    @ObservationIgnored private var displayedQuery = ""

    @ObservationIgnored var prepareNavigation: ((LibraryNavigationPreview) -> Void)?
    @ObservationIgnored var onPublication: (() -> Void)?

    convenience init(account: NeteaseAccount, player: NowPlayingModel = AppContainer.shared.player,
                     playlistLibrary: PlaylistLibrary = AppContainer.shared.playlistLibrary) {
        self.init(account: account, container: .shared, player: player, playlistLibrary: playlistLibrary)
    }

    init(account: NeteaseAccount, container: AppContainer, player: NowPlayingModel? = nil,
         playlistLibrary: PlaylistLibrary? = nil) {
        self.account = account
        self.container = container
        self.player = player ?? container.player
        self.playlistLibrary = playlistLibrary ?? container.playlistLibrary
    }
    private var store: NeteaseSearchStore? { account.search }

    func connect() {
        guard !connected else { return }; connected = true
        model.onQuery = { [weak self] in self?.runQuery() }
        model.onSubmit = { [weak self] in
            guard let self else { return }
            store?.record(model.query); runQuery()
        }
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
        model.onPrepareNavigation = { [weak self] in self?.prepareNavigation?($0) }
        model.onOpen = { [weak self] in self?.play($0) }
        model.onRemoveHistory = { [weak self] query in
            guard let self else { return }
            store?.removeHistory(query); model.history = store?.recent() ?? []
        }
        store?.onArtworkChange = { [weak self] in self?.publishArtwork($0) }
        observeSearch()
        observeSongState()
        Task { await store?.loadCategories() }
    }

    private func observeSearch() {
        withObservationTracking {
            _ = store?.sessionID; _ = store?.page; _ = store?.suggestions; _ = store?.history
            _ = store?.isLoading; _ = store?.isLoadingMore; _ = store?.error; _ = store?.moreError; _ = store?.suggestionError
            _ = store?.categories; _ = store?.isLoadingCategories; _ = store?.categoriesError
            _ = store?.categoryPage; _ = store?.isLoadingCategory; _ = store?.isLoadingMoreCategory
            _ = store?.categoryError; _ = store?.categoryMoreError
        } onChange: { [weak self] in Task { @MainActor in self?.observeSearch() } }
        if sessionID != store?.sessionID {
            sessionID = store?.sessionID
            queryTask?.cancel(); queryID = UUID()
            resources = [:]; artworkURLs = [:]; publishedSongs = [:]
            lastPublished = []
            container.songLibrary.replaceExternalSongs([], source: "search")
            model.cachedGroups = [:]; model.groups = []; model.suggestions = []; model.categoryItems = []
            showsLogin = false
            Task { await store?.loadCategories() }
            if let category = model.category { Task { await store?.openCategory(category) } }
            if !model.query.isEmpty { runQuery() }
        }
        publish()
    }

    private func observeSongState() {
        withObservationTracking {
            _ = account.downloads?.records
            if let downloads = account.downloads, !downloads.availableFileIDs.isEmpty {
                _ = container.songLibrary.songs
            }
            _ = account.music?.likedIDs
        } onChange: { [weak self] in Task { @MainActor in self?.observeSongState() } }
        publish()
    }

    private func runQuery(force: Bool = false) {
        queryTask?.cancel()
        let id = UUID(); queryID = id
        let query = model.query, kind = model.kind, submitted = model.submitted
        if displayedQuery != query {
            displayedQuery = query
            model.cachedGroups = [:]; model.groups = []
            if !publishedSongs.isEmpty || !resources.isEmpty {
                let referenced = ReferencedLibrarySongs.collect(player: player, playlists: playlistLibrary)
                let ids = Set(referenced.map(\.id))
                let owner = store?.sessionOwnerID ?? "search-guest"
                let onlineIDs = Set(referenced.filter { $0.onlineOwnerID == owner }.compactMap(\.onlineSongID))
                publishedSongs = publishedSongs.filter { ids.contains($0.key) }
                resources = resources.filter { $0.value.song.map { onlineIDs.contains($0.id) } == true }
            }
        }
        model.history = store?.recent() ?? []
        model.error = nil; model.moreError = nil; model.hasMore = false
        if !submitted { model.keywords = []; model.suggestions = [] }
        model.isLoading = !query.isEmpty
        queryTask = Task {
            await store?.cancelQuery()
            guard !Task.isCancelled, queryID == id else { return }
            guard !query.isEmpty else { model.isLoading = false; publish(); return }
            if submitted {
                await store?.search(query, kind: NeteaseSearchKind(rawValue: kind.rawValue) ?? .combined, force: force)
            } else {
                await store?.suggest(query)
            }
            guard !Task.isCancelled, queryID == id else { return }
            model.isLoading = false; publish()
        }
    }

    private func refresh() async {
        if !model.isSearching && !model.submitted {
            await store?.loadCategories(force: true)
        } else {
            runQuery(force: true)
            await queryTask?.value
        }
    }

    private func publish() {
        guard let store else { return }
        assign(\.ownerID, store.sessionOwnerID)
        assign(\.categories, Self.categoryItems(store.categories))
        assign(\.history, store.recent())
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
        } else if model.isSearching {
            assign(\.keywords, store.suggestions.keywords)
            assign(\.suggestions, store.suggestions.resources.map(mapItem))
            assign(\.error, store.suggestionError)
        } else {
            assign(\.isLoading, store.isLoadingCategories)
            assign(\.error, store.categoriesError)
        }
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
            let id = OnlineSongIdentity.format(ownerID: store?.sessionOwnerID ?? "search-guest", song: value.id)
            song = OnlineSongProjector.makeSong(
                value,
                id: id,
                artwork: cover,
                artworkURL: value.artworkURL.flatMap { store?.cachedArtwork($0) },
                isFavorite: account.music?.likedIDs.contains(value.id) == true,
                favoriteAddedAt: account.music?.likedAt[value.id]
            )
            if retainingPreviousArtwork {
                song = song?.retainingArtwork(from: publishedSongs[id] ?? container.songLibrary.song(id: id))
            }
            if let downloads = account.downloads, downloads.availableFileIDs.contains(value.id),
               let record = downloads.records[value.id],
               let local = container.songLibrary.song(id: record.relativePath) { song = local }
            if let song { publishedSongs[song.id] = song }
        }
        let route: LibraryRoute?
        switch resource.kind {
        case .album: route = .album(CatalogRouteIdentity.albumID(resource.resourceID))
        case .artist: route = .artist(CatalogRouteIdentity.artistID(resource.resourceID))
        case .playlist: route = .playlist(PlaylistRouteIdentity.homePlaylistID(resource.resourceID))
        default: route = nil
        }
        return .init(id: resource.id, kind: kind, title: resource.title, subtitle: resource.subtitle,
                     artwork: song?.artwork ?? cover, song: song, route: route)
    }

    private func artwork(_ remote: URL?, id: String) -> Artwork {
        guard let remote else { return .missing }
        let key = DeferredArtworkKey(domain: .search, session: sessionID?.uuidString ?? "guest", payload: id).rawValue
        artworkURLs[key] = remote
        if let file = store?.cachedArtwork(remote) { return .file(file) }
        return .deferred(id: key, placeholder: .missing)
    }
    func requestArtwork(for id: String) {
        guard let store, let sessionID, sessionID == store.sessionID,
              DeferredArtworkRoute.key(id, session: sessionID, domain: .search) != nil,
              let url = artworkURLs[id] else { return }
        store.requestArtwork(url)
    }
    func cachedArtworkFile(for id: String) async -> URL? {
        guard let store, let sessionID else { return nil }
        return await DeferredArtworkRoute.cachedFile(id, session: sessionID, domain: .search,
            isCurrent: { sessionID == store.sessionID }) { key in
                guard let url = artworkURLs[key.rawValue] else { return nil }
                return await store.cachedArtworkFile(url)
            }
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
        container.songLibrary.updateOnlineArtwork(songs, source: "search")
        playlistLibrary.updateArtwork(songs: songs)
    }

    private func publishSongs() {
        let values = publishedSongs.values.sorted { $0.id < $1.id }
        guard values != lastPublished else { return }
        lastPublished = values
        container.songLibrary.replaceExternalSongs(values, source: "search")
        onPublication?()
    }

    func play(_ item: MusicSearchItem) {
        guard let target = item.song else { return }
        let candidates = model.submitted ? model.groups.flatMap(\.items) : model.suggestions
        let songs = candidates.compactMap(\.song)
        guard let index = songs.firstIndex(where: { $0.id == target.id }) else { return }
        if requiresLogin(for: target) { showsLogin = true; return }
        player.requestPlay(songs, startingAt: index, from: model.query)
    }

    private func requiresLogin(for song: LibrarySongItem) -> Bool {
        guard let owner = song.onlineOwnerID else { return false }
        return account.restoredPlaybackIdentity != .signedIn(owner)
    }

    var songActions: SongMenuActions {
        var actions = container.songActions(for: .category(.songs))
        let next = actions.playNext, later = actions.playLater, favorite = actions.toggleFavorite, add = actions.addToPlaylist
        func authorized(_ song: LibrarySongItem, _ action: (LibrarySongItem) -> Void) {
            if requiresLogin(for: song) { showsLogin = true } else { action(song) }
        }
        actions.playNext = { authorized($0, next) }; actions.playLater = { authorized($0, later) }
        actions.toggleFavorite = { authorized($0, favorite) }; actions.addToPlaylist = { authorized($0, add) }
        return actions
    }
}
