import FullScreenPlayer
import SwiftUI

@MainActor
struct CollectionDownloadHandling {
    var download: ((LibraryRoute) -> Bool)?
    var remove: ((LibraryRoute) -> Bool)?
    var downloadedState: ((LibraryRoute) -> Bool?)?
    var canDownload: ((LibraryRoute) -> Bool)?
    var canRemoveDownload: ((LibraryRoute) -> Bool)?
    var stop: ((LibraryRoute) -> Void)?
}

typealias AppLibrary = LocalLibrary

@MainActor
extension AppContainer {
    var songs: [LibrarySongItem] { runtime.localSongs }
    var allSongs: [LibrarySongItem] { runtime.allSongs }
    private func song(id: String) -> LibrarySongItem? {
        guard let song = songLibrary.song(id: id), song.isOnline || !deletedAlbums.ids.contains(song.albumID) else { return nil }
        return song
    }
    var favorites: [LibrarySongItem] {
        Self.favoriteRows(online: songLibrary.onlineSongs, favorites: songLibrary.favoriteSongs,
                     downloadedSongID: { catalog.downloadedOnlineSongID?($0) })
            .filter { $0.isOnline || !deletedAlbums.ids.contains($0.albumID) }
    }

    static func favoriteRows(online: [LibrarySongItem],
                             favorites: [LibrarySongItem],
                             downloadedSongID: (String) -> Int64?) -> [LibrarySongItem] {
        var onlineBySongID: [Int64: LibrarySongItem] = [:]
        for song in online where song.isFavorite {
            guard let id = song.onlineSongID, onlineBySongID[id] == nil else { continue }
            onlineBySongID[id] = song
        }
        var seen: Set<String> = []
        var items: [LibrarySongItem] = []
        items.reserveCapacity(favorites.count + onlineBySongID.count)
        for song in favorites {
            let shown = song.isOnline ? song : downloadedSongID(song.id).flatMap { onlineBySongID[$0] } ?? song
            if seen.insert(shown.id).inserted { items.append(shown) }
        }
        for song in online where song.isFavorite {
            if seen.insert(song.id).inserted { items.append(song) }
        }
        return SongLibrary.orderedFavorites(items)
    }
    private func albumSongs(_ id: String) -> [LibrarySongItem] {
        guard !deletedAlbums.ids.contains(id) else { return [] }
        return songLibrary.albumIndex.songIDsByAlbum[id, default: []].compactMap { songLibrary.song(id: $0) }
    }
    func isAlbumDownloaded(_ id: String) -> Bool { !albumSongs(id).isEmpty }
    var albums: [LibraryShelfItem] {
        catalog.albums + songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
    }
    private func albumItem(_ id: String) -> LibraryShelfItem? {
        guard !deletedAlbums.ids.contains(id), let item = songLibrary.albumIndex.itemsByID[id] else { return nil }
        return withPinState(item)
    }
    var downloadedAlbumItems: [LibraryShelfItem] {
        let local = songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.albums.map { ($0.id, $0) })
        let netease = catalog.downloadedAlbums.map { catalogByID[$0.id] ?? $0 }
        return netease + local
    }

    private func withPinState(_ album: LibraryShelfItem) -> LibraryShelfItem {
        var album = album
        album.isPinned = pinnedAlbums.ids.contains(album.id)
        album.isFavorite = favoriteAlbums.ids.contains(album.id)
        return album
    }

    var allRecentlyAdded: [LibraryShelfItem] { recentAdditions() }
    var recentlyAdded: [LibraryShelfItem] { recentAdditions(limit: 6) }

    private func recentAdditions(limit: Int? = nil) -> [LibraryShelfItem] {
        let playlists = playlistLibrary.playlists.filter { !$0.isSystem }.map { playlist in
            var shown = playlist
            shown.artwork = playlistLibrary.displayArtwork(of: playlist)
            var item = shown.shelfItem
            if !playlist.isReadOnly { item.subtitle = "我" }
            return (item, playlist.addedAt)
        }
        let albumItems = albums.map { album in
            (album, LibraryRecentAdditions.date(forAddedOrder: album.addedOrder))
        }
        let added = playlistLibrary.recentlyAddedSongs()
        let hiddenAlbums = deletedAlbums.ids
        var songItems = songLibrary.favoriteSongs.compactMap { song -> (LibrarySongItem, Date?)? in
            guard added[song.id] == nil, song.isOnline || !hiddenAlbums.contains(song.albumID) else { return nil }
            return (song, song.favoriteAddedAt)
        }
        for (id, entry) in added {
            let visible = songLibrary.visibleSong(id: id).flatMap {
                $0.isOnline || !hiddenAlbums.contains($0.albumID) ? $0 : nil
            }
            let song = visible ?? entry.song
            songItems.append((song, song.favoriteAddedAt.map { max($0, entry.addedAt) } ?? entry.addedAt))
        }
        return LibraryRecentAdditions.ordered(collections: playlists + albumItems, songs: songItems, limit: limit)
    }

    var musicPickerSource: MusicPickerSource {
        MusicPickerSource(
            songs: { self.allSongs },
            artists: { self.artists },
            albums: { self.albums.map(self.withPinState) },
            downloadedAlbums: { self.downloadedAlbumItems.map(self.withPinState) },
            recentlyAdded: { self.allRecentlyAdded },
            recentlyPlayed: { self.recentPlaybackFixture },
            playlistLibrary: playlistLibrary,
            albumSongs: { self.albumSongs($0) },
            loadAlbumSongs: { id in
                if CatalogRouteIdentity.isCatalogID(id), let load = self.catalog.loadAlbumSongs {
                    return try await load(id)
                }
                return self.albumSongs(id)
            },
            loadArtistDetail: { id in
                if CatalogRouteIdentity.isCatalogID(id), let load = self.catalog.loadArtistDetail {
                    return try await load(id)
                }
                return nil
            },
            songByID: { self.songForMenu($0) }
        )
    }

    func playLibrarySong(_ id: String) {
        guard let song = songForMenu(id) else { return }
        playSongs([song], shuffled: false)
    }

    func songForMenu(_ id: String) -> LibrarySongItem? {
        song(id: id) ?? playlistLibrary.containedSong(id)
    }

    var pinned: [LibraryShelfItem] {
        var items = playlistLibrary.playlists.filter(\.isPinned).map(\.shelfItem) + albums.map(withPinState).filter(\.isPinned)
        if !artistPreferences.pins(for: libraryArtistOwner).isEmpty {
            items += libraryArtists.filter(\.isPinned).sorted(byName: \.name).map(\.shelfItem)
        }
        return pinnedOrder.ordered(items) { $0.route.flatMap(PinnedOrderID.init(route:)) }
    }

    @discardableResult
    func reorderPinned(_ routes: [LibraryRoute]) -> Bool {
        let items = pinned
        let visible = items.compactMap { $0.route.flatMap(PinnedOrderID.init(route:)) }
        let requested = routes.compactMap(PinnedOrderID.init(route:))
        guard visible.count == items.count, requested.count == routes.count else { return false }
        return pinnedOrder.reorder(visible: visible, to: requested)
    }

    var recentPlaybackFixture: [LibrarySongItem] { [] }

    var downloadedPlaylists: PlaylistLibrary { downloadedPlaylistView }

    func refreshDownloadPresentation() {
        songLibrary.refreshDownloadPresentation()
        refreshDownloadedPlaylistsPresentation()
    }

    func refreshDownloadedPlaylistsPresentation() {
        playlistLibrary.reconcileOfflineAvailability()
        let candidates = playlistLibrary.downloadedSnapshotItems + playlistLibrary.playlists.filter { !$0.isReadOnly }
        var items: [LibraryPlaylistItem] = []
        var contents: [String: [LibrarySongItem]] = [:]
        for var item in candidates {
            let available = playlistLibrary.songs(in: item.id).filter { downloads.state(of: $0.id) == .downloaded }
            guard !available.isEmpty else { continue }
            item.isReadOnlyContent = true
            items.append(item)
            contents[item.id] = available
        }
        downloadedPlaylistView.replaceDownloadedPlaylists(items: items, songs: contents)
    }
    var playlists: [LibraryPlaylistItem] { playlistLibrary.playlists }
    var artists: [LibraryArtistItem] { catalog.artists }

    private var libraryArtistOwner: String? { catalog.activeArtistOwner?() }

    var libraryArtists: [LibraryArtistEntry] {
        let owner = libraryArtistOwner
        let collected = catalog.albums.filter { $0.sourceOwnerID == owner && owner != nil }
        let localAlbums = songLibrary.albumIndex.items.filter { !deletedAlbums.ids.contains($0.id) }.map(withPinState)
        let additions = playlistLibrary.recentlyAddedSongs()
        let playlistTracks = playlistLibrary.playlists.filter {
            !$0.isSystem && ($0.sourceOwnerID == nil || $0.sourceOwnerID == owner)
        }.flatMap { playlist in
            playlistLibrary.songs(in: playlist.id).filter(\.isOnline).map { track in
                var song = songLibrary.song(id: track.id) ?? track
                if let date = additions[track.id]?.addedAt {
                    song.addedOrder = max(song.addedOrder, Int(date.timeIntervalSince1970))
                }
                return song
            }
        }
        return LibraryArtistCatalog.make(
            local: songs,
            online: playlistTracks + songLibrary.onlineSongs.filter(\.isFavorite),
            subscribed: owner != nil && catalog.artistOwnerID == owner ? catalog.artists : [],
            albums: collected + localAlbums + catalog.downloadedAlbums,
            owner: owner,
            preferences: artistPreferences,
            downloadedID: { catalog.downloadedOnlineSongID?($0) }
        )
    }

    private func libraryArtist(_ id: LibraryArtistIdentity) -> LibraryArtistEntry? {
        guard id.belongs(to: libraryArtistOwner) else { return nil }
        return libraryArtists.first { $0.id == id }
    }

    private func toggleLibraryArtistFavorite(_ id: LibraryArtistIdentity) {
        guard let artist = libraryArtist(id) else { return }
        if case .catalog(_, .some) = id, let route = artist.id.onlineRoute {
            catalog.actions.toggleFavorite(route)
        } else {
            artistPreferences.toggleFavorite(id, owner: libraryArtistOwner)
            LibraryHaptics.success()
            toasts.show(artist.isFavorite ? .unfavorited : .favorited)
        }
    }

    private func playLibraryArtist(_ id: LibraryArtistIdentity, shuffled: Bool) async {
        guard let artist = libraryArtist(id) else { return }
        let session = catalog.activeArtistSession?()
        let ownedAlbums = artist.albums.filter { $0.sourceOwnerID != nil && $0.isFavorite }
        var loaded: [LibrarySongItem] = []
        var failure: String?
        if let load = catalog.loadAlbumSongs, session != nil {
            for album in ownedAlbums {
                do {
                    try Task.checkCancellation()
                    let tracks = try await load(album.id)
                    guard session == catalog.activeArtistSession?(), id.belongs(to: libraryArtistOwner) else { return }
                    loaded += tracks.filter { track in
                        track.artistReferences.contains { $0.id == id.itemID }
                            || (track.artistReferences.isEmpty && album.artistReferences.contains { $0.id == id.itemID })
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failure = error.localizedDescription
                }
            }
        } else if !ownedAlbums.isEmpty {
            failure = "账户资料正在恢复，请稍后重试。"
        }
        guard !Task.isCancelled, let current = libraryArtist(id),
              ownedAlbums.isEmpty || session == catalog.activeArtistSession?() else { return }
        let currentAlbums = Set(current.albums.filter(\.isFavorite).map(\.id))
        var seen = Set<String>()
        let playable = (current.songs + loaded.filter { currentAlbums.contains($0.albumID) }).filter { track in
            let stableID = track.onlineSongID ?? catalog.downloadedOnlineSongID?(track.id)
            return track.unavailabilityReason == nil && seen.insert(stableID.map { "catalog-song:\($0)" } ?? track.id).inserted
        }
        guard !playable.isEmpty else {
            toasts.show(.error(failure ?? "该艺人在资料库中没有可播放的歌曲"))
            return
        }
        player.requestPlay(playable, from: current.name, shuffled: shuffled)
        if failure != nil { toasts.show(.error("部分专辑未能读取，正在播放已可用的歌曲")) }
    }

    private func libraryArtistAlbum(_ id: LibraryArtistIdentity, albumID: String) -> CollectionDetail? {
        guard let artist = libraryArtist(id), let item = artist.albums.first(where: { $0.id == albumID }) else { return nil }
        let likedIDs = Set(songLibrary.onlineSongs.filter {
            $0.onlineOwnerID == libraryArtistOwner && $0.isFavorite
        }.compactMap(\.onlineSongID))
        let tracks = songs.filter { $0.albumID == albumID }.map { track in
            var song = track
            if let id = catalog.downloadedOnlineSongID?(track.id) { song.isFavorite = likedIDs.contains(id) }
            return song
        }.sorted(by: LibrarySongItem.albumOrder)
        guard !tracks.isEmpty else { return nil }
        return .init(kind: .album, title: item.title, subtitle: item.subtitle, caption: item.year.map { "\($0)年" },
                     artwork: item.artwork, tint: Color(.systemBackground), albumBackdrop: item.albumBackdrop,
                     songs: tracks, route: .libraryArtistAlbum(id, albumID))
    }
    func albumDetail(_ id: String) -> CollectionDetail? {
        let orderedSongs = albumSongs(id)
        guard let album = albumItem(id) else { return nil }
        return CollectionDetail(kind: .album, title: album.title, subtitle: album.subtitle, caption: nil,
            artwork: album.artwork, tint: Color(.systemBackground), albumBackdrop: album.albumBackdrop, isFavorite: favoriteAlbums.ids.contains(id),
            isPinned: pinnedAlbums.ids.contains(id), songs: orderedSongs, route: .album(id))
    }
    func playlistDetail(_ id: String) -> CollectionDetail? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        return CollectionDetail(kind: .playlist, title: playlist.title, subtitle: nil, caption: nil,
            artwork: playlist.artwork, tint: Color(.systemBackground), isFavorite: playlist.isFavorite,
            isPinned: playlist.isPinned, songs: id == "favorites" ? favorites : playlistLibrary.songs(in: id), route: .playlist(id))
    }
    func songAlbumPreview(_ song: LibrarySongItem, route: LibraryRoute) -> LibraryNavigationPreview? {
        guard case .album(let id) = route else { return nil }
        let online = CatalogRouteIdentity.isCatalogID(id)
        if let owner = song.onlineOwnerID, owner != (playbackAccountID ?? "search-guest") { return nil }
        let album: LibraryShelfItem?
        if online {
            album = catalog.cachedAlbumItem?(id) ?? catalog.albums.first {
                $0.id == id && $0.sourceOwnerID == playbackAccountID
            }
        } else {
            album = albumItem(id)
        }
        let songCover: Artwork
        if let url = song.artworkURL, url.isFileURL { songCover = .file(url) }
        else { songCover = song.artwork }
        let cover = album.flatMap { $0.artwork == .missing ? nil : $0.artwork } ?? songCover
        let color = album?.albumBackdrop ?? LocalArtworkImages.cachedBackdrop(for: cover)
            ?? song.artworkBackdrop ?? LocalArtworkImages.cachedBackdrop(for: songCover)
        var preview = LibraryNavigationPreview(route: route, ownerID: online ? playbackAccountID : nil,
            title: album?.title ?? song.album, subtitle: album?.subtitle ?? (song.albumArtist.isEmpty ? song.artist : song.albumArtist),
            artwork: cover, albumBackdrop: color)
        preview.requiresMatchingAccount = online
        return preview
    }

    private func playerNavigationSong(id: String) -> LibrarySongItem? {
        if let indexed = song(id: id) { return indexed }
        // An authenticated queue snapshot can restore the current song before any catalog source publishes it.
        let current = player.current
        guard player.hasCurrent, current.id == id, current.unavailabilityReason == nil,
              let owner = current.onlineOwnerID, owner == playbackAccountID else { return nil }
        return current
    }

    func playerActions(navigate: @escaping (LibraryRoute, LibraryNavigationPreview?) -> Void,
                       openAudioQualitySettings: (() -> Void)?) -> PlayerActions {
        let openRoute: (LibraryRoute) -> Void = { navigate($0, nil) }
        return PlayerActions(
            isFavorite: { id in self.song(id: id)?.isFavorite == true },
            toggleFavorite: { self.songLibrary.toggleFavorite($0) },
            addToPlaylist: { id in
                guard let song = self.song(id: id) else { return }
                if let prepareSongForLibraryAction = self.prepareSongForLibraryAction {
                    guard let prepared = prepareSongForLibraryAction(song) else { return }
                    self.playlistLibrary.pendingAddition = .init(songs: [prepared])
                } else { self.playlistLibrary.pendingAddition = .init(songs: [song]) }
            },
            openAlbum: { id in
                guard let song = self.playerNavigationSong(id: id) else { return }
                self.songActions.openAlbum(song) { route in navigate(route, self.songAlbumPreview(song, route: route)) }
            },
            openArtist: { id in
                guard let song = self.playerNavigationSong(id: id) else { return }
                if let ref = song.artistReferences.first { openRoute(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || self.catalog.downloadedOnlineSongID?(id) != nil { self.catalog.openSongArtist?(song, nil, openRoute) }
            }, artistNames: { id in
                guard let song = self.playerNavigationSong(id: id) else { return [] }
                let refs = song.artistReferences.map(\.name)
                if !refs.isEmpty { return refs }
                if song.isNeteaseCatalogSong || self.catalog.downloadedOnlineSongID?(id) != nil {
                    return song.artist.isEmpty ? [] : [song.artist]
                }
                return []
            }, openNamedArtist: { id, name in
                guard let song = self.playerNavigationSong(id: id) else { return }
                if let ref = song.artistReferences.first(where: { $0.name == name }) { openRoute(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || self.catalog.downloadedOnlineSongID?(id) != nil { self.catalog.openSongArtist?(song, name, openRoute) }
            }, feedback: { LibraryHaptics.success() }, notify: { self.toasts.show(LibraryToast($0)) }, completesFavoriteSynchronously: { id in
                guard let song = self.song(id: id) else { return false }
                return !song.isNeteaseCatalogSong && !self.downloads.canRemove(song)
            }, audioQuality: { id in
                guard self.player.hasCurrent, self.player.current.id == id else { return nil }
                if !self.player.current.isOnline {
                    return PlayerAudioQuality.localFile(self.runtime.root.appending(path: id))
                }
                guard let value = self.player.actualQuality,
                      let quality = NeteaseMusicQuality(rawValue: value) else { return nil }
                return PlayerAudioQuality(title: quality.title,
                    isLossless: quality == .lossless || quality == .hiRes)
            }, openAudioQualitySettings: openAudioQualitySettings)
    }

    private func collection(_ route: LibraryRoute) -> (title: String, songs: [LibrarySongItem])? {
        switch route {
        case .album(let id): albumDetail(id).map { ($0.title, $0.songs) }
        case .playlist(let id): playlistDetail(id).map { ($0.title, $0.songs) }
        case .artist(let id): (id, songs.filter { $0.albumArtist == id })
        case .libraryArtistAlbum(let artist, let album): libraryArtistAlbum(artist, albumID: album).map { ($0.title, $0.songs) }
        default: nil
        }
    }

    func playbackCollection(_ route: LibraryRoute) -> PlaybackCollectionReference? {
        switch route {
        case .album(let id):
            guard let detail = albumDetail(id) else { return nil }
            return .init(kind: .localAlbum, id: id, ownerID: nil, title: detail.title)
        case .playlist(let id):
            guard let item = playlistLibrary.playlist(id) else { return nil }
            if item.isSystem { return .init(kind: .favorites, id: id, ownerID: playbackAccountID, title: item.title) }
            return .init(kind: item.sourceOwnerID == nil ? .localPlaylist : .onlinePlaylist,
                         id: id, ownerID: item.sourceOwnerID, title: item.title)
        default: return nil
        }
    }

    private func withCollection(_ route: LibraryRoute,
                                       perform: @escaping @MainActor ((title: String, songs: [LibrarySongItem])) -> Void) {
        guard case .playlist(let id) = route, let item = playlistLibrary.playlist(id) else {
            if let value = collection(route) { perform(value) }
            return
        }
        let owner = item.sourceOwnerID
        let accountID = playbackAccountID
        let needsOnline = owner != nil || playlistLibrary.onlineHasMore.contains(id)
            || (id == "favorites" && accountID != nil)
        guard needsOnline else {
            if let value = collection(route) { perform(value) }
            return
        }
        let complete = playlistLibrary.completeOnlinePlaylist
        let load = playlistLibrary.loadOnlinePlaylist
        guard complete != nil || load != nil else {
            toasts.show(.error("请登录网易云账号后重试"))
            return
        }
        Task {
            let completed: Bool
            if let complete { completed = await complete(id) }
            else {
                await load?(id)
                completed = playlistLibrary.loadedOnlinePlaylistIDs.contains(id)
            }
            guard !Task.isCancelled, playlistLibrary.playlist(id)?.sourceOwnerID == owner,
                  playbackAccountID == accountID else { return }
            if let error = playlistLibrary.onlineErrors[id] {
                toasts.show(.error(error))
                return
            }
            guard completed, !playlistLibrary.onlineHasMore.contains(id),
                  !playlistLibrary.loadingPlaylistIDs.contains(id), let value = collection(route) else {
                toasts.show(.error("播放列表尚未完整加载，请重试"))
                return
            }
            perform(value)
        }
    }

    var menuActions: CollectionMenuActions {
        CollectionMenuActions(
            play: { route, shuffled in
                if self.catalog.handles(route) { self.catalog.actions.play(route, shuffled); return }
                self.withCollection(route) { collection in
                    guard !collection.songs.isEmpty else { return }
                    self.player.requestPlay(collection.songs, from: collection.title, shuffled: shuffled, collection: self.playbackCollection(route))
                }
            },
            playNext: { route in if self.catalog.handles(route) { self.catalog.actions.playNext(route); return }; self.withCollection(route) { self.player.insertNext($0.songs) } },
            playLater: { route in if self.catalog.handles(route) { self.catalog.actions.playLater(route); return }; self.withCollection(route) { self.player.appendLater($0.songs) } },
            toggleFavorite: { route in
                if self.catalog.handles(route) { self.catalog.actions.toggleFavorite(route); return }
                switch route {
                case .playlist(let id): self.playlistLibrary.toggleFavorite(id)
                case .album(let id): self.favoriteAlbums.toggle(id)
                case .artist(let id): self.favoriteArtists.toggle(id)
                case .libraryArtist(let id): self.toggleLibraryArtistFavorite(id)
                default: break
                }
            },
            togglePin: { route in
                switch route {
                case .playlist(let id): self.playlistLibrary.togglePin(id)
                case .album(let id): self.pinnedAlbums.toggle(id)
                case .libraryArtist(let id):
                    guard let artist = self.libraryArtist(id) else { return }
                    self.artistPreferences.togglePin(id, name: artist.name, owner: self.libraryArtistOwner)
                default: break
                }
            },
            addToPlaylist: { route in
                if self.catalog.handles(route) { self.catalog.actions.addToPlaylist(route); return }
                self.withCollection(route) { collection in
                    self.playlistLibrary.pendingAddition = .init(songs: collection.songs)
                }
            },
            playbackSource: { self.player.isPlaying ? self.player.sourceTitle : nil },
            requestMove: { self.playlistLibrary.pendingMove = self.playlistLibrary.playlist($0) },
            canDelete: { route in
                if self.catalog.handles(route) { return false }
                return switch route {
                case .playlist(let id): self.playlistLibrary.canDelete(id) || self.playlistLibrary.canUnsubscribe(id)
                case .album: true
                default: false
                }
            },
            isDownloaded: { route in
                if let value = self.collectionDownloads.downloadedState?(route) { return value }
                if case .album(let id) = route { return self.isAlbumDownloaded(id) }
                return false
            },
            edit: { route in
                guard case .playlist(let id) = route else { return }
                self.playlistLibrary.pendingEdit = self.playlistLibrary.playlist(id)
            },
            requestDelete: { route in
                guard case .playlist(let id) = route else { return }
                self.playlistLibrary.pendingDeletion = self.playlistLibrary.playlists.first { $0.id == id }
            },
            delete: { route in
                switch route {
                case .playlist(let id): self.playlistLibrary.deletePlaylist(id)
                case .album(let id):
                    let removed = self.albumSongs(id)
                    self.deletedAlbums.insert(id)
                    self.playlistLibrary.removeSongsEverywhere(Set(removed.map(\.id)))
                    self.pinnedAlbums.remove(id)
                default: break
                }
            },
            notify: { self.toasts.show($0) },
            removeDownload: { route in
                if self.collectionDownloads.remove?(route) == true { return }
                if case .album(let id) = route { self.downloads.requestRemoval(self.albumSongs(id)) }
            },
            download: { route in
                if self.collectionDownloads.download?(route) == true { return }
                if case .album(let id) = route { self.downloads.download(self.albumSongs(id)) }
            },
            canDownload: { self.collectionDownloads.canDownload?($0) ?? false },
            canRemoveDownload: { self.collectionDownloads.canRemoveDownload?($0) ?? false },
            stopDownload: { self.collectionDownloads.stop?($0) },
            downloads: downloads
        )
    }

    private var songActions: SongMenuActions {
        SongMenuActions(
            downloads: downloads,
            play: { songs, index, source in self.player.requestPlay(songs, startingAt: index, from: source) },
            playNext: { self.player.insertNext([$0]) },
            toggleFavorite: { self.songLibrary.toggleFavorite($0.id) },
            removeFromFavorites: { self.songLibrary.setFavorite($0.id, false, playsSuccessHaptic: false) },
            togglePin: { self.songLibrary.togglePin($0.id) },
            addToPlaylist: { song in
                if let prepareSongForLibraryAction = self.prepareSongForLibraryAction {
                    guard let prepared = prepareSongForLibraryAction(song) else { return }
                    self.playlistLibrary.pendingAddition = .init(songs: [prepared])
                } else { self.playlistLibrary.pendingAddition = .init(songs: [song]) }
            },
            playLater: { self.player.appendLater([$0]) },
            delete: { song in
                self.songLibrary.delete(song.id)
                self.playlistLibrary.removeSongsEverywhere([song.id])
            },
            playbackSource: { self.player.isPlaying ? self.player.sourceTitle : nil },
            albumPreview: songAlbumPreview,
            openAlbum: { song, open in
                if song.onlineAlbumID != nil { open(.album(song.albumID)) }
                else if song.isNeteaseCatalogSong || self.catalog.downloadedOnlineSongID?(song.id) != nil { self.catalog.openSongAlbum?(song, open) }
                else { open(.album(song.albumID)) }
            },
            openArtist: { song, open in
                if let ref = song.artistReferences.first { open(.artist(ref.id)) }
                else if song.isNeteaseCatalogSong || self.catalog.downloadedOnlineSongID?(song.id) != nil { self.catalog.openSongArtist?(song, nil, open) }
            },
            notify: { self.toasts.show($0) },
            isAsynchronousFavorite: { $0.isNeteaseCatalogSong || self.downloads.canRemove($0) }
        )
    }

    func songActions(for route: LibraryRoute) -> SongMenuActions {
        var actions = songActions
        actions.play = { songs, index, source in
            self.player.requestPlay(songs, startingAt: index, from: source, collection: self.playbackCollection(route))
        }
        return actions
    }

    var app: some View {
        let playableOffline = player.hasOfflineCurrentSong || (player.hasCurrent && !player.current.isOnline)
        let showRestoredTrack = runtime.isInitialPresentationReady && (runtime.isInitialPlaybackReady || playableOffline)
        return AppShell(library: { [self] in
            LocalLibraryHome(container: self)
        }, detailDestination: { AnyView(LocalDestination(container: self, route: $0)) }, nowPlaying: player, playlistLibrary: playlistLibrary, toasts: toasts,
           referencePlayer: referencePlayer, referenceLibrary: referenceLibrary, makePlayerActions: playerActions,
           isInitialContentReady: showRestoredTrack, libraryPath: launchPath, isPlayerPresented: ["nowplaying", "paused", "queue"].contains(launchPage))
        .playlistEditSheet(playlistLibrary, songs: { self.allSongs })
        .downloadRemovalConfirmation()
        .environment(\.libraryDownloads, downloads)
        .environment(\.collectionMenuActions, menuActions)
        .environment(\.songMenuActions, songActions)
        .environment(\.songRowPlayback, player)
        .environment(\.musicPickerSource, musicPickerSource)
    }

    func playSongs(_ songs: [LibrarySongItem], shuffled: Bool) {
        player.requestPlay(songs, from: "歌曲", shuffled: shuffled)
    }

    func playAlbums(_ ids: [String], shuffled: Bool) {
        if ids.contains(where: CatalogRouteIdentity.isCatalogID) {
            Task {
                do {
                    var songs: [LibrarySongItem] = []
                    for id in ids {
                        if CatalogRouteIdentity.isCatalogID(id), let load = catalog.loadAlbumSongs { songs += try await load(id) }
                        else { songs += albumDetail(id)?.songs ?? [] }
                    }
                    player.requestPlay(songs, from: "专辑", shuffled: shuffled)
                } catch is CancellationError { } catch { toasts.show(.error(error.localizedDescription)) }
            }
            return
        }
        let tracks = ids.flatMap { albumDetail($0)?.songs ?? [] }
        player.requestPlay(tracks, from: "专辑", shuffled: shuffled)
    }

    @ViewBuilder fileprivate func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .category(.downloaded): DownloadedLibraryView(albums: downloadedAlbumItems.map(withPinState))
        case .downloadedCategory(.songs): SongsListView(songs: songs.filter { downloads.state(of: $0.id) == .downloaded }, playAll: playSongs)
        case .downloadedCategory(.albums): AlbumsGridView(albums: downloadedAlbumItems.map(withPinState), playAll: playAlbums)
        case .downloadedCategory(.artists):
            ArtistsListView(artists: libraryArtists, filter: .downloaded)
        case .downloadedCategory(.playlists): PlaylistsListView(library: downloadedPlaylists)
        case .downloadedCategory(.downloaded): EmptyView()
        case .category(.songs): SongsListView(songs: songs, playAll: playSongs)
        case .category(.albums): AlbumsGridView(albums: albums.map(withPinState), playAll: playAlbums)
        case .category(.artists): ArtistsListView(artists: libraryArtists)
        case .category(.playlists): PlaylistsListView(library: playlistLibrary)
        case .playlistFolder(let id): PlaylistsListView(library: playlistLibrary, folderID: id)
        case .album(let id): albumDetail(id).map { CollectionDetailView(detail: $0) }
        case .libraryArtist(let id):
            if let artist = libraryArtist(id) {
                LibraryArtistDetailView(artist: artist, play: { await self.playLibraryArtist(id, shuffled: $0) })
            } else {
                ContentUnavailableView("艺人已不可用", systemImage: "music.microphone")
            }
        case .libraryArtistAlbum(let artist, let id):
            if let detail = libraryArtistAlbum(artist, albumID: id) {
                CollectionDetailView(detail: detail)
            } else {
                ContentUnavailableView("专辑已不可用", systemImage: "square.stack")
            }
        case .playlist(let id):
            if id == "favorites" { LocalFavoritesDetail(container: self) }
            else { PlaylistDetailView(playlistID: id, library: playlistLibrary, songs: [], availableSongs: { self.allSongs }, recentlyPlayedSongs: recentPlaybackFixture) }
        case .artist, .artistSection, .searchCategory: EmptyView()
        }
    }

    private var launchPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mockPage"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private var launchPath: [LibraryRoute] {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-catalogArtist"), args.indices.contains(index + 1), Int64(args[index + 1]) != nil { return [.artist(CatalogRouteIdentity.artistID(args[index + 1]))] }
        #endif
        guard let page = launchPage else { return [] }
        let pages: [String: [LibraryRoute]] = [
            "downloaded": [.category(.downloaded)],
            "songs": [.category(.songs)], "albums": [.category(.albums)], "artists": [.category(.artists)],
            "playlists": [.category(.playlists)], "album": [.category(.albums), .album("-斩断-")],
            "album-light": [.category(.albums), .album("月光入侵计划")],
            "album-night": [.category(.albums), .album("夜语花")],
            "playlist": [.category(.playlists), .playlist("test")],
            "favorites": [.category(.playlists), .playlist("favorites")],
            "folder": [.category(.playlists), .playlistFolder("111")],
        ]
        return pages[page] ?? []
    }


}

