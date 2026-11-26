import FrontAM
import SwiftUI

@MainActor @Observable
final class ShowcaseLibrary {
    let catalog: ShowcaseCatalog
    let playlists: ShowcasePlaylists
    let playback = ShowcasePlayback()
    @ObservationIgnored lazy var player = PlayerState(source: playback)
    let home = HomeContentModel()
    let search = SearchPageModel()
    let toasts = LibraryToastCenter()
    private var favorites: Set<String> = []
    private var favoriteCollections: Set<LibraryRoute> = []
    private var pinOrder: [LibraryRoute]

    init() {
        let catalog = ShowcaseCatalog()
        self.catalog = catalog
        playlists = ShowcasePlaylists(catalog: catalog)
        pinOrder = [.album(catalog.albums[0].id), .playlist("night-post"), .artist(catalog.artists[1].id)]
        configureHome()
        configureSearch()
    }

    var songs: [LibrarySongItem] {
        catalog.songs.map { song in
            var item = song
            item.isFavorite = favorites.contains(song.id)
            return item
        }
    }

    var albums: [LibraryShelfItem] { catalog.albums.map(albumItem) }
    var artists: [LibraryArtistEntry] {
        catalog.artists.map { artist in
            .init(id: .catalog(id: artist.id, ownerID: nil), name: artist.name, catalogRoute: .artist(artist.id),
                  portrait: artist.cover.artwork, isFavorite: favoriteCollections.contains(.artist(artist.id)),
                  isPinned: pinOrder.contains(.artist(artist.id)),
                  songs: tracks(in: .artist(artist.id)), albums: albums(for: artist.id))
        }
    }

    var recentlyAdded: [LibraryShelfItem] {
        (albums + playlists.playlists.map(\.shelfItem)).sorted { $0.addedOrder > $1.addedOrder }
    }

    var pinned: [LibraryShelfItem] { pinOrder.compactMap(item(for:)) }

    func reorderPinned(_ routes: [LibraryRoute]) -> Bool {
        // A deleted playlist may still be in the stored order until the next edit.
        guard routes.count == pinned.count, Set(routes) == Set(pinned.compactMap(\.route)) else { return false }
        pinOrder = routes
        return true
    }

    func albumItem(_ album: ShowcaseCatalog.Album) -> LibraryShelfItem {
        .init(id: album.id, title: album.title, subtitle: album.songs.first?.artist,
              artwork: album.cover.artwork, route: .album(album.id),
              isFavorite: favoriteCollections.contains(.album(album.id)), isPinned: pinOrder.contains(.album(album.id)),
              addedOrder: album.songs.last?.addedOrder ?? 0, albumBackdrop: album.cover.backdrop)
    }

    func albums(for artistID: String) -> [LibraryShelfItem] {
        catalog.albums.filter { $0.artistID == artistID }.map(albumItem)
    }

    func item(for route: LibraryRoute) -> LibraryShelfItem? {
        switch route {
        case .album(let id), .libraryArtistAlbum(_, let id):
            return catalog.albums.first { $0.id == id }.map(albumItem)
        case .playlist(let id):
            return playlists.playlist(id)?.shelfItem
        case .artist(let id), .artistSection(let id, _):
            guard let artist = catalog.artists.first(where: { $0.id == id }) else { return nil }
            return .init(id: id, title: artist.name, artwork: artist.cover.artwork, route: .artist(id),
                         isFavorite: favoriteCollections.contains(.artist(id)), isPinned: pinOrder.contains(.artist(id)))
        case .libraryArtist(let id):
            return item(for: .artist(id.itemID))
        default:
            return nil
        }
    }

    func preview(for route: LibraryRoute) -> LibraryNavigationPreview? {
        guard let item = item(for: route) else { return nil }
        return .init(route: route, ownerID: nil, title: item.title, subtitle: item.subtitle,
                     artwork: item.artwork, albumBackdrop: item.albumBackdrop)
    }

    func tracks(in route: LibraryRoute) -> [LibrarySongItem] {
        switch route {
        case .album(let id), .libraryArtistAlbum(_, let id):
            songs.filter { $0.albumID == id }
        case .playlist(let id):
            playlists.songs(in: id)
        case .artist(let id), .artistSection(let id, _):
            songs.filter { $0.artist == catalog.artists.first(where: { $0.id == id })?.name }
        case .libraryArtist(let id):
            tracks(in: .artist(id.itemID))
        default:
            []
        }
    }

