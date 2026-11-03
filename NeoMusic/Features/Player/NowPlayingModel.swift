import SwiftUI
import AVFoundation
import MediaPlayer

/// 本地播放、队列及恢复状态；URL 由资料库注入，不持有平台实现。
@MainActor @Observable
final class NowPlayingModel {
    enum RepeatMode: String, Codable { case off, all, one }

    private(set) var queue: [LibrarySongItem]
    private(set) var currentIndex: Int
    private(set) var entryIDs: [UUID]
    private var originalOrder: [UUID] = []
    private var applyingState = false
    var isPlaying: Bool
    var elapsed: Double { didSet { if !updatingTime && !applyingState { audio.seek(to: elapsed); saveQueue(); updateNowPlaying() } } }
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

    struct PendingPlay: Identifiable {
        let songs: [LibrarySongItem]
        let source: String
        let shuffled: Bool
        var startingIndex: Int? = nil
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
    var duration: Double { audio.duration > 0 ? audio.duration : Double(max(current.duration, 1)) }
    var isLoading: Bool { audio.isLoading }
    func spectrumLevels() -> [Float] { audio.spectrumLevels() }
    var isCrossfadeEnabled: Bool { audio.crossfadeEnabled }
    func toggleCrossfade() { audio.crossfadeEnabled.toggle(); saveQueue() }

    var previous: LibrarySongItem? { queue.indices.contains(currentIndex - 1) ? queue[currentIndex - 1] : nil }
    var next: LibrarySongItem? { queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1] : nil }
    var upcoming: ArraySlice<LibrarySongItem> { queue[min(currentIndex + 1, queue.count)...] }
    /// 待播部分里还有手动加入的歌曲。
    var hasUserQueuedUpcoming: Bool { entryIDs.dropFirst(min(currentIndex + 1, entryIDs.count)).contains { userQueuedIDs.contains($0) } }