struct LocalLibraryHome: View {
    var container: AppContainer = .shared
    var body: some View {
        let ready = container.runtime.isInitialPresentationReady
        LibraryHomeView(pinned: ready ? container.pinned : [], recentlyAdded: ready ? container.recentlyAdded : [],
                        playlistLibrary: container.playlistLibrary,
                        isContentReady: ready,
                        reorderPinned: container.reorderPinned,
                        playSong: container.playLibrarySong,
                        songForMenu: container.songForMenu)
            .safeAreaInset(edge: .bottom) {
                if ready, let status = container.runtime.status { LibraryStatusMessage(message: status) }
                if ready, let error = container.playlistLibrary.persistenceError {
                    LibraryStatusMessage(message: error, title: "保存状态", isError: true)
                }
            }
    }
}

private struct LocalDestination: View {
    var container: AppContainer = .shared
    let route: LibraryRoute
    @Environment(\.libraryZoomNamespace) private var zoomNamespace

    @ViewBuilder var body: some View {
        switch route {
        case .album, .playlist:
            container.destination(route)
                .environment(\.songMenuActions, container.songActions(for: route))
                #if DEBUG
                .navigationDiagnostics(route.diagnosticPage)
                #endif
                .libraryZoomTransition(route, in: zoomNamespace)
        default:
            container.destination(route)
                #if DEBUG
                .navigationDiagnostics(route.diagnosticPage)
                #endif
        }
    }
}

