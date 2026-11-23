import Foundation
import Observation

public struct PlayerTrack: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artists: String
    public let albumTitle: String
    public let coverURL: URL?
    public let duration: TimeInterval
    public var artworkLoadID: String?

    public init(id: String, title: String, artists: String, albumTitle: String,
                coverURL: URL?, duration: TimeInterval, artworkLoadID: String? = nil) {
        self.id = id; self.title = title; self.artists = artists; self.albumTitle = albumTitle
        self.coverURL = coverURL; self.duration = duration; self.artworkLoadID = artworkLoadID
    }
}

public struct PlayerAdjacentTrack: Identifiable {
    public let index: Int
    public let track: PlayerTrack
    public var id: Int { index }
    public init(index: Int, track: PlayerTrack) { self.index = index; self.track = track }
}

public enum PlayerRepeatMode: Sendable {
    case off, all, one
    var systemImage: String { self == .one ? "repeat.1" : "repeat" }
    var accessibilityTitle: String {
        switch self { case .off: "循环关闭"; case .all: "列表循环"; case .one: "单曲循环" }
    }
}

public struct PlayerQueueVersion: Equatable, Sendable {
    public let revision: UInt64
    public let index: Int
    public let repeatMode: PlayerRepeatMode
    public var queueContinues: Bool
    public init(revision: UInt64, index: Int, repeatMode: PlayerRepeatMode, queueContinues: Bool = false) {
        self.revision = revision; self.index = index; self.repeatMode = repeatMode
        self.queueContinues = queueContinues
    }
}

public struct PlayerQueueEntry: Identifiable, Sendable {
    public let id: UUID
    public let queueIndex: Int
    private let readSong: @MainActor @Sendable () -> PlayerTrack
    let artworkIdentity: ObjectIdentifier?
    @MainActor public var song: PlayerTrack { readSong() }
    public init(id: UUID, queueIndex: Int, song: PlayerTrack) {
        self.id = id; self.queueIndex = queueIndex; self.readSong = { song }; self.artworkIdentity = nil
    }
    public init(id: UUID, queueIndex: Int, artworkIdentity: ObjectIdentifier,
                song: @escaping @MainActor @Sendable () -> PlayerTrack) {
        self.id = id; self.queueIndex = queueIndex; self.artworkIdentity = artworkIdentity; self.readSong = song
    }
}

public struct PlayerHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    private let snapshot: PlayerTrack
    private let readSong: (@MainActor @Sendable () -> PlayerTrack)?
    let artworkIdentity: ObjectIdentifier?
    @MainActor public var song: PlayerTrack { readSong?() ?? snapshot }

    public init(id: UUID, song: PlayerTrack) {
        self.id = id
        self.snapshot = song
        self.readSong = nil
        self.artworkIdentity = nil
    }

    public init(id: UUID, artworkIdentity: ObjectIdentifier, song: PlayerTrack,
                liveSong: @escaping @MainActor @Sendable () -> PlayerTrack) {
        self.id = id
        self.snapshot = song
        self.readSong = liveSong
        self.artworkIdentity = artworkIdentity
    }

    public static func == (lhs: PlayerHistoryEntry, rhs: PlayerHistoryEntry) -> Bool {
        lhs.id == rhs.id && lhs.artworkIdentity == rhs.artworkIdentity && lhs.snapshot == rhs.snapshot
    }
}

public struct PlayerLyricLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: TimeInterval
    public let text: String
    public let translation: String
    public init(id: Int, time: TimeInterval, text: String, translation: String = "") {
        self.id = id
        self.time = time
        self.text = text
        self.translation = translation
    }
}

public struct PlayerLyrics: Equatable, Sendable {
    public var lines: [PlayerLyricLine]
    public var plainText: String
    public var source: String
    public init(lines: [PlayerLyricLine] = [], plainText: String = "", source: String = "") {
        self.lines = lines; self.plainText = plainText; self.source = source
    }
    public var isEmpty: Bool { lines.isEmpty && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isTimed: Bool { !lines.isEmpty }
    public var hasTranslation: Bool { lines.contains { !$0.translation.isEmpty } }
    public func activeLine(at time: TimeInterval) -> Int? { lines.last { $0.time <= time }?.id }
}

public struct PlayerTimelineAnchor: Equatable, Sendable {
    public let baseElapsed: Double
    public let hostTimestamp: TimeInterval
    public let rate: Double
    public let duration: Double

    public init(
        baseElapsed: Double,
        hostTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        rate: Double,
        duration: Double
    ) {
        self.baseElapsed = baseElapsed.isFinite ? max(0, baseElapsed) : 0
        self.hostTimestamp = hostTimestamp
        self.rate = rate.isFinite ? max(0, rate) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    public static let zero = PlayerTimelineAnchor(baseElapsed: 0, hostTimestamp: 0, rate: 0, duration: 0)

    public func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard rate > 0 else { return clamped(baseElapsed) }
        let delta = max(0, uptime - hostTimestamp)
        return clamped(baseElapsed + delta * rate)
    }

