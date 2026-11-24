import AVFoundation

struct PlaybackBackendSnapshot: Sendable {
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
final class PlaybackAudioBackend {
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