    func play(_ songs: [LibrarySongItem], at index: Int = 0, source: String?, shuffled: Bool = false) {
        playback.play(songs.map(catalog.track), at: index, source: source, shuffled: shuffled)
    }

    func playSong(_ song: LibrarySongItem) {
        let albumSongs = tracks(in: .album(song.albumID))
        if let index = albumSongs.firstIndex(where: { $0.id == song.id }) {
            play(albumSongs, at: index, source: song.album)
        } else {
            play([song], source: song.album)
        }
    }

    func playCollection(_ route: LibraryRoute, shuffled: Bool) {
        play(tracks(in: route), source: item(for: route)?.title, shuffled: shuffled)
    }

    func enqueue(_ route: LibraryRoute, next: Bool) {
        let songs = tracks(in: route)
        // Inserting after the current song reverses repeated inserts.
        let ordered = next && playback.currentTrack != nil ? Array(songs.reversed()) : songs
        for song in ordered { playback.enqueue(catalog.track(song), next: next) }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        let favorite = !favorites.contains(id)
        if favorite { favorites.insert(id) } else { favorites.remove(id) }
        playlists.updateFavorite(favorite, songID: id)
        updateSearch()
    }

    func toggleCollectionFavorite(_ route: LibraryRoute) {
        if case .playlist(let id) = route { playlists.toggleFavorite(id) }
        else if favoriteCollections.contains(route) { favoriteCollections.remove(route) }
        else { favoriteCollections.insert(route) }
    }

    func togglePin(_ route: LibraryRoute) {
        if case .playlist(let id) = route { playlists.togglePin(id) }
        if pinOrder.contains(route) { pinOrder.removeAll { $0 == route } }
        else { pinOrder.append(route) }
    }

    var collectionActions: CollectionMenuActions {
        .init(play: playCollection, playNext: { self.enqueue($0, next: true) },
              playLater: { self.enqueue($0, next: false) }, toggleFavorite: toggleCollectionFavorite, togglePin: togglePin,
              addToPlaylist: { self.playlists.pendingAddition = .init(songs: self.tracks(in: $0)) },
              playbackSource: { self.playback.playbackSourceTitle },
              requestMove: { self.playlists.pendingMove = self.playlists.playlist($0) },
              canDelete: { if case .playlist(let id) = $0 { self.playlists.canDelete(id) } else { false } },
              edit: { if case .playlist(let id) = $0 { self.playlists.pendingEdit = self.playlists.playlist(id) } },
              requestDelete: { if case .playlist(let id) = $0 { self.playlists.pendingDeletion = self.playlists.playlist(id) } },
              delete: { if case .playlist(let id) = $0 { self.playlists.deletePlaylist(id) } },
              notify: toasts.show)
    }

    var songActions: SongMenuActions {
        .init(play: { self.play($0, at: $1, source: $2) },
              playNext: { self.playback.enqueue(self.catalog.track($0), next: true) },
              toggleFavorite: { self.toggleFavorite($0.id) },
              removeFromFavorites: { if self.isFavorite($0.id) { self.toggleFavorite($0.id) } },
              addToPlaylist: { self.playlists.pendingAddition = .init(songs: [$0]) },
              playLater: { self.playback.enqueue(self.catalog.track($0), next: false) },
              playbackSource: { self.playback.playbackSourceTitle },
              albumPreview: { _, route in self.preview(for: route) },
              notify: toasts.show)
    }

    func playerServices(open: @escaping (LibraryRoute) -> Void) -> PlayerServices {
        let actions = PlayerActions(isFavorite: isFavorite, toggleFavorite: toggleFavorite,
            addToPlaylist: { id in
                if let song = self.songs.first(where: { $0.id == id }) { self.playlists.pendingAddition = .init(songs: [song]) }
            }, openAlbum: { id in
                if let song = self.songs.first(where: { $0.id == id }) { open(.album(song.albumID)) }
            }, openArtist: { id in
                if let track = self.songs.first(where: { $0.id == id }),
                   let artist = self.catalog.artists.first(where: { $0.name == track.artist }) {
                    open(.artist(artist.id))
                }
            }, notify: { notice in
                let toast: LibraryToast = switch notice {
                case .favorited: .favorited
                case .unfavorited: .unfavorited
                case .playingNext: .playingNext
                case .addedToQueue: .addedToQueue
                }
                self.toasts.show(toast)
            })
        return .init(actions: actions, lyrics: .init(load: catalog.lyrics),
                     artwork: .init(cached: { self.catalog.image(at: $0.url) }, load: { request in
                         guard let image = self.catalog.image(at: request.url) else { throw CocoaError(.fileNoSuchFile) }
                         return image
                     }))
    }

