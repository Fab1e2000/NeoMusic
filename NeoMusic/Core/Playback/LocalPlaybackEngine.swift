import AVFoundation
import Observation

struct PlaybackTimelineAnchor: Equatable, Sendable {
    let baseElapsed: Double
    let hostTimestamp: TimeInterval
    let rate: Double
    let duration: Double

    init(
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

    static let zero = PlaybackTimelineAnchor(baseElapsed: 0, hostTimestamp: 0, rate: 0, duration: 0)

    func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard rate > 0 else { return clamped(baseElapsed) }
        let delta = max(0, uptime - hostTimestamp)
        return clamped(baseElapsed + delta * rate)
    }

    private func clamped(_ value: Double) -> Double {
        let safe = value.isFinite ? max(0, value) : 0
        return duration > 0 ? min(safe, duration) : safe
    }
}

private struct PlaybackBackendSnapshot: Sendable {
    let generation: Int
    let sequence: UInt64
    let isLoading: Bool
    let isCrossfading: Bool
    let elapsed: Double?
    let duration: Double?
    let isAdvancing: Bool
    let error: String?
    let hostTimestamp: TimeInterval
}

@PlaybackAudioActor
private final class PlaybackAudioBackend {
    nonisolated let graph = SharedAudioGraph()
    private(set) var player: StreamingPlaybackDeck!
    private var incoming: StreamingPlaybackDeck!
    private var preparedURL: URL?
    private var crossfadeEnabled = false
    private var fadeStart: Double?
    private(set) var isCrossfading = false
    private var isGaplessArmed = false
    private var isPlaying = false
    private var generation = 0
    private var latestSequence: UInt64 = 0
    private var lastAnchorElapsed: Double = 0
    private var lastAnchorTimestamp: TimeInterval = 0
    private var lastAnchorRate: Double = 0
    private var monitorTask: Task<Void, Never>?

    var onSnapshot: (@Sendable (PlaybackBackendSnapshot) -> Void)?
    var onAdvanced: (@Sendable (Int, Int, PlaybackBackendSnapshot) -> Void)?
    var onFinished: (@Sendable (Int, PlaybackBackendSnapshot) -> Void)?

    nonisolated init() {}

    func bootstrap(
        onSnapshot: @escaping @Sendable (PlaybackBackendSnapshot) -> Void,
        onAdvanced: @escaping @Sendable (Int, Int, PlaybackBackendSnapshot) -> Void,
        onFinished: @escaping @Sendable (Int, PlaybackBackendSnapshot) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onAdvanced = onAdvanced
        self.onFinished = onFinished
        self.player = StreamingPlaybackDeck(graph: graph)
        self.incoming = StreamingPlaybackDeck(graph: graph)
        bindPlayer()
    }

    private func bindPlayer() {
        let observed = player
        player.onChange = { [weak self, weak observed] in
            guard let self, self.player === observed else { return }
            if self.player.error != nil {
                self.isPlaying = false
                self.player.pause()
                self.incoming.pause()
                self.graph.pause()
                self.stopMonitor()
            }
            self.emitSnapshot(force: true)
            self.updateMonitorSchedule()
        }
        player.onEnded = { [weak self, weak observed] in
            guard let self, self.player === observed else { return }
            let previousGen = self.generation
            if self.isCrossfading, !self.incoming.isLoading {
                self.generation += 1
                self.promoteIncomingInternal()
                let snapshot = self.makeSnapshot()
                self.onAdvanced?(previousGen, self.generation, snapshot)
            } else if self.isGaplessArmed, !self.incoming.isLoading {
                self.generation += 1
                self.incoming.play(atHostTime: nil)
                self.promoteIncomingInternal()
                let snapshot = self.makeSnapshot()
                self.onAdvanced?(previousGen, self.generation, snapshot)
            } else if self.preparedURL != nil {
                let continuing = self.isPlaying
                self.generation += 1
                self.promoteIncomingInternal()
                if continuing {
                    self.isPlaying = true
                    self.player.play()
                    self.updateMonitorSchedule()
                }
                let snapshot = self.makeSnapshot()
                self.onAdvanced?(previousGen, self.generation, snapshot)
            } else {
                self.isPlaying = false
                self.cancelGapless()
                self.player.pause()
                self.incoming.pause()
                self.graph.pause()
                self.stopMonitor()
                let snapshot = self.makeSnapshot()
                self.onFinished?(self.generation, snapshot)
            }
        }
    }

