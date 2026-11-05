import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

/// 本地播放、队列及恢复状态；URL 由资料库注入，不持有平台实现。
@MainActor @Observable
final class NowPlayingModel {
    enum RepeatMode: String, Codable, Sendable { case off, all, one }

    private(set) var queue: [LibrarySongItem] { didSet { queueRevision &+= 1 } }
    private(set) var queueRevision: UInt64 = 0
    private(set) var currentIndex: Int
    private(set) var entryIDs: [UUID]
    private var originalOrder: [UUID] = []
    private var applyingState = false
    var isPlaying: Bool
    var elapsed: Double { didSet { if !updatingTime && !applyingState { audio?.seek(to: elapsed); saveQueue(); updateNowPlaying() } } }
    var volume = 1.0 // Compatibility only; the native volume control adjusts system volume.
    var repeatMode = RepeatMode.all { didSet { if !applyingState { prepareNext() }; saveQueue() } }
    var isShuffled = false { didSet {
        guard !applyingState, oldValue != isShuffled, hasCurrent else { return }
        if isShuffled { originalOrder = entryIDs }
        let start = currentIndex + 1
        let pairs = Array(zip(entryIDs.dropFirst(start), queue.dropFirst(start)))
        let order = Dictionary(originalOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let reordered = isShuffled ? pairs.shuffled() : pairs.sorted { order[$0.0, default: Int.max] < order[$1.0, default: Int.max] }
        entryIDs = Array(entryIDs.prefix(start)) + reordered.map(\.0)
        queue = Array(queue.prefix(start)) + reordered.map(\.1)
        prepareNext(); saveQueue()
    } }
    /// 当前播放来源的名称（专辑或播放列表），显示在“随后播放”下方。
    var sourceTitle: String?
    /// 用户用“插播”“随后播放”手动加入的歌曲。
    private var userQueuedIDs: Set<UUID> = []
    /// 等待确认的整组播放：队列里还有手动加入的歌曲时，替换前先确认，与 Apple Music 一致。
    var pendingPlay: PendingPlay?
    var onCollectionPlaybackStarted: ((PlaybackCollectionReference) -> Void)?
    private var pendingCollection: PlaybackCollectionReference?

    struct PendingPlay: Identifiable {
        var songs: [LibrarySongItem]
        let source: String
        let shuffled: Bool
        var startingIndex: Int? = nil
        var collection: PlaybackCollectionReference? = nil
        var onStarted: (() -> Void)? = nil
        let id = UUID()
    }

    init(queue: [LibrarySongItem], currentIndex: Int, isPlaying: Bool = true, elapsed: Double = 1) {
        self.queue = queue
        self.entryIDs = queue.map { _ in UUID() }
        self.currentIndex = min(max(0, currentIndex), max(0, queue.count - 1))
        self.isPlaying = isPlaying
        self.elapsed = elapsed
    }

    var hasCurrent: Bool { queue.indices.contains(currentIndex) }
    var current: LibrarySongItem { hasCurrent ? queue[currentIndex] : LibrarySongItem(id: "", title: "未在播放", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing) }
    var duration: Double {
        if let duration = audio?.duration, duration > 0 { return duration }
        return Double(max(current.duration, 1))
    }
    var isLoading: Bool { resolvingResource || (audio?.isLoading ?? false) }
    func spectrumLevels() -> [Float] { audio?.spectrumLevels() ?? Array(repeating: 0, count: 5) }
    private(set) var isCrossfadeEnabled = false
    func toggleCrossfade() { isCrossfadeEnabled.toggle(); audio?.crossfadeEnabled = isCrossfadeEnabled; saveQueue() }

    var previous: LibrarySongItem? { queue.indices.contains(currentIndex - 1) ? queue[currentIndex - 1] : nil }
    var next: LibrarySongItem? { queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1] : nil }
    var upcoming: ArraySlice<LibrarySongItem> { queue[min(currentIndex + 1, queue.count)...] }
    /// 待播部分里还有手动加入的歌曲。
    var hasUserQueuedUpcoming: Bool { entryIDs.dropFirst(min(currentIndex + 1, entryIDs.count)).contains { userQueuedIDs.contains($0) } }

