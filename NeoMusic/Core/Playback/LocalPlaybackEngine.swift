import AVFoundation
import Observation

@MainActor @Observable final class LocalPlaybackEngine {
    private(set) var isPlaying = false
    private(set) var isActivating = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    @ObservationIgnored private let graph = SharedAudioGraph()
    @ObservationIgnored private var player: StreamingPlaybackDeck
    @ObservationIgnored private var incoming: StreamingPlaybackDeck
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private let activateSession: @Sendable () async throws -> Bool
    @ObservationIgnored private(set) var activation: Task<Void, Never>?
    @ObservationIgnored private var playRequested = false
    @ObservationIgnored private var reportsActivationFailure = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var preparedURL: URL?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var fadeStart: Double?
    var crossfadeEnabled = false { didSet { if !crossfadeEnabled { cancelFade() } else { cancelGapless() } } }
    private(set) var isCrossfading = false
    @ObservationIgnored private var isGaplessArmed = false
    @ObservationIgnored var onAdvanced: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onTimeChange: (() -> Void)?
    enum SeekSource: String, Sendable { case interaction, remote, previous, load, restore, resource }

    init(activateSession: @escaping @Sendable () async throws -> Bool = LocalPlaybackEngine.activateAudioSession) {
        self.activateSession = activateSession
        self.player = StreamingPlaybackDeck(graph: graph)
        self.incoming = StreamingPlaybackDeck(graph: graph)
        bindPlayer()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = (self?.isPlaying == true) ? .milliseconds(16) : .milliseconds(100)
                do { try await Task.sleep(for: interval) } catch { return }
                self?.tick()
            }
        }
        let session = AVAudioSession.sharedInstance()
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] note in
            guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                  context.source == .system else { return }
            MainActor.assumeIsolated {
                self?.handleInterruption(began: true)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { [weak self] note in
            guard let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
            MainActor.assumeIsolated {
                self?.handleInterruption(began: false, shouldResume: context.recommendation == .shouldResume)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
    }


    private func bindPlayer() {
        let observed = player
        player.onChange = { [weak self, weak observed] in
            guard let self, self.player === observed else { return }
            self.isLoading = self.player.isLoading
            self.readCurrentTime()
            if let failure = self.player.error { self.error = failure.localizedDescription; self.pause() }
            self.onStateChange?()
        }
        player.onEnded = { [weak self, weak observed] in
            guard let self, self.player === observed else { return }
            if self.isCrossfading, !self.incoming.isLoading {
                self.promoteIncoming(); self.onAdvanced?()
            } else if self.isGaplessArmed, !self.incoming.isLoading {
                self.incoming.play(atHostTime: nil)
                self.promoteIncoming(); self.onAdvanced?()
            } else if !self.advancePrepared() {
                self.pause(); self.onFinished?()
            }
        }
    }
    private func readCurrentTime() {
        if let time = player.currentPlaybackTime, time.isFinite { elapsed = max(0, time) }
        if let length = player.playbackDuration, length.isFinite { duration = max(0, length) }
    }
    private func tick() {
        let previousElapsed = elapsed
        let previousDuration = duration
        readCurrentTime()
        updateFade()
        updateGapless()
        if previousDuration != duration {
            onStateChange?()
        } else if abs(previousElapsed - elapsed) > 0.0001 {
            onTimeChange?()
        }
    }
    func spectrumLevels() -> [Float] {
        guard isPlaying, !isLoading, error == nil else { return Array(repeating: 0, count: 5) }
        return player.spectrumLevels()
    }
    func load(url: URL, nextURL: URL? = nil, position: Double = 0, autoplay: Bool = false) {
        stop()
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { error = "音乐文件不可用"; return }
        elapsed = max(0, position); isLoading = true
        player.load(url: url, position: elapsed)
        prepareNext(url: nextURL)
        if autoplay { play() }
    }
    func prepareNext(url: URL?) {
        cancelFade()
        cancelGapless()
        preparedURL = url
        incoming.clear()
        if let url, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) { incoming.load(url: url) }
    }
    private func cancelFade() {
        incoming.pause()
        if isCrossfading { incoming.seek(to: 0) }
        player.volume = 1; incoming.volume = 0
        fadeStart = nil; isCrossfading = false
    }
    private func cancelGapless() {
        guard isGaplessArmed else { return }
        incoming.pause()
        incoming.seek(to: 0)
        isGaplessArmed = false
    }
    private func updateGapless() {
        guard !crossfadeEnabled, !isGaplessArmed, isPlaying, !isLoading,
              duration > 0, duration - elapsed <= 1.5,
              let url = preparedURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path),
              !incoming.isLoading, incoming.itemID != nil,
              let endHostTime = player.exactEndHostTime() else { return }
        isGaplessArmed = true
        incoming.volume = 1
        incoming.play(atHostTime: endHostTime)
    }
    private func updateFade() {
        guard crossfadeEnabled, isPlaying, !isLoading, duration > 3,
              preparedURL != nil, !incoming.isLoading, let nextDuration = incoming.playbackDuration else { return }
        let overlap = min(3, nextDuration / 2)
        guard overlap > 0 else { return }
        if fadeStart == nil, duration - elapsed <= overlap, duration > elapsed {
            fadeStart = elapsed; isCrossfading = true; incoming.volume = 0; incoming.play()
        }
        guard let start = fadeStart else { return }
        let fraction = Float(min(1, max(0, (elapsed - start) / max(0.01, duration - start))))
        player.volume = 1 - fraction; incoming.volume = fraction
    }
    private func promoteIncoming() {
        player.clear()
        player = incoming; incoming = StreamingPlaybackDeck(graph: graph)
        player.volume = 1; preparedURL = nil; fadeStart = nil; isCrossfading = false; isGaplessArmed = false
        generation += 1
        elapsed = 0; duration = 0
        bindPlayer(); readCurrentTime(); isLoading = player.isLoading
        if let failure = player.error { error = failure.localizedDescription; pause() }
    }
    @discardableResult func advancePrepared() -> Bool {
        guard let url = preparedURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { return false }
        let continuing = playRequested
        cancelActivation()
        promoteIncoming()
        if continuing { continuePlayback() }
        onAdvanced?()
        return true
    }
    func seek(to seconds: Double, source: SeekSource = .interaction) {
        guard seconds.isFinite, player.itemID != nil else { return }
        cancelFade(); cancelGapless(); elapsed = max(0, seconds); isLoading = true
        player.seek(to: elapsed)
        onStateChange?()
    }
    func replaceResource(url: URL, shouldResume: @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        let token = generation
        let candidate = StreamingPlaybackDeck(graph: graph)
        candidate.load(url: url)
        do { try await candidate.waitUntilReady() }
        catch { candidate.clear(); throw error }
        guard token == generation, !Task.isCancelled else { candidate.clear(); throw CancellationError() }
        player.pause()
        let position = player.currentPlaybackTime ?? elapsed
        cancelActivation(); cancelFade(); cancelGapless(); player.clear()
        generation += 1
        player = candidate; bindPlayer(); elapsed = position
        player.seek(to: position); isLoading = true
        onStateChange?()
        if playRequested && shouldResume() { continuePlayback() } else { pause() }
        try await player.waitUntilReady()
        try Task.checkCancellation()
    }
    func play() {
        reportsActivationFailure = true
        continuePlayback()
    }

    private func continuePlayback() {
        guard player.itemID != nil, error == nil else { return }
        playRequested = true
        if isPlaying {
            player.play()
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
                    self.activationDidFail()
                    return
                }
                self.isPlaying = true
                self.player.play()
                if self.isCrossfading { self.incoming.play() }
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.playRequested else { return }
                self.activation = nil; self.isActivating = false
                self.activationDidFail()
            }
        }
        onStateChange?()
    }

    private func activationDidFail() {
        if reportsActivationFailure { error = "暂时无法播放，请稍后再试" }
        pause()
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
        cancelGapless()
        player.pause(); incoming.pause(); graph.pause(); isPlaying = false
        readCurrentTime()
        onStateChange?()
    }
    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            if !interrupted { resumeAfterInterruption = playRequested }
            interrupted = true
            playRequested = false
            cancelActivation()
            cancelGapless()
            player.pause(); incoming.pause(); graph.pause(); isPlaying = false
            readCurrentTime()
            onStateChange?()
        } else {
            let resume = interrupted && resumeAfterInterruption && shouldResume
            interrupted = false; resumeAfterInterruption = false
            if resume {
                reportsActivationFailure = false
                continuePlayback()
            }
        }
    }


    func stop() {
        generation += 1
        interrupted = false
        pause(); player.clear(); incoming.clear(); graph.stop(); preparedURL = nil
        fadeStart = nil; isCrossfading = false; isGaplessArmed = false; isLoading = false
        elapsed = 0; duration = 0; error = nil
    }
    func shutdown() {
        stop(); clock?.cancel(); clock = nil
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
    }
}