    func togglePlayback() { guard hasCurrent else { return }; isPlaying.toggle(); if isPlaying { if loadedEntry == entryIDs[currentIndex], audio.error == nil { audio.play() } else { startCurrent(at: elapsed) } } else { audio.pause(); saveQueue(); updateNowPlaying() } }

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
           audio.advancePrepared() {
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
        for (slot, entry) in zip(indices, entries) { entryIDs[slot] = entry; queue[slot] = songs[entry]! }
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
    func requestPlay(_ songs: [LibrarySongItem], from source: String, shuffled: Bool) {
        guard !songs.isEmpty else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: shuffled)
        } else {
            play(songs, from: source, shuffled: shuffled)
        }
    }

    /// 点击具体歌曲也遵循手动队列清除确认，并保留用户选择的位置。
    func requestPlay(_ songs: [LibrarySongItem], startingAt index: Int, from source: String) {
        guard songs.indices.contains(index) else { return }
        if hasUserQueuedUpcoming {
            pendingPlay = PendingPlay(songs: songs, source: source, shuffled: false, startingIndex: index)
        } else {
            play(songs, startingAt: index, from: source)
        }
    }

    /// 确认清除队列并播放挂起的一组歌曲。
    func confirmPendingPlay() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        if let index = pending.startingIndex {
            play(pending.songs, startingAt: index, from: pending.source)
        } else {
            play(pending.songs, from: pending.source, shuffled: pending.shuffled)
        }
    }

    /// 从头播放一组歌曲，替换当前队列。
    func play(_ songs: [LibrarySongItem], from source: String, shuffled: Bool) {
        guard !songs.isEmpty else { return }
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
    func play(_ songs: [LibrarySongItem], startingAt index: Int, from source: String) {
        guard songs.indices.contains(index) else { return }
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
    private let audio = LocalPlaybackEngine()
    @ObservationIgnored private var mediaSession: PlaybackMediaSession?
    @ObservationIgnored private var loadedEntry: UUID?
    @ObservationIgnored private var preparedEntry: UUID?
    @ObservationIgnored private var configuringAudio = false
    @ObservationIgnored private var lastSavedPlaybackTime = Date.distantPast
    @ObservationIgnored private var resolveURL: ((String) -> URL?)?
    @ObservationIgnored private var persistenceURL: URL?
    @ObservationIgnored private var updatingTime = false
    var errorMessage: String?
    private(set) var unavailableIDs: Set<String> = []

    struct SavedQueue: Codable {
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
    }

    func configurePlayback(resolveURL: @escaping (String) -> URL?, persistenceURL: URL) {
        self.resolveURL = resolveURL
        self.persistenceURL = persistenceURL
        guard mediaSession == nil else { return }
        mediaSession = PlaybackMediaSession(play: { [weak self] in if let self, !self.isPlaying { self.togglePlayback() } },
            pause: { [weak self] in if let self, self.isPlaying { self.togglePlayback() } },
            next: { [weak self] in self?.skipForward() }, previous: { [weak self] in self?.skipBackward() },
            seek: { [weak self] in self?.elapsed = $0 })
        audio.onStateChange = { [weak self] in self?.syncTransport() }
        audio.onTimeChange = { [weak self] in self?.syncTransport(publishNowPlaying: false) }
        audio.onAdvanced = { [weak self] in
            guard let self, let entry = self.preparedEntry, let index = self.entryIDs.firstIndex(of: entry) else { return }
            self.currentIndex = index
            self.loadedEntry = entry
            self.syncTransport()
            self.prepareNext()
            self.saveQueue()
        }
        audio.onFinished = { [weak self] in
            guard let self else { return }
            if self.repeatMode == .one { self.isPlaying = true; self.startCurrent() }
            else if let index = self.nextPlaybackIndex { self.isPlaying = true; self.select(index) }
            else { self.syncTransport() }
        }
    }

    private var nextPlaybackIndex: Int? {
        guard hasCurrent else { return nil }
        if repeatMode == .one { return currentIndex }
        if queue.indices.contains(currentIndex + 1) { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }
    private func prepareNext() {
        guard !applyingState, !configuringAudio else { return }
        let next = nextPlaybackIndex
        preparedEntry = next.map { entryIDs[$0] }
        audio.prepareNext(url: next.flatMap { resolveURL?(queue[$0].id) })
    }
    private func syncTransport(publishNowPlaying: Bool = true) {
        guard !configuringAudio else { return }
        let stopped = isPlaying && !audio.isPlaying
        updatingTime = true
        elapsed = audio.elapsed
        updatingTime = false
        isPlaying = audio.isPlaying
        if let error = audio.error { errorMessage = error }
        if Date().timeIntervalSince(lastSavedPlaybackTime) >= 5 || stopped { saveQueue() }
        if publishNowPlaying { updateNowPlaying() }
    }
    func startCurrent(at position: Double = 0) {
        guard let resolveURL else { return }
        let autoplay = isPlaying
        configuringAudio = true
        defer { configuringAudio = false; syncTransport(); saveQueue() }
        guard hasCurrent, let url = resolveURL(current.id) else {
            audio.stop(); loadedEntry = nil; errorMessage = "文件已移除或不可用"; return
        }
        errorMessage = nil
        loadedEntry = entryIDs[currentIndex]
        let next = nextPlaybackIndex
        preparedEntry = next.map { entryIDs[$0] }
        audio.load(url: url, nextURL: next.flatMap { resolveURL(queue[$0].id) }, position: position, autoplay: autoplay)
    }

    func saveQueue() {
        guard !applyingState, let persistenceURL else { return }
        lastSavedPlaybackTime = Date()
        do {
            let state = SavedQueue(ids: queue.map(\.id), index: currentIndex, elapsed: elapsed, repeatMode: repeatMode, shuffled: isShuffled, source: sourceTitle, entryIDs: entryIDs, originalOrder: originalOrder, userQueuedIDs: userQueuedIDs, crossfadeEnabled: isCrossfadeEnabled)
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: persistenceURL, options: .atomic)
        } catch { errorMessage = "播放状态保存失败：" + error.localizedDescription }
    }

    @discardableResult
    func restoreQueue(songs: [LibrarySongItem], requireCompleteLibrary: Bool = false) -> Bool {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return true }
        do {
            let state = try JSONDecoder().decode(SavedQueue.self, from: Data(contentsOf: persistenceURL))
            let map = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if requireCompleteLibrary, !state.ids.allSatisfy({ map[$0] != nil }) { return false }
            applyingState = true
            defer { applyingState = false }
            queue = state.ids.map { map[$0] ?? LibrarySongItem(id: $0, title: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, artist: "文件不可用", album: "", albumArtist: "", trackNumber: 0, artwork: .missing) }
            entryIDs = state.entryIDs?.count == queue.count && Set(state.entryIDs ?? []).count == queue.count ? state.entryIDs! : queue.map { _ in UUID() }
            originalOrder = state.originalOrder ?? entryIDs
            userQueuedIDs = state.userQueuedIDs ?? []
            currentIndex = min(max(0, state.index), max(0, queue.count - 1))
            audio.crossfadeEnabled = state.crossfadeEnabled ?? false
            repeatMode = state.repeatMode
            // Restore the saved order without shuffling a second time.
            let savedOrder = queue
            isShuffled = state.shuffled
            queue = savedOrder
            sourceTitle = state.source
            isPlaying = false
            elapsed = state.elapsed.isFinite ? max(0, state.elapsed) : 0
            reconcileAvailability(songs: songs)
            if hasCurrent { startCurrent(at: elapsed) }
            return true
        } catch {
            errorMessage = "播放状态恢复失败：" + error.localizedDescription
            return false
        }
    }

    func reconcileAvailability(songs: [LibrarySongItem]) {
        let refreshed = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = queue.map { refreshed[$0.id] ?? $0 }
        let ids = Set(refreshed.keys)
        unavailableIDs = Set(queue.map(\.id)).subtracting(ids)
        if hasCurrent && unavailableIDs.contains(current.id) { audio.stop(); loadedEntry = nil; isPlaying = false; errorMessage = "当前文件已移除" }
        updateNowPlaying()
    }

    func shutdownPlayback() {
        audio.onStateChange = nil; audio.onTimeChange = nil; audio.onAdvanced = nil; audio.onFinished = nil
        audio.shutdown(); mediaSession?.shutdown(); mediaSession = nil
        loadedEntry = nil; preparedEntry = nil; isPlaying = false
    }

    private func updateNowPlaying() {
        guard hasCurrent else { return }
        mediaSession?.update(.init(title: current.title, artist: current.artist, album: current.album, artwork: current.artworkData), elapsed: elapsed, duration: duration, playing: isPlaying)
    }
}
