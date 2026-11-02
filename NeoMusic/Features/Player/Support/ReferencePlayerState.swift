import Foundation
import Observation
import UIKit

struct ReferenceTrack: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: String
    let albumTitle: String
    let coverURL: URL?
    let duration: TimeInterval
}

struct ReferenceUpcomingTrack: Identifiable {
    let index: Int
    let track: ReferenceTrack
    var id: Int { index }
}

/// Presentation adapter for the live player. Queue and transport state have one owner.
@MainActor @Observable final class ReferencePlayerState {
    enum RepeatMode { case off, all, one
        var systemImage: String { self == .one ? "repeat.1" : "repeat" }
        var accessibilityTitle: String { switch self { case .off: "循环关闭"; case .all: "列表循环"; case .one: "单曲循环" } }
    }
    private let model: NowPlayingModel
    var tracks: [ReferenceTrack] { model.queue.map(Self.convert) }
    var isPlaying: Bool {
        get { model.isPlaying }
        set { if model.isPlaying != newValue { model.togglePlayback() } }
    }
    var isLoading: Bool { model.isLoading }
    var issue: String? { model.errorMessage }
    var isCrossfadeEnabled: Bool { model.isCrossfadeEnabled }
    let isPreview = false
    let isDiscovery = false
    let canAutomaticallyContinue = false
    let isAutomaticContinuationEnabled = false
    var automaticContinuationDescription: String { "接下来播放的歌曲" }
    var currentQueueIndex: Int { model.currentIndex }
    var currentTrack: ReferenceTrack? { item(at: currentQueueIndex)?.track }
    var duration: Double { model.duration }
    var progress: Double { model.elapsed }
    var isShuffled: Bool { model.isShuffled }
    var repeatMode: RepeatMode { switch model.repeatMode { case .off: .off; case .all: .all; case .one: .one } }
    var queueModeBadgeSystemImage: String? { isShuffled ? "shuffle" : repeatMode == .off ? nil : repeatMode.systemImage }
    var canPlayNext: Bool { nextInOrder != nil }
    var canPlayPrevious: Bool { previousInOrder != nil }
    private var count: Int { model.queue.count }
    var previousInOrder: ReferenceUpcomingTrack? { item(at: currentQueueIndex > 0 ? currentQueueIndex - 1 : repeatMode == .all ? count - 1 : -1) }
    var nextInOrder: ReferenceUpcomingTrack? { item(at: currentQueueIndex + 1 < count ? currentQueueIndex + 1 : repeatMode == .all ? 0 : -1) }
    var adjacentArtworkURLs: [URL] {
        let urls = [previousInOrder?.track.coverURL, nextInOrder?.track.coverURL].compactMap { $0 }
        return urls.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var upcoming: [ReferenceUpcomingTrack] {
        guard count > 0 else { return [] }
        let indices = Array((currentQueueIndex + 1)..<count) + (repeatMode == .all ? Array(0..<currentQueueIndex) : [])
        return indices.compactMap(item(at:))
    }

    init(model: NowPlayingModel) { self.model = model }
    private func item(at index: Int) -> ReferenceUpcomingTrack? {
        guard model.queue.indices.contains(index) else { return nil }
        return .init(index: index, track: Self.convert(model.queue[index]))
    }
    func togglePlayback() { guard currentTrack != nil else { return }; isPlaying.toggle() }
    func seek(to value: Double) { guard value.isFinite else { return }; model.elapsed = min(duration, max(0, value)) }
    func next() { if let nextInOrder { skip(toQueueIndex: nextInOrder.index) } }
    func previous() { if progress > 3 { seek(to: 0) } else if let previousInOrder { skip(toQueueIndex: previousInOrder.index) } }
    func skip(toQueueIndex index: Int) { model.select(index) }
    func playFromQueue(at index: Int) { skip(toQueueIndex: index); isPlaying = currentTrack != nil }
    func enqueue(_ track: ReferenceTrack, next: Bool) {
        guard let song = model.queue.first(where: { $0.id == track.id }) else { return }
        if next { model.insertNext([song]) } else { model.appendLater([song]) }
    }
    func toggleShuffle() { model.isShuffled.toggle() }
    func cycleRepeatMode() { model.cycleRepeat() }
    func toggleCrossfade() { model.toggleCrossfade() }
    func toggleAutomaticContinuation() { }
    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        model.reorderUpcoming(indices: upcoming.map(\.index), fromOffsets: source, toOffset: destination)
    }
    func removeFromQueue(at index: Int) {
        model.removeQueueEntry(at: index)
    }
    private static var coverCache: [String: (Data, URL)] = [:]
    private static func convert(_ song: LibrarySongItem) -> ReferenceTrack {
        var url: URL?
        if let data = song.artworkData {
            if let cached = coverCache[song.id], cached.0 == data { url = cached.1 }
            else {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("neomusic-cover-" + UUID().uuidString)
                if (try? data.write(to: file, options: .atomic)) != nil { coverCache[song.id] = (data, file); url = file }
            }
        }
        return .init(id: song.id, title: song.title, artists: song.artist, albumTitle: song.album, coverURL: url, duration: Double(song.duration))
    }
}