    func load(url: URL, nextURL: URL?, position: Double, generation: Int, sequence: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        self.latestSequence = sequence
        stopInternal(resetGeneration: false)
        player.load(url: url, position: max(0, position))
        prepareNextInternal(url: nextURL)
        emitSnapshot(force: true)
    }

    func prepareNext(url: URL?, generation: Int, sequence: UInt64) {
        guard generation == self.generation else { return }
        latestSequence = max(latestSequence, sequence)
        prepareNextInternal(url: url)
        updateMonitorSchedule()
        emitSnapshot(force: false)
    }

    private func prepareNextInternal(url: URL?) {
        cancelFade()
        cancelGapless()
        preparedURL = url
        incoming.clear()
        if let url, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
            incoming.load(url: url)
        }
    }

    func setCrossfadeEnabled(_ enabled: Bool, sequence: UInt64) {
        latestSequence = max(latestSequence, sequence)
        crossfadeEnabled = enabled
        if !enabled {
            cancelFade()
        } else {
            cancelGapless()
        }
        updateMonitorSchedule()
        emitSnapshot(force: true)
    }

    func play(generation: Int, sequence: UInt64) {
        guard generation == self.generation, player.itemID != nil, player.error == nil else { return }
        latestSequence = max(latestSequence, sequence)
        isPlaying = true
        player.play()
        if isCrossfading { incoming.play() }
        updateMonitorSchedule()
        emitSnapshot(force: true)
    }

    func pause(generation: Int, sequence: UInt64) {
        guard generation == self.generation else { return }
        latestSequence = max(latestSequence, sequence)
        isPlaying = false
        cancelGapless()
        player.pause()
        incoming.pause()
        graph.pause()
        stopMonitor()
        emitSnapshot(force: true)
    }

    func seek(to seconds: Double, generation: Int, sequence: UInt64) {
        guard generation == self.generation, player.itemID != nil else { return }
        latestSequence = max(latestSequence, sequence)
        cancelFade()
        cancelGapless()
        player.seek(to: max(0, seconds))
        updateMonitorSchedule()
        emitSnapshot(force: true)
    }

    func stop(generation: Int, sequence: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        latestSequence = sequence
        stopInternal(resetGeneration: false)
    }

    private func stopInternal(resetGeneration: Bool) {
        if resetGeneration { generation += 1 }
        isPlaying = false
        stopMonitor()
        cancelGapless()
        player.pause()
        incoming.pause()
        player.clear()
        incoming.clear()
        graph.stop()
        preparedURL = nil
        fadeStart = nil
        isCrossfading = false
        isGaplessArmed = false
    }

    func shutdown() {
        stopInternal(resetGeneration: true)
        onSnapshot = nil
        onAdvanced = nil
        onFinished = nil
    }

    func advancePrepared(expectedGeneration: Int, nextGeneration: Int, shouldContinuePlaying: Bool, sequence: UInt64) -> Bool {
        guard expectedGeneration == self.generation,
              let url = preparedURL,
              !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        self.generation = nextGeneration
        latestSequence = sequence
        promoteIncomingInternal()
        if shouldContinuePlaying {
            isPlaying = true
            player.play()
        } else {
            isPlaying = false
        }
        updateMonitorSchedule()
        emitSnapshot(force: true)
        return true
    }

    func replaceResource(
        url: URL,
        expectedGeneration: Int,
        nextGeneration: Int,
        sequence: UInt64,
        fallbackElapsed: Double,
        onSwapped: @escaping @MainActor @Sendable (Double) -> Bool
    ) async throws -> PlaybackBackendSnapshot {
        try Task.checkCancellation()
        let candidate = StreamingPlaybackDeck(graph: graph)
        candidate.load(url: url)
        do {
            try await candidate.waitUntilReady()
        } catch {
            candidate.clear()
            throw error
        }
        guard expectedGeneration == self.generation, !Task.isCancelled else {
            candidate.clear()
            throw CancellationError()
        }
        player.pause()
        let nativePosition = player.currentPlaybackTime
        let position: Double = if !isPlaying, let nativePosition, abs(nativePosition - fallbackElapsed) < 0.05 {
            fallbackElapsed
        } else {
            nativePosition ?? fallbackElapsed
        }
        cancelFade()
        cancelGapless()
        player.clear()
        self.generation = nextGeneration
        latestSequence = max(latestSequence, sequence)
        player = candidate
        bindPlayer()
        player.seek(to: position)

        let resume = await onSwapped(position)
        guard self.generation == nextGeneration, player === candidate, !Task.isCancelled else {
            throw CancellationError()
        }
        if resume {
            isPlaying = true
            player.play()
        } else {
            isPlaying = false
            player.pause()
            graph.pause()
        }
        updateMonitorSchedule()
        try await candidate.waitUntilReady()
        try Task.checkCancellation()
        guard self.generation == nextGeneration, player === candidate else { throw CancellationError() }
        let finalSnapshot = makeSnapshot()
        onSnapshot?(finalSnapshot)
        return finalSnapshot
    }

    private func promoteIncomingInternal() {
        player.clear()
        player = incoming
        incoming = StreamingPlaybackDeck(graph: graph)
        player.volume = 1
        preparedURL = nil
        fadeStart = nil
        isCrossfading = false
        isGaplessArmed = false
        bindPlayer()
        if player.error != nil {
            isPlaying = false
            player.pause()
            graph.pause()
            stopMonitor()
        }
    }

    private func cancelFade() {
        incoming.pause()
        if isCrossfading { incoming.seek(to: 0) }
        player.volume = 1
        incoming.volume = 0
        fadeStart = nil
        isCrossfading = false
    }

    private func cancelGapless() {
        guard isGaplessArmed else { return }
        incoming.pause()
        incoming.seek(to: 0)
        isGaplessArmed = false
    }

    private func updateMonitorSchedule() {
        guard isPlaying else {
            stopMonitor()
            return
        }
        guard monitorTask == nil else { return }
        monitorTask = Task { @PlaybackAudioActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                let interval = self.backgroundMonitorStep()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            if !Task.isCancelled { self?.monitorTask = nil }
        }
    }

    private func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func backgroundMonitorStep() -> Duration {
        let wasCrossfading = isCrossfading
        updateFade()
        updateGapless()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = player.currentPlaybackTime
        let duration = player.playbackDuration

        var needsPublish = wasCrossfading != isCrossfading
        if !needsPublish, let elapsed, isPlaying, !player.isLoading {
            let predicted = lastAnchorRate > 0
                ? lastAnchorElapsed + max(0, now - lastAnchorTimestamp) * lastAnchorRate
                : lastAnchorElapsed
            let drift = abs(elapsed - predicted)
            let sinceLastSync = now - lastAnchorTimestamp
            if drift > 0.35 || sinceLastSync >= 5.0 {
                needsPublish = true
            }
        }
        if needsPublish {
            emitSnapshot(force: true)
        }

        if isCrossfading {
            return .milliseconds(33)
        }
        if preparedURL != nil, let elapsed, let duration, duration > 0 {
            let remaining = duration - elapsed
            if remaining <= 4.5 {
                return .milliseconds(40)
            }
        }
        return .milliseconds(250)
    }

    private func updateGapless() {
        guard !crossfadeEnabled, !isGaplessArmed, isPlaying, !player.isLoading,
              let elapsed = player.currentPlaybackTime,
              let duration = player.playbackDuration,
              duration > 0, duration - elapsed <= 1.5,
              let url = preparedURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path),
              !incoming.isLoading, incoming.itemID != nil,
              let endHostTime = player.exactEndHostTime() else { return }
        isGaplessArmed = true
        incoming.volume = 1
        incoming.play(atHostTime: endHostTime)
    }

    private func updateFade() {
        guard crossfadeEnabled, isPlaying, !player.isLoading,
              let elapsed = player.currentPlaybackTime,
              let duration = player.playbackDuration,
              duration > 3,
              preparedURL != nil, !incoming.isLoading,
              let nextDuration = incoming.playbackDuration else { return }
        let overlap = min(3, nextDuration / 2)
        guard overlap > 0 else { return }
        if fadeStart == nil, duration - elapsed <= overlap, duration > elapsed {
            fadeStart = elapsed
            isCrossfading = true
            incoming.volume = 0
            incoming.play()
        }
        guard let start = fadeStart else { return }
        let fraction = Float(min(1, max(0, (elapsed - start) / max(0.01, duration - start))))
        player.volume = 1 - fraction
        incoming.volume = fraction
    }

    private func makeSnapshot() -> PlaybackBackendSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = player.currentPlaybackTime
        let duration = player.playbackDuration
        let advancing = isPlaying && !player.isLoading && player.error == nil
        if let elapsed {
            lastAnchorElapsed = elapsed
            lastAnchorTimestamp = now
            lastAnchorRate = advancing ? 1.0 : 0.0
        }
        return PlaybackBackendSnapshot(
            generation: generation,
            sequence: latestSequence,
            isLoading: player.isLoading,
            isCrossfading: isCrossfading,
            elapsed: elapsed,
            duration: duration,
            isAdvancing: advancing,
            error: player.error?.localizedDescription,
            hostTimestamp: now
        )
    }

    private func emitSnapshot(force: Bool) {
        guard force || isCrossfading else { return }
        onSnapshot?(makeSnapshot())
    }

    func debugState(prepared: Bool = false) -> (deckID: ObjectIdentifier, itemID: UUID?, currentPlaybackTime: Double?, rate: Float) {
        let deck = prepared ? incoming! : player!
        return (ObjectIdentifier(deck), deck.itemID, deck.currentPlaybackTime, deck.rate)
    }
}

