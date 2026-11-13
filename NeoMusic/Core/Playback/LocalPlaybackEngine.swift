import AVFoundation
import Observation

/// Independent audio transport. Its owner supplies file URLs and owns the logical queue.
@MainActor @Observable final class LocalPlaybackEngine {
    private(set) var isPlaying = false
    private(set) var isActivating = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var incoming = AVQueuePlayer()
    @ObservationIgnored private var spectrumAnalyzers: [ObjectIdentifier: AudioSpectrumAnalyzer] = [:]
    @ObservationIgnored private var spectrumTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private let activateSession: @Sendable () async throws -> Bool
    @ObservationIgnored private(set) var activation: Task<Void, Never>?
    @ObservationIgnored private var playRequested = false

    enum SeekSource: String, Sendable {
        case interaction, remote, previous, load, restore, resource
    }
    private struct SeekRequest: Sendable {
        let revision: Int
        let time: CMTime
        let source: SeekSource
        let completion: (@MainActor @Sendable (Bool) -> Void)?
        var submitted = false
    }
    @ObservationIgnored private var seekRevision = 0
    @ObservationIgnored private var pendingSeek: SeekRequest?

    /// Read on demand by visible indicators; no high-frequency Observation invalidations.
    func spectrumLevels() -> [Float] {
        guard isPlaying, !isLoading, error == nil, player.timeControlStatus == .playing,
              let item = player.currentItem,
              let analyzer = spectrumAnalyzers[ObjectIdentifier(item)] else { return Array(repeating: 0, count: 5) }
        return (0..<5).map { analyzer.level(at: $0) }
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        let identity = ObjectIdentifier(item)
        spectrumTasks[identity] = Task { [weak self, weak item] in
            guard let item else { return }
            let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
            guard !Task.isCancelled, let self,
                  self.player.items().contains(where: { $0 === item }) || self.incoming.items().contains(where: { $0 === item }) else { return }
            defer { self.spectrumTasks[identity] = nil }
            guard let track = tracks?.first, item.audioMix == nil else { return }
            let analyzer = AudioSpectrumAnalyzer()
            if analyzer.attach(to: item, track: track) { self.spectrumAnalyzers[identity] = analyzer }
        }
        return item
    }

    private func pruneSpectrum() {
        let active = Set((player.items() + incoming.items()).map(ObjectIdentifier.init))
        for key in Array(spectrumTasks.keys) where !active.contains(key) {
            spectrumTasks.removeValue(forKey: key)?.cancel()
        }
        spectrumAnalyzers = spectrumAnalyzers.filter { active.contains($0.key) }
    }

    @ObservationIgnored private var preparedURL: URL?
    @ObservationIgnored private var fadeStart: Double?
    @ObservationIgnored private var nextDuration: Double = 0
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interrupted = false
    var crossfadeEnabled = false {
        didSet { if !crossfadeEnabled { cancelFade() } }
    }
    private(set) var isCrossfading = false
    @ObservationIgnored var onAdvanced: (() -> Void)?

