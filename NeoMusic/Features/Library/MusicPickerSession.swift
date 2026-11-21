import SwiftUI

@MainActor
struct MusicPickerSource {
    var songs: @MainActor () -> [LibrarySongItem] = { [] }
    var artists: @MainActor () -> [LibraryArtistItem] = { [] }
    var albums: @MainActor () -> [LibraryShelfItem] = { [] }
    var downloadedAlbums: @MainActor () -> [LibraryShelfItem] = { [] }
    var recentlyAdded: @MainActor () -> [LibraryShelfItem] = { [] }
    var recentlyPlayed: @MainActor () -> [LibrarySongItem] = { [] }
    var playlistLibrary: PlaylistLibrary? = nil
    var albumSongs: @MainActor (String) -> [LibrarySongItem] = { _ in [] }
    var loadAlbumSongs: (@MainActor (String) async throws -> [LibrarySongItem])? = nil
    var loadArtistDetail: (@MainActor (String) async throws -> ArtistDetail?)? = nil
    var songByID: @MainActor (String) -> LibrarySongItem? = { _ in nil }

    static func fallback(songs: [LibrarySongItem], playlists: [LibraryPlaylistItem],
                         playlistLibrary: PlaylistLibrary?, playlistSongs: [String: [LibrarySongItem]],
                         recentlyPlayed: [LibrarySongItem]) -> Self {
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupedArtists: [LibraryArtistItem] = {
            var seen = Set<String>()
            var result: [LibraryArtistItem] = []
            for song in songs {
                if !song.artistReferences.isEmpty {
                    for ref in song.artistReferences where seen.insert(ref.id).inserted {
                        result.append(LibraryArtistItem(id: ref.id, name: ref.name, artwork: nil))
                    }
                } else if !song.artist.isEmpty, seen.insert(song.artist).inserted {
                    result.append(LibraryArtistItem(id: song.artist, name: song.artist, artwork: nil))
                }
            }
            return result.sorted(byName: \.name)
        }()
        let groupedAlbums: [LibraryShelfItem] = {
            let byAlbum = Dictionary(grouping: songs, by: \.albumID)
            return byAlbum.compactMap { id, tracks in
                guard let first = tracks.first, !first.album.isEmpty else { return nil }
                return LibraryShelfItem(
                    id: id,
                    title: first.album,
                    subtitle: first.albumArtist.isEmpty ? first.artist : first.albumArtist,
                    artwork: first.artwork,
                    route: .album(id),
                    addedOrder: tracks.map(\.addedOrder).max() ?? 0
                )
            }
        }()
        let resolvedLibrary = playlistLibrary ?? {
            let temp = PlaylistLibrary(playlists: playlists)
            for (id, tracks) in playlistSongs {
                temp.addSongs(tracks, to: id)
            }
            return temp
        }()
        let recentCollections = (groupedAlbums + playlists.filter { !$0.isSystem }.map(\.shelfItem))
            .sorted { $0.addedOrder > $1.addedOrder }
        return Self(
            songs: { songs },
            artists: { groupedArtists },
            albums: { groupedAlbums },
            downloadedAlbums: { groupedAlbums },
            recentlyAdded: { recentCollections },
            recentlyPlayed: { recentlyPlayed },
            playlistLibrary: resolvedLibrary,
            albumSongs: { albumID in songs.filter { $0.albumID == albumID }.sorted(by: LibrarySongItem.albumOrder) },
            loadAlbumSongs: nil,
            loadArtistDetail: nil,
            songByID: { songsByID[$0] }
        )
    }
}

extension EnvironmentValues {
    @Entry var musicPickerSource: MusicPickerSource? = nil
}



@MainActor @Observable
final class MusicPickerSession {
    private(set) var prepared = false
    private(set) var allSongs: [LibrarySongItem] = []
    private(set) var sortedSongs: [LibrarySongItem] = []
    private(set) var recentFavorites: [LibrarySongItem] = []
    private(set) var recentlyPlayed: [LibrarySongItem] = []
    private(set) var sortedArtists: [LibraryArtistItem] = []
    private(set) var sortedAlbums: [LibraryShelfItem] = []
    private(set) var sortedDownloadedAlbums: [LibraryShelfItem] = []
    private(set) var recentlyAdded: [LibraryShelfItem] = []

    private var artistsByID: [String: LibraryArtistItem] = [:]
    private var albumsByID: [String: LibraryShelfItem] = [:]
    private var albumSongsCache: [String: [LibrarySongItem]] = [:]
    private var artistCatalogCache: [String: ArtistDetail] = [:]
    @ObservationIgnored private var cachedFallbackSource: MusicPickerSource?

