import Foundation

enum OnlineSongProjector {
    struct DownloadedFields {
        let record: NeteaseDownloadRecord
        let localSong: LibrarySongItem?
        let unavailabilityReason: String?
    }

    static func makeSong(_ value: NeteaseMusicSong,
                         id: String,
                         artwork: Artwork,
                         artworkURL: URL?,
                         isFavorite: Bool,
                         favoriteAddedAt: Date?,
                         downloaded: DownloadedFields? = nil) -> LibrarySongItem {
        let metadata = downloaded?.record.metadata
        let local = downloaded?.localSong
        return LibrarySongItem(
            id: id,
            title: value.title,
            artist: value.artist,
            album: value.album,
            albumArtist: metadata?.albumArtist ?? value.artist,
            trackNumber: metadata?.trackNumber ?? value.trackNumber ?? 0,
            artwork: artwork,
            albumDirectory: downloaded.map { ($0.record.relativePath as NSString).deletingLastPathComponent },
            discNumber: metadata?.discNumber ?? value.discNumber ?? 1,
            artworkData: local?.artworkData,
            artworkURL: artworkURL,
            artworkBackdrop: local?.artworkBackdrop,
            duration: Int(value.duration),
            isPinned: local?.isPinned ?? false,
            addedOrder: local?.addedOrder ?? 0,
            isFavorite: isFavorite,
            favoriteAddedAt: favoriteAddedAt,
            unavailabilityReason: downloaded == nil ? (value.unavailable ? "暂无完整音源" : nil) : downloaded?.unavailabilityReason,
            onlineAlbumID: value.albumID,
            artistReferences: (value.artists ?? []).map {
                .init(id: CatalogRouteIdentity.artistID($0.id), name: $0.name)
            },
            year: metadata?.year ?? local?.year
        )
    }

    @concurrent static func groupArtworkInBackground(_ songs: [NeteaseMusicSong]) async throws -> (byURL: [URL: [NeteaseMusicSong]], uniqueURLs: [URL]) {
        try groupByArtworkURL(songs, checkCancellation: { try Task.checkCancellation() })
    }

    nonisolated static func groupByArtworkURL(_ songs: some Sequence<NeteaseMusicSong>) -> (byURL: [URL: [NeteaseMusicSong]], uniqueURLs: [URL]) {
        groupByArtworkURL(songs, checkCancellation: {})
    }

    nonisolated private static func groupByArtworkURL(_ songs: some Sequence<NeteaseMusicSong>,
                                              checkCancellation: () throws -> Void) rethrows -> (byURL: [URL: [NeteaseMusicSong]], uniqueURLs: [URL]) {
        var byURL: [URL: [NeteaseMusicSong]] = [:]
        var uniqueURLs: Set<URL> = []
        for song in songs {
            try checkCancellation()
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
