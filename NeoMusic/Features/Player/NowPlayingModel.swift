import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

@MainActor @Observable
final class NowPlayingModel {
    enum RepeatMode: String, Codable, Sendable { case off, all, one }

    private let history = NowPlayingHistory()
    private var currentEntryID: UUID? { hasCurrent ? entryIDs[currentIndex] : nil }

    var playbackHistory: [TrackPlaybackEvent] {
        history.visible(owner: resolvedOnlineOwnerID, generation: playbackGeneration, entry: currentEntryID)
    }

    func clearPlaybackHistory() { history.clear(owner: resolvedOnlineOwnerID) }

    func playFromHistory(_ eventID: UUID) {
        guard let event = playbackHistory.first(where: { $0.id == eventID }) else { return }
        if hasCurrent {
            insertNext([event.song], userQueued: false)
            select(currentIndex + 1)
            if !isPlaying, errorMessage == nil { togglePlayback() }
        } else {
            play([event.song], from: "历史记录", shuffled: false)
        }
    }

    var queue: [LibrarySongItem] { didSet { queueRevision &+= 1; updateRemoteCommandAvailability() } }
    private(set) var queueRevision: UInt64 = 0
    private(set) var playbackGeneration: UInt64 = 0
    var currentIndex: Int { didSet { updateRemoteCommandAvailability() } }
    var entryIDs: [UUID]
    var originalOrder: [UUID] = []
    private var applyingState = false
    var isPlaying: Bool
    @ObservationIgnored private var idleAnchorTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var storedElapsed: Double {
        didSet {
            if storedElapsed != oldValue {
                idleAnchorTimestamp = ProcessInfo.processInfo.systemUptime
            }
        }
    }
    var elapsed: Double {
        get { timelineAnchor.elapsed() }
        set {
            storedElapsed = newValue
            if !updatingTime && !applyingState {
                audio?.seek(to: newValue)
                saveQueue()
                updateNowPlaying()
            }
        }
    }
    var repeatMode = RepeatMode.all {
        didSet {
            if !applyingState {
                if repeatMode != .off { stopAutomaticContinuation() }
                prepareNext()
            }
            updateRemoteCommandAvailability()
            saveQueue()
        }
    }
    var isShuffled = false { didSet {
        guard !applyingState, oldValue != isShuffled, hasCurrent else { return }
        if isShuffled { originalOrder = entryIDs + suspended.map(\.0) }
        let start = currentIndex + 1
        let pairs = Array(zip(entryIDs.dropFirst(start), queue.dropFirst(start)))
        let order = Dictionary(originalOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        if isShuffled { suspended.shuffle() }
        else { suspended.sort { order[$0.0, default: Int.max] < order[$1.0, default: Int.max] } }
        let reordered = isShuffled ? pairs.shuffled() : pairs.sorted { order[$0.0, default: Int.max] < order[$1.0, default: Int.max] }
        entryIDs = Array(entryIDs.prefix(start)) + reordered.map(\.0)
        queue = Array(queue.prefix(start)) + reordered.map(\.1)
        prepareNext(); saveQueue()
    } }
    var sourceTitle: String?
    var continuation: PlaybackQueueContinuation? { didSet { updateRemoteCommandAvailability() } }
    var userQueuedIDs: Set<UUID> = []
    var pendingPlay: PendingPlay?
    var onCollectionPlaybackStarted: ((PlaybackCollectionReference) -> Void)?
    var queueContinues: Bool { continuation != nil }
    var replenishQueue: ((_ continuation: PlaybackQueueContinuation, _ shouldAdvance: Bool, _ playbackEnded: Bool) -> Void)?
    var recommendationOwner: ((LibrarySongItem) -> String?)?
    var fetchRecommendations: (@MainActor (LibrarySongItem) async throws -> [LibrarySongItem])?
    var onRecommendationsQueued: (() -> Void)?
    var canAutomaticallyContinue: Bool { hasCurrent && recommendationOwner?(current) != nil }
    var isAutomaticContinuationEnabled: Bool { continuation?.kind == .recommendations }
    var hasRecommendationBatch = false
    var suspended: [(UUID, LibrarySongItem)] = []
    var recommendedEntries = Set<UUID>()
    @ObservationIgnored var recommendationTask: Task<Void, Never>?
    var advanceAfterRecommendations: UUID?
    var endedWaitingForRecommendations = false

    private var pendingCollection: PlaybackCollectionReference?

    struct PendingPlay: Identifiable {
        var songs: [LibrarySongItem]
        let source: String
        let shuffled: Bool
        var startingIndex: Int? = nil
        var collection: PlaybackCollectionReference? = nil
        var continuation: PlaybackQueueContinuation? = nil
        var onStarted: (() -> Void)? = nil
        let id = UUID()
    }

    init(queue: [LibrarySongItem], currentIndex: Int, isPlaying: Bool = true, elapsed: Double = 1,
         makeAudioEngine: @escaping @MainActor () -> LocalPlaybackEngine = { LocalPlaybackEngine() }) {
        self.queue = queue
        self.entryIDs = queue.map { _ in UUID() }
        self.currentIndex = min(max(0, currentIndex), max(0, queue.count - 1))
        self.isPlaying = isPlaying
        self.storedElapsed = elapsed
        self.makeAudioEngine = makeAudioEngine
    }

    var hasCurrent: Bool { queue.indices.contains(currentIndex) }
    var current: LibrarySongItem { hasCurrent ? queue[currentIndex] : LibrarySongItem(id: "", title: "未在播放", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing) }
    var duration: Double {
        if let duration = audio?.duration, duration > 0 { return duration }
        return Double(max(current.duration, 1))
    }
    var timelineAnchor: PlaybackTimelineAnchor {
        if let audio, hasCurrent, loadedEntry == entryIDs[currentIndex] {
            let anchor = audio.timelineAnchor
            let effectiveRate = (isPlaying && !audio.isLoading && audio.error == nil) ? anchor.rate : 0
            return PlaybackTimelineAnchor(
                baseElapsed: anchor.baseElapsed,
                hostTimestamp: anchor.hostTimestamp,
                rate: effectiveRate,
                duration: anchor.duration
            )
        }
        return PlaybackTimelineAnchor(
            baseElapsed: storedElapsed,
            hostTimestamp: idleAnchorTimestamp,
            rate: 0,
            duration: 0
        )
    }
    var liveElapsed: Double { timelineAnchor.elapsed() }
    var isLoading: Bool { resolvingResource || (audio?.isLoading ?? false) || (audio?.isActivating ?? false) }
    var spectrumAnalyzer: ThreadSafeSpectrumAnalyzer? { audio?.spectrumAnalyzer }

    func spectrumLevels() -> [Float] { audio?.spectrumLevels() ?? Array(repeating: 0, count: 5) }
    private(set) var isCrossfadeEnabled = false
    func toggleCrossfade() { isCrossfadeEnabled.toggle(); audio?.crossfadeEnabled = isCrossfadeEnabled; saveQueue() }

    var previous: LibrarySongItem? { queue.indices.contains(currentIndex - 1) ? queue[currentIndex - 1] : nil }
    var next: LibrarySongItem? { queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1] : nil }
    var canSkipForward: Bool { hasCurrent && (next != nil || queueContinues || repeatMode == .all) }
    var upcoming: ArraySlice<LibrarySongItem> { queue[min(currentIndex + 1, queue.count)...] }
    var hasUserQueuedUpcoming: Bool { entryIDs.dropFirst(min(currentIndex + 1, entryIDs.count)).contains { userQueuedIDs.contains($0) } }