    private func cancelFade() {
        incoming.pause(); incoming.replaceCurrentItem(with: nil)
        pruneSpectrum()
        player.volume = 1; fadeStart = nil; isCrossfading = false
    }
    private func updateFade() {
        guard crossfadeEnabled, isPlaying, duration > 3, let preparedURL else { return }
        let remaining = duration - elapsed
        let overlap = min(3, nextDuration / 2)
        guard overlap > 0 else { return }
        if fadeStart == nil, remaining <= overlap, remaining > 0 {
            incoming.replaceCurrentItem(with: makeItem(url: preparedURL))
            incoming.actionAtItemEnd = .pause
            incoming.volume = 0; incoming.play()
            fadeStart = elapsed; isCrossfading = true
        }
        guard let start = fadeStart else { return }
        let fraction = Float(min(1, max(0, (elapsed - start) / max(0.01, duration - start))))
        player.volume = 1 - fraction; incoming.volume = fraction
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var status: NSKeyValueObservation?
    @ObservationIgnored private var clock: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onTimeChange: (() -> Void)?

    init(activateSession: @escaping @Sendable () async throws -> Bool = LocalPlaybackEngine.activateAudioSession) {
        self.activateSession = activateSession
        // Advance is coordinated by the owner so duplicate entries retain their identity.
        player.actionAtItemEnd = .pause
        bindClock()
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let endedItem = note.object as? AVPlayerItem else { return }
            let identity = ObjectIdentifier(endedItem)
            MainActor.assumeIsolated {
                guard let self, let current = self.player.currentItem, identity == ObjectIdentifier(current) else { return }
                PerformanceDiagnostics.restoration("player.ended generation=\(self.generation) current=\(current.currentTime().seconds) duration=\(current.duration.seconds)")
                if self.isCrossfading, self.incoming.currentItem?.status == .readyToPlay {
                    self.completeFade()
                } else if !self.advancePrepared() { self.pause(); self.onFinished?() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                PerformanceDiagnostics.restoration("player.timeJump generation=\(self.generation) current=\(item.currentTime().seconds) seeking=\(self.pendingSeek != nil)")
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                if kind == AVAudioSession.InterruptionType.began.rawValue { self?.handleInterruption(began: true) }
                else if kind == AVAudioSession.InterruptionType.ended.rawValue {
                    self?.handleInterruption(began: false, shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
    }

    private func bindClock() {
        let observed = player
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player === observed else { return }
                // Keep the latest requested position visible until AVPlayer completes it.
                // Earlier samples remain valid for audio, but must not undo the user's seek.
                if self.pendingSeek == nil { self.readCurrentTime() }
                let length = self.player.currentItem?.duration.seconds ?? 0
                let duration = length.isFinite ? max(0, length) : 0
                let durationChanged = self.duration != duration
                if durationChanged { self.duration = duration }
                if self.pendingSeek == nil { self.updateFade() }
                // A newly resolved duration is metadata; ordinary time ticks only
                // drive in-app progress. Now Playing extrapolates elapsed time.
                if durationChanged { self.onStateChange?() }
                else { self.onTimeChange?() }
            }
        }
    }

    private func observeStatus(_ item: AVPlayerItem) {
        let token = generation
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, token == self.generation, self.player.currentItem === item else { return }
                self.isLoading = item.status == .unknown || self.pendingSeek != nil
                if item.status == .readyToPlay { self.submitPendingSeek() }
                if item.status == .failed {
                    self.error = item.error?.localizedDescription ?? "无法播放此音乐文件"
                    self.invalidateSeek()
                    self.isLoading = false
                    self.pause()
                }
                self.onStateChange?()
            }
        }
    }

    private func completeFade() {
        guard isCrossfading, let item = incoming.currentItem else { return }
        invalidateSeek()
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        let outgoing = player
        player = incoming
        incoming = outgoing
        incoming.pause(); incoming.removeAllItems()
        pruneSpectrum()
        player.actionAtItemEnd = .pause
        player.volume = 1
        fadeStart = nil; isCrossfading = false; preparedURL = nil
        generation += 1
        elapsed = max(0, player.currentTime().seconds)
        let length = item.duration.seconds
        duration = length.isFinite ? length : 0
        observeStatus(item)
        bindClock()
        onAdvanced?()
    }

    func prepareNext(url: URL?) {
        cancelFade()
        preparation?.cancel()
        preparedURL = url; nextDuration = 0
        for item in player.items().dropFirst() { player.remove(item) }
        pruneSpectrum()
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path), let current = player.currentItem else { return }
        player.insert(makeItem(url: url), after: current)
        let token = generation
        preparation = Task { [weak self] in
            let value = try? await AVURLAsset(url: url).load(.duration).seconds
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.nextDuration = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        }
    }

    func load(url: URL, nextURL: URL? = nil, position: Double = 0, autoplay: Bool = false) {
        stop()
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { error = "音乐文件不可用"; return }
        error = nil; isLoading = true
        preparedURL = nextURL
        let token = generation
        if let nextURL {
            preparation = Task { [weak self] in
                let value = try? await AVURLAsset(url: nextURL).load(.duration).seconds
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.nextDuration = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            }
        }
        let item = makeItem(url: url)
        player.insert(item, after: nil)
        if let nextURL, nextURL.isFileURL, FileManager.default.fileExists(atPath: nextURL.path) {
            player.insert(makeItem(url: nextURL), after: item)
        }
        observeStatus(item)
        seek(to: position, source: position > 0 ? .restore : .load)
        if autoplay { play() }
    }