    func togglePlayback() { guard hasCurrent else { return }; isPlaying.toggle(); if isPlaying { if loadedEntry == entryIDs[currentIndex], audio?.error == nil { audio?.play() } else { startCurrent(at: elapsed) } } else { audio?.pause(); saveQueue(); updateNowPlaying() } }

    func skipForward() {
        guard next != nil else { if repeatMode == .all && hasCurrent { select(0) }; return }
        select(currentIndex + 1)
    }

    /// 播放超过 3 秒时先回到开头，否则回到上一首。
    func skipBackward() {
        if elapsed > 3 || previous == nil {
            elapsed = 0
        } else {
            select(currentIndex - 1)
        }
    }

    func select(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        // Reuse AVQueuePlayer's next item only when it is the requested queue
        // occurrence and the player still owns the current occurrence.
        if index != currentIndex, hasCurrent,
           loadedEntry == entryIDs[currentIndex], preparedEntry == entryIDs[index],
           audio?.advancePrepared() == true {
            return
        }
        currentIndex = index
        updatingTime = true; elapsed = 0; updatingTime = false
        startCurrent()
    }

    /// 在待播部分内移动；偏移以“当前曲目之后”为起点。
    func moveUpcoming(from source: Int, to destination: Int) {
        let base = currentIndex + 1
        guard queue.indices.contains(base + source), destination >= 0 else { return }
        let entry = entryIDs.remove(at: base + source)
        let item = queue.remove(at: base + source)
        let target = base + min(destination, queue.count - base)
        queue.insert(item, at: target)
        entryIDs.insert(entry, at: target)
        prepareNext()
        saveQueue()
    }

    /// Circular queue presentation: every occurrence except the current one, tail then prefix.
    var wrappedUpcomingEntryIDs: [UUID] {
        guard hasCurrent else { return [] }
        return Array(entryIDs.dropFirst(currentIndex + 1)) + Array(entryIDs.prefix(currentIndex))
    }
    func moveWrappedUpcoming(from source: Int, to destination: Int) {
        var upcoming = wrappedUpcomingEntryIDs
        guard upcoming.indices.contains(source), destination >= 0 else { return }
        let entry = upcoming.remove(at: source)
        upcoming.insert(entry, at: min(destination, upcoming.count))
        applyWrappedOrder(upcoming)
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
        // Publish the completed native reorder once, independent of queue length.
        entryIDs = reorderedIDs
        queue = reorderedQueue
        prepareNext(); saveQueue()
    }
    func removeQueueEntry(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        let entry = entryIDs.remove(at: index)
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        originalOrder.removeAll { $0 == entry }; userQueuedIDs.remove(entry)
        prepareNext(); saveQueue()
    }
    func removeWrappedUpcoming(_ entry: UUID) {
        guard let index = entryIDs.firstIndex(of: entry) else { return }
        removeQueueEntry(at: index)
    }
    private func applyWrappedOrder(_ upcoming: [UUID]) {
        guard hasCurrent, upcoming.count == queue.count - 1 else { return }
        let slots = Array(queue.indices.dropFirst(currentIndex + 1)) + Array(queue.indices.prefix(currentIndex))
        let songs = Dictionary(uniqueKeysWithValues: zip(entryIDs, queue))
        for (slot, entry) in zip(slots, upcoming) { entryIDs[slot] = entry; queue[slot] = songs[entry]! }
        prepareNext(); saveQueue()
    }