    func togglePlayback() {
        guard hasCurrent else { return }
        isPlaying.toggle()
        if isPlaying {
            if loadedEntry == entryIDs[currentIndex], audio?.error == nil { audio?.play() }
            else { startCurrent(at: elapsed) }
        } else {
            advanceAfterRecommendations = nil
            endedWaitingForRecommendations = false
            audio?.pause()
            saveQueue()
            updateNowPlaying()
        }
    }

    func skipForward() {
        guard canSkipForward else { return }
        guard next != nil else {
            if let continuation { replenish(continuation, true, false); return }
            if repeatMode == .all && hasCurrent { select(0) }
            return
        }
        select(currentIndex + 1)
        if let continuation { replenish(continuation, false, false) }
    }

    func skipBackward() {
        if liveElapsed > 3 || previous == nil {
            seek(to: 0, source: .previous)
        } else {
            let targetIndex = currentIndex - 1
            if queue.indices.contains(targetIndex) {
                history.returnToPrevious(generation: playbackGeneration, entry: currentEntryID,
                    targetEntry: entryIDs[targetIndex], targetSongID: queue[targetIndex].id, owner: resolvedOnlineOwnerID)
            }
            select(targetIndex)
        }
    }

    func select(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        if index != currentIndex, hasCurrent,
           loadedEntry == entryIDs[currentIndex], preparedEntry == entryIDs[index],
           audio?.advancePrepared() == true {
            return
        }
        let selectedEntry = entryIDs[index]
        currentIndex = index
        recommendedEntries.remove(selectedEntry)
        userQueuedIDs.remove(selectedEntry)
        playbackGeneration &+= 1
        history.carryRecording(for: selectedEntry, to: playbackGeneration)
        updatingTime = true; elapsed = 0; updatingTime = false
        startCurrent()
        if let continuation { replenish(continuation, false, false) }
    }

    func reorderUpcoming(indices: [Int], fromOffsets: IndexSet, toOffset: Int) {
        guard indices.allSatisfy({ queue.indices.contains($0) && $0 != currentIndex }),
              Set(indices).count == indices.count, fromOffsets.allSatisfy({ indices.indices.contains($0) }),
              toOffset >= 0, toOffset <= indices.count else { return }
        var entries = indices.map { entryIDs[$0] }
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let songs = Dictionary(uniqueKeysWithValues: zip(entryIDs, queue))
        var reorderedIDs = entryIDs
        var reorderedQueue = queue
        for (slot, entry) in zip(indices, entries) {
            reorderedIDs[slot] = entry
            reorderedQueue[slot] = songs[entry]!
        }
        entryIDs = reorderedIDs
        queue = reorderedQueue
        prepareNext(); saveQueue()
    }
    func removeQueueEntry(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        let entry = entryIDs.remove(at: index)
        recommendedEntries.remove(entry)
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        originalOrder.removeAll { $0 == entry }; userQueuedIDs.remove(entry)
        prepareNext(); saveQueue()
    }

