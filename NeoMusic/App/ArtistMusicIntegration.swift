import SwiftUI
import Observation

@MainActor @Observable final class ArtistMusicIntegration {
    private let account: NeteaseAccount
    var showsLogin = false
    private var connected = false
    @ObservationIgnored private var backdrops: [Int64: AlbumArtworkBackdrop] = [:]
    private let backdropPreparer = AlbumArtworkBackdropPreparer()
    @ObservationIgnored private var backdropTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var backdropSources: [Int64: URL] = [:]
    @ObservationIgnored private var artworkSongs: [URL: [NeteaseMusicSong]] = [:]
    @ObservationIgnored private var artworkRoutes: [URL: Set<String>] = [:]
    @ObservationIgnored private var detailStates: [String: DetailState] = [:]
    @ObservationIgnored private var routeArtwork: [String: Set<URL>] = [:]
    @ObservationIgnored private var routeSongs: [String: [NeteaseMusicSong]] = [:]
    @ObservationIgnored private var songRoutes: [Int64: Set<String>] = [:]
    @ObservationIgnored private var routeArtists: [String: Set<Int64>] = [:]
    @ObservationIgnored private var routeAlbums: [String: Set<Int64>] = [:]
    @ObservationIgnored private var artistRoutes: [Int64: Set<String>] = [:]
    @ObservationIgnored private var albumRoutes: [Int64: Set<String>] = [:]
    @ObservationIgnored private var songValues: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var independentSongIDs: Set<Int64> = []
    @ObservationIgnored private var projectedSongs: [Int64: LibrarySongItem] = [:]
    @ObservationIgnored private var subscribedArtistIDs: Set<Int64> = []
    @ObservationIgnored private var subscribedAlbumIDs: Set<Int64> = []
    @ObservationIgnored private var likedIDs: Set<Int64> = []
    @ObservationIgnored private var likedAt: [Int64: Date] = [:]
    @ObservationIgnored private var displayedOwner: Int64?
    @ObservationIgnored private var sessionRevision: UUID?
    @Observable final class DetailState {
        var artist: ArtistDetail?
        var album: CollectionDetail?
        var error: String?
    }
    private func state(_ route: String) -> DetailState {
        if let state = detailStates[route] { return state }
        let state = DetailState(); detailStates[route] = state; return state
    }
    var sessionIdentity: String { "\(store?.isReady == true):\(owner.map(String.init) ?? "guest"):\(store?.userID.map(String.init) ?? "guest")" }
    init(account: NeteaseAccount) { self.account = account }
    private var store: NeteaseArtistStore? { account.artists }
    private var owner: Int64? { account.profile?.userID }
    func connect() {
        guard !connected else { return }; connected = true
        store?.onContentChange = { [weak self] in self?.publish($0) }
        store?.onArtworkChange = { [weak self] in self?.publishArtwork($0) }
        LocalLibrary.catalog.openSongAlbum = { [weak self] song, open in self?.openSong(song, artist: nil, album: true, open: open) }
        LocalLibrary.catalog.openSongArtist = { [weak self] song, artist, open in self?.openSong(song, artist: artist, album: false, open: open) }
        LocalLibrary.catalog.actions = collectionActions
        LocalLibrary.catalog.loadAlbumSongs = { [weak self] key in
            guard let self, let captured = self.owner else { throw NeteaseAccountError.authenticationRequired }
            let route = LibraryRoute.album(key)
            let available = await self.loadSongs(route)
            guard captured == self.owner else { throw CancellationError() }
            guard available, let id = Self.number(route), let detail = self.albumDetail(id) else { throw NeteaseAccountError.invalidResponse }
            return detail.songs
        }
        observe()
    }
    private func observe() {
        withObservationTracking {
            _ = account.profile; _ = account.music?.likedIDs; _ = account.music?.likedAt
        } onChange: { [weak self] in Task { @MainActor in self?.observe() } }
        if sessionRevision != store?.sessionRevision || displayedOwner != owner { publish(.reset) }
        let newIDs = account.music?.likedIDs ?? []
        let newDates = account.music?.likedAt ?? [:]
        let changed = likedIDs.symmetricDifference(newIDs).union(Set(likedAt.keys).union(newDates.keys).filter { likedAt[$0] != newDates[$0] })
        likedIDs = newIDs; likedAt = newDates
        guard !changed.isEmpty else { return }
        var routes = Set<String>(), updated = false
        for id in changed {
            routes.formUnion(songRoutes[id] ?? [])
            if let value = songValues[id] { projectedSongs[id] = songItem(value); updated = true }
        }
        for route in routes { rebuild(route, updateSongs: false) }
        if updated { publishSongs() }
    }
    private func publish(_ change: NeteaseArtistStore.Change) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if sessionRevision != store?.sessionRevision || displayedOwner != owner {
                sessionRevision = store?.sessionRevision
                displayedOwner = owner
                for task in backdropTasks.values { task.cancel() }
                backdropTasks = [:]; backdropSources = [:]; backdrops = [:]
                for state in detailStates.values { state.artist = nil; state.album = nil; state.error = nil }
                artworkSongs = [:]; artworkRoutes = [:]; routeArtwork = [:]; routeSongs = [:]
                songRoutes = [:]; artistRoutes = [:]; albumRoutes = [:]; routeArtists = [:]; routeAlbums = [:]; songValues = [:]; projectedSongs = [:]; independentSongIDs = []
                subscribedArtistIDs = []; subscribedAlbumIDs = []
            }
            guard let store, store.isReady, store.userID == owner else {
                if !LocalLibrary.catalog.artists.isEmpty { LocalLibrary.catalog.artists = [] }
                if !LocalLibrary.catalog.albums.isEmpty { LocalLibrary.catalog.albums = [] }
                LocalLibrary.songLibrary.replaceExternalSongs([], source: "artists"); return
            }
            switch change {
            case .reset:
                publishSubscribedArtists(); publishSubscribedAlbums()
                for id in store.details.keys { rebuild("artist:\(id)", updateSongs: true, publishSongs: false) }
                for id in store.albums.keys { rebuild("album:\(id)", updateSongs: true, publishSongs: false) }
                publishSongs()
            case .artist(let id): rebuild("artist:\(id)", updateSongs: true)
            case .album(let id): rebuild("album:\(id)", updateSongs: true)
            case .song(let id):
                if let value = store.cachedSong(id) { independentSongIDs.insert(id); updateSongs([value]); publishSongs() }
            case .subscribedArtists(let ids):
                publishSubscribedArtists(changedIDs: ids)
                let routes = ids.reduce(into: Set<String>()) { $0.formUnion(artistRoutes[$1] ?? []) }
                for route in routes { rebuild(route, updateSongs: false) }
            case .subscribedAlbums(let ids):
                publishSubscribedAlbums(changedIDs: ids)
                let routes = ids.reduce(into: Set<String>()) { $0.formUnion(albumRoutes[$1] ?? []) }
                for route in routes { rebuild(route, updateSongs: false) }
            case .error(let key):
                guard let id = key.split(separator: ":").last.flatMap({ Int64($0) }) else { return }
                let prefix = key.hasPrefix("album:") || key.hasPrefix("write:false:") ? "album" : "artist"
                rebuild("\(prefix):\(id)", updateSongs: false)
            }
        }
    }
    private func publishSubscribedArtists(changedIDs: Set<Int64>? = nil) {
        let values = store?.subscribedArtists ?? []
        subscribedArtistIDs = Set(values.map(\.id))
        let existing = Dictionary(LocalLibrary.catalog.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = values.map { value in
            if changedIDs?.contains(value.id) == false, let item = existing["catalog:artist:\(value.id)"] { return item }
            return artistItem(value)
        }
        if LocalLibrary.catalog.artists != items { LocalLibrary.catalog.artists = items }
    }
    private func publishSubscribedAlbums(changedIDs: Set<Int64>? = nil) {
        let values = store?.subscribedAlbums ?? []
        subscribedAlbumIDs = Set(values.map(\.id))
        let existing = Dictionary(LocalLibrary.catalog.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = values.map { value in
            if changedIDs?.contains(value.id) == false, let item = existing["catalog:album:\(value.id)"] { return item }
            return albumItem(value)
        }
        if LocalLibrary.catalog.albums != items { LocalLibrary.catalog.albums = items }
    }
    private func publishSongs() {
        LocalLibrary.songLibrary.replaceExternalSongs(projectedSongs.keys.sorted().compactMap { projectedSongs[$0] }, source: "artists")
    }
    @discardableResult private func updateSongs(_ values: [NeteaseMusicSong]) -> Bool {
        var changed = false
        for value in values {
            let item = songItem(value)
            if projectedSongs[value.id] != item { projectedSongs[value.id] = item; changed = true }
            if let previous = songValues[value.id], previous.artworkURL != value.artworkURL, let url = previous.artworkURL {
                artworkSongs[url]?.removeAll { $0.id == value.id }
            }
            songValues[value.id] = value
            if let url = value.artworkURL {
                var songs = artworkSongs[url] ?? []
                if let index = songs.firstIndex(where: { $0.id == value.id }) { songs[index] = value }
                else { songs.append(value) }
                artworkSongs[url] = songs
            }
        }
        return changed
    }
    private func rebuild(_ route: String, updateSongs shouldUpdateSongs: Bool, publishSongs shouldPublish: Bool = true) {
        guard let store, let id = route.split(separator: ":").last.flatMap({ Int64($0) }) else { return }
        let state = state(route)
        let values: [NeteaseMusicSong]
        var urls = Set<URL>(), artistIDs = Set<Int64>(), albumIDs = Set<Int64>()
        if route.hasPrefix("album:") {
            state.album = makeAlbumDetail(id)
            state.error = store.errors["album:\(id)"]
            values = store.albums[id]?.songs ?? []
            if let url = store.albums[id]?.album.artworkURL { urls.insert(url) }
            albumIDs.insert(id)
        } else {
            state.artist = makeArtistDetail(id)
            state.error = store.errors["artist:\(id)"]
            values = store.details[id]?.songs ?? []
            if let url = store.details[id]?.artist.artworkURL { urls.insert(url) }
            artistIDs.insert(id)
            for value in store.releases[id] ?? [] {
                albumIDs.insert(value.id)
                if let url = value.artworkURL { urls.insert(url) }
            }
            for value in store.similar[id] ?? [] {
                artistIDs.insert(value.id)
                if let url = value.artworkURL { urls.insert(url) }
            }
        }
        for id in (routeArtists[route] ?? []).subtracting(artistIDs) { artistRoutes[id]?.remove(route) }
        for id in (routeAlbums[route] ?? []).subtracting(albumIDs) { albumRoutes[id]?.remove(route) }
        for id in artistIDs { artistRoutes[id, default: []].insert(route) }
        for id in albumIDs { albumRoutes[id, default: []].insert(route) }
        routeArtists[route] = artistIDs; routeAlbums[route] = albumIDs
        urls.formUnion(values.compactMap(\.artworkURL))
        for url in routeArtwork[route] ?? [] { artworkRoutes[url]?.remove(route) }
        for url in urls { artworkRoutes[url, default: []].insert(route) }
        routeArtwork[route] = urls
        guard shouldUpdateSongs, routeSongs[route] != values else { return }
        let previousIDs = Set((routeSongs[route] ?? []).map(\.id))
        let currentIDs = Set(values.map(\.id))
        var removed = false
        for id in previousIDs.subtracting(currentIDs) {
            songRoutes[id]?.remove(route)
            if songRoutes[id]?.isEmpty != false, !independentSongIDs.contains(id) {
                if let url = songValues[id]?.artworkURL { artworkSongs[url]?.removeAll { $0.id == id } }
                songValues[id] = nil; projectedSongs[id] = nil; songRoutes[id] = nil; removed = true
            }
        }
        for value in values { songRoutes[value.id, default: []].insert(route) }
        routeSongs[route] = values
        let changed = updateSongs(values)
        if shouldPublish && (changed || removed) { publishSongs() }
    }
    private func artwork(_ remote: URL?) -> Artwork {
        guard let remote, let store else { return .missing }
        if let file = store.cachedArtworkURL(remote) { return .file(file) }
        return .deferred(id: "artists:\(store.sessionRevision.uuidString):\(remote.absoluteString)", placeholder: .missing)
    }
    func requestArtwork(for id: String) {
        guard let store, store.userID == owner else { return }
        let prefix = "artists:\(store.sessionRevision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return }
        store.requestArtwork([url])
    }
    func cachedArtworkFile(for id: String) async -> URL? {
        guard let store, store.userID == owner, !Task.isCancelled else { return nil }
        let revision = store.sessionRevision, owner = store.userID
        let prefix = "artists:\(revision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return nil }
        let file = await store.cachedArtworkFile(url)
        guard revision == store.sessionRevision, store.userID == owner,
              self.owner == owner, !Task.isCancelled else { return nil }
        return file
    }
    private func artistItem(_ value: NeteaseArtistReference) -> LibraryArtistItem {
        .init(id: "catalog:artist:\(value.id)", name: value.name, artwork: artwork(value.artworkURL), isFavorite: subscribedArtistIDs.contains(value.id))
    }
    private func albumItem(_ value: NeteaseArtistAlbum) -> LibraryShelfItem {
        .init(id: "catalog:album:\(value.id)", title: value.title, subtitle: value.artist, artwork: artwork(value.artworkURL), route: .album("catalog:album:\(value.id)"), isFavorite: subscribedAlbumIDs.contains(value.id), addedOrder: store?.albumAddedDate(value.id).map { Int($0.timeIntervalSince1970) } ?? 0, year: value.publishTime.map { Calendar.current.component(.year, from: $0) }, sourceOwnerID: owner.map(String.init))
    }
    private func releaseItem(_ value: NeteaseArtistAlbum) -> LibraryShelfItem {
        var item = albumItem(value); item.subtitle = item.year.map { "\($0)年" }; return item
    }
    private func songItem(_ value: NeteaseMusicSong) -> LibrarySongItem {
        let url = value.artworkURL.flatMap { store?.cachedArtworkURL($0) }
        return .init(id: owner.map { "netease:\($0):\(value.id)" } ?? "catalog-guest:\(value.id)", title: value.title, artist: value.artist, album: value.album, albumArtist: value.artist, trackNumber: 0, artwork: artwork(value.artworkURL), artworkURL: url, duration: Int(value.duration), isFavorite: account.music?.likedIDs.contains(value.id) == true, favoriteAddedAt: account.music?.likedAt[value.id], unavailabilityReason: value.unavailable ? "暂无完整音源" : nil, onlineAlbumID: value.albumID, artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }
    func artistDetail(_ id: Int64) -> ArtistDetail? { state("artist:\(id)").artist }
    private func makeArtistDetail(_ id: Int64) -> ArtistDetail? {
        guard store?.userID == owner, let value = store?.details[id] else { return nil }
        let releases = store?.releases[id] ?? []
        let singles = releases.filter { ["Single", "EP"].contains($0.type) }
        let albums = releases.filter { $0.type == "专辑" || $0.type == "Album" }
        var latest = releases.first.map(albumItem)
        if let first = releases.first { latest?.subtitle = "\(first.trackCount) 首歌曲" }
        var detail = ArtistDetail(name: value.artist.name, artwork: artwork(value.artist.artworkURL), isFavorite: subscribedArtistIDs.contains(id), albums: albums.map(releaseItem), id: "catalog:artist:\(id)", biography: value.biography, songs: value.songs.map(songItem), singles: singles.map(releaseItem), similar: (store?.similar[id] ?? []).map(artistItem), latest: latest, latestCaption: releases.first?.publishTime?.formatted(.dateTime.year().month().day()), shareURL: value.artist.shareURL)
        detail.errors = (store?.errors ?? [:]).filter { $0.key.hasSuffix(":\(id)") && !$0.key.hasPrefix("album:") && (owner != nil || !$0.key.hasPrefix("similar:")) }
        return detail
    }
    func albumDetail(_ id: Int64) -> CollectionDetail? { state("album:\(id)").album }
    private func makeAlbumDetail(_ id: Int64) -> CollectionDetail? {
        guard store?.userID == owner, let value = store?.albums[id] else { return nil }
        let item = albumItem(value.album)
        return .init(kind: .album, title: value.album.title, subtitle: value.album.artist, caption: item.year.map { "\($0)年" }, artwork: item.artwork, tint: Color(.systemBackground), albumBackdrop: backdrops[id], isFavorite: item.isFavorite, songs: value.songs.map(songItem), route: .album(item.id))
    }
    func destination(_ route: LibraryRoute) -> AnyView? {
        guard LocalLibrary.catalog.handles(route) else { return nil }
        return AnyView(ArtistCatalogDestination(route: route, integration: self))
    }
    func load(_ route: LibraryRoute) async {
        guard store?.userID == owner, let id = Self.number(route) else { return }
        switch route { case .album:
            await store?.loadAlbum(id: id)
            prepareBackdrop(id)
        default: await store?.loadArtist(id: id) }
    }
    private func loadSongs(_ route: LibraryRoute) async -> Bool {
        guard let store, store.isReady, store.userID == owner, let id = Self.number(route) else { return false }
        if route.isCatalogAlbum { return await store.prepareAlbumPlayback(id: id) }
        return await store.prepareArtistPlayback(id: id)
    }
    private func publishArtwork(_ urls: Set<URL>) {
        guard let store, store.userID == owner, store.sessionRevision == sessionRevision else { return }
        var songs: [String: LibrarySongItem] = [:]
        var routes = Set<String>()
        for url in urls {
            routes.formUnion(artworkRoutes[url] ?? [])
            for value in artworkSongs[url] ?? [] {
                let item = songItem(value)
                songs[item.id] = item
                projectedSongs[value.id] = item
            }
        }
        for route in routes { rebuild(route, updateSongs: false) }
        for value in store.subscribedArtists where value.artworkURL.map(urls.contains) == true {
            if let index = LocalLibrary.catalog.artists.firstIndex(where: { $0.id == "catalog:artist:\(value.id)" }) {
                let item = artistItem(value)
                if LocalLibrary.catalog.artists[index] != item { LocalLibrary.catalog.artists[index] = item }
            }
        }
        for value in store.subscribedAlbums where value.artworkURL.map(urls.contains) == true {
            if let index = LocalLibrary.catalog.albums.firstIndex(where: { $0.id == "catalog:album:\(value.id)" }) {
                let item = albumItem(value)
                if LocalLibrary.catalog.albums[index] != item { LocalLibrary.catalog.albums[index] = item }
            }
        }
        LocalLibrary.songLibrary.updateOnlineArtwork(songs, source: "artists")
        LocalLibrary.playlistLibrary.updateArtwork(songs: songs)
        LocalLibrary.player.updateArtwork(songs)
        for route in routes where route.hasPrefix("album:") {
            if let id = Int64(route.dropFirst("album:".count)) { prepareBackdrop(id) }
        }
    }

    private func prepareBackdrop(_ id: Int64) {
        guard let store, store.userID == owner, let remote = store.albums[id]?.album.artworkURL,
              let url = store.cachedArtworkURL(remote), backdropSources[id] != url, backdropTasks[id] == nil else { return }
        let revision = store.sessionRevision
        let preparer = backdropPreparer
        backdropTasks[id] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let data else {
                if self?.store?.sessionRevision == revision { self?.backdropTasks[id] = nil }
                return
            }
            let colors = try? await preparer.prepare([String(id): data])
            guard let self, !Task.isCancelled, self.store?.sessionRevision == revision,
                  self.store?.userID == self.owner else { return }
            self.backdropTasks[id] = nil
            self.backdropSources[id] = url
            if self.backdrops[id] != colors?[String(id)] {
                self.backdrops[id] = colors?[String(id)]
                self.rebuild("album:\(id)", updateSongs: false)
            }
        }
    }

    func error(_ route: LibraryRoute) -> String? {
        guard let id = Self.number(route) else { return nil }
        return state((route.isCatalogAlbum ? "album:" : "artist:") + String(id)).error
    }
    static func number(_ route: LibraryRoute) -> Int64? {
        switch route {
        case .artist(let id), .artistSection(let id, _), .album(let id): Int64(id.split(separator: ":").last ?? "")
        default: nil
        }
    }
    func play(_ route: LibraryRoute, song: LibrarySongItem? = nil, shuffled: Bool = false) {
        guard owner != nil else { showsLogin = true; return }
        let songs: [LibrarySongItem]
        let title: String
        guard let id = Self.number(route) else { return }
        if route.isCatalogAlbum { guard let detail = albumDetail(id) else { return }; songs = detail.songs; title = detail.title }
        else { guard let detail = artistDetail(id) else { return }; songs = detail.songs; title = detail.name }
        if let song, let index = songs.firstIndex(where: { $0.id == song.id }) { LocalLibrary.player.requestPlay(songs, startingAt: index, from: title) }
        else { LocalLibrary.player.requestPlay(songs, from: title, shuffled: shuffled) }
    }
    func toggle(_ route: LibraryRoute) {
        guard owner != nil else { showsLogin = true; return }
        guard let id = Self.number(route), let store else { return }
        let current = route.isCatalogAlbum
            ? store.subscribedAlbums.contains { $0.id == id }
            : store.subscribedArtists.contains { $0.id == id }
        subscriptionTask(route, subscribed: !current)
    }

    @discardableResult func collectRelease(_ item: LibraryShelfItem) -> Task<Void, Never>? {
        guard let owner else { showsLogin = true; return nil }
        guard item.sourceOwnerID == nil || item.sourceOwnerID == String(owner),
              let route = item.route else { return nil }
        return subscriptionTask(route, subscribed: true)
    }

    @discardableResult private func subscriptionTask(_ route: LibraryRoute, subscribed: Bool) -> Task<Void, Never>? {
        guard let capturedOwner = owner, let store, !account.isLoggingOut else { return nil }
        let revision = store.sessionRevision
        return Task {
            guard !Task.isCancelled, owner == capturedOwner, store.sessionRevision == revision,
                  !account.isLoggingOut else { return }
            await setSubscribed(route, subscribed: subscribed)
        }
    }

    func setSubscribed(_ route: LibraryRoute, subscribed: Bool) async {
        guard owner != nil else { showsLogin = true; return }
        guard let id = Self.number(route), let store else { return }
        guard store.isReady, store.userID == owner else {
            LocalLibrary.toasts.show(.error("账户资料正在恢复，请稍后重试。"))
            return
        }
        let capturedOwner = owner
        let revision = store.sessionRevision
        let current = route.isCatalogAlbum
            ? store.subscribedAlbums.contains { $0.id == id }
            : store.subscribedArtists.contains { $0.id == id }
        guard current != subscribed else { return }
        do {
            try Task.checkCancellation()
            if route.isCatalogAlbum { try await store.setAlbumSubscribed(id: id, subscribed: subscribed) }
            else { try await store.setArtistSubscribed(id: id, subscribed: subscribed) }
            guard !Task.isCancelled, capturedOwner == owner, revision == store.sessionRevision else { return }
            let confirmed = route.isCatalogAlbum
                ? store.subscribedAlbums.contains { $0.id == id }
                : store.subscribedArtists.contains { $0.id == id }
            guard confirmed == subscribed else { throw NeteaseAccountError.invalidResponse }
            if !route.isCatalogAlbum { LocalLibrary.toasts.show(subscribed ? .favorited : .unfavorited) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, capturedOwner == owner, revision == store.sessionRevision else { return }
            LocalLibrary.toasts.show(.error(error.localizedDescription))
        }
    }
    func songActions(_ route: LibraryRoute) -> SongMenuActions {
        var actions = LocalLibrary.songActions(for: route)
        actions.play = { [weak self] songs, index, _ in
            guard songs.indices.contains(index) else { return }
            self?.play(route, song: songs[index])
        }
        if owner == nil {
            let login: (LibrarySongItem) -> Void = { [weak self] _ in self?.showsLogin = true }
            actions.playNext = login; actions.playLater = login; actions.toggleFavorite = login
            actions.addToPlaylist = login; actions.removeFromFavorites = login
        }
        return actions
    }
    var collectionActions: CollectionMenuActions {
        var actions = LocalLibrary.menuActions
        actions.play = { [weak self] route, shuffle in
            guard let self else { return }
            guard let captured = self.owner else { self.showsLogin = true; return }
            Task { if await self.loadSongs(route), captured == self.owner { self.play(route, shuffled: shuffle) } }
        }
        actions.toggleFavorite = { [weak self] in self?.toggle($0) }
        actions.playNext = { [weak self] route in self?.enqueue(route, next: true) }
        actions.playLater = { [weak self] route in self?.enqueue(route, next: false) }
        actions.addToPlaylist = { [weak self] route in self?.enqueue(route, next: nil) }
        return actions
    }
    private func enqueue(_ route: LibraryRoute, next: Bool?) {
        guard owner != nil else { showsLogin = true; return }
        let captured = owner
        Task {
            let available = await loadSongs(route)
            guard available, captured == owner, let id = Self.number(route) else { return }
            let songs = route.isCatalogAlbum ? albumDetail(id)?.songs : artistDetail(id)?.songs
            guard let songs else { return }
            if let next { if next { LocalLibrary.player.insertNext(songs) } else { LocalLibrary.player.appendLater(songs) } }
            else { LocalLibrary.playlistLibrary.pendingAddition = .init(songs: songs) }
        }
    }
    private func openSong(_ songID: String, artist: String?, album: Bool, open: @escaping (LibraryRoute) -> Void) {
        guard let song = LocalLibrary.songLibrary.song(id: songID), song.onlineOwnerID == owner.map(String.init) else { return }
        if album, let id = song.onlineAlbumID { open(.album("catalog:album:\(id)")); return }
        if !album, let ref = song.artistReferences.first(where: { artist == nil || $0.name == artist }) { open(.artist(ref.id)); return }
        guard let id = song.onlineSongID, let store else { return }
        let captured = owner
        Task {
            do {
                let value = try await store.song(id: id)
                guard captured == owner else { return }
                if album, let albumID = value.albumID { open(.album("catalog:album:\(albumID)")) }
                else if let ref = value.artists?.first(where: { artist == nil || $0.name == artist || artist == song.artist }) { open(.artist("catalog:artist:\(ref.id)")) }
            } catch is CancellationError { } catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
        }
    }
}
private extension LibraryRoute {
    var isCatalogAlbum: Bool { if case .album = self { true } else { false } }
}
private struct ArtistCatalogDestination: View {
    let route: LibraryRoute
    let integration: ArtistMusicIntegration
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    var body: some View {
        Group {
            if let id = ArtistMusicIntegration.number(route) {
                if case .album = route {
                    album(id)
                } else if let detail = integration.artistDetail(id) {
                    artistPage(detail)
                } else if let error = integration.error(route) {
                    ContentUnavailableView { Label("暂时无法读取", systemImage: "exclamationmark.circle") } description: { Text(error) } actions: { Button("重试") { Task { await integration.load(route) } } }
                } else if case .artist = route, let placeholder = artistPlaceholder(id) {
                    artistPage(placeholder)
                } else { Color.clear }
            }
        }.environment(\.songMenuActions, integration.songActions(route))
        .environment(\.collectionMenuActions, integration.collectionActions)
        .task(id: "\(route):\(integration.sessionIdentity)") { await integration.load(route) }
        .onChange(of: scenePhase) { old, new in if old == .background, new == .active { Task { await integration.load(route) } } }
    }

    @ViewBuilder private func artistPage(_ detail: ArtistDetail) -> some View {
        if case .artistSection(_, let section) = route {
            ArtistSectionView(detail: detail, section: section, playSong: { integration.play(route, song: $0) })
        } else {
            ArtistDetailView(detail: detail, playSong: { integration.play(route, song: $0) }, toggleFavorite: { integration.toggle(route) }, collectRelease: { item in
                integration.collectRelease(item)
            }, retry: { _ in Task { await integration.load(route) } })
        }
    }

    private func artistPlaceholder(_ id: Int64) -> ArtistDetail? {
        guard case .artist(let routeID) = route else { return nil }
        if let preview = navigationPreview, preview.route == route {
            return ArtistDetail(name: preview.title, artwork: preview.artwork, albums: [], id: routeID)
        }
        let catalogID = "catalog:artist:\(id)"
        guard let item = LocalLibrary.catalog.artists.first(where: { $0.id == catalogID || $0.id == routeID }) else { return nil }
        return ArtistDetail(name: item.name, artwork: item.artwork, albums: [], id: routeID)
    }

    @ViewBuilder private func album(_ id: Int64) -> some View {
        let preview = navigationPreview.flatMap { $0.route == route ? $0 : nil }
        let detail = integration.albumDetail(id) ?? preview.map {
            CollectionDetail(kind: .album, title: $0.title, subtitle: $0.subtitle, artwork: $0.artwork,
                             tint: .clear, songs: [], route: route)
        }
        if let detail {
            CollectionDetailView(detail: detail)
                .environment(\.collectionMenuActions, integration.collectionActions)
                .safeAreaInset(edge: .bottom) {
                    if let error = integration.error(route) {
                        HStack {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Button("重试") { Task { await integration.load(route) } }
                        }.padding().background(.regularMaterial)
                    }
                }
        } else if let error = integration.error(route) {
            ContentUnavailableView { Label("暂时无法读取", systemImage: "exclamationmark.circle") }
                description: { Text(error) }
                actions: { Button("重试") { Task { await integration.load(route) } } }
        } else { Color.clear }
    }
}