    func replaceResource(url: URL, shouldResume: @MainActor () -> Bool) async throws {
        let candidate = PlaybackCandidate(url: url)
        let previousGeneration = generation
        try await candidate.waitUntilReady()
        try Task.checkCancellation()
        guard generation == previousGeneration else { throw CancellationError() }
        // A pending interaction owns its target; otherwise capture the native clock
        // at the handover, rather than the last periodic UI sample.
        player.pause()
        let position = pendingSeek?.time ?? player.currentTime()
        guard position.seconds.isFinite else { throw URLError(.cannotDecodeContentData) }
        invalidateSeek()
        cancelActivation()
        // Keep the ready item attached to its original player. Detaching an item
        // does not synchronously release AVFoundation's player association.
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        generation += 1
        preparation?.cancel(); preparation = nil
        preparedURL = nil; nextDuration = 0
        status = nil
        player.removeAllItems()
        cancelFade()
        player = candidate.readyPlayer
        player.actionAtItemEnd = .pause
        guard let item = player.currentItem else { throw URLError(.cannotDecodeContentData) }
        pruneSpectrum()
        error = nil; isLoading = false
        observeStatus(item)
        let revision = generation
        var replacementSeek = 0
        let finished = await withCheckedContinuation { continuation in
            replacementSeek = requestSeek(to: position, source: .resource) { finished in
                continuation.resume(returning: finished)
            }
            bindClock()
            if playRequested && shouldResume() { play() }
            else { pause() }
        }
        guard generation == revision, !Task.isCancelled else { throw CancellationError() }
        // A later seek acts directly on the new player and owns its completion.
        guard seekRevision == replacementSeek else { return }
        guard finished else { throw URLError(.cannotDecodeContentData) }
        if playRequested && shouldResume() { play() }
        else { pause() }
    }

    func play() {
        guard player.currentItem != nil, error == nil else { return }
        playRequested = true
        if isPlaying {
            if pendingSeek == nil { player.play() }
            if isCrossfading { incoming.play() }
            onStateChange?()
            return
        }
        guard !isActivating else { return }
        let token = generation
        let activate = activateSession
        isActivating = true
        activation = Task { [weak self] in
            do {
                let activated = try await activate()
                guard !Task.isCancelled, let self, self.generation == token, self.playRequested else { return }
                self.activation = nil; self.isActivating = false
                guard activated else {
                    self.error = "无法激活音频会话"
                    self.pause()
                    return
                }
                self.isPlaying = true
                if self.pendingSeek == nil { self.player.play() }
                if self.isCrossfading { self.incoming.play() }
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.playRequested else { return }
                self.activation = nil; self.isActivating = false
                self.error = error.localizedDescription
                self.pause()
            }
        }
        onStateChange?()
    }

    @concurrent private static func activateAudioSession() async throws -> Bool {
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default {
            try session.setCategory(.playback, mode: .default)
        }
        try Task.checkCancellation()
        return try await session.activate()
    }

    private func cancelActivation() {
        activation?.cancel(); activation = nil; isActivating = false
    }

