import FrontAM
import SwiftUI

@MainActor @Observable
final class ShowcasePlayback: PlayerPlaybackSource, FrontAMTrackPlayback {
    private struct Entry: Identifiable {
        let id = UUID()
        let track: PlayerTrack
    }

    private var queue: [Entry] = []
    private(set) var currentQueueIndex = 0
    private(set) var playbackGeneration: UInt64 = 0
    private var queueRevision: UInt64 = 0
    private(set) var timelineAnchor: PlayerTimelineAnchor = .zero
    private(set) var playbackHistory: [PlayerHistoryEntry] = []
    private(set) var playbackSourceTitle: String?
    private var sourceOrder: [UUID] = []
    private(set) var isShuffled = false
    private(set) var repeatMode: PlayerRepeatMode = .off
    private(set) var isCrossfadeEnabled = false

    var tracks: [PlayerTrack] { queue.map(\.track) }
    var currentTrack: PlayerTrack? { queue.indices.contains(currentQueueIndex) ? queue[currentQueueIndex].track : nil }
    var currentSongID: String? { currentTrack?.id }
    var isLoading: Bool { false }
    var issue: String? { nil }
    var duration: Double { currentTrack?.duration ?? 0 }
    var progress: Double { timelineAnchor.elapsed() }
    var playbackSpectrum: (any FrontAMSpectrumSource)? { nil }
    func spectrumLevels() -> [Float] { [] }

    var isPlaying: Bool {
        get { timelineAnchor.rate > 0 }
        set {
            guard currentTrack != nil, newValue != isPlaying else { return }
            updateTime(newValue && progress >= duration ? 0 : progress, playing: newValue)
        }
    }

    var previousInOrder: PlayerAdjacentTrack? { adjacent(at: currentQueueIndex - 1) }
    var nextInOrder: PlayerAdjacentTrack? {
        adjacent(at: currentQueueIndex + 1) ?? (repeatMode == .all ? adjacent(at: 0) : nil)
    }
    var canPlayNext: Bool { nextInOrder != nil }
    var canPlayPrevious: Bool { currentTrack != nil }
    var canAutomaticallyContinue: Bool { false }
    var isAutomaticContinuationEnabled: Bool { false }
    var automaticContinuationDescription: String { "" }
    var upcoming: [PlayerAdjacentTrack] {
        queue.indices.dropFirst(currentQueueIndex + 1).map { .init(index: $0, track: queue[$0].track) }
    }
    var upcomingQueueVersion: PlayerQueueVersion {
        .init(revision: queueRevision, index: currentQueueIndex, repeatMode: repeatMode)
    }
    var upcomingQueueEntries: [PlayerQueueEntry] {
        upcoming.map { .init(id: queue[$0.index].id, queueIndex: $0.index, song: $0.track) }
    }

    func play(_ tracks: [PlayerTrack], at index: Int = 0, source: String?, shuffled: Bool = false) {
        guard tracks.indices.contains(index) else { return }
        let entries = tracks.map { Entry(track: $0) }
        sourceOrder = entries.map(\.id)
        queue = shuffled ? entries.shuffled() : entries
        isShuffled = shuffled
        playbackSourceTitle = source
        queueRevision &+= 1
        start(at: shuffled ? 0 : index)
    }

    func togglePlayback() { isPlaying.toggle() }
    func seek(to value: Double) { updateTime(min(max(0, value), duration), playing: isPlaying) }
    func next() { if let nextInOrder { start(at: nextInOrder.index) } }

    func previous() {
        if progress > 3 || previousInOrder == nil { seek(to: 0) }
        else if let previousInOrder { start(at: previousInOrder.index) }
    }

    func skip(toQueueIndex index: Int) { start(at: index) }
    func playFromQueue(at index: Int) { start(at: index) }

    func playFromHistory(_ eventID: UUID) {
        guard let entry = playbackHistory.first(where: { $0.id == eventID }) else { return }
        if let index = queue.firstIndex(where: { $0.track.id == entry.song.id }) { start(at: index) }
        else { play([entry.song], source: entry.song.albumTitle) }
    }

    func clearPlaybackHistory() { playbackHistory.removeAll() }

    func enqueue(_ track: PlayerTrack, next: Bool) {
        guard currentTrack != nil else { play([track], source: track.albumTitle); return }
        let entry = Entry(track: track)
        queue.insert(entry, at: next ? currentQueueIndex + 1 : queue.count)
        if next, let currentIndex = sourceOrder.firstIndex(of: queue[currentQueueIndex].id) {
            sourceOrder.insert(entry.id, at: currentIndex + 1)
        } else {
            sourceOrder.append(entry.id)
        }
        queueRevision &+= 1
    }

    func toggleShuffle() {
        guard queue.indices.contains(currentQueueIndex) else { return }
        let firstUpcoming = currentQueueIndex + 1
        let tail = queue[firstUpcoming...]
        if isShuffled {
            let positions = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($1, $0) })
            queue.replaceSubrange(firstUpcoming..., with: tail.sorted { positions[$0.id, default: 0] < positions[$1.id, default: 0] })
        } else {
            queue.replaceSubrange(firstUpcoming..., with: tail.shuffled())
        }
        isShuffled.toggle()
        queueRevision &+= 1
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    func toggleCrossfade() { isCrossfadeEnabled.toggle() }
    func toggleAutomaticContinuation() {}

    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let firstUpcoming = currentQueueIndex + 1
        guard currentTrack != nil else { return }
        var tail = Array(queue[firstUpcoming...])
        guard source.allSatisfy(tail.indices.contains), (0...tail.count).contains(destination) else { return }
        tail.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(firstUpcoming..., with: tail)
        if !isShuffled { sourceOrder = queue.map(\.id) }
        queueRevision &+= 1
    }

    func removeFromQueue(at index: Int) {
        guard index > currentQueueIndex, queue.indices.contains(index) else { return }
        let entry = queue.remove(at: index)
        sourceOrder.removeAll { $0 == entry.id }
        queueRevision &+= 1
    }

    func clearQueue() {
        queue.removeAll()
        sourceOrder.removeAll()
        currentQueueIndex = 0
        playbackSourceTitle = nil
        queueRevision &+= 1
        playbackGeneration &+= 1
        timelineAnchor = .zero
    }

    func advanceWhenFinished(anchor: PlayerTimelineAnchor) async {
        guard anchor.rate > 0 else { return }
        do { try await Task.sleep(for: .seconds(max(0, anchor.duration - anchor.elapsed()))) }
        catch { return }
        guard !Task.isCancelled, timelineAnchor == anchor else { return }
        if repeatMode == .one { start(at: currentQueueIndex) }
        else if let nextInOrder { start(at: nextInOrder.index) }
        else { updateTime(duration, playing: false) }
    }

    private func adjacent(at index: Int) -> PlayerAdjacentTrack? {
        guard queue.indices.contains(index) else { return nil }
        return .init(index: index, track: queue[index].track)
    }

    private func start(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentQueueIndex = index
        playbackGeneration &+= 1
        playbackHistory.append(.init(id: UUID(), song: queue[index].track))
        if playbackHistory.count > 30 { playbackHistory.removeFirst() }
        updateTime(0, playing: true)
    }

    private func updateTime(_ time: Double, playing: Bool) {
        timelineAnchor = .init(baseElapsed: time, rate: playing ? 1 : 0, duration: duration)
    }
}
