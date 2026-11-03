import AVFoundation
import Observation

/// Independent audio transport. Its owner supplies file URLs and owns the logical queue.
@MainActor @Observable final class LocalPlaybackEngine {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var incoming = AVQueuePlayer()
    @ObservationIgnored private var spectrumAnalyzers: [ObjectIdentifier: AudioSpectrumAnalyzer] = [:]
    @ObservationIgnored private var spectrumTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

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

    init() {
        // Advance is coordinated by the owner so duplicate entries retain their identity.
        player.actionAtItemEnd = .pause
        bindClock()
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let endedItem = note.object as? AVPlayerItem else { return }
            let identity = ObjectIdentifier(endedItem)
            MainActor.assumeIsolated {
                guard let self, let current = self.player.currentItem, identity == ObjectIdentifier(current) else { return }
                if self.isCrossfading, self.incoming.currentItem?.status == .readyToPlay {
                    self.completeFade()
                } else if !self.advancePrepared() { self.pause(); self.onFinished?() }
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
                let time = self.player.currentTime().seconds
                if time.isFinite { self.elapsed = max(0, time) }
                let length = self.player.currentItem?.duration.seconds ?? 0
                let duration = length.isFinite ? max(0, length) : 0
                let durationChanged = self.duration != duration
                self.duration = duration
                self.updateFade()
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
                self.isLoading = item.status == .unknown
                if item.status == .failed { self.error = item.error?.localizedDescription ?? "无法播放此音乐文件"; self.pause() }
                self.onStateChange?()
            }
        }
    }

    private func completeFade() {
        guard isCrossfading, let item = incoming.currentItem else { return }
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
        seek(to: position)
        if autoplay { play() }
    }

    func replaceResource(url: URL, shouldResume: @MainActor () -> Bool) async throws {
        let candidate = PlaybackCandidate(url: url)
        try await candidate.waitUntilReady()
        try Task.checkCancellation()
        let position = elapsed
        // Keep the ready item attached to its original player. Detaching an item
        // does not synchronously release AVFoundation's player association.
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        generation += 1
        preparation?.cancel(); preparation = nil
        preparedURL = nil; nextDuration = 0
        status = nil
        player.pause()
        player.removeAllItems()
        cancelFade()
        player = candidate.readyPlayer
        player.actionAtItemEnd = .pause
        guard let item = player.currentItem else { throw URLError(.cannotDecodeContentData) }
        pruneSpectrum()
        bindClock()
        error = nil; isLoading = false
        observeStatus(item)
        let revision = generation
        elapsed = position
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        guard generation == revision, !Task.isCancelled else { return }
        if isPlaying && shouldResume() { play() }
        else { pause() }
    }

    func play() {
        guard player.currentItem != nil, error == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            isPlaying = true; player.play(); if isCrossfading { incoming.play() }; onStateChange?()
        } catch { self.error = error.localizedDescription; pause() }
    }
    func pause() {
        resumeAfterInterruption = false
        player.pause(); incoming.pause(); isPlaying = false; onStateChange?()
    }
    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            if !interrupted { resumeAfterInterruption = isPlaying }
            interrupted = true
            player.pause(); incoming.pause(); isPlaying = false; onStateChange?()
        } else {
            let resume = interrupted && resumeAfterInterruption && shouldResume
            interrupted = false; resumeAfterInterruption = false
            if resume { play() }
        }
    }

    @discardableResult func advancePrepared() -> Bool {
        guard player.items().count > 1 else { return false }
        let continuing = isPlaying
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
        if continuing { player.play() }
        onAdvanced?()
        return true
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        cancelFade()
        elapsed = max(0, seconds)
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() {
        generation += 1; preparation?.cancel(); preparation = nil; nextDuration = 0
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