    func pause() {
        resumeAfterInterruption = false
        playRequested = false
        cancelActivation()
        player.pause(); incoming.pause(); isPlaying = false
        if pendingSeek == nil { readCurrentTime() }
        onStateChange?()
    }
    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            if !interrupted { resumeAfterInterruption = playRequested }
            interrupted = true
            playRequested = false
            cancelActivation()
            player.pause(); incoming.pause(); isPlaying = false
            if pendingSeek == nil { readCurrentTime() }
            onStateChange?()
        } else {
            let resume = interrupted && resumeAfterInterruption && shouldResume
            interrupted = false; resumeAfterInterruption = false
            if resume { play() }
        }
    }

    @discardableResult func advancePrepared() -> Bool {
        guard player.items().count > 1 else { return false }
        let continuing = playRequested
        invalidateSeek()
        cancelActivation()
        cancelFade()
        generation += 1; preparation?.cancel(); preparedURL = nil; nextDuration = 0
        player.advanceToNextItem()
        pruneSpectrum()
        guard let item = player.currentItem else { return false }
        elapsed = 0
        let length = item.duration.seconds
        duration = length.isFinite ? max(0, length) : 0
        isLoading = item.status == .unknown
        observeStatus(item)
        if continuing {
            if isPlaying { player.play() }
            else { play() }
        }
        onAdvanced?()
        return true
    }
    func seek(to seconds: Double, source: SeekSource = .interaction) {
        guard seconds.isFinite else { return }
        cancelFade()
        requestSeek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), source: source)
    }

    @discardableResult
    private func requestSeek(to time: CMTime, source: SeekSource,
                             completion: (@MainActor @Sendable (Bool) -> Void)? = nil) -> Int {
        invalidateSeek()
        seekRevision += 1
        guard player.currentItem != nil else {
            completion?(false)
            return seekRevision
        }
        pendingSeek = SeekRequest(revision: seekRevision, time: time, source: source, completion: completion)
        elapsed = max(0, time.seconds)
        isLoading = true
        PerformanceDiagnostics.restoration("player.seek.request source=\(source.rawValue) generation=\(generation) request=\(seekRevision) target=\(time.seconds)")
        submitPendingSeek()
        return seekRevision
    }

    /// Item readiness comes from KVO; repeated input replaces the current request immediately.
    private func submitPendingSeek() {
        guard let request = pendingSeek, !request.submitted,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        pendingSeek?.submitted = true
        let observed = player, token = generation
        observed.seek(to: request.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                let current = self.player === observed && self.player.currentItem === item
                    && self.generation == token && self.pendingSeek?.revision == request.revision
                PerformanceDiagnostics.restoration("player.seek.completed source=\(request.source.rawValue) generation=\(token) request=\(request.revision) target=\(request.time.seconds) finished=\(finished) current=\(observed.currentTime().seconds) applied=\(current)")
                guard current else { return }
                self.pendingSeek = nil
                self.readCurrentTime()
                let length = item.duration.seconds
                if length.isFinite { self.duration = max(0, length) }
                self.isLoading = item.status == .unknown
                if finished {
                    if self.playRequested { self.play() }
                    else { self.onStateChange?() }
                } else {
                    self.error = item.error?.localizedDescription ?? "无法定位到播放位置，请重试"
                    self.pause()
                }
                request.completion?(finished)
            }
        }
    }

    private func invalidateSeek() {
        guard let request = pendingSeek else { return }
        pendingSeek = nil
        player.currentItem?.cancelPendingSeeks()
        request.completion?(false)
    }

    private func readCurrentTime() {
        let time = player.currentTime().seconds
        if time.isFinite { elapsed = max(0, time) }
    }
    func stop() {
        generation += 1; preparation?.cancel(); preparation = nil; nextDuration = 0
        invalidateSeek()
        interrupted = false
        pause(); cancelFade(); preparedURL = nil; status = nil
        player.removeAllItems(); pruneSpectrum(); isLoading = false; elapsed = 0; duration = 0; error = nil
    }
    /// Called when the transport owner is retired; removes observer ownership as well as audio.
    func shutdown() {
        stop()
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
    }
}

/// A separate native player readies the replacement without disrupting current audio.
@MainActor
private final class PlaybackCandidate {
    private let player = AVQueuePlayer()
    var readyPlayer: AVQueuePlayer { player }
    private let item: AVPlayerItem
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL) { item = AVPlayerItem(url: url) }

    func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.checkStatus() }
                }
                player.replaceCurrentItem(with: item)
                if Task.isCancelled { finish(.failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func checkStatus() {
        switch item.status {
        case .readyToPlay: finish(.success(()))
        case .failed: finish(.failure(item.error ?? URLError(.cannotDecodeContentData)))
        default: break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil; observation = nil
        continuation.resume(with: result)
    }

}
