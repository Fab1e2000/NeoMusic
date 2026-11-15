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

public struct PlayerQueueEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let queueIndex: Int
    public let song: PlayerTrack
    public init(id: UUID, queueIndex: Int, song: PlayerTrack) {
        self.id = id; self.queueIndex = queueIndex; self.song = song
    }
}

public struct PlayerLyricLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: TimeInterval
    public let text: String
    public init(id: Int, time: TimeInterval, text: String) { self.id = id; self.time = time; self.text = text }
}

/// Display-ready lyrics. Parsing, translation and storage belong to the host.
public struct PlayerLyrics: Equatable, Sendable {
    public var lines: [PlayerLyricLine]
    public var plainText: String
    public var source: String
    public init(lines: [PlayerLyricLine] = [], plainText: String = "", source: String = "") {
        self.lines = lines; self.plainText = plainText; self.source = source
    }
    public var isEmpty: Bool { lines.isEmpty && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isTimed: Bool { !lines.isEmpty }
    public func activeLine(at time: TimeInterval) -> Int? { lines.last { $0.time <= time }?.id }
}

/// Reads must participate in Observation. The host owns playback and queue mutations.
@MainActor public protocol PlayerPlaybackSource: AnyObject, Observable {
    var tracks: [PlayerTrack] { get }
    var currentTrack: PlayerTrack? { get }
    var currentQueueIndex: Int { get }
    var isPlaying: Bool { get set }
    var isLoading: Bool { get }
    var issue: String? { get }
    var duration: Double { get }
    var progress: Double { get }
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
    func togglePlayback()
    func seek(to value: Double)
    func next()
    func previous()
    func skip(toQueueIndex index: Int)
    func playFromQueue(at index: Int)
    func enqueue(_ track: PlayerTrack, next: Bool)
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleCrossfade()
    func toggleAutomaticContinuation()
    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int)
    func removeFromQueue(at index: Int)
}

/// Stable environment identity with live reads into the host; no copied playback state or clock.
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
    public var isLoading: Bool { source.isLoading }
    public var issue: String? { source.issue }
    public var duration: Double { source.duration }
    public var progress: Double { source.progress }
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
    public func togglePlayback() { self.source.togglePlayback() }
    public func seek(to value: Double) { self.source.seek(to: value) }
    public func next() { self.source.next() }
    public func previous() { self.source.previous() }
    public func skip(toQueueIndex index: Int) { self.source.skip(toQueueIndex: index) }
    public func playFromQueue(at index: Int) { self.source.playFromQueue(at: index) }
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
}