struct LocalFavoritesDetail: View {
    var container: AppContainer = .shared
    @Environment(NeteaseAccount.self) private var account

    private struct LoadRequest: Equatable {
        let revision: UUID
        let playlistID: Int64
    }

    private var loadRequest: LoadRequest? {
        guard account.hasRestored, let music = account.music, music.userID != nil,
              let favorites = music.playlists.first(where: \.isFavorites) else { return nil }
        return LoadRequest(revision: music.sessionRevision, playlistID: favorites.id)
    }

    var body: some View {
        if let detail = container.playlistDetail("favorites") {
            let library = container.playlistLibrary
            let request = loadRequest
            let awaitingOnlineDetail = request.map { request in
                !library.hasReceivedPlaylistDetail(for: "favorites")
                    && account.music?.playlistErrors[request.playlistID] == nil
                    && account.music?.error == nil
            } ?? false
            let awaitingDetail = detail.songs.isEmpty
                && (!container.runtime.isInitialLibraryReady || awaitingOnlineDetail)
            CollectionDetailView(
                detail: detail,
                awaitingDetail: awaitingDetail,
                hasMoreSongs: library.onlineHasMore.contains("favorites"),
                totalSongCount: library.onlineTrackCounts["favorites"],
                onReachedEnd: {
                    guard container.playlistLibrary.onlineHasMore.contains("favorites"),
                          container.playlistLibrary.onlineErrors["favorites"] == nil else { return }
                    Task { await container.playlistLibrary.loadMoreOnlinePlaylist?("favorites") }
                },
                onPrepareCompleteCollection: {
                    _ = await container.playlistLibrary.prepareCompleteCollection("favorites")
                }
            )
                .task(id: request) {
                    guard request != nil else { return }
                    await loadFavorites()
                }
                .refreshable { await loadFavorites(force: true) }
        }
    }

    private func loadFavorites(force: Bool = false) async {
        guard let music = account.music else { return }
        let revision = music.sessionRevision
        await music.loadFavoritesPreview(force: force)
        guard revision == music.sessionRevision, !Task.isCancelled else { return }
        let playlistError = music.playlists.first(where: \.isFavorites).flatMap { music.playlistErrors[$0.id] }
        if let message = playlistError ?? music.error { container.toasts.show(.error(message)) }
    }
}

extension PinnedOrderID {
    init?(route: LibraryRoute) {
        switch route {
        case .playlist(let id): self.init(kind: .playlist, id: id)
        case .album(let id): self.init(kind: .album, id: id)
        case .libraryArtist(let artist):
            let owner: String? = if case .catalog(_, let owner) = artist { owner } else { nil }
            self.init(kind: .artist, id: artist.itemID, ownerID: owner)
        default: return nil
        }
    }
}
