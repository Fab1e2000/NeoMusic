@preconcurrency import AVFoundation
@preconcurrency import AudioStreaming

@PlaybackAudioActor final class StreamingPlaybackDeck: NSObject, @preconcurrency AudioPlayerDelegate {
    var onChange: (() -> Void)?
    var onEnded: (() -> Void)?
    private(set) var itemID: UUID?
    private(set) var isLoading = false
    private(set) var error: Error?
    private nonisolated let graph: SharedAudioGraph
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
    nonisolated func spectrumLevels() -> [Float] { graph.spectrumLevels() }

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
            guard !Task.isCancelled, let self, self.itemID == identity else { return }
            self.preparation = nil
            let player = AudioStreaming.AudioPlayer(
                configuration: AudioPlayerConfiguration(
                    bufferSizeInSeconds: 8,
                    secondsRequiredToStartPlaying: 0.15,
                    gracePeriodAfterSeekInSeconds: 0.02
                ),
                externalRenderOutput: true
            )
            let renderFormat = player.renderAudioFormat
            let nodeFormat = AVAudioFormat(
                standardFormatWithSampleRate: renderFormat.sampleRate,
                channels: renderFormat.channelCount
            ) ?? renderFormat
            let gate = StreamRenderGate(player: player, sourceFormat: renderFormat)
            let node = Self.makeSourceNode(gate: gate, format: nodeFormat)
            node.volume = self.volume
            self.graph.attach(node, format: nodeFormat)
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
    nonisolated private static func makeSourceNode(gate: StreamRenderGate, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, timestamp, frameCount, outputData in
            gate.render(timestamp: timestamp, frameCount: frameCount, outputData: outputData)
        }
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
            Task { @PlaybackAudioActor [weak self] in
                self?.readiness.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
            }
        }
    }
    private func finishReadiness(_ result: Result<Void, Error>) {
        let pending = readiness.values
        readiness.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }
    nonisolated func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        let playerBox = UncheckedSendableBox(value: player)
        let entryBox = UncheckedSendableBox(value: entryId)
        Task { @PlaybackAudioActor [weak self] in
            self?.handleDidStartPlaying(player: playerBox.value, entryId: entryBox.value)
        }
    }
    private func handleDidStartPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId) {
        guard player === audio else { return }
        entryID = entryId
        if let position = initialPosition { initialPosition = nil; player.seek(to: position, resumeAfterSeek: wantsPlayback) }
    }
    nonisolated func audioPlayerStateChanged(player: AudioStreaming.AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        let playerBox = UncheckedSendableBox(value: player)
        let stateBox = UncheckedSendableBox(value: newState)
        Task { @PlaybackAudioActor [weak self] in
            self?.handleStateChanged(player: playerBox.value, newState: stateBox.value)
        }
    }
    private func handleStateChanged(player: AudioStreaming.AudioPlayer, newState: AudioPlayerState) {
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
            if initialPosition == nil, !player.isSeeking, player.state == .paused {
                isLoading = false
                player.volume = 1
                sourceNode?.volume = volume
                finishReadiness(.success(()))
                if wantsPlayback { player.resume() }
            }
        case .bufferring, .running:
            guard player.state == newState else { return }
            isLoading = true
        default: break
        }
        onChange?()
    }
    nonisolated func audioPlayerDidFinishPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        let playerBox = UncheckedSendableBox(value: player)
        let entryBox = UncheckedSendableBox(value: entryId)
        let reasonBox = UncheckedSendableBox(value: stopReason)
        Task { @PlaybackAudioActor [weak self] in
            self?.handleDidFinishPlaying(player: playerBox.value, entryId: entryBox.value, stopReason: reasonBox.value, progress: progress)
        }
    }
    private func handleDidFinishPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double) {
        guard player === audio, self.entryID == entryId, stopReason == .eof else { return }
        finishedPosition = progress; isLoading = false; wantsPlayback = false
        finishReadiness(.success(()))
        onChange?(); onEnded?()
    }
    nonisolated func audioPlayerUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        let playerBox = UncheckedSendableBox(value: player)
        let errorBox = UncheckedSendableBox(value: error)
        Task { @PlaybackAudioActor [weak self] in
            self?.handleUnexpectedError(player: playerBox.value, error: errorBox.value)
        }
    }
    private func handleUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        guard player === audio else { return }
        self.error = error; isLoading = false; wantsPlayback = false
        finishReadiness(.failure(error))
        onChange?()
    }
    nonisolated func audioPlayerDidFinishBuffering(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {}
    nonisolated func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {}
    nonisolated func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String: String]) {}
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class StreamRenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AudioStreaming.AudioPlayer?
    private var isActive = false
    private var startHostTime: UInt64 = 0
    private let sampleRate: Double
    private let channelCount: Int
    private let sourceIsInterleaved: Bool
    private let bytesPerFrame: Int
    private var scratchBuffer: [Float]

    init(player: AudioStreaming.AudioPlayer, sourceFormat: AVAudioFormat) {
        self.player = player
        self.sampleRate = max(1, sourceFormat.sampleRate)
        self.channelCount = max(1, Int(sourceFormat.channelCount))
        self.sourceIsInterleaved = sourceFormat.isInterleaved
        self.bytesPerFrame = max(1, Int(sourceFormat.streamDescription.pointee.mBytesPerFrame))
        self.scratchBuffer = Array(repeating: 0, count: 4096 * max(1, Int(sourceFormat.channelCount)))
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

        var skipFrames: AVAudioFrameCount = 0
        if targetHostTime > 0 {
            let sliceStart = timestamp.pointee.mHostTime
            let sliceDuration = AVAudioTime.hostTime(forSeconds: Double(frameCount) / sampleRate)
            if sliceStart + sliceDuration <= targetHostTime {
                return noErr
            }
            lock.lock()
            startHostTime = 0
            lock.unlock()
            if sliceStart < targetHostTime {
                let delaySeconds = AVAudioTime.seconds(forHostTime: targetHostTime - sliceStart)
                skipFrames = min(frameCount, AVAudioFrameCount((delaySeconds * sampleRate).rounded()))
            }
        }

        let renderFrames = frameCount - skipFrames
        guard renderFrames > 0 else { return noErr }

        if !sourceIsInterleaved {
            if skipFrames == 0 {
                return activePlayer.renderExternal(inNumberFrames: renderFrames, ioData: outputData)
            }
            return activePlayer.renderExternal(inNumberFrames: frameCount, ioData: outputData)
        }

        let neededSamples = Int(renderFrames) * channelCount
        if scratchBuffer.count < neededSamples {
            scratchBuffer = Array(repeating: 0, count: neededSamples)
        }
        let status: OSStatus = scratchBuffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return noErr }
            memset(baseAddress, 0, neededSamples * MemoryLayout<Float>.size)
            var interleavedList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(Int(renderFrames) * bytesPerFrame),
                    mData: baseAddress
                )
            )
            return activePlayer.renderExternal(inNumberFrames: renderFrames, ioData: &interleavedList)
        }

        let destOffset = Int(skipFrames)
        let frames = Int(renderFrames)
        let channelsToCopy = min(channelCount, buffers.count)
        for ch in 0..<channelsToCopy {
            guard let destData = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames {
                destData[destOffset + frame] = scratchBuffer[frame * channelCount + ch]
            }
        }
        return status
    }
}