@MainActor @Observable final class LocalPlaybackEngine {
    private(set) var isPlaying = false
    private(set) var isActivating = false
    private(set) var isLoading = false
    private(set) var duration: Double = 0
    private(set) var error: String?
    private(set) var isCrossfading = false
    private(set) var timelineAnchor: PlaybackTimelineAnchor = .zero

    var elapsed: Double {
        timelineAnchor.elapsed()
    }

    var crossfadeEnabled = false {
        didSet {
            guard oldValue != crossfadeEnabled else { return }
            if !crossfadeEnabled { isCrossfading = false }
            let enabled = crossfadeEnabled
            let seq = commandSequence
            enqueueBackend { backend in
                backend.setCrossfadeEnabled(enabled, sequence: seq)
            }
        }
    }

    @ObservationIgnored private let backend: PlaybackAudioBackend
    @ObservationIgnored private var backendReadyTask: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private let activateSession: @Sendable () async throws -> Bool
    @ObservationIgnored private(set) var activation: Task<Void, Never>?
    @ObservationIgnored private var playRequested = false
    // Only accepted backend snapshots can confirm playback, after loading and activation.
    @ObservationIgnored private(set) var isPlaybackConfirmed = false
    @ObservationIgnored private var reportsActivationFailure = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var commandSequence: UInt64 = 0
    @ObservationIgnored private var hasLoadedItem = false
    @ObservationIgnored private var preparedURL: URL?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored var onAdvanced: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onTimeChange: (() -> Void)?
    enum SeekSource: String, Sendable { case interaction, remote, previous, load, restore, resource }

