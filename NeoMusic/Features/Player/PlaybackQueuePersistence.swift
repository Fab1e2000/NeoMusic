import Foundation

/// Display metadata can restore independently of a catalog or a temporary playback resource.
struct PlaybackSongSnapshot: Codable, Sendable {
    struct Artist: Codable, Sendable {
        let id: String
        let name: String
    }
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int
    let albumDirectory: String?
    let discNumber: Int
    let duration: Int
    let addedOrder: Int
    let isFavorite: Bool
    let favoriteAddedAt: Date?
    let isPinned: Bool
    let unavailabilityReason: String?
    let artworkURL: URL?
    let artworkBackdrop: AlbumArtworkBackdrop?
    let onlineAlbumID: Int64?
    let artistReferences: [Artist]

    var onlineOwnerID: String? {
        let parts = id.split(separator: ":")
        return parts.count == 3 && parts[0] == "netease" ? String(parts[1]) : nil
    }

    @MainActor init(_ song: LibrarySongItem) {
        id = song.id; title = song.title; artist = song.artist; album = song.album
        albumArtist = song.albumArtist; trackNumber = song.trackNumber
        albumDirectory = song.albumDirectory; discNumber = song.discNumber
        duration = song.duration; addedOrder = song.addedOrder
        isFavorite = song.isFavorite; favoriteAddedAt = song.favoriteAddedAt; isPinned = song.isPinned
        unavailabilityReason = song.unavailabilityReason
        let cover: URL?
        if case .file(let url) = song.artwork { cover = url }
        else { cover = song.artworkURL }
        artworkURL = cover?.isFileURL == true ? cover : nil
        artworkBackdrop = song.artworkBackdrop
        onlineAlbumID = song.onlineAlbumID
        artistReferences = song.artistReferences.map { Artist(id: $0.id, name: $0.name) }
    }

    @MainActor var song: LibrarySongItem {
        // A snapshot never supplies a remote image URL to the playback resource path.
        let cover = artworkURL.flatMap { $0.isFileURL ? $0 : nil }
        return LibrarySongItem(id: id, title: title, artist: artist, album: album, albumArtist: albumArtist,
            trackNumber: trackNumber, artwork: cover.map(Artwork.file) ?? .missing,
            albumDirectory: albumDirectory, discNumber: discNumber, artworkURL: cover,
            artworkBackdrop: artworkBackdrop, duration: duration, isPinned: isPinned,
            addedOrder: addedOrder, isFavorite: isFavorite, favoriteAddedAt: favoriteAddedAt,
            unavailabilityReason: unavailabilityReason, onlineAlbumID: onlineAlbumID,
            artistReferences: artistReferences.map { LibraryArtistReference(id: $0.id, name: $0.name) })
    }
}

/// Serial disk access keeps encoding and atomic replacement off the UI actor.
actor PlaybackQueuePersistence {
    func save(_ state: NowPlayingModel.SavedQueue, to url: URL) throws {
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
