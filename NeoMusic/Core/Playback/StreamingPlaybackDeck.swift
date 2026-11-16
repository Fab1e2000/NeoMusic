@preconcurrency import AVFoundation
@preconcurrency import AudioStreaming

/// One decoded stream. Seeking stays muted until the requested sample is ready.
@MainActor final class StreamingPlaybackDeck: NSObject, @preconcurrency AudioPlayerDelegate {
    var onChange: (() -> Void)?
    var onEnded: (() -> Void)?
    private(set) var itemID: UUID?
    private(set) var isLoading = false
    private(set) var error: Error?
    private var preparation: Task<Void, Never>?
    private var operationStarted = ProcessInfo.processInfo.systemUptime
    private var operation = "load"
    private var audio: AudioStreaming.AudioPlayer?
    private var localNode: LocalFilePlaybackNode?
    private var source: URL?
    private var initialPosition: Double?
    private var wantsPlayback = false
    private var finishedPosition: Double?
    private var entryID: AudioEntryId?
    private var analyzer = AudioSpectrumAnalyzer()
    private var readiness: [UUID: CheckedContinuation<Void, Error>] = [:]
    var volume: Float = 1 {
        didSet {
            localNode?.volume = volume
            if !isLoading { audio?.volume = volume }
        }
    }
    var rate: Float {
        if let localNode { return wantsPlayback && localNode.isPlaying ? 1 : 0 }
        return wantsPlayback && !isLoading && audio?.state == .playing ? 1 : 0
    }
    var currentPlaybackTime: Double? {
        if let localNode { return localNode.currentTime }
        guard !isLoading else { return nil }
        return finishedPosition ?? audio?.progress
    }
    var playbackDuration: Double? {
        if let localNode { return localNode.duration }
        guard let duration = audio?.duration, duration > 0 else { return nil }
        return duration
    }
    func spectrumLevels() -> [Float] { (0..<5).map { analyzer.level(at: $0) } }
    func load(url: URL, position: Double = 0) {
        clear()
        analyzer = AudioSpectrumAnalyzer()
        source = url; itemID = UUID(); initialPosition = max(0, position); isLoading = true
        operation = "load"; operationStarted = ProcessInfo.processInfo.systemUptime
        PerformanceDiagnostics.restoration("stream.load.request")
        let identity = itemID
        if url.isFileURL {
            preparation = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.itemID == identity else { return }
                self.preparation = nil
                do {
                    let file = try AVAudioFile(forReading: url)
                    let startAt = self.initialPosition ?? 0
                    self.initialPosition = nil
                    let node = LocalFilePlaybackNode(file: file, analyzer: self.analyzer, volume: self.volume, initialPosition: startAt)
                    node.onEnded = { [weak self] in
                        guard let self, self.itemID == identity else { return }
                        self.wantsPlayback = false
                        self.onChange?()
                        self.onEnded?()
                    }
                    self.localNode = node
                    self.isLoading = false
                    if self.wantsPlayback { node.play() }
                    PerformanceDiagnostics.restoration("stream.\(self.operation).ready elapsed_ms=\((ProcessInfo.processInfo.systemUptime - self.operationStarted) * 1000) position=\(node.currentTime ?? 0)")
                    self.finishReadiness(.success(()))
                    self.onChange?()
                } catch {
                    self.error = error
                    self.isLoading = false
                    self.wantsPlayback = false
                    self.finishReadiness(.failure(error))
                    self.onChange?()
                }
            }
            return
        }
        preparation = Task { [weak self] in
            let format = await Self.readFormat(url: url)
            guard !Task.isCancelled, let self, self.itemID == identity else { return }
            self.preparation = nil
            let player = AudioStreaming.AudioPlayer(configuration: AudioPlayerConfiguration(
                bufferSizeInSeconds: 8, secondsRequiredToStartPlaying: 0.15, gracePeriodAfterSeekInSeconds: 0.02), outputFormat: format)
            self.audio = player; player.volume = 0; player.delegate = self
            let analyzer = self.analyzer
            player.frameFiltering.add(entry: "neomusic.spectrum", filter: Self.spectrumCallback(analyzer))
            player.play(url: url)
        }
    }
    // AudioStreaming invokes this on its audio tap queue, outside MainActor.
    nonisolated private static func spectrumCallback(_ analyzer: AudioSpectrumAnalyzer) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in analyzer.consume(buffer) }
    }
    @concurrent private static func readFormat(url: URL) async -> AVAudioFormat? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        return (try? AVAudioFile(forReading: url))?.processingFormat
    }
    func play() {
        wantsPlayback = true
        if let localNode {
            localNode.play()
            onChange?()
            return
        }
        audio?.resumeAfterSeek = true
        if audio?.state == .stopped { seek(to: 0) }
        audio?.resume()
    }
    func pause() {
        wantsPlayback = false
        if let localNode {
            localNode.pause()
            onChange?()
            return
        }
        audio?.resumeAfterSeek = false
        if !isLoading { audio?.pause() }
    }
    func seek(to seconds: Double) {
        guard itemID != nil else { return }
        operation = "seek"; operationStarted = ProcessInfo.processInfo.systemUptime
        PerformanceDiagnostics.restoration("stream.seek.request target=\(seconds)")
        if let localNode {
            localNode.seek(to: seconds)
            PerformanceDiagnostics.restoration("stream.seek.ready elapsed_ms=\((ProcessInfo.processInfo.systemUptime - operationStarted) * 1000) position=\(localNode.currentTime ?? 0)")
            onChange?()
            return
        }
        guard let audio else { initialPosition = seconds; return }
        finishedPosition = nil; isLoading = true; audio.volume = 0
        if initialPosition != nil { initialPosition = seconds }
        else if audio.state == .stopped, let source { initialPosition = seconds; audio.play(url: source) }
        else { audio.seek(to: seconds, resumeAfterSeek: wantsPlayback); audio.resume() }
    }
    func clear() {
        preparation?.cancel(); preparation = nil
        finishReadiness(.failure(CancellationError()))
        localNode?.stopAndClean(); localNode = nil
        audio?.delegate = nil; audio?.stop(); audio = nil
        itemID = nil; source = nil; initialPosition = nil; finishedPosition = nil
        entryID = nil; wantsPlayback = false; isLoading = false; error = nil
    }
    func waitUntilReady() async throws {
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if let error { continuation.resume(throwing: error) }
                else if !isLoading { continuation.resume() }
                else { readiness[waiter] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.readiness.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
            }
        }
    }
    private func finishReadiness(_ result: Result<Void, Error>) {
        let pending = readiness.values
        readiness.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }
    func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        guard player === audio else { return }
        entryID = entryId
        if let position = initialPosition { initialPosition = nil; player.seek(to: position, resumeAfterSeek: wantsPlayback) }
    }
    func audioPlayerStateChanged(player: AudioStreaming.AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        guard player === audio else { return }
        switch newState {
        case .playing:
            guard initialPosition == nil, !player.isSeeking, player.state == .playing else { return }
            let wasLoading = isLoading
            isLoading = false
            if wasLoading {
                PerformanceDiagnostics.restoration("stream.\(operation).ready elapsed_ms=\((ProcessInfo.processInfo.systemUptime - operationStarted) * 1000) position=\(player.progress)")
            }
            if !wantsPlayback { player.pause() }
            player.volume = volume
            finishReadiness(.success(()))
        case .paused:
            if initialPosition == nil, !player.isSeeking {
                isLoading = false
                player.volume = volume
                finishReadiness(.success(()))
            }
        case .bufferring, .running: isLoading = true
        default: break
        }
        onChange?()
    }
    func audioPlayerDidFinishPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        guard player === audio, self.entryID == entryId, stopReason == .eof else { return }
        finishedPosition = progress; isLoading = false; wantsPlayback = false
        finishReadiness(.success(()))
        onChange?(); onEnded?()
    }
    func audioPlayerUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        guard player === audio else { return }
        self.error = error; isLoading = false; wantsPlayback = false
        finishReadiness(.failure(error))
        onChange?()
    }
    func audioPlayerDidFinishBuffering(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {}
    func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String: String]) {}
}