    private func configureHome() {
        home.isGuest = false
        let coverItems = (albums + playlists.playlists.map(\.shelfItem)).compactMap { item in
            item.route.map {
                HomeContentItem(id: item.id, title: item.title, subtitle: item.subtitle ?? "",
                                artwork: item.artwork, action: .navigate($0))
            }
        }
        home.sections = [
            HomeContentSection(id: "covers", title: "最近收藏", kind: .covers, items: coverItems),
            HomeContentSection(id: "songs", title: "今日选曲", kind: .songs, items: songs.map {
                .init(id: $0.id, title: $0.title, subtitle: $0.artist, artwork: $0.artwork, action: .playSong)
            })
        ]
        home.play = { [weak self] _, id in
            guard let self, let song = self.songs.first(where: { $0.id == id }) else { return }
            self.playSong(song)
        }
    }

    private var searchItems: [MusicSearchItem] {
        let tracks = songs.map { MusicSearchItem(id: $0.id, kind: .song, title: $0.title,
                                                subtitle: $0.artist, artwork: $0.artwork, song: $0) }
        let releases = albums.map { MusicSearchItem(id: $0.id, kind: .album, title: $0.title,
                                                   subtitle: $0.subtitle ?? "", artwork: $0.artwork, route: $0.route) }
        let performers = catalog.artists.map { MusicSearchItem(id: $0.id, kind: .artist, title: $0.name,
                                                              subtitle: "艺人", artwork: $0.cover.artwork, route: .artist($0.id)) }
        let lists = playlists.playlists.map { MusicSearchItem(id: $0.id, kind: .playlist, title: $0.title,
                                                            subtitle: "", artwork: $0.artwork, route: .playlist($0.id)) }
        return tracks + releases + performers + lists
    }

    private func configureSearch() {
        search.categories = [
            .init(id: "night", title: "夜间邮路", colorIndex: 5, isHot: true),
            .init(id: "glass", title: "玻璃潮汐", colorIndex: 3, isHot: true)
        ]
        search.keywords = ["月背", "折纸", "零号"]
        search.onQuery = { [weak self] in self?.updateSearch() }
        search.onKind = { [weak self] in self?.updateSearch() }
        search.onSubmit = { [weak self] in
            guard let self else { return }
            self.search.history.removeAll { $0 == self.search.query }
            self.search.history.insert(self.search.query, at: 0)
            self.updateSearch()
        }
        search.onRemoveHistory = { [weak self] term in
            if let term { self?.search.history.removeAll { $0 == term } }
            else { self?.search.history.removeAll() }
        }
        search.onOpen = { [weak self] item in if let song = item.song { self?.playSong(song) } }
    }

    private func updateSearch() {
        let query = search.query
        let matches = query.isEmpty ? [] : searchItems.filter {
            $0.title.localizedStandardContains(query) || $0.subtitle.localizedStandardContains(query)
                || $0.song?.album.localizedStandardContains(query) == true
        }
        search.suggestions = Array(matches.prefix(6))
        let groups = [MusicSearchKind.song, .artist, .album, .playlist].compactMap { kind -> MusicSearchGroup? in
            let items = matches.filter { $0.kind == kind }
            return items.isEmpty ? nil : .init(kind: kind, items: items)
        }
        search.cachedGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.kind, [$0]) })
        search.cachedGroups[.combined] = groups
        search.groups = search.cachedGroups[search.kind] ?? []
    }

    func showCategory(_ id: String) {
        search.category = id
        search.categoryItems = id == "night" ? searchItems.filter { $0.id == "night-post" }
            : searchItems.filter { $0.title.localizedStandardContains("玻璃") || $0.song?.albumID == "folder:glass-tides" }
    }
}