    init(activateSession: @escaping @Sendable () async throws -> Bool = LocalPlaybackEngine.activateAudioSession) {
        self.activateSession = activateSession
        let createdBackend = PlaybackAudioBackend()
        self.backend = createdBackend
        self.backendReadyTask = Task { @PlaybackAudioActor [weak self, createdBackend] in
            createdBackend.bootstrap(
                onSnapshot: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.apply(snapshot: snapshot)
                    }
                },
                onAdvanced: { [weak self] previousGeneration, nextGeneration, snapshot in
                    Task { @MainActor [weak self] in
                        self?.handleBackendAdvanced(previousGeneration: previousGeneration, nextGeneration: nextGeneration, snapshot: snapshot)
                    }
                },
                onFinished: { [weak self] backendGeneration, snapshot in
                    Task { @MainActor [weak self] in
                        self?.handleBackendFinished(backendGeneration: backendGeneration, snapshot: snapshot)
                    }
                }
            )
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

    private func nextSequence() -> UInt64 {
        commandSequence &+= 1
        return commandSequence
    }

    private func enqueueBackend(_ operation: @escaping @PlaybackAudioActor @Sendable (PlaybackAudioBackend) -> Void) {
        let previous = backendReadyTask
        let backend = self.backend
        backendReadyTask = Task { @PlaybackAudioActor in
            await previous?.value
            operation(backend)
        }
    }

