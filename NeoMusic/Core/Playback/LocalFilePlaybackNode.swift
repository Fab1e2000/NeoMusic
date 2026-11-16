@preconcurrency import AVFoundation

/// Native `AVAudioFile` + `AVAudioPlayerNode` deck for local files.
/// Seeking schedules directly at the target sample frame without re-decoding from frame 0.
@MainActor final class LocalFilePlaybackNode {
    var onEnded: (() -> Void)?

    private let file: AVAudioFile
    private let analyzer: AudioSpectrumAnalyzer
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sampleRate: Double
    private let totalFrames: AVAudioFramePosition

    private var anchoredFrame: AVAudioFramePosition = 0
    private var pausedTime: Double?
    private var finished = false
    private var isPlayingState = false
    private var wantsPlayback = false
    private var scheduleGeneration = 0

    var volume: Float = 1 {
        didSet { playerNode.volume = volume }
    }

    var isPlaying: Bool { isPlayingState }

    var duration: Double? {
        guard totalFrames > 0, sampleRate > 0 else { return nil }
        return Double(totalFrames) / sampleRate
    }

    var currentTime: Double? {
        guard sampleRate > 0 else { return nil }
        if finished { return duration }
        if let pausedTime { return pausedTime }
        if isPlayingState,
           let nodeTime = playerNode.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.sampleTime >= 0
        {
            let frames = min(totalFrames, anchoredFrame + playerTime.sampleTime)
            return Double(frames) / sampleRate
        }
        return Double(anchoredFrame) / sampleRate
    }

    init(file: AVAudioFile, analyzer: AudioSpectrumAnalyzer, volume: Float, initialPosition: Double) {
        self.file = file
        self.analyzer = analyzer
        self.volume = volume
        self.sampleRate = max(1, file.processingFormat.sampleRate)
        self.totalFrames = file.length

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        playerNode.volume = volume
        playerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: file.processingFormat,
            block: Self.makeTapBlock(analyzer: analyzer)
        )
        engine.prepare()

        let clamped = Self.clampedSeconds(initialPosition, duration: Double(totalFrames) / sampleRate)
        anchoredFrame = AVAudioFramePosition((clamped * sampleRate).rounded())
        pausedTime = clamped
        scheduleFrom(frame: anchoredFrame, startPlaying: false)
    }

    func play() {
        wantsPlayback = true
        if finished {
            scheduleFrom(frame: 0, startPlaying: true)
            return
        }
        if pausedTime != nil {
            pausedTime = nil
        }
        startEngineAndNodeIfNeeded()
    }

    func pause() {
        wantsPlayback = false
        let current = currentTime
        playerNode.pause()
        isPlayingState = false
        if let current { pausedTime = current }
    }

    func seek(to seconds: Double) {
        let maxDuration = Double(totalFrames) / sampleRate
        let clamped = Self.clampedSeconds(seconds, duration: maxDuration)
        let targetFrame = AVAudioFramePosition((clamped * sampleRate).rounded())
        pausedTime = wantsPlayback ? nil : clamped
        scheduleFrom(frame: targetFrame, startPlaying: wantsPlayback)
    }

    func stopAndClean() {
        scheduleGeneration &+= 1
        wantsPlayback = false
        isPlayingState = false
        playerNode.stop()
        engine.stop()
        playerNode.removeTap(onBus: 0)
        engine.reset()
    }

    private func scheduleFrom(frame: AVAudioFramePosition, startPlaying: Bool) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        playerNode.stop()
        anchoredFrame = min(max(0, frame), totalFrames)
        finished = false

        guard totalFrames > 0, anchoredFrame < totalFrames else {
            isPlayingState = false
            if startPlaying, totalFrames > 0 {
                finished = true
                wantsPlayback = false
                onEnded?()
            }
            return
        }

        let remaining = AVAudioFrameCount(min(Int64(UInt32.max), totalFrames - anchoredFrame))
        playerNode.scheduleSegment(
            file,
            startingFrame: anchoredFrame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletionHandler(node: self, generation: generation)
        )

        if startPlaying {
            startEngineAndNodeIfNeeded()
        } else {
            isPlayingState = false
        }
    }

    private func startEngineAndNodeIfNeeded() {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                isPlayingState = false
                return
            }
        }
        playerNode.play()
        isPlayingState = true
    }

    private func handleSegmentCompleted(generation: Int) {
        guard generation == scheduleGeneration, isPlayingState else { return }
        isPlayingState = false
        wantsPlayback = false
        finished = true
        pausedTime = duration
        onEnded?()
    }

    nonisolated private static func makeTapBlock(analyzer: AudioSpectrumAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in analyzer.consume(buffer) }
    }

    nonisolated private static func makeCompletionHandler(
        node: LocalFilePlaybackNode,
        generation: Int
    ) -> AVAudioPlayerNodeCompletionHandler {
        { [weak node] _ in
            Task { @MainActor [weak node] in
                node?.handleSegmentCompleted(generation: generation)
            }
        }
    }

    private static func clampedSeconds(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, seconds), duration)
    }
}
