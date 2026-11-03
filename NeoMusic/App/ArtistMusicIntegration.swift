import SwiftUI
import Observation

@MainActor @Observable final class ArtistMusicIntegration {
    private let account: NeteaseAccount
    var showsLogin = false
    private var connected = false
    private var contentRevision = 0
    private var backdrops: [Int64: AlbumArtworkBackdrop] = [:]
    private let backdropPreparer = AlbumArtworkBackdropPreparer()
    var sessionIdentity: String { "\(store?.isReady == true):\(owner.map(String.init) ?? "guest"):\(store?.userID.map(String.init) ?? "guest")" }
    init(account: NeteaseAccount) { self.account = account }
    private var store: NeteaseArtistStore? { account.artists }
    private var owner: Int64? { account.profile?.userID }
    func connect() {
        guard !connected else { return }; connected = true
        store?.onChange = { [weak self] in self?.publish() }
        LocalLibrary.catalog.openSongAlbum = { [weak self] song, open in self?.openSong(song, artist: nil, album: true, open: open) }
        LocalLibrary.catalog.openSongArtist = { [weak self] song, artist, open in self?.openSong(song, artist: artist, album: false, open: open) }
        LocalLibrary.catalog.actions = collectionActions
        LocalLibrary.catalog.loadAlbumSongs = { [weak self] key in
            guard let self, let captured = self.owner else { throw NeteaseAccountError.authenticationRequired }
            let route = LibraryRoute.album(key)
            await self.load(route)
            guard captured == self.owner else { throw CancellationError() }
            guard self.error(route) == nil, let id = Self.number(route), let detail = self.albumDetail(id) else { throw NeteaseAccountError.invalidResponse }
            return detail.songs
        }
        observe()
    }
    private func observe() {
        withObservationTracking {
            _ = account.profile; _ = account.music?.likedIDs; _ = account.music?.likedAt
        } onChange: { [weak self] in Task { @MainActor in self?.observe() } }
        publish()
    }
    private func publish() {
        contentRevision += 1
        guard store?.userID == owner else {
            LocalLibrary.catalog.artists = []; LocalLibrary.catalog.albums = []
            LocalLibrary.songLibrary.replaceExternalSongs([], source: "artists"); return
        }
        LocalLibrary.catalog.artists = (store?.subscribedArtists ?? []).map(artistItem)
        LocalLibrary.catalog.albums = (store?.subscribedAlbums ?? []).map(albumItem)
        LocalLibrary.songLibrary.replaceExternalSongs((store?.cachedSongs ?? []).map(songItem), source: "artists")
    }
    private func artwork(_ remote: URL?) -> Artwork {
        remote.flatMap { store?.cachedArtworkURL($0) }.map(Artwork.file) ?? .missing
    }
    private func artistItem(_ value: NeteaseArtistReference) -> LibraryArtistItem {
        .init(id: "catalog:artist:\(value.id)", name: value.name, artwork: artwork(value.artworkURL), isFavorite: store?.subscribedArtists.contains { $0.id == value.id } == true)
    }
    private func albumItem(_ value: NeteaseArtistAlbum) -> LibraryShelfItem {
        .init(id: "catalog:album:\(value.id)", title: value.title, subtitle: value.artist, artwork: artwork(value.artworkURL), route: .album("catalog:album:\(value.id)"), isFavorite: store?.subscribedAlbums.contains { $0.id == value.id } == true, year: value.publishTime.map { Calendar.current.component(.year, from: $0) })
    }
    private func releaseItem(_ value: NeteaseArtistAlbum) -> LibraryShelfItem {
        var item = albumItem(value); item.subtitle = item.year.map { "\($0)年" }; return item
    }
    private func songItem(_ value: NeteaseMusicSong) -> LibrarySongItem {
        let url = value.artworkURL.flatMap { store?.cachedArtworkURL($0) }
        return .init(id: owner.map { "netease:\($0):\(value.id)" } ?? "catalog-guest:\(value.id)", title: value.title, artist: value.artist, album: value.album, albumArtist: value.artist, trackNumber: 0, artwork: url.map(Artwork.file) ?? .missing, artworkURL: url, duration: Int(value.duration), isFavorite: account.music?.likedIDs.contains(value.id) == true, favoriteAddedAt: account.music?.likedAt[value.id], unavailabilityReason: value.unavailable ? "暂无完整音源" : nil, onlineAlbumID: value.albumID, artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }
    func artistDetail(_ id: Int64) -> ArtistDetail? {
        _ = contentRevision
        guard store?.userID == owner, let value = store?.details[id] else { return nil }
        let releases = store?.releases[id] ?? []
        let singles = releases.filter { ["Single", "EP"].contains($0.type) }
        let albums = releases.filter { $0.type == "专辑" || $0.type == "Album" }
        var latest = releases.first.map(albumItem)
        if let first = releases.first { latest?.subtitle = "\(first.trackCount) 首歌曲" }
        var detail = ArtistDetail(name: value.artist.name, artwork: artwork(value.artist.artworkURL), isFavorite: store?.subscribedArtists.contains { $0.id == id } == true, albums: albums.map(releaseItem), id: "catalog:artist:\(id)", biography: value.biography, songs: value.songs.map(songItem), singles: singles.map(releaseItem), similar: (store?.similar[id] ?? []).map(artistItem), latest: latest, latestCaption: releases.first?.publishTime?.formatted(.dateTime.year().month().day()), shareURL: value.artist.shareURL)
        detail.errors = (store?.errors ?? [:]).filter { $0.key.hasSuffix(":\(id)") && !$0.key.hasPrefix("album:") && (owner != nil || !$0.key.hasPrefix("similar:")) }
        return detail
    }
    func albumDetail(_ id: Int64) -> CollectionDetail? {
        _ = contentRevision
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
            if let remote = store?.albums[id]?.album.artworkURL, let url = store?.cachedArtworkURL(remote), let data = try? Data(contentsOf: url) {
                let colors = try? await backdropPreparer.prepare([String(id): data]); backdrops[id] = colors?[String(id)]
            }
        default: await store?.loadArtist(id: id) }
    }
    func error(_ route: LibraryRoute) -> String? {
        guard let id = Self.number(route) else { return nil }
        return store?.errors[(route.isCatalogAlbum ? "album:" : "artist:") + String(id)]
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
        Task {
            do {
                if route.isCatalogAlbum { try await store.setAlbumSubscribed(id: id, subscribed: !store.subscribedAlbums.contains { $0.id == id }) }
                else { try await store.setArtistSubscribed(id: id, subscribed: !store.subscribedArtists.contains { $0.id == id }) }
            } catch is CancellationError { } catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
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
        var actions = CollectionMenuActions()
        actions.play = { [weak self] route, shuffle in
            guard let self else { return }; let captured = self.owner
            Task { await self.load(route); if captured == self.owner, self.error(route) == nil { self.play(route, shuffled: shuffle) } }
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
            await load(route)
            guard captured == owner, let id = Self.number(route), error(route) == nil else { return }
            let songs = route.isCatalogAlbum ? albumDetail(id)?.songs : artistDetail(id)?.songs
            guard let songs else { return }
            if let next { if next { LocalLibrary.player.insertNext(songs) } else { LocalLibrary.player.appendLater(songs) } }
            else { LocalLibrary.playlistLibrary.pendingAddition = .init(songs: songs) }
        }
    }
    private func openSong(_ songID: String, artist: String?, album: Bool, open: @escaping (LibraryRoute) -> Void) {
        guard let song = LocalLibrary.allSongs.first(where: { $0.id == songID }), song.onlineOwnerID == owner.map(String.init) else { return }
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
    var body: some View {
        Group {
            if let id = ArtistMusicIntegration.number(route) {
                if case .album = route, let detail = integration.albumDetail(id) {
                    CollectionDetailView(detail: detail).environment(\.collectionMenuActions, integration.collectionActions)
                } else if let detail = integration.artistDetail(id) {
                    if case .artistSection(_, let section) = route { ArtistSectionView(detail: detail, section: section, playSong: { integration.play(route, song: $0) }) }
                    else { ArtistDetailView(detail: detail, playSong: { integration.play(route, song: $0) }, toggleFavorite: { integration.toggle(route) }, collectRelease: { if let route = $0.route { integration.toggle(route) } }, retry: { _ in Task { await integration.load(route) } }) }
                } else if let error = integration.error(route) {
                    ContentUnavailableView { Label("暂时无法读取", systemImage: "exclamationmark.circle") } description: { Text(error) } actions: { Button("重试") { Task { await integration.load(route) } } }
                } else { Color.clear }
            }
        }.environment(\.songMenuActions, integration.songActions(route))
        .task(id: "\(route):\(integration.sessionIdentity)") { await integration.load(route) }
        .onChange(of: scenePhase) { old, new in if old == .background, new == .active { Task { await integration.load(route) } } }
    }
}
