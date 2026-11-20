import SwiftUI

enum DetailSort: String, CaseIterable, Identifiable, Sendable {
    case order = "播放列表顺序", title = "标题", artist = "艺人", album = "专辑"
    var id: Self { self }
}

/// 专辑与歌单详情页共享的异步曲目过滤/排序投影与时长聚合。
struct TrackFilterProjectionInput: Equatable {
    let tracks: [LibrarySongItem]
    let query: String
    let sort: DetailSort

    init(tracks: [LibrarySongItem], query: String, sort: DetailSort = .order) {
        self.tracks = tracks
        self.query = query
        self.sort = sort
    }

    func calculate() -> TrackFilterProjectionResult {
        TrackFilterProjection.calculateSync(self)
    }
}

struct TrackFilterProjectionResult {
    let tracks: [LibrarySongItem]
    let totalDuration: Int

    static var empty: Self { Self(tracks: [], totalDuration: 0) }
}

enum TrackFilterProjection {
    static let fastPathThreshold = 120

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

    static func fastPath(_ input: TrackFilterProjectionInput) -> TrackFilterProjectionResult? {
        if input.query.isEmpty && input.sort == .order {
            return TrackFilterProjectionResult(
                tracks: input.tracks,
                totalDuration: input.tracks.reduce(0) { $0 + $1.duration }
            )
        }
        guard input.tracks.count <= fastPathThreshold else { return nil }
        return calculateSync(input)
    }

    static func calculateSync(_ input: TrackFilterProjectionInput) -> TrackFilterProjectionResult {
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
    static func update(
        _ projection: AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>,
        for input: TrackFilterProjectionInput
    ) async {
        guard fastPath(input) == nil else { return }
        let entries = input.tracks.enumerated().map { index, track in
            Entry(index: index, title: track.title, artist: track.artist,
                  album: track.album, duration: track.duration)
        }
        let currentQuery = input.query
        let currentSort = input.sort
        await projection.computeIfNeeded(
            for: input,
            fastPath: fastPath,
            background: { computeIndices(entries: entries, query: currentQuery, sort: currentSort) },
            finish: { result in
                TrackFilterProjectionResult(
                    tracks: result.indices.map { input.tracks[$0] },
                    totalDuration: result.totalDuration
                )
            }
        )
    }

    private nonisolated static func computeIndices(
        entries: [Entry],
        query: String,
        sort: DetailSort
    ) -> IndexedResult {
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query)
        }
        let ordered: [Entry]
        switch sort {
        case .order: ordered = filtered
        case .title: ordered = filtered.sorted(byName: \.title)
        case .artist: ordered = filtered.sorted(byName: \.artist)
        case .album: ordered = filtered.sorted(byName: \.album)
        }
        return IndexedResult(
            indices: ordered.map(\.index),
            totalDuration: entries.reduce(0) { $0 + $1.duration }
        )
    }
}

/// 统一通过共享缓存提取详情页封面背景色，避免无缓存重算与主线程 PNG 编码。
@MainActor enum CollectionBackdropResolver {
    static func resolve(artwork: Artwork, loadArtwork: ArtworkLoadAction) async -> AlbumArtworkBackdrop? {
        if let cached = LocalArtworkImages.cachedBackdrop(for: artwork) { return cached }
        switch artwork {
        case .file(let url):
            return await LocalArtworkImages.loadBackdrop(for: url)
        case .deferred(let id, _):
            if let resolved = LocalArtworkImages.resolvedURL(for: id) {
                return await LocalArtworkImages.loadBackdrop(for: resolved)
            }
            guard let url = await loadArtwork.resolve?(id), !Task.isCancelled else { return nil }
            LocalArtworkImages.registerResolvedArtwork(id, url: url)
            return await LocalArtworkImages.loadBackdrop(for: url)
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
