import Foundation

enum OnlineSongProjector {
    static func makeSong(_ value: NeteaseMusicSong,
                         id: String,
                         artwork: Artwork,
                         artworkURL: URL?,
                         isFavorite: Bool,
                         favoriteAddedAt: Date?) -> LibrarySongItem {
        LibrarySongItem(
            id: id,
            title: value.title,
            artist: value.artist,
            album: value.album,
            albumArtist: value.artist,
            trackNumber: value.trackNumber ?? 0,
            artwork: artwork,
            discNumber: value.discNumber ?? 1,
            artworkURL: artworkURL,
            duration: Int(value.duration),
            isFavorite: isFavorite,
            favoriteAddedAt: favoriteAddedAt,
            unavailabilityReason: value.unavailable ? "暂无完整音源" : nil,
            onlineAlbumID: value.albumID,
            artistReferences: (value.artists ?? []).map {
                .init(id: CatalogRouteIdentity.artistID($0.id), name: $0.name)
            }
        )
    }

    static func groupByArtworkURL(_ songs: some Sequence<NeteaseMusicSong>) -> (byURL: [URL: [NeteaseMusicSong]], uniqueURLs: [URL]) {
        var byURL: [URL: [NeteaseMusicSong]] = [:]
        var uniqueURLs: Set<URL> = []
        for song in songs {
            guard let url = song.artworkURL else { continue }
            byURL[url, default: []].append(song)
            uniqueURLs.insert(url)
        }
        return (byURL, Array(uniqueURLs))
    }
}

@MainActor
final class OnlineSongProjectionCache {
    struct Entry {
        let owner: String?
        let revision: UUID?
        let source: NeteaseMusicSong
        let isFavorite: Bool
        let favoriteAddedAt: Date?
        let cachedArtworkURL: URL?
        let item: LibrarySongItem
    }

    private(set) var entries: [Int64: Entry] = [:]

    var keys: Dictionary<Int64, Entry>.Keys { entries.keys }
    var count: Int { entries.count }

    subscript(songID: Int64) -> Entry? {
        get { entries[songID] }
        set { entries[songID] = newValue }
    }

    func removeAll() {
        entries = [:]
    }

    func removeValue(forKey key: Int64) {
        entries.removeValue(forKey: key)
    }

    func prune(keeping liveIDs: Set<Int64>) {
        guard entries.count > liveIDs.count else { return }
        for key in entries.keys where !liveIDs.contains(key) {
            entries.removeValue(forKey: key)
        }
    }

    func project(_ value: NeteaseMusicSong,
                 owner: String?,
                 revision: UUID?,
                 isFavorite: Bool,
                 favoriteAddedAt: Date?,
                 cachedArtworkURL: URL?,
                 build: () -> LibrarySongItem) -> LibrarySongItem {
        if let entry = entries[value.id],
           entry.owner == owner,
           entry.revision == revision,
           entry.source == value,
           entry.isFavorite == isFavorite,
           entry.favoriteAddedAt == favoriteAddedAt,
           entry.cachedArtworkURL == cachedArtworkURL {
            return entry.item
        }
        let item = build()
        entries[value.id] = Entry(
            owner: owner,
            revision: revision,
            source: value,
            isFavorite: isFavorite,
            favoriteAddedAt: favoriteAddedAt,
            cachedArtworkURL: cachedArtworkURL,
            item: item
        )
        return item
    }
}
