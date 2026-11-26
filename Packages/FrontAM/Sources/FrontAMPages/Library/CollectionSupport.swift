import FrontAMCore
import SwiftUI

public enum DetailSort: String, CaseIterable, Identifiable, Sendable {
    case order = "播放列表顺序", title = "标题", artist = "艺人", album = "专辑"
    public var id: Self { self }
}

public struct TrackFilterProjectionInput: Equatable {
    public let tracks: [LibrarySongItem]
    public let query: String
    public let sort: DetailSort
    public var followsPlaylistOrder: Bool { query.isEmpty && sort == .order }

    public init(tracks: [LibrarySongItem], query: String, sort: DetailSort = .order) {
        self.tracks = tracks
        self.query = query
        self.sort = sort
    }

    public func calculate() -> TrackFilterProjectionResult {
        TrackFilterProjection.calculateSync(self)
    }
}

public struct TrackFilterProjectionResult {
    public let tracks: [LibrarySongItem]
    public let totalDuration: Int

    public static var empty: Self { Self(tracks: [], totalDuration: 0) }
}

public enum TrackFilterProjection {
    public static let fastPathThreshold = 120

    private struct Entry: Sendable {
        let index: Int
        let title: String
        let artist: String
        let album: String
        let duration: Int
    }

    private struct IndexedResult: Sendable {
        let indices: [Int]
        let totalDuration: Int
    }

    public static func fastPath(_ input: TrackFilterProjectionInput) -> TrackFilterProjectionResult? {
        if input.followsPlaylistOrder {
            return TrackFilterProjectionResult(
                tracks: input.tracks,
                totalDuration: input.tracks.reduce(0) { $0 + $1.duration }
            )
        }
        guard input.tracks.count <= fastPathThreshold else { return nil }
        return calculateSync(input)
    }

    public static func calculateSync(_ input: TrackFilterProjectionInput) -> TrackFilterProjectionResult {
        let filtered = input.query.isEmpty ? input.tracks : input.tracks.filter {
            $0.title.localizedStandardContains(input.query)
                || $0.artist.localizedStandardContains(input.query)
                || $0.album.localizedStandardContains(input.query)
        }
        let ordered: [LibrarySongItem]
        switch input.sort {
        case .order: ordered = filtered
        case .title: ordered = filtered.sorted(byName: \.title)
        case .artist: ordered = filtered.sorted(byName: \.artist)
        case .album: ordered = filtered.sorted(byName: \.album)
        }
        return TrackFilterProjectionResult(
            tracks: ordered,
            totalDuration: input.tracks.reduce(0) { $0 + $1.duration }
        )
    }

    @MainActor
    public static func update(
        _ projection: AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>,
        for input: TrackFilterProjectionInput
    ) async {
        guard !input.followsPlaylistOrder, input.tracks.count > fastPathThreshold else { return }
        await projection.computeIfNeeded(for: input) { await result(for: input) }
    }

    @MainActor
    public static func result(for input: TrackFilterProjectionInput) async -> TrackFilterProjectionResult? {
        guard !Task.isCancelled else { return nil }
        if let immediate = fastPath(input) { return immediate }

        let entries = input.tracks.enumerated().map { index, track in
            Entry(index: index, title: track.title, artist: track.artist,
                  album: track.album, duration: track.duration)
        }
        guard let result = await computeIndices(entries: entries, query: input.query, sort: input.sort),
              !Task.isCancelled else { return nil }
        return TrackFilterProjectionResult(
            tracks: result.indices.map { input.tracks[$0] },
            totalDuration: result.totalDuration
        )
    }

    @concurrent
    private static func computeIndices(
        entries: [Entry],
        query: String,
        sort: DetailSort
    ) async -> IndexedResult? {
        var filtered: [Entry] = []
        var totalDuration = 0
        for entry in entries {
            guard !Task.isCancelled else { return nil }
            totalDuration += entry.duration
            if query.isEmpty || entry.title.localizedStandardContains(query)
                || entry.artist.localizedStandardContains(query) || entry.album.localizedStandardContains(query) {
                filtered.append(entry)
            }
        }
        let ordered: [Entry]
        switch sort {
        case .order: ordered = filtered
        case .title: ordered = filtered.sorted(byName: \.title)
        case .artist: ordered = filtered.sorted(byName: \.artist)
        case .album: ordered = filtered.sorted(byName: \.album)
        }
        guard !Task.isCancelled else { return nil }
        return IndexedResult(indices: ordered.map(\.index), totalDuration: totalDuration)
    }
}

@MainActor public enum CollectionBackdropResolver {
    public static func resolve(artwork: Artwork, loadArtwork: ArtworkLoadAction) async -> AlbumArtworkBackdrop? {
        if let cached = loadArtwork.provider.cachedBackdrop(for: artwork) { return cached }
        switch artwork {
        case .file(let url):
            return await loadArtwork.provider.loadBackdrop(for: url)
        case .deferred(let id, _):
            if let resolved = loadArtwork.provider.resolvedURL(for: id) {
                return await loadArtwork.provider.loadBackdrop(for: resolved)
            }
            guard let url = await loadArtwork.resolve?(id), !Task.isCancelled else { return nil }
            loadArtwork.provider.registerResolvedArtwork(id, url: url)
            return await loadArtwork.provider.loadBackdrop(for: url)
        case .image(let image):
            let renderer = ImageRenderer(content: image.resizable().scaledToFill().frame(width: 128, height: 128).clipped())
            guard let cgImage = renderer.cgImage else { return nil }
            return await Task.detached(priority: .utility) {
                AlbumArtworkBackdrop.extract(from: cgImage)
            }.value
        default:
            return nil
        }
    }
}