    private func updateAnchor(baseElapsed: Double, rate: Double, duration: Double? = nil, hostTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let resolvedDuration = duration ?? self.duration
        if resolvedDuration != self.duration {
            self.duration = resolvedDuration
        }
        let next = PlaybackTimelineAnchor(
            baseElapsed: max(0, baseElapsed),
            hostTimestamp: hostTimestamp,
            rate: rate,
            duration: resolvedDuration
        )
        if next != timelineAnchor {
            timelineAnchor = next
        }
    }

    private func apply(snapshot: PlaybackBackendSnapshot) {
        guard snapshot.generation == generation else { return }
        if snapshot.sequence < commandSequence { return }

        let previousDuration = duration
        let previousLoading = isLoading
        let previousCrossfading = isCrossfading
        let previousError = error

        isLoading = snapshot.isLoading
        isCrossfading = snapshot.isCrossfading
        if let newDuration = snapshot.duration, newDuration.isFinite {
            duration = max(0, newDuration)
        }
        if let failure = snapshot.error {
            error = failure
            isPlaying = false
            playRequested = false
            cancelActivation()
        }
        let rawElapsed = snapshot.elapsed ?? timelineAnchor.elapsed(at: snapshot.hostTimestamp)
        let rate: Double = (isPlaying && !isLoading && error == nil && snapshot.isAdvancing) ? 1.0 : 0.0
        isPlaybackConfirmed = rate > 0
        let resolvedElapsed: Double = if rate == 0, !previousLoading, !isLoading,
                                         timelineAnchor.rate == 0,
                                         abs(rawElapsed - timelineAnchor.baseElapsed) < 0.05 {
            timelineAnchor.baseElapsed
        } else {
            rawElapsed
        }
        updateAnchor(
            baseElapsed: resolvedElapsed,
            rate: rate,
            duration: duration,
            hostTimestamp: snapshot.hostTimestamp
        )

        if previousDuration != duration || previousLoading != isLoading || previousCrossfading != isCrossfading || previousError != error {
            onStateChange?()
        } else {
            onTimeChange?()
        }
    }

    private func handleBackendAdvanced(previousGeneration: Int, nextGeneration: Int, snapshot: PlaybackBackendSnapshot) {
        guard previousGeneration == generation else { return }
        generation = nextGeneration
        preparedURL = nil
        isCrossfading = false
        isLoading = snapshot.isLoading
        duration = snapshot.duration ?? 0
        if let failure = snapshot.error {
            error = failure
            isPlaying = false
            playRequested = false
        }
        let resolvedElapsed = snapshot.elapsed ?? 0
        let rate: Double = (isPlaying && !isLoading && error == nil && snapshot.isAdvancing) ? 1.0 : 0.0
        isPlaybackConfirmed = rate > 0
        updateAnchor(baseElapsed: resolvedElapsed, rate: rate, duration: duration, hostTimestamp: snapshot.hostTimestamp)
        onAdvanced?()
    }