    private func clamped(_ value: Double) -> Double {
        let safe = value.isFinite ? max(0, value) : 0
        return duration > 0 ? min(safe, duration) : safe
    }
}

@MainActor public protocol PlayerPlaybackSource: AnyObject, Observable {
    var tracks: [PlayerTrack] { get }
    var currentTrack: PlayerTrack? { get }
    var currentQueueIndex: Int { get }
    var playbackGeneration: UInt64 { get }
    var isPlaying: Bool { get set }
    var isLoading: Bool { get }
    var issue: String? { get }
    var duration: Double { get }
    var progress: Double { get }
    var timelineAnchor: PlayerTimelineAnchor { get }
    var isCrossfadeEnabled: Bool { get }
    var isShuffled: Bool { get }
    var repeatMode: PlayerRepeatMode { get }
    var canPlayNext: Bool { get }
    var canPlayPrevious: Bool { get }
    var canAutomaticallyContinue: Bool { get }
    var isAutomaticContinuationEnabled: Bool { get }
    var automaticContinuationDescription: String { get }
    var previousInOrder: PlayerAdjacentTrack? { get }
    var nextInOrder: PlayerAdjacentTrack? { get }
    var upcoming: [PlayerAdjacentTrack] { get }
    var upcomingQueueVersion: PlayerQueueVersion { get }
    var upcomingQueueEntries: [PlayerQueueEntry] { get }
    var playbackHistory: [PlayerHistoryEntry] { get }
    func togglePlayback()
    func seek(to value: Double)
    func next()
    func previous()
    func skip(toQueueIndex index: Int)
    func playFromQueue(at index: Int)
    func playFromHistory(_ eventID: UUID)
    func clearPlaybackHistory()
    func enqueue(_ track: PlayerTrack, next: Bool)
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleCrossfade()
    func toggleAutomaticContinuation()
    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int)
    func removeFromQueue(at index: Int)
}

public extension PlayerPlaybackSource {
    var playbackGeneration: UInt64 { 0 }
    var playbackHistory: [PlayerHistoryEntry] { [] }
    func playFromHistory(_ eventID: UUID) {}
    func clearPlaybackHistory() {}
    var timelineAnchor: PlayerTimelineAnchor {
        PlayerTimelineAnchor(baseElapsed: progress, rate: 0, duration: duration)
    }
}

@MainActor @Observable public final class PlayerState {
    private let source: any PlayerPlaybackSource
    public init(source: any PlayerPlaybackSource) { self.source = source }
    public var isPlaying: Bool {
        get { source.isPlaying }
        set { source.isPlaying = newValue }
    }
    var queueModeBadgeSystemImage: String? { isShuffled ? "shuffle" : repeatMode == .off ? nil : repeatMode.systemImage }
    public var adjacentArtworkURLs: [URL] {
        [previousInOrder?.track.coverURL, nextInOrder?.track.coverURL].compactMap { $0 }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    public var tracks: [PlayerTrack] { source.tracks }
    public var currentTrack: PlayerTrack? { source.currentTrack }
    public var currentQueueIndex: Int { source.currentQueueIndex }
    public var playbackGeneration: UInt64 { source.playbackGeneration }
    public var currentTrackTransitionKey: String {
        "\(currentTrack?.id ?? ""):\(currentQueueIndex):\(playbackGeneration)"
    }
    public var isLoading: Bool { source.isLoading }
    public var issue: String? { source.issue }
    public var duration: Double { source.duration }
    public var progress: Double { source.progress }
    public var timelineAnchor: PlayerTimelineAnchor { source.timelineAnchor }
    public var isCrossfadeEnabled: Bool { source.isCrossfadeEnabled }
    public var isShuffled: Bool { source.isShuffled }
    public var repeatMode: PlayerRepeatMode { source.repeatMode }
    public var canPlayNext: Bool { source.canPlayNext }
    public var canPlayPrevious: Bool { source.canPlayPrevious }
    public var canAutomaticallyContinue: Bool { source.canAutomaticallyContinue }
    public var isAutomaticContinuationEnabled: Bool { source.isAutomaticContinuationEnabled }
    public var automaticContinuationDescription: String { source.automaticContinuationDescription }
    public var previousInOrder: PlayerAdjacentTrack? { source.previousInOrder }
    public var nextInOrder: PlayerAdjacentTrack? { source.nextInOrder }
    public var upcoming: [PlayerAdjacentTrack] { source.upcoming }
    public var upcomingQueueVersion: PlayerQueueVersion { source.upcomingQueueVersion }
    public var upcomingQueueEntries: [PlayerQueueEntry] { source.upcomingQueueEntries }
    public var playbackHistory: [PlayerHistoryEntry] { source.playbackHistory }
    public func togglePlayback() { self.source.togglePlayback() }
    public func seek(to value: Double) { self.source.seek(to: value) }
    public func next() { self.source.next() }
    public func previous() { self.source.previous() }
    public func skip(toQueueIndex index: Int) { self.source.skip(toQueueIndex: index) }
    public func playFromQueue(at index: Int) { self.source.playFromQueue(at: index) }
    public func playFromHistory(_ eventID: UUID) { source.playFromHistory(eventID) }
    public func clearPlaybackHistory() { source.clearPlaybackHistory() }
    public func enqueue(_ track: PlayerTrack, next: Bool) { self.source.enqueue(track, next: next) }
    public func toggleShuffle() { self.source.toggleShuffle() }
    public func cycleRepeatMode() { self.source.cycleRepeatMode() }
    public func toggleCrossfade() { self.source.toggleCrossfade() }
    public func toggleAutomaticContinuation() { self.source.toggleAutomaticContinuation() }
    public func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) { self.source.moveUpcomingQueueItems(fromOffsets: source, toOffset: destination) }
    public func removeFromQueue(at index: Int) { self.source.removeFromQueue(at: index) }
}

public enum PlayerInteraction {
    public static let trackSwipeGestureName = "FullScreenPlayer.TrackSwipe"
    public static let queueScrollGestureName = "FullScreenPlayer.QueueScroll"
}
