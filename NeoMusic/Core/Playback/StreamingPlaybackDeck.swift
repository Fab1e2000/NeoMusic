@preconcurrency import AVFoundation
@preconcurrency import AudioStreaming

/// One decoded stream. Seeking stays muted until the requested sample is ready.
@MainActor final class StreamingPlaybackDeck: NSObject, @preconcurrency AudioPlayerDelegate {
    var onChange: (() -> Void)?
    var onEnded: (() -> Void)?
    private(set) var itemID: UUID?
    private(set) var isLoading = false
    private(set) var error: Error?
    private let graph: SharedAudioGraph
    private var preparation: Task<Void, Never>?
    private var operationStarted = ProcessInfo.processInfo.systemUptime
    private var operation = "load"
    private var audio: AudioStreaming.AudioPlayer?
    private var sourceNode: AVAudioSourceNode?
    private var renderGate: StreamRenderGate?
    private var localNode: LocalFilePlaybackNode?
    private var source: URL?
    private var initialPosition: Double?
    private var wantsPlayback = false
    private var finishedPosition: Double?
    private var entryID: AudioEntryId?
    private var readiness: [UUID: CheckedContinuation<Void, Error>] = [:]
    var volume: Float = 1 {
        didSet {
            localNode?.volume = volume
            sourceNode?.volume = volume
        }
    }

    init(graph: SharedAudioGraph = SharedAudioGraph()) {
        self.graph = graph
        super.init()
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
    func spectrumLevels() -> [Float] { graph.spectrumLevels() }

    func exactEndHostTime() -> UInt64? {
        if let localNode { return localNode.exactEndHostTime() }
        guard rate > 0, let pos = currentPlaybackTime, let dur = playbackDuration,
              dur > pos, let anchor = graph.currentHostTime else { return nil }
        return anchor + AVAudioTime.hostTime(forSeconds: dur - pos)
    }

    func load(url: URL, position: Double = 0) {
        clear()
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
                    let node = LocalFilePlaybackNode(file: file, graph: self.graph, volume: self.volume, initialPosition: startAt)
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
            let player = AudioStreaming.AudioPlayer(
                configuration: AudioPlayerConfiguration(
                    bufferSizeInSeconds: 8,
                    secondsRequiredToStartPlaying: 0.15,
                    gracePeriodAfterSeekInSeconds: 0.02
                ),
                outputFormat: format,
                externalRenderOutput: true
            )
            let renderFormat = player.renderAudioFormat
            let gate = StreamRenderGate(player: player, format: renderFormat)
            let node = AVAudioSourceNode(format: renderFormat) { _, timestamp, frameCount, outputData in
                gate.render(timestamp: timestamp, frameCount: frameCount, outputData: outputData)
            }
            node.volume = self.volume
            self.graph.attach(node, format: renderFormat)
            self.sourceNode = node
            self.renderGate = gate
            self.audio = player
            player.volume = 1
            player.delegate = self
            if self.wantsPlayback {
                gate.activate(startHostTime: 0)
                try? self.graph.startIfNeeded()
            }
            player.play(url: url)
        }
    }
    @concurrent private static func readFormat(url: URL) async -> AVAudioFormat? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        return (try? AVAudioFile(forReading: url))?.processingFormat
    }
    func play(atHostTime hostTime: UInt64? = nil) {
        wantsPlayback = true
        if let localNode {
            localNode.play(atHostTime: hostTime)
            onChange?()
            return
        }
        renderGate?.activate(startHostTime: hostTime ?? 0)
        try? graph.startIfNeeded()
        audio?.resumeAfterSeek = true
        if audio?.state == .stopped { seek(to: 0) }
        audio?.resume()
    }
    func pause() {
        wantsPlayback = false
        renderGate?.deactivate()
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
        renderGate?.detach(); renderGate = nil
        if let sourceNode {
            graph.detach(sourceNode)
            self.sourceNode = nil
        }
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
            if !wantsPlayback {
                renderGate?.deactivate()
                player.pause()
            } else {
                renderGate?.activate(startHostTime: 0)
            }
            player.volume = 1
            sourceNode?.volume = volume
            finishReadiness(.success(()))
        case .paused:
            if initialPosition == nil, !player.isSeeking {
                isLoading = false
                player.volume = 1
                sourceNode?.volume = volume
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

/// Real-time audio thread gate for pulling `AudioStreaming` frames at an exact `hostTime`.
private final class StreamRenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AudioStreaming.AudioPlayer?
    private var isActive = false
    private var startHostTime: UInt64 = 0
    private let sampleRate: Double
    private let bytesPerFrame: Int

    init(player: AudioStreaming.AudioPlayer, format: AVAudioFormat) {
        self.player = player
        self.sampleRate = max(1, format.sampleRate)
        self.bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
    }

    func activate(startHostTime: UInt64) {
        lock.lock()
        isActive = true
        self.startHostTime = startHostTime
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        isActive = false
        startHostTime = 0
        lock.unlock()
    }

    func detach() {
        lock.lock()
        isActive = false
        startHostTime = 0
        player = nil
        lock.unlock()
    }

    func render(
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for index in 0..<buffers.count {
            if let data = buffers[index].mData {
                memset(data, 0, Int(buffers[index].mDataByteSize))
            }
        }

        lock.lock()
        let activePlayer = player
        let active = isActive
        let targetHostTime = startHostTime
        lock.unlock()
        guard active, let activePlayer else { return noErr }

        if targetHostTime > 0 {
            let sliceStart = timestamp.pointee.mHostTime
            let sliceDuration = AVAudioTime.hostTime(forSeconds: Double(frameCount) / sampleRate)
            if sliceStart + sliceDuration <= targetHostTime {
                return noErr
            }
            lock.lock()
            startHostTime = 0
            lock.unlock()
            if sliceStart < targetHostTime, buffers.count == 1, let baseData = buffers[0].mData {
                let delaySeconds = AVAudioTime.seconds(forHostTime: targetHostTime - sliceStart)
                let skipFrames = min(frameCount, AVAudioFrameCount((delaySeconds * sampleRate).rounded()))
                let renderFrames = frameCount - skipFrames
                guard renderFrames > 0 else { return noErr }
                let byteOffset = Int(skipFrames) * bytesPerFrame
                var offsetBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: buffers[0].mNumberChannels,
                        mDataByteSize: UInt32(Int(renderFrames) * bytesPerFrame),
                        mData: baseData.advanced(by: byteOffset)
                    )
                )
                return activePlayer.renderExternal(inNumberFrames: renderFrames, ioData: &offsetBufferList)
            }
        }

        return activePlayer.renderExternal(inNumberFrames: frameCount, ioData: outputData)
    }
}