    func requestPlay(_ songs: [LibrarySongItem], from source: String, shuffled: Bool,
                     collection: PlaybackCollectionReference? = nil,
                     continuation: PlaybackQueueContinuation? = nil, onStarted: (() -> Void)? = nil) {
        guard !songs.isEmpty else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: shuffled, collection: collection, continuation: continuation, onStarted: onStarted)
        } else {
            play(songs, from: source, shuffled: shuffled, collection: collection, continuation: continuation)
            onStarted?()
        }
    }

    func requestPlay(_ songs: [LibrarySongItem], startingAt index: Int, from source: String,
                     collection: PlaybackCollectionReference? = nil,
                     continuation: PlaybackQueueContinuation? = nil, onStarted: (() -> Void)? = nil) {
        guard songs.indices.contains(index) else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: false, startingIndex: index, collection: collection, continuation: continuation, onStarted: onStarted)
        } else {
            play(songs, startingAt: index, from: source, collection: collection, continuation: continuation)
            onStarted?()
        }
    }

    func confirmPendingPlay() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        if let index = pending.startingIndex {
            play(pending.songs, startingAt: index, from: pending.source, collection: pending.collection, continuation: pending.continuation)
        } else {
            play(pending.songs, from: pending.source, shuffled: pending.shuffled, collection: pending.collection, continuation: pending.continuation)
        }
        pending.onStarted?()
    }

    func play(_ songs: [LibrarySongItem], from source: String, shuffled: Bool,
              collection: PlaybackCollectionReference? = nil, continuation: PlaybackQueueContinuation? = nil) {
        guard !songs.isEmpty else { return }
        pendingPlay = nil
        stopAutomaticContinuation()
        pendingCollection = collection
        queueRestorationFailed = false
        pendingRestoredSongs = [:]
        userQueuedIDs = []
        applyingState = true
        let original = songs.map { (UUID(), $0) }
        let arranged = shuffled ? original.shuffled() : original
        queue = arranged.map(\.1)
        entryIDs = arranged.map(\.0)
        originalOrder = original.map(\.0)
        currentIndex = 0
        elapsed = 0
        isShuffled = shuffled
        applyingState = false
        playbackGeneration &+= 1
        isPlaying = true
        sourceTitle = source
        self.continuation = continuation
        startCurrent()
    }

    func play(_ songs: [LibrarySongItem], startingAt index: Int, from source: String,
              collection: PlaybackCollectionReference? = nil, continuation: PlaybackQueueContinuation? = nil) {
        guard songs.indices.contains(index) else { return }
        pendingPlay = nil
        stopAutomaticContinuation()
        pendingCollection = collection
        queueRestorationFailed = false
        pendingRestoredSongs = [:]
        userQueuedIDs = []
        applyingState = true
        queue = songs
        entryIDs = songs.map { _ in UUID() }
        originalOrder = entryIDs
        isShuffled = false
        currentIndex = index
        elapsed = 0
        applyingState = false
        playbackGeneration &+= 1
        isPlaying = true
        sourceTitle = source
        self.continuation = continuation
        startCurrent()
    }

    func insertNext(_ songs: [LibrarySongItem], userQueued: Bool = true) {
        guard !songs.isEmpty else { return }
        queueRestorationFailed = false
        let ids = songs.map { _ in UUID() }
        let position = min(currentIndex + 1, queue.count)
        queue.insert(contentsOf: songs, at: position)
        entryIDs.insert(contentsOf: ids, at: position)
        originalOrder.append(contentsOf: ids)
        if userQueued { userQueuedIDs.formUnion(ids) }
        prepareNext()
        saveQueue()
    }

    func appendLater(_ songs: [LibrarySongItem]) {
        appendToEnd(songs, userQueued: true)
    }

    func appendContinuing(_ songs: [LibrarySongItem]) {
        appendToEnd(songs, userQueued: false)
    }

    func appendToEnd(_ songs: [LibrarySongItem], userQueued: Bool, recommended: Bool = false) {
        guard !songs.isEmpty else { return }
        let previousNextEntry = nextPlaybackIndex.map { entryIDs[$0] }
        queueRestorationFailed = false
        let ids = songs.map { _ in UUID() }
        queue.append(contentsOf: songs)
        entryIDs.append(contentsOf: ids)
        originalOrder.append(contentsOf: ids)
        if recommended { recommendedEntries.formUnion(ids) }
        if userQueued { userQueuedIDs.formUnion(ids) }
        if recommended || nextPlaybackIndex.map({ entryIDs[$0] }) != previousNextEntry { prepareNext() }
        saveQueue()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
    private var audio: LocalPlaybackEngine?
    @ObservationIgnored private let makeAudioEngine: @MainActor () -> LocalPlaybackEngine
    var hasAudioEngine: Bool { audio != nil }
    @ObservationIgnored private var mediaSession: PlaybackMediaSession?
    private var loadedEntry: UUID?
    @ObservationIgnored private var preparedEntry: UUID? { didSet { preparedQuality = nil } }
    @ObservationIgnored private var preparedQuality: String?
    @ObservationIgnored private var configuringAudio = false
    @ObservationIgnored private var lastSavedPlaybackTime = Date.distantPast
    @ObservationIgnored private var resolveResource: (@MainActor (String) async throws -> PlaybackResource)?
    @ObservationIgnored private var offlineSong: (@MainActor (String) -> LibrarySongItem?)?
    private var offlineSongIDs: Set<String> = []
    @ObservationIgnored private var resourceTask: Task<Void, Never>?
    @ObservationIgnored private var nextResourceTask: Task<Void, Never>?
    @ObservationIgnored private var resourceRevision = UUID()
    private var resolvingResource = false
    private(set) var actualQuality: String?
    @ObservationIgnored private var resolveURL: ((String) -> URL?)?
    @ObservationIgnored private var persistenceURL: URL?
    @ObservationIgnored private let queuePersistence = PlaybackQueuePersistence()
    @ObservationIgnored private let persistenceQueue = BackgroundTaskPersistenceQueue()
    @ObservationIgnored private var queuePersistenceDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var updatingTime = false
    var errorMessage: String?
    private(set) var unavailableIDs: Set<String> = []
    @ObservationIgnored private var hasResolvedOnlineIdentity = false {
        didSet { cachedQueueContent = nil }
    }
    private var resolvedOnlineOwnerID: String?
    @ObservationIgnored private var queueRestorationFailed = false
    @ObservationIgnored private var pendingRestoredSongs: [String: PlaybackSongSnapshot] = [:] {
        didSet { cachedQueueContent = nil }
    }
    @ObservationIgnored private var cachedQueueContent: (revision: UInt64, id: UUID, entries: [UUID], ids: [String], songs: [PlaybackSongSnapshot])?

    struct SavedQueue: Codable, Sendable {
        var snapshotID: UUID? = nil
        var ids: [String]
        var index: Int
        var elapsed: Double
        var repeatMode: RepeatMode
        var shuffled: Bool
        var source: String?
        var entryIDs: [UUID]? = nil
        var originalOrder: [UUID]? = nil
        var userQueuedIDs: Set<UUID>? = nil
        var suspendedCount: Int? = nil
        var hasRecommendationBatch: Bool? = nil
        var recommendedEntries: Set<UUID>? = nil
        var crossfadeEnabled: Bool? = nil
        var songs: [PlaybackSongSnapshot]? = nil
        var continuation: PlaybackQueueContinuation? = nil
    }

    func configurePlayback(resolveURL: @escaping (String) -> URL?, persistenceURL: URL) {
        self.resolveURL = resolveURL
        self.persistenceURL = persistenceURL
        guard mediaSession == nil else { return }
        mediaSession = PlaybackMediaSession(play: { [weak self] in if let self, !self.isPlaying { self.togglePlayback() } },
            pause: { [weak self] in if let self, self.isPlaying { self.togglePlayback() } },
            next: { [weak self] in self?.skipForward() }, previous: { [weak self] in self?.skipBackward() },
            seek: { [weak self] in self?.seek(to: $0, source: .remote) })
        updateRemoteCommandAvailability()
    }

    func configurePlayback(resolveResource: @escaping @MainActor (String) async throws -> PlaybackResource, persistenceURL: URL) {
        configurePlayback(resolveURL: { _ in nil }, persistenceURL: persistenceURL)
        self.resolveResource = resolveResource
    }

    func waitForResourceResolution() async { await resourceTask?.value }

    func configureOfflineSongs(_ resolver: @escaping @MainActor (String) -> LibrarySongItem?) {
        offlineSong = resolver
        reconcileOfflineAvailability()
    }

    func reconcileOfflineAvailability() {
        let previous = queue, previousUnavailable = unavailableIDs
        let currentSongs = queue.filter {
            !offlineSongIDs.contains($0.id) || $0.isOnline || offlineSong?($0.id) != nil
        }
        reconcileAvailability(songs: currentSongs)
        if previous != queue || previousUnavailable != unavailableIDs { saveQueue() }
    }

    var hasOfflineCurrentSong: Bool { hasCurrent && offlineSongIDs.contains(current.id) }

    func remapSongReferences(_ replacements: [String: LibrarySongItem]) {
        let replacements = replacements.filter { $0.key != $0.value.id }
        guard !replacements.isEmpty else { return }
        let updated = queue.map { replacements[$0.id] ?? $0 }
        if var pending = pendingPlay {
            let songs = pending.songs.map { replacements[$0.id] ?? $0 }
            if songs != pending.songs {
                pending.songs = songs
                pendingPlay = pending
            }
        }
        for (id, replacement) in replacements where pendingRestoredSongs[id] != nil {
            pendingRestoredSongs.removeValue(forKey: id)
            pendingRestoredSongs[replacement.id] = PlaybackSongSnapshot(replacement)
        }
        guard updated != queue else { return }
        for song in queue {
            guard let replacement = replacements[song.id] else { continue }
            unavailableIDs.remove(song.id)
            if replacement.unavailabilityReason == nil { unavailableIDs.remove(replacement.id) }
            else { unavailableIDs.insert(replacement.id) }
            offlineSongIDs.remove(song.id)
            if offlineSong?(replacement.id) != nil { offlineSongIDs.insert(replacement.id) }
        }
        queue = updated
        updateNowPlaying()
        saveQueue()
    }

    func reloadCurrentResource() {
        guard hasCurrent, current.id.hasPrefix("netease:"), loadedEntry == entryIDs[currentIndex] else { return }
        resolveCurrent(at: elapsed, replacing: true)
    }

    func restoreOnlineIdentity(ownerID: String?) {
        guard !hasResolvedOnlineIdentity || resolvedOnlineOwnerID != ownerID else { return }
        PerformanceDiagnostics.restoration("player.identity.resolved signedIn=\(ownerID != nil) pendingMetadata=\(pendingRestoredSongs.count)")
        hasResolvedOnlineIdentity = true
        resolvedOnlineOwnerID = ownerID
        invalidateOnlinePlayback(ownerID: ownerID, persist: false)
        var updated = queue
        for index in updated.indices {
            let item = updated[index]
            if let offline = offlineSong?(item.id) {
                updated[index] = offline
                unavailableIDs.remove(item.id)
                continue
            }
            guard let owner = item.onlineOwnerID, owner == ownerID,
                  let snapshot = pendingRestoredSongs[item.id] else { continue }
            updated[index] = snapshot.song
            if updated[index].unavailabilityReason == nil { unavailableIDs.remove(item.id) }
        }
        for index in suspended.indices {
            let song = suspended[index].1
            if let offline = offlineSong?(song.id) { suspended[index].1 = offline }
            else if song.onlineOwnerID == ownerID, let snapshot = pendingRestoredSongs[song.id] {
                suspended[index].1 = snapshot.song
            }
        }
        pendingRestoredSongs = [:]
        if updated != queue { queue = updated }
        updateNowPlaying()
        saveQueue()
    }

    func invalidateOnlinePlayback(ownerID: String?, persist: Bool = true) {
        if hasResolvedOnlineIdentity {
            resolvedOnlineOwnerID = ownerID
            pendingRestoredSongs = pendingRestoredSongs.filter { $0.value.onlineOwnerID == ownerID }
        }
        let interruptedPlayback = isPlaying || resolvingResource
        if let owner = pendingCollection?.ownerID, owner != ownerID { pendingCollection = nil }
        if let owner = pendingPlay?.collection?.ownerID, owner != ownerID { pendingPlay = nil }
        if let owner = pendingPlay?.continuation?.ownerID, owner != ownerID { pendingPlay = nil }
        if let owner = continuation?.ownerID, owner != ownerID { stopAutomaticContinuation(); continuation = nil }
        let retryOffline = hasCurrent && resolvingResource && offlineSong?(current.id) != nil
            && (ownerID == nil || current.onlineOwnerID != ownerID)
        if hasCurrent, current.isOnline, offlineSong?(current.id) == nil,
           ownerID == nil || current.onlineOwnerID != ownerID {
            resourceRevision = UUID()
            resourceTask?.cancel(); resourceTask = nil; resolvingResource = false
        }
        nextResourceTask?.cancel()
        for index in queue.indices where queue[index].id.hasPrefix("netease:") {
            let id = queue[index].id
            if let offline = offlineSong?(id) {
                queue[index] = offline
                unavailableIDs.remove(id)
                offlineSongIDs.insert(id)
                continue
            }
            guard ownerID == nil || !id.hasPrefix("netease:\(ownerID!):") else { continue }
            queue[index] = Self.unavailableOnlineSong(id)
            unavailableIDs.insert(id)
        }
        if hasCurrent, unavailableIDs.contains(current.id), current.id.hasPrefix("netease:") {
            audio?.stop(); loadedEntry = nil; isPlaying = false; actualQuality = nil
            if interruptedPlayback { errorMessage = "请登录原账号后重试" }
        }
        updateNowPlaying()
        if retryOffline { resolveCurrent(at: elapsed) }
        else { prepareNext() }
        if persist { saveQueue() }
    }

    private static func blocksPlayback(_ song: LibrarySongItem) -> Bool {
        guard let reason = song.unavailabilityReason else { return false }
        return reason != "暂无完整音源"
    }

    private static func unavailableOnlineSong(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: "在线歌曲不可用", artist: "登录原账号后可用", album: "", albumArtist: "", trackNumber: 0,
                        artwork: .missing, unavailabilityReason: "请登录原账号后重试")
    }

    private func resolveCurrent(at position: Double, replacing: Bool = false) {
        guard hasCurrent, let resolveResource else { return }
        AppLogger.playback.notice("player.resource.request online=\(self.current.onlineOwnerID != nil) replacing=\(replacing) resume=\(position > 0) target=\(position)")
        if offlineSong?(current.id) == nil, let owner = current.onlineOwnerID,
           (hasResolvedOnlineIdentity ? owner != resolvedOnlineOwnerID : unavailableIDs.contains(current.id)) {
            resourceRevision = UUID()
            resourceTask?.cancel(); nextResourceTask?.cancel(); resourceTask = nil; resolvingResource = false
            configuringAudio = true
            audio?.stop(); loadedEntry = nil; preparedEntry = nil
            configuringAudio = false
            isPlaying = false; actualQuality = nil
            errorMessage = "请登录原账号后重试"
            updateNowPlaying(); saveQueue()
            return
        }
        resourceTask?.cancel(); nextResourceTask?.cancel()
        let revision = UUID(), entry = entryIDs[currentIndex], songID = current.id
        resourceRevision = revision
        let intent = isPlaying
        if !replacing {
            configuringAudio = true
            audio?.stop(); loadedEntry = nil; preparedEntry = nil
            configuringAudio = false
            updatingTime = true; elapsed = max(0, position); updatingTime = false
            isPlaying = intent
            actualQuality = nil
            updateNowPlaying()
        }
        resolvingResource = true; errorMessage = nil
        resourceTask = Task { [weak self] in
            do {
                let resource = try await resolveResource(songID)
                try Task.checkCancellation()
                guard let self, self.resourceRevision == revision, self.hasCurrent,
                      self.entryIDs[self.currentIndex] == entry else { return }
                if let expiry = resource.expiresAt, expiry <= Date() { throw URLError(.resourceUnavailable) }
                let autoplay = self.isPlaying
                let resume = self.elapsed
                if replacing {
                    try await self.ensureAudioEngine().replaceResource(url: resource.url, shouldResume: { self.isPlaying })
                    guard self.resourceRevision == revision, !Task.isCancelled else { return }
                } else {
                    self.configuringAudio = true
                    self.loadedEntry = entry
                    self.ensureAudioEngine().load(url: resource.url, position: resume, autoplay: autoplay)
                    self.configuringAudio = false
                }
                AppLogger.playback.notice("player.resource.ready replacing=\(replacing) resume=\(resume > 0)")
                self.resolvingResource = false
                self.actualQuality = resource.quality
                self.resourceTask = nil
                self.syncTransport(); self.prepareNext(); self.saveQueue()
            } catch is CancellationError {
                guard let self, self.resourceRevision == revision else { return }
                self.resolvingResource = false; self.resourceTask = nil
                self.syncTransport()
            } catch {
                guard let self, self.resourceRevision == revision, !Task.isCancelled else { return }
                AppLogger.playback.notice("player.resource.failed")
                self.resolvingResource = false; self.resourceTask = nil
                if !replacing { self.isPlaying = false; self.loadedEntry = nil }
                self.errorMessage = error.localizedDescription
                self.updateNowPlaying(); self.saveQueue()
            }
        }
    }

    private func ensureAudioEngine() -> LocalPlaybackEngine {
        if let audio { return audio }
        let engine = makeAudioEngine()
        engine.crossfadeEnabled = isCrossfadeEnabled
        audio = engine
        engine.onStateChange = { [weak self] in self?.syncTransport() }
        engine.onTimeChange = { [weak self] in self?.syncTransport(publishNowPlaying: false) }
        engine.onAdvanced = { [weak self] in
            guard let self, let entry = self.preparedEntry, let index = self.entryIDs.firstIndex(of: entry) else { return }
            let quality = self.preparedQuality
            self.currentIndex = index
            self.recommendedEntries.remove(entry)
            self.userQueuedIDs.remove(entry)
            self.playbackGeneration &+= 1
            self.history.carryRecording(for: entry, to: self.playbackGeneration)
            self.loadedEntry = entry
            self.actualQuality = quality
            self.errorMessage = nil
            self.syncTransport()
            self.prepareNext()
            self.saveQueue()
            if let continuation = self.continuation { self.replenish(continuation, false, false) }
        }
        engine.onFinished = { [weak self] in
            guard let self else { return }
            if self.repeatMode == .one {
                self.playbackGeneration &+= 1
                self.isPlaying = true
                self.startCurrent()
            }
            else if self.queue.indices.contains(self.currentIndex + 1) {
                self.isPlaying = true
                self.select(self.currentIndex + 1)
                if let continuation = self.continuation { self.replenish(continuation, false, false) }
            } else if let continuation = self.continuation {
                self.isPlaying = true
                self.replenish(continuation, true, true)
            } else if let index = self.nextPlaybackIndex { self.isPlaying = true; self.select(index) }
            else { self.syncTransport() }
        }
        return engine
    }

    var nextPlaybackIndex: Int? {
        guard hasCurrent else { return nil }
        if repeatMode == .one { return currentIndex }
        if queue.indices.contains(currentIndex + 1) { return currentIndex + 1 }
        if queueContinues { return nil }
        return repeatMode == .all ? 0 : nil
    }
    func prepareNext() {
        guard !applyingState, !configuringAudio, audio != nil else { return }
        let next = nextPlaybackIndex
        nextResourceTask?.cancel()
        if let resolveResource {
            preparedEntry = nil
            audio?.prepareNext(url: nil)
            guard let next, !queue[next].id.hasPrefix("netease:") || offlineSong?(queue[next].id) != nil else { return }
            let revision = resourceRevision, entry = entryIDs[next], id = queue[next].id
            nextResourceTask = Task { [weak self] in
                guard let resource = try? await resolveResource(id), !Task.isCancelled,
                      let self, self.resourceRevision == revision else { return }
                self.preparedEntry = entry
                self.preparedQuality = resource.quality
                self.audio?.prepareNext(url: resource.url)
            }
            return
        }
        preparedEntry = next.map { entryIDs[$0] }
        audio?.prepareNext(url: next.flatMap { resolveURL?(queue[$0].id) })
    }
    private func syncTransport(publishNowPlaying: Bool = true) {
        guard !configuringAudio, let audio else { return }
        if resolvingResource, !hasCurrent || loadedEntry != entryIDs[currentIndex] { return }
        let stopped = isPlaying && !audio.isPlaying && !audio.isActivating
        if abs(elapsed - audio.elapsed) > 0.0001 {
            updatingTime = true
            elapsed = audio.elapsed
            updatingTime = false
        }
        if !audio.isActivating, isPlaying != audio.isPlaying { isPlaying = audio.isPlaying }
        if audio.isPlaybackConfirmed, !audio.isLoading, !resolvingResource, hasCurrent,
           let loadedEntry, loadedEntry == currentEntryID {
            history.record(current, generation: playbackGeneration, entry: loadedEntry, owner: resolvedOnlineOwnerID)
        }
        if audio.isPlaying, let collection = pendingCollection {
            pendingCollection = nil
            onCollectionPlaybackStarted?(collection)
        }
        if let error = audio.error { errorMessage = error }
        if Date().timeIntervalSince(lastSavedPlaybackTime) >= 5 || stopped { saveQueue() }
        if publishNowPlaying { updateNowPlaying() }
    }

    private func seek(to position: Double, source: LocalPlaybackEngine.SeekSource) {
        guard position.isFinite else { return }
        let target = max(0, position)
        storedElapsed = target
        audio?.seek(to: target, source: source)
        saveQueue(); updateNowPlaying()
    }
    func startCurrent(at position: Double = 0) {
        if resolveResource != nil { resolveCurrent(at: position); return }
        guard let resolveURL else { return }
        let autoplay = isPlaying
        configuringAudio = true
        defer { configuringAudio = false; syncTransport(); saveQueue() }
        guard hasCurrent, let url = resolveURL(current.id) else {
            audio?.stop(); loadedEntry = nil; isPlaying = false
            errorMessage = "文件已移除或不可用"; updateNowPlaying(); return
        }
        errorMessage = nil
        loadedEntry = entryIDs[currentIndex]
        let next = nextPlaybackIndex
        preparedEntry = next.map { entryIDs[$0] }
        ensureAudioEngine().load(url: url, nextURL: next.flatMap { resolveURL(queue[$0].id) }, position: position, autoplay: autoplay)
    }

    func saveQueue(immediate: Bool = false) {
        guard !applyingState, !queueRestorationFailed, let persistenceURL else { return }
        lastSavedPlaybackTime = Date()
        queuePersistenceDebounceTask?.cancel()
        queuePersistenceDebounceTask = nil
        if !immediate {
            queuePersistenceDebounceTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.queuePersistenceDebounceTask = nil
                self.commitQueueSave(to: persistenceURL)
            }
            return
        }
        commitQueueSave(to: persistenceURL)
    }

    private func commitQueueSave(to persistenceURL: URL) {
        guard !applyingState, !queueRestorationFailed else { return }
        if cachedQueueContent?.revision != queueRevision {
            var seen = Set<String>()
            let allSongs = queue + suspended.map(\.1)
            let metadata = allSongs.filter { seen.insert($0.id).inserted }.map { song in
                !hasResolvedOnlineIdentity ? pendingRestoredSongs[song.id] ?? PlaybackSongSnapshot(song) : PlaybackSongSnapshot(song)
            }
            cachedQueueContent = (queueRevision, UUID(), entryIDs + suspended.map(\.0), allSongs.map(\.id), metadata)
        }
        guard let content = cachedQueueContent else { return }
        let state = SavedQueue(ids: content.ids, index: currentIndex, elapsed: liveElapsed,
                               repeatMode: repeatMode, shuffled: isShuffled, source: sourceTitle,
                               entryIDs: content.entries, originalOrder: originalOrder, userQueuedIDs: userQueuedIDs,
                               suspendedCount: suspended.count, hasRecommendationBatch: hasRecommendationBatch,
                               recommendedEntries: recommendedEntries, crossfadeEnabled: isCrossfadeEnabled, songs: content.songs, continuation: continuation)
        let persistence = queuePersistence
        persistenceQueue.enqueue { [weak self] in
            do {
                try await persistence.save(state, contentID: content.id, to: persistenceURL)
                if self?.errorMessage?.hasPrefix("播放状态保存失败：") == true {
                    self?.errorMessage = nil
                }
            } catch {
                AppLogger.playback.notice("queue.persist.failed")
            }
        }
    }

    func flushQueuePersistence() async {
        flushDebouncedQueueSave()
        await persistenceQueue.flush()
    }

    private func flushDebouncedQueueSave() {
        if queuePersistenceDebounceTask != nil, let persistenceURL {
            queuePersistenceDebounceTask?.cancel()
            queuePersistenceDebounceTask = nil
            commitQueueSave(to: persistenceURL)
        }
    }

    func saveQueueForBackground() {
        guard persistenceURL != nil else { return }
        persistenceQueue.saveInBackground(named: "Save playback queue") {
            saveQueue(immediate: true)
            flushDebouncedQueueSave()
        }
    }

    @discardableResult
    func restoreQueue(songs: [LibrarySongItem], restoredState: Result<SavedQueue?, Error>? = nil) -> Bool {
        guard let persistenceURL else { return true }
        resourceRevision = UUID(); resourceTask?.cancel(); nextResourceTask?.cancel(); resourceTask = nil; resolvingResource = false
        do {
            let saved: SavedQueue?
            if let restoredState { saved = try restoredState.get() }
            else { saved = try PlaybackQueuePersistence.load(from: persistenceURL) }
            queueRestorationFailed = false
            guard let state = saved else {
                PerformanceDiagnostics.restoration("queue.restore.empty")
                return true
            }
            recommendationTask?.cancel()
            recommendationTask = nil
            advanceAfterRecommendations = nil
            endedWaitingForRecommendations = false
            let map = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let snapshots = Dictionary((state.songs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pendingRestoredSongs = [:]
            offlineSongIDs = []
            let restoredSongs = state.ids.map { id -> LibrarySongItem in
                if let offline = offlineSong?(id) {
                    offlineSongIDs.insert(id)
                    return offline
                }
                let metadata = map[id] ?? snapshots[id]?.song
                guard let owner = metadata?.onlineOwnerID ?? snapshots[id]?.onlineOwnerID else {
                    return metadata ?? .unavailable(id)
                }
                if !hasResolvedOnlineIdentity {
                    if let metadata { pendingRestoredSongs[id] = PlaybackSongSnapshot(metadata) }
                    return Self.unavailableOnlineSong(id)
                }
                guard owner == resolvedOnlineOwnerID else { return Self.unavailableOnlineSong(id) }
                return metadata ?? .unavailable(id)
            }
            applyingState = true
            defer { applyingState = false }
            configuringAudio = true
            audio?.stop()
            configuringAudio = false
            queue = restoredSongs
            entryIDs = state.entryIDs?.count == queue.count && Set(state.entryIDs ?? []).count == queue.count ? state.entryIDs! : queue.map { _ in UUID() }
            let count = min(max(0, state.suspendedCount ?? 0), max(0, queue.count - 1))
            suspended = Array(zip(entryIDs.suffix(count), queue.suffix(count)))
            entryIDs.removeLast(count)
            queue.removeLast(count)
            hasRecommendationBatch = state.hasRecommendationBatch ?? false
            originalOrder = state.originalOrder ?? entryIDs
            userQueuedIDs = state.userQueuedIDs ?? []
            currentIndex = min(max(0, state.index), max(0, queue.count - 1))
            isCrossfadeEnabled = state.crossfadeEnabled ?? false
            audio?.crossfadeEnabled = isCrossfadeEnabled
            repeatMode = state.repeatMode
            let savedOrder = queue
            isShuffled = state.shuffled
            queue = savedOrder
            sourceTitle = state.source
            recommendedEntries = state.recommendedEntries ?? []
            continuation = state.continuation
            if hasResolvedOnlineIdentity, continuation?.ownerID != resolvedOnlineOwnerID { stopAutomaticContinuation(); continuation = nil }
            isPlaying = false
            elapsed = state.elapsed.isFinite ? max(0, state.elapsed) : 0
            unavailableIDs = Set(state.ids).subtracting(Set(map.keys).union(snapshots.keys).union(offlineSongIDs))
                .union(restoredSongs.filter { $0.unavailabilityReason != nil }.map(\.id))
            errorMessage = nil
            updateNowPlaying()
            loadedEntry = nil
            preparedEntry = nil
            PerformanceDiagnostics.restoration("queue.restore.success count=\(queue.count) snapshots=\(snapshots.count) current=\(hasCurrent) resume=\(elapsed > 0)")
            return true
        } catch {
            queueRestorationFailed = true
            PerformanceDiagnostics.restoration("queue.restore.failed")
            return false
        }
    }

    @ObservationIgnored private var artworkQueueIndex: (revision: UInt64, indices: [String: [Int]])?

    func updateArtwork(_ replacements: [String: LibrarySongItem]) {
        guard !replacements.isEmpty else { return }
        if artworkQueueIndex?.revision != queueRevision {
            artworkQueueIndex = (queueRevision, Dictionary(grouping: queue.indices, by: { queue[$0].id }))
        }
        var changed = false
        var currentChanged = false
        for (id, incoming) in replacements {
            let offline = offlineSong?(id)
            var replacement = incoming
            if let offline {
                let file: URL?
                if let url = offline.artworkURL { file = url }
                else if case .file(let url) = offline.artwork { file = url }
                else { file = nil }
                if let file, file.isFileURL, FileManager.default.fileExists(atPath: file.path) {
                    replacement = offline
                }
            }
            if let indices = artworkQueueIndex?.indices[id], let first = indices.first {
                if offline != nil || queue[first].onlineOwnerID == nil
                    || (hasResolvedOnlineIdentity && queue[first].onlineOwnerID == resolvedOnlineOwnerID) {
                    // Occurrences can share their artwork state. Check the playing occurrence first.
                    if hasCurrent, current.id == id {
                        currentChanged = current.publishArtwork(from: replacement) || currentChanged
                    }
                    for index in indices where index != currentIndex {
                        changed = queue[index].publishArtwork(from: replacement) || changed
                    }
                }
            }
            changed = history.updateArtwork(id: id, replacement: replacement, isOffline: offline != nil,
                hasResolvedIdentity: hasResolvedOnlineIdentity, owner: resolvedOnlineOwnerID) || changed
        }
        if changed || currentChanged { cachedQueueContent = nil }
        if currentChanged { updateNowPlaying() }
    }

    func reconcileAvailability(songs: [LibrarySongItem]) {
        guard !queue.isEmpty else {
            if !offlineSongIDs.isEmpty { offlineSongIDs = [] }
            if !unavailableIDs.isEmpty { unavailableIDs = [] }
            return
        }
        let queueIDs = Set(queue.map(\.id))
        var offline: [String: LibrarySongItem] = [:]
        offline.reserveCapacity(queueIDs.count)
        for id in queueIDs {
            if let resolved = offlineSong?(id) { offline[id] = resolved }
        }
        let nextOfflineIDs = Set(offline.keys)
        if offlineSongIDs != nextOfflineIDs {
            offlineSongIDs = nextOfflineIDs
        }
        for id in offline.keys { pendingRestoredSongs.removeValue(forKey: id) }

        var refreshed: [String: LibrarySongItem] = [:]
        refreshed.reserveCapacity(queueIDs.count)
        for song in songs where queueIDs.contains(song.id) {
            if let owner = song.onlineOwnerID, !(hasResolvedOnlineIdentity && owner == resolvedOnlineOwnerID) {
                continue
            }
            if refreshed[song.id] == nil { refreshed[song.id] = song }
        }

        var updated: [LibrarySongItem]?
        var ids = Set(refreshed.keys)
        ids.formUnion(offline.keys)
        var unavailable: Set<String> = []
        for index in queue.indices {
            let song = queue[index]
            let next: LibrarySongItem
            if let downloaded = offline[song.id] {
                next = downloaded
            } else if let owner = song.onlineOwnerID, !hasResolvedOnlineIdentity || owner != resolvedOnlineOwnerID {
                next = Self.unavailableOnlineSong(song.id)
            } else {
                next = refreshed[song.id]?.retainingArtwork(from: song) ?? song
            }
            if next != song {
                if updated == nil { updated = queue }
                updated?[index] = next
            }
            if next.onlineOwnerID != nil && hasResolvedOnlineIdentity && next.onlineOwnerID == resolvedOnlineOwnerID && !Self.blocksPlayback(next) {
                ids.insert(next.id)
            } else if !ids.contains(next.id) || Self.blocksPlayback(next) {
                unavailable.insert(next.id)
            }
        }
        let queueChanged = updated != nil
        let changed = queueChanged || unavailable != unavailableIDs
        if let updated { queue = updated }
        if hasCurrent, unavailableIDs.contains(current.id), !unavailable.contains(current.id) { errorMessage = nil }
        if unavailable != unavailableIDs { unavailableIDs = unavailable }
        if hasCurrent && unavailableIDs.contains(current.id) {
            let interruptedPlayback = isPlaying || resolvingResource
            resourceRevision = UUID(); resourceTask?.cancel(); nextResourceTask?.cancel()
            resourceTask = nil; resolvingResource = false
            audio?.stop(); loadedEntry = nil; isPlaying = false; actualQuality = nil
            if interruptedPlayback {
                errorMessage = current.unavailabilityReason ?? (current.isOnline ? "在线歌曲当前不可用，请重试" : "当前文件已移除")
            }
        }
        if changed { updateNowPlaying() }
    }

    func shutdownPlayback() {
        recommendationTask?.cancel(); recommendationTask = nil
        pendingCollection = nil
        pendingPlay = nil
        queuePersistenceDebounceTask?.cancel(); queuePersistenceDebounceTask = nil
        resourceRevision = UUID(); resourceTask?.cancel(); nextResourceTask?.cancel(); resourceTask = nil; resolvingResource = false
        audio?.onStateChange = nil; audio?.onTimeChange = nil; audio?.onAdvanced = nil; audio?.onFinished = nil
        audio?.shutdown(); audio = nil; mediaSession?.shutdown(); mediaSession = nil
        loadedEntry = nil; preparedEntry = nil; isPlaying = false
    }

    private func updateRemoteCommandAvailability() {
        mediaSession?.setCanSkipForward(canSkipForward)
    }

    private func updateNowPlaying() {
        guard hasCurrent else { return }
        mediaSession?.update(
            .init(title: current.title, artist: current.artist, album: current.album,
                  artwork: current.artworkData, artworkURL: current.artworkURL),
            elapsed: liveElapsed,
            duration: duration,
            playing: isPlaying
        )
    }
}

extension NowPlayingModel: FrontAMTrackPlayback {
    var currentSongID: String? { hasCurrent ? current.id : nil }
    var playbackSourceTitle: String? { sourceTitle }
    var playbackSpectrum: (any FrontAMSpectrumSource)? { spectrumAnalyzer }
}
