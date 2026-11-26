import FrontAMCore
import SwiftUI

@MainActor
public struct MusicPickerSource {
    public var songs: @MainActor () -> [LibrarySongItem] = { [] }
    public var artists: @MainActor () -> [LibraryArtistItem] = { [] }
    public var albums: @MainActor () -> [LibraryShelfItem] = { [] }
    public var downloadedAlbums: @MainActor () -> [LibraryShelfItem] = { [] }
    public var recentlyAdded: @MainActor () -> [LibraryShelfItem] = { [] }
    public var recentlyPlayed: @MainActor () -> [LibrarySongItem] = { [] }
    public var playlistLibrary: (any FrontAMPlaylistSource)? = nil
    public var albumSongs: @MainActor (String) -> [LibrarySongItem] = { _ in [] }
    public var loadAlbumSongs: (@MainActor (String) async throws -> [LibrarySongItem])? = nil
    public var loadArtistDetail: (@MainActor (String) async throws -> ArtistDetail?)? = nil
    public var canOpenCatalogArtist: @MainActor (String) -> Bool = { _ in false }
    public var songByID: @MainActor (String) -> LibrarySongItem? = { _ in nil }

    public static func fallback(songs: [LibrarySongItem], playlists: [LibraryPlaylistItem],
                         playlistLibrary: (any FrontAMPlaylistSource)?,
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
        let recentCollections = (groupedAlbums + playlists.filter { !$0.isSystem }.map(\.shelfItem))
            .sorted { $0.addedOrder > $1.addedOrder }
        return Self(
            songs: { songs },
            artists: { groupedArtists },
            albums: { groupedAlbums },
            downloadedAlbums: { groupedAlbums },
            recentlyAdded: { recentCollections },
            recentlyPlayed: { recentlyPlayed },
            playlistLibrary: playlistLibrary,
            albumSongs: { albumID in songs.filter { $0.albumID == albumID }.sorted(by: LibrarySongItem.albumOrder) },
            loadAlbumSongs: nil,
            loadArtistDetail: nil,
            songByID: { songsByID[$0] }
        )
    }

    public init(songs: @escaping @MainActor () -> [LibrarySongItem] = { [] },
                artists: @escaping @MainActor () -> [LibraryArtistItem] = { [] },
                albums: @escaping @MainActor () -> [LibraryShelfItem] = { [] },
                downloadedAlbums: @escaping @MainActor () -> [LibraryShelfItem] = { [] },
                recentlyAdded: @escaping @MainActor () -> [LibraryShelfItem] = { [] },
                recentlyPlayed: @escaping @MainActor () -> [LibrarySongItem] = { [] },
                playlistLibrary: (any FrontAMPlaylistSource)? = nil,
                albumSongs: @escaping @MainActor (String) -> [LibrarySongItem] = { _ in [] },
                loadAlbumSongs: (@MainActor (String) async throws -> [LibrarySongItem])? = nil,
                loadArtistDetail: (@MainActor (String) async throws -> ArtistDetail?)? = nil,
                canOpenCatalogArtist: @escaping @MainActor (String) -> Bool = { _ in false },
                songByID: @escaping @MainActor (String) -> LibrarySongItem? = { _ in nil }) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.downloadedAlbums = downloadedAlbums
        self.recentlyAdded = recentlyAdded
        self.recentlyPlayed = recentlyPlayed
        self.playlistLibrary = playlistLibrary
        self.albumSongs = albumSongs
        self.loadAlbumSongs = loadAlbumSongs
        self.loadArtistDetail = loadArtistDetail
        self.canOpenCatalogArtist = canOpenCatalogArtist
        self.songByID = songByID
    }
}

extension EnvironmentValues {
    @Entry public var musicPickerSource: MusicPickerSource? = nil
}



@MainActor @Observable
public final class MusicPickerSession {
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

    public func resolvedSource(environment: MusicPickerSource?, makeFallback: () -> MusicPickerSource) -> MusicPickerSource {
        if let environment { return environment }
        if let cachedFallbackSource { return cachedFallbackSource }
        let created = makeFallback()
        cachedFallbackSource = created
        return created
    }

    public func prepareIfNeeded(using source: MusicPickerSource) {
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

    public func artist(id: String) -> LibraryArtistItem? { artistsByID[id] }
    public func album(id: String) -> LibraryShelfItem? { albumsByID[id] }

    public func registerAlbums(_ items: [LibraryShelfItem]) {
        for item in items where albumsByID[item.id] == nil {
            albumsByID[item.id] = item
        }
    }

    public func albums(for artist: LibraryArtistItem) -> [LibraryShelfItem] {
        let matchedAlbumIDs = Set(songs(for: artist).map(\.albumID))
        let filtered = sortedAlbums.filter { album in
            matchedAlbumIDs.contains(album.id) || album.subtitle == artist.name
        }
        return filtered.sorted { ($0.year ?? 0, $1.title) > ($1.year ?? 0, $0.title) }
    }

    public func songs(for artist: LibraryArtistItem) -> [LibrarySongItem] {
        allSongs.filter { song in
            song.artistReferences.contains { $0.id == artist.id }
                || song.albumArtist == artist.name
                || song.artist == artist.name
        }
    }

    public func cachedAlbumSongs(id: String) -> [LibrarySongItem]? { albumSongsCache[id] }
    public func storeAlbumSongs(_ tracks: [LibrarySongItem], for id: String) { albumSongsCache[id] = tracks }

    public func catalogArtist(id: String) -> ArtistDetail? { artistCatalogCache[id] }
    public func storeCatalogArtist(_ detail: ArtistDetail, for id: String) {
        artistCatalogCache[id] = detail
        var extra = detail.albums + detail.singles
        if let latest = detail.latest { extra.append(latest) }
        registerAlbums(extra)
    }
}


public enum MusicPickerRoute: Hashable, Sendable {
    case artists, albums, songs, playlists, downloaded, recent
    case artist(id: String, name: String)
    case artistCatalog(id: String, name: String)
    case artistCatalogSection(id: String, name: String, section: ArtistSection)
    case album(id: String, title: String, subtitle: String?)
    case playlist(id: String, title: String)
    case playlistFolder(id: String, title: String)

    public static let categories: [Self] = [.artists, .albums, .songs, .playlists, .downloaded, .recent]

    public var navigationTitle: String {
        switch self {
        case .artists: pageText("艺人")
        case .albums: pageText("专辑")
        case .songs: pageText("歌曲")
        case .playlists: pageText("播放列表")
        case .downloaded: pageText("已下载")
        case .recent: pageText("最近添加")
        case .artist(_, let name), .artistCatalog(_, let name): name
        case .artistCatalogSection(_, _, let section): section.title
        case .playlistFolder(_, let title): title
        case .album, .playlist: ""
        }
    }

    public var categoryTitle: String {
        switch self {
        case .artists: pageText("艺人")
        case .albums: pageText("专辑")
        case .songs: pageText("歌曲")
        case .playlists: pageText("播放列表")
        case .downloaded: pageText("已下载")
        case .recent: pageText("最近添加")
        default: navigationTitle
        }
    }

    public var categoryImage: String {
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