    func resolvedSource(environment: MusicPickerSource?, makeFallback: () -> MusicPickerSource) -> MusicPickerSource {
        if let environment { return environment }
        if let cachedFallbackSource { return cachedFallbackSource }
        let created = makeFallback()
        cachedFallbackSource = created
        return created
    }

    func prepareIfNeeded(using source: MusicPickerSource) {
        guard !prepared else { return }
        prepared = true
        let songs = source.songs()
        allSongs = songs
        sortedSongs = songs.sorted(byName: \.title)
        recentFavorites = songs
            .filter(\.isFavorite)
            .sorted { lhs, rhs in
                if lhs.favoriteAddedAt != rhs.favoriteAddedAt {
                    return (lhs.favoriteAddedAt ?? .distantPast) > (rhs.favoriteAddedAt ?? .distantPast)
                }
                return lhs.addedOrder > rhs.addedOrder
            }
        recentlyPlayed = source.recentlyPlayed()

        let artists = source.artists().sorted(byName: \.name)
        sortedArtists = artists
        artistsByID = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let albums = source.albums().sorted(byName: \.title)
        sortedAlbums = albums
        let downloaded = source.downloadedAlbums().sorted(byName: \.title)
        sortedDownloadedAlbums = downloaded
        let recent = source.recentlyAdded()
        recentlyAdded = recent

        var map: [String: LibraryShelfItem] = [:]
        for item in recent { map[item.id] = item }
        for item in downloaded { map[item.id] = item }
        for item in albums { map[item.id] = item }
        albumsByID = map
    }

    func artist(id: String) -> LibraryArtistItem? { artistsByID[id] }
    func album(id: String) -> LibraryShelfItem? { albumsByID[id] }

    func registerAlbums(_ items: [LibraryShelfItem]) {
        for item in items where albumsByID[item.id] == nil {
            albumsByID[item.id] = item
        }
    }

    func albums(for artist: LibraryArtistItem) -> [LibraryShelfItem] {
        let matchedAlbumIDs = Set(songs(for: artist).map(\.albumID))
        let filtered = sortedAlbums.filter { album in
            matchedAlbumIDs.contains(album.id) || album.subtitle == artist.name
        }
        return filtered.sorted { ($0.year ?? 0, $1.title) > ($1.year ?? 0, $0.title) }
    }

    func songs(for artist: LibraryArtistItem) -> [LibrarySongItem] {
        allSongs.filter { song in
            song.artistReferences.contains { $0.id == artist.id }
                || song.albumArtist == artist.name
                || song.artist == artist.name
        }
    }

    func cachedAlbumSongs(id: String) -> [LibrarySongItem]? { albumSongsCache[id] }
    func storeAlbumSongs(_ tracks: [LibrarySongItem], for id: String) { albumSongsCache[id] = tracks }

    func catalogArtist(id: String) -> ArtistDetail? { artistCatalogCache[id] }
    func storeCatalogArtist(_ detail: ArtistDetail, for id: String) {
        artistCatalogCache[id] = detail
        var extra = detail.albums + detail.singles
        if let latest = detail.latest { extra.append(latest) }
        registerAlbums(extra)
    }
}


enum MusicPickerRoute: Hashable {
    case artists, albums, songs, playlists, downloaded, recent
    case artist(id: String, name: String)
    case artistCatalog(id: String, name: String)
    case artistCatalogSection(id: String, name: String, section: ArtistSection)
    case album(id: String, title: String, subtitle: String?)
    case playlist(id: String, title: String)
    case playlistFolder(id: String, title: String)

    static let categories: [Self] = [.artists, .albums, .songs, .playlists, .downloaded, .recent]

    var navigationTitle: String {
        switch self {
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        case .downloaded: "已下载"
        case .recent: "最近添加"
        case .artist(_, let name), .artistCatalog(_, let name): name
        case .artistCatalogSection(_, _, let section): section.title
        case .playlistFolder(_, let title): title
        case .album, .playlist: ""
        }
    }

    var categoryTitle: String {
        switch self {
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        case .downloaded: "已下载"
        case .recent: "最近添加"
        default: navigationTitle
        }
    }

    var categoryImage: String {
        switch self {
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .downloaded: "arrow.down.circle"
        case .recent: "clock"
        default: "music.note"
        }
    }
}

