import Foundation

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

actor PlaybackQueuePersistence {
    private struct Progress: Codable {
        let snapshotID: UUID
        let entryID: UUID
        let index: Int
        let elapsed: Double
    }

    private struct SnapshotKey: Equatable {
        let url: URL
        let contentID: UUID
        let repeatMode: NowPlayingModel.RepeatMode
        let shuffled: Bool
        let source: String?
        let crossfade: Bool?
        let continuation: PlaybackQueueContinuation?
        let recommendations: Set<UUID>?
        let hasBatch: Bool?
    }

    private var written: (key: SnapshotKey, id: UUID)?

    nonisolated static func load(from url: URL) throws -> NowPlayingModel.SavedQueue? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        var state = try decoder.decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        if let id = state.snapshotID, let entries = state.entryIDs,
           let data = try? Data(contentsOf: url.appendingPathExtension("progress")),
           let progress = try? decoder.decode(Progress.self, from: data),
           progress.snapshotID == id, entries.indices.contains(progress.index),
           entries[progress.index] == progress.entryID,
           progress.elapsed.isFinite, progress.elapsed >= 0 {
            state.index = progress.index
            state.elapsed = progress.elapsed
        }
        return state
    }

    func save(_ state: NowPlayingModel.SavedQueue, contentID: UUID, to url: URL) throws {
        let key = SnapshotKey(url: url, contentID: contentID, repeatMode: state.repeatMode,
                              shuffled: state.shuffled, source: state.source, crossfade: state.crossfadeEnabled,
                              continuation: state.continuation, recommendations: state.recommendedEntries,
                              hasBatch: state.hasRecommendationBatch)
        if let written, written.key == key, let entries = state.entryIDs, entries.indices.contains(state.index) {
            let progress = Progress(snapshotID: written.id, entryID: entries[state.index], index: state.index, elapsed: state.elapsed)
            try JSONEncoder().encode(progress).write(to: url.appendingPathExtension("progress"), options: .atomic)
            return
        }

        let snapshotID = UUID()
        var snapshot = state
        snapshot.snapshotID = snapshotID
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        written = (key, snapshotID)
    }
}