    private func handleBackendFinished(backendGeneration: Int, snapshot: PlaybackBackendSnapshot) {
        guard backendGeneration == generation else { return }
        resumeAfterInterruption = false
        playRequested = false
        cancelActivation()
        isPlaying = false
        isPlaybackConfirmed = false
        isCrossfading = false
        isLoading = false
        if let newDuration = snapshot.duration, newDuration.isFinite {
            duration = max(0, newDuration)
        }
        let finalElapsed = snapshot.elapsed ?? duration
        updateAnchor(baseElapsed: finalElapsed, rate: 0, duration: duration, hostTimestamp: snapshot.hostTimestamp)
        onStateChange?()
        onFinished?()
    }

    var spectrumAnalyzer: ThreadSafeSpectrumAnalyzer { backend.graph.analyzer }

    func spectrumLevels() -> [Float] {
        guard isPlaying, !isLoading, error == nil else { return Array(repeating: 0, count: 5) }
        return backend.graph.spectrumLevels()
    }

    func load(url: URL, nextURL: URL? = nil, position: Double = 0, autoplay: Bool = false) {
        stop()
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            error = "音乐文件不可用"
            return
        }
        hasLoadedItem = true
        let startPosition = max(0, position)
        isLoading = true
        preparedURL = nextURL
        updateAnchor(baseElapsed: startPosition, rate: 0, duration: 0)
        let gen = generation
        let seq = nextSequence()
        enqueueBackend { backend in
            backend.load(url: url, nextURL: nextURL, position: startPosition, generation: gen, sequence: seq)
        }
        if autoplay { play() }
    }

    func prepareNext(url: URL?) {
        isCrossfading = false
        preparedURL = url
        let gen = generation
        let seq = commandSequence
        enqueueBackend { backend in
            backend.prepareNext(url: url, generation: gen, sequence: seq)
        }
    }

    @discardableResult func advancePrepared() -> Bool {
        guard let url = preparedURL, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let continuing = playRequested
        let expectedGen = generation
        generation += 1
        isPlaybackConfirmed = false
        let nextGen = generation
        cancelActivation()
        preparedURL = nil
        isCrossfading = false
        isLoading = true
        duration = 0
        error = nil
        updateAnchor(baseElapsed: 0, rate: 0, duration: 0)
        let seq = nextSequence()
        enqueueBackend { backend in
            _ = backend.advancePrepared(
                expectedGeneration: expectedGen,
                nextGeneration: nextGen,
                shouldContinuePlaying: false,
                sequence: seq
            )
        }
        if continuing {
            isPlaying = false
            continuePlayback()
        }
        onAdvanced?()
        return true
    }

    func seek(to seconds: Double, source: SeekSource = .interaction) {
        guard seconds.isFinite, hasLoadedItem else { return }
        let target = max(0, seconds)
        isCrossfading = false
        isLoading = true
        updateAnchor(baseElapsed: target, rate: 0, duration: duration)
        let gen = generation
        let seq = nextSequence()
        enqueueBackend { backend in
            backend.seek(to: target, generation: gen, sequence: seq)
        }
        onStateChange?()
    }

    func replaceResource(url: URL, shouldResume: @escaping @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        let expectedGen = generation
        let nextGen = generation + 1
        let fallbackElapsed = elapsed
        let seq = nextSequence()
        let previous = backendReadyTask
        let backend = self.backend

        await previous?.value
        try Task.checkCancellation()
        guard expectedGen == generation else { throw CancellationError() }

        let swappedHandler: @MainActor @Sendable (Double) -> Bool = { [weak self] position in
            guard let self, self.generation == expectedGen else { return false }
            let wantResume = self.playRequested && shouldResume()
            self.generation = nextGen
            self.isPlaybackConfirmed = false
            self.cancelActivation()
            self.isCrossfading = false
            self.isLoading = true
            self.updateAnchor(baseElapsed: position, rate: 0, duration: self.duration)
            self.onStateChange?()
            if wantResume {
                self.isPlaying = false
                self.continuePlayback()
            } else {
                self.pause()
            }
            return wantResume && self.isPlaying
        }

        let finalSnapshot = try await backend.replaceResource(
            url: url,
            expectedGeneration: expectedGen,
            nextGeneration: nextGen,
            sequence: seq,
            fallbackElapsed: fallbackElapsed,
            onSwapped: swappedHandler
        )

        try Task.checkCancellation()
        if generation == nextGen {
            apply(snapshot: finalSnapshot)
        }
    }

    func play() {
        reportsActivationFailure = true
        continuePlayback()
    }

    private func continuePlayback() {
        guard hasLoadedItem, error == nil else { return }
        playRequested = true
        if isPlaying {
            let gen = generation
            let seq = nextSequence()
            if !isLoading {
                updateAnchor(baseElapsed: elapsed, rate: 1.0, duration: duration)
            }
            enqueueBackend { backend in
                backend.play(generation: gen, sequence: seq)
            }
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
                self.activation = nil
                self.isActivating = false
                guard activated else {
                    self.activationDidFail()
                    return
                }
                self.isPlaying = true
                if !self.isLoading {
                    self.updateAnchor(baseElapsed: self.elapsed, rate: 1.0, duration: self.duration)
                }
                let seq = self.nextSequence()
                self.enqueueBackend { backend in
                    backend.play(generation: token, sequence: seq)
                }
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.playRequested else { return }
                self.activation = nil
                self.isActivating = false
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
        activation?.cancel()
        activation = nil
        isActivating = false
    }

    func pause() {
        resumeAfterInterruption = false
        playRequested = false
        cancelActivation()
        let frozenElapsed = elapsed
        isPlaying = false
        isPlaybackConfirmed = false
        updateAnchor(baseElapsed: frozenElapsed, rate: 0, duration: duration)
        let gen = generation
        let seq = nextSequence()
        enqueueBackend { backend in
            backend.pause(generation: gen, sequence: seq)
        }
        onStateChange?()
    }

    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            if !interrupted { resumeAfterInterruption = playRequested }
            interrupted = true
            playRequested = false
            cancelActivation()
            let frozenElapsed = elapsed
            isPlaying = false
            isPlaybackConfirmed = false
            updateAnchor(baseElapsed: frozenElapsed, rate: 0, duration: duration)
            let gen = generation
            let seq = nextSequence()
            enqueueBackend { backend in
                backend.pause(generation: gen, sequence: seq)
            }
            onStateChange?()
        } else {
            let resume = interrupted && resumeAfterInterruption && shouldResume
            interrupted = false
            resumeAfterInterruption = false
            if resume {
                reportsActivationFailure = false
                continuePlayback()
            }
        }
    }

    func stop() {
        generation += 1
        interrupted = false
        resumeAfterInterruption = false
        playRequested = false
        cancelActivation()
        hasLoadedItem = false
        preparedURL = nil
        isPlaying = false
        isPlaybackConfirmed = false
        isCrossfading = false
        isLoading = false
        duration = 0
        error = nil
        timelineAnchor = .zero
        let gen = generation
        let seq = nextSequence()
        enqueueBackend { backend in
            backend.stop(generation: gen, sequence: seq)
        }
        onStateChange?()
    }

    func shutdown() {
        stop()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        enqueueBackend { backend in
            backend.shutdown()
        }
    }

    func debugBackendState(prepared: Bool = false) async -> (deckID: ObjectIdentifier, itemID: UUID?, currentPlaybackTime: Double?, rate: Float) {
        await backendReadyTask?.value
        let backend = self.backend
        return await Task { @PlaybackAudioActor in
            backend.debugState(prepared: prepared)
        }.value
    }
}