    /// 请求从头播放一组歌曲：会清除手动加入的歌曲时先挂起，由宿主弹出确认。
    func requestPlay(_ songs: [LibrarySongItem], from source: String, shuffled: Bool, collection: PlaybackCollectionReference? = nil, onStarted: (() -> Void)? = nil) {
        guard !songs.isEmpty else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: shuffled, collection: collection, onStarted: onStarted)
        } else {
            play(songs, from: source, shuffled: shuffled, collection: collection)
            onStarted?()
        }
    }

    /// 点击具体歌曲也遵循手动队列清除确认，并保留用户选择的位置。
    func requestPlay(_ songs: [LibrarySongItem], startingAt index: Int, from source: String, collection: PlaybackCollectionReference? = nil, onStarted: (() -> Void)? = nil) {
        guard songs.indices.contains(index) else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: false, startingIndex: index, collection: collection, onStarted: onStarted)
        } else {
            play(songs, startingAt: index, from: source, collection: collection)
            onStarted?()
        }
    }

    /// 确认清除队列并播放挂起的一组歌曲。
    func confirmPendingPlay() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        if let index = pending.startingIndex {
            play(pending.songs, startingAt: index, from: pending.source, collection: pending.collection)
        } else {
            play(pending.songs, from: pending.source, shuffled: pending.shuffled, collection: pending.collection)
        }
        pending.onStarted?()
    }

    /// 从头播放一组歌曲，替换当前队列。
    func play(_ songs: [LibrarySongItem], from source: String, shuffled: Bool, collection: PlaybackCollectionReference? = nil) {
        guard !songs.isEmpty else { return }
        pendingPlay = nil
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
        isPlaying = true
        sourceTitle = source
        startCurrent()
    }

    /// 从一组歌曲中的某一首开始播放，替换当前队列。
    func play(_ songs: [LibrarySongItem], startingAt index: Int, from source: String, collection: PlaybackCollectionReference? = nil) {
        guard songs.indices.contains(index) else { return }
        pendingPlay = nil
        pendingCollection = collection
        queueRestorationFailed = false
        pendingRestoredSongs = [:]
        userQueuedIDs = []
        applyingState = true
        queue = songs
        entryIDs = songs.map { _ in UUID() }
        originalOrder = entryIDs
        isShuffled = false
        applyingState = false
        currentIndex = index
        elapsed = 0
        isPlaying = true
        sourceTitle = source
        startCurrent()
    }

    /// 插播：放在当前歌曲之后。
    func insertNext(_ songs: [LibrarySongItem]) {
        guard !songs.isEmpty else { return }
        queueRestorationFailed = false
        let ids = songs.map { _ in UUID() }
        let position = min(currentIndex + 1, queue.count)
        queue.insert(contentsOf: songs, at: position)
        entryIDs.insert(contentsOf: ids, at: position)
        originalOrder.append(contentsOf: ids)
        userQueuedIDs.formUnion(ids)
        prepareNext()
        saveQueue()
    }

    /// 随后播放：放在队列末尾。
    func appendLater(_ songs: [LibrarySongItem]) {
        guard !songs.isEmpty else { return }
        queueRestorationFailed = false
        let ids = songs.map { _ in UUID() }
        queue.append(contentsOf: songs)
        entryIDs.append(contentsOf: ids)
        originalOrder.append(contentsOf: ids)
        userQueuedIDs.formUnion(ids)
        prepareNext()
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
    var hasAudioEngine: Bool { audio != nil }
    @ObservationIgnored private var mediaSession: PlaybackMediaSession?
    @ObservationIgnored private var loadedEntry: UUID?
    @ObservationIgnored private var preparedEntry: UUID?
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
    @ObservationIgnored private var queuePersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var queuePersistenceRevision = 0
    @ObservationIgnored private var persistenceBackgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var updatingTime = false
    var errorMessage: String?
    private(set) var unavailableIDs: Set<String> = []
    @ObservationIgnored private var hasResolvedOnlineIdentity = false
    @ObservationIgnored private var resolvedOnlineOwnerID: String?
    @ObservationIgnored private var queueRestorationFailed = false
    @ObservationIgnored private var pendingRestoredSongs: [String: PlaybackSongSnapshot] = [:]

    struct SavedQueue: Codable, Sendable {
        var ids: [String]
        var index: Int
        var elapsed: Double
        var repeatMode: RepeatMode
        var shuffled: Bool
        var source: String?
        var entryIDs: [UUID]? = nil
        var originalOrder: [UUID]? = nil
        var userQueuedIDs: Set<UUID>? = nil
        var crossfadeEnabled: Bool? = nil
        var songs: [PlaybackSongSnapshot]? = nil
    }

    func configurePlayback(resolveURL: @escaping (String) -> URL?, persistenceURL: URL) {
        self.resolveURL = resolveURL
        self.persistenceURL = persistenceURL
        guard mediaSession == nil else { return }
        mediaSession = PlaybackMediaSession(play: { [weak self] in if let self, !self.isPlaying { self.togglePlayback() } },
            pause: { [weak self] in if let self, self.isPlaying { self.togglePlayback() } },
            next: { [weak self] in self?.skipForward() }, previous: { [weak self] in self?.skipBackward() },
            seek: { [weak self] in self?.elapsed = $0 })
    }

    func configurePlayback(resolveResource: @escaping @MainActor (String) async throws -> PlaybackResource, persistenceURL: URL) {
        configurePlayback(resolveURL: { _ in nil }, persistenceURL: persistenceURL)
        self.resolveResource = resolveResource
    }

    func waitForResourceResolution() async { await resourceTask?.value }

    /// The owner of local files supplies metadata only while the file is available.
    /// Queue identities remain unchanged when an online item gains an offline copy.
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

    /// Relink a removed local copy without replacing its queue occurrences or transport.
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

    /// Resolve saved display metadata after the account owner is known, without loading its catalog.
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

    private static func unavailableOnlineSong(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: "在线歌曲不可用", artist: "登录原账号后可用", album: "", albumArtist: "", trackNumber: 0,
                        artwork: .missing, unavailabilityReason: "请登录原账号后重试")
    }

    private func resolveCurrent(at position: Double, replacing: Bool = false) {
        guard hasCurrent, let resolveResource else { return }
        PerformanceDiagnostics.restoration("player.resource.request online=\(current.onlineOwnerID != nil) resume=\(position > 0)")
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
                let resume = replacing ? self.elapsed : position
                if replacing {
                    try await self.ensureAudioEngine().replaceResource(url: resource.url, shouldResume: { self.isPlaying })
                    guard self.resourceRevision == revision, !Task.isCancelled else { return }
                } else {
                    self.configuringAudio = true
                    self.loadedEntry = entry
                    self.ensureAudioEngine().load(url: resource.url, position: resume, autoplay: autoplay)
                    self.configuringAudio = false
                }
                PerformanceDiagnostics.restoration("player.resource.ready resume=\(resume > 0)")
                self.resolvingResource = false
                self.actualQuality = resource.quality
                self.resourceTask = nil
                self.syncTransport(); self.prepareNext(); self.saveQueue()
            } catch {
                guard let self, self.resourceRevision == revision, !Task.isCancelled else { return }
                PerformanceDiagnostics.restoration("player.resource.failed")
                self.resolvingResource = false; self.resourceTask = nil
                if !replacing { self.isPlaying = false; self.loadedEntry = nil }
                self.errorMessage = error.localizedDescription
                self.updateNowPlaying(); self.saveQueue()
            }
        }
    }

    private func ensureAudioEngine() -> LocalPlaybackEngine {
        if let audio { return audio }
        let engine = LocalPlaybackEngine()
        engine.crossfadeEnabled = isCrossfadeEnabled
        audio = engine
        engine.onStateChange = { [weak self] in self?.syncTransport() }
        engine.onTimeChange = { [weak self] in self?.syncTransport(publishNowPlaying: false) }
        engine.onAdvanced = { [weak self] in
            guard let self, let entry = self.preparedEntry, let index = self.entryIDs.firstIndex(of: entry) else { return }
            self.currentIndex = index
            self.loadedEntry = entry
            self.syncTransport()
            self.prepareNext()
            self.saveQueue()
        }
        engine.onFinished = { [weak self] in
            guard let self else { return }
            if self.repeatMode == .one { self.isPlaying = true; self.startCurrent() }
            else if let index = self.nextPlaybackIndex { self.isPlaying = true; self.select(index) }
            else { self.syncTransport() }
        }
        return engine
    }

    private var nextPlaybackIndex: Int? {
        guard hasCurrent else { return nil }
        if repeatMode == .one { return currentIndex }
        if queue.indices.contains(currentIndex + 1) { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }
    private func prepareNext() {
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
                self.audio?.prepareNext(url: resource.url)
            }
            return
        }
        preparedEntry = next.map { entryIDs[$0] }
        audio?.prepareNext(url: next.flatMap { resolveURL?(queue[$0].id) })
    }
    private func syncTransport(publishNowPlaying: Bool = true) {
        guard !configuringAudio, !resolvingResource, let audio else { return }
        let stopped = isPlaying && !audio.isPlaying
        updatingTime = true
        elapsed = audio.elapsed
        updatingTime = false
        isPlaying = audio.isPlaying
        if audio.isPlaying, let collection = pendingCollection {
            pendingCollection = nil
            onCollectionPlaybackStarted?(collection)
        }
        if let error = audio.error { errorMessage = error }
        if Date().timeIntervalSince(lastSavedPlaybackTime) >= 5 || stopped { saveQueue() }
        if publishNowPlaying { updateNowPlaying() }
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

    func saveQueue() {
        guard !applyingState, !queueRestorationFailed, let persistenceURL else { return }
        lastSavedPlaybackTime = Date()
        var seen = Set<String>()
        let metadata = queue.filter { seen.insert($0.id).inserted }.map { song in
            !hasResolvedOnlineIdentity ? pendingRestoredSongs[song.id] ?? PlaybackSongSnapshot(song) : PlaybackSongSnapshot(song)
        }
        let state = SavedQueue(ids: queue.map(\.id), index: currentIndex, elapsed: elapsed, repeatMode: repeatMode, shuffled: isShuffled, source: sourceTitle, entryIDs: entryIDs, originalOrder: originalOrder, userQueuedIDs: userQueuedIDs, crossfadeEnabled: isCrossfadeEnabled, songs: metadata)
        let previous = queuePersistenceTask
        let persistence = queuePersistence
        queuePersistenceRevision += 1
        let revision = queuePersistenceRevision
        // Each write waits for its predecessor; actor scheduling alone does not
        // guarantee that snapshots arrive in the order the UI submitted them.
        queuePersistenceTask = Task { [weak self] in
            await previous?.value
            do {
                try await persistence.save(state, to: persistenceURL)
                if self?.errorMessage?.hasPrefix("播放状态保存失败：") == true {
                    self?.errorMessage = nil
                }
            } catch {
                self?.errorMessage = "播放状态保存失败：" + error.localizedDescription
            }
            if self?.queuePersistenceRevision == revision {
                self?.queuePersistenceTask = nil
            }
        }
    }

    /// Wait for submitted snapshots, including changes made while a write finishes.
    func flushQueuePersistence() async {
        while let pending = queuePersistenceTask {
            await pending.value
        }
    }

    func saveQueueForBackground() {
        guard persistenceURL != nil else { return }
        if persistenceBackgroundTask == .invalid {
            persistenceBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save playback queue") { [weak self] in
                self?.endPersistenceBackgroundTask()
            }
        }
        saveQueue()
        Task { [weak self] in
            guard let self else { return }
            await flushQueuePersistence()
            endPersistenceBackgroundTask()
        }
    }

    private func endPersistenceBackgroundTask() {
        guard persistenceBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(persistenceBackgroundTask)
        persistenceBackgroundTask = .invalid
    }

    @discardableResult
    func restoreQueue(songs: [LibrarySongItem], restoredState: Result<SavedQueue?, Error>? = nil) -> Bool {
        guard let persistenceURL else { return true }
        resourceRevision = UUID(); resourceTask?.cancel(); nextResourceTask?.cancel(); resourceTask = nil; resolvingResource = false
        do {
            let saved: SavedQueue?
            if let restoredState { saved = try restoredState.get() }
            else { saved = FileManager.default.fileExists(atPath: persistenceURL.path) ? try JSONDecoder().decode(SavedQueue.self, from: Data(contentsOf: persistenceURL)) : nil }
            queueRestorationFailed = false
            guard let state = saved else {
                PerformanceDiagnostics.restoration("queue.restore.empty")
                return true
            }
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
            originalOrder = state.originalOrder ?? entryIDs
            userQueuedIDs = state.userQueuedIDs ?? []
            currentIndex = min(max(0, state.index), max(0, queue.count - 1))
            isCrossfadeEnabled = state.crossfadeEnabled ?? false
            audio?.crossfadeEnabled = isCrossfadeEnabled
            repeatMode = state.repeatMode
            // Restore the saved order without shuffling a second time.
            let savedOrder = queue
            isShuffled = state.shuffled
            queue = savedOrder
            sourceTitle = state.source
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
            errorMessage = "播放状态恢复失败：" + error.localizedDescription
            return false
        }
    }

    /// Artwork arrival leaves playback resources, queue order and availability alone.
    func updateArtwork(_ replacements: [String: LibrarySongItem]) {
        guard !replacements.isEmpty else { return }
        var updated = queue
        var changed = false
        var currentChanged = false
        for index in queue.indices {
            let existing = queue[index]
            if offlineSong?(existing.id) == nil, let owner = existing.onlineOwnerID,
               !hasResolvedOnlineIdentity || owner != resolvedOnlineOwnerID { continue }
            guard let replacement = replacements[existing.id],
                  replacement.artwork != existing.artwork
                    || replacement.artworkData != existing.artworkData
                    || replacement.artworkURL != existing.artworkURL
                    || replacement.artworkBackdrop != existing.artworkBackdrop else { continue }
            updated[index].artwork = replacement.artwork
            updated[index].artworkData = replacement.artworkData
            updated[index].artworkURL = replacement.artworkURL
            updated[index].artworkBackdrop = replacement.artworkBackdrop
            changed = true
            if index == currentIndex { currentChanged = true }
        }
        if changed { queue = updated }
        if currentChanged { updateNowPlaying() }
    }

    func reconcileAvailability(songs: [LibrarySongItem]) {
        let offline = Dictionary(queue.compactMap { song in
            offlineSong?(song.id).map { (song.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        offlineSongIDs = Set(offline.keys)
        for id in offline.keys { pendingRestoredSongs.removeValue(forKey: id) }
        let refreshed = Dictionary(songs.filter { song in
            guard let owner = song.onlineOwnerID else { return true }
            return hasResolvedOnlineIdentity && owner == resolvedOnlineOwnerID
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = queue.map { song in
            if let downloaded = offline[song.id] { return downloaded }
            if let owner = song.onlineOwnerID, !hasResolvedOnlineIdentity || owner != resolvedOnlineOwnerID {
                return Self.unavailableOnlineSong(song.id)
            }
            return refreshed[song.id] ?? song
        }
        var ids = Set(refreshed.keys)
        ids.formUnion(offline.keys)
        // An authenticated stable online identity is playable without a loaded detail page.
        ids.formUnion(updated.filter { song in
            song.onlineOwnerID != nil && hasResolvedOnlineIdentity && song.onlineOwnerID == resolvedOnlineOwnerID
                && song.unavailabilityReason == nil
        }.map(\.id))
        let unavailable = Set(queue.map(\.id)).subtracting(ids).union(updated.filter { $0.unavailabilityReason != nil }.map(\.id))
        let changed = updated != queue || unavailable != unavailableIDs
        if updated != queue { queue = updated }
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
        pendingCollection = nil
        pendingPlay = nil
        resourceRevision = UUID(); resourceTask?.cancel(); nextResourceTask?.cancel(); resourceTask = nil; resolvingResource = false
        audio?.onStateChange = nil; audio?.onTimeChange = nil; audio?.onAdvanced = nil; audio?.onFinished = nil
        audio?.shutdown(); audio = nil; mediaSession?.shutdown(); mediaSession = nil
        loadedEntry = nil; preparedEntry = nil; isPlaying = false
    }

    private func updateNowPlaying() {
        guard hasCurrent else { return }
        mediaSession?.update(.init(title: current.title, artist: current.artist, album: current.album, artwork: current.artworkData, artworkURL: current.artworkURL), elapsed: elapsed, duration: duration, playing: isPlaying)
    }
}
