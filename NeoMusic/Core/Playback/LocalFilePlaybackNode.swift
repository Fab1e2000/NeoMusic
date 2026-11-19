@preconcurrency import AVFoundation

/// Native `AVAudioFile` + `AVAudioPlayerNode` deck for local files.
/// Seeking schedules directly at the target sample frame without re-decoding from frame 0.
@PlaybackAudioActor final class LocalFilePlaybackNode {
    var onEnded: (() -> Void)?

    private let file: AVAudioFile
    private let graph: SharedAudioGraph
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

    init(file: AVAudioFile, graph: SharedAudioGraph, volume: Float, initialPosition: Double) {
        self.file = file
        self.graph = graph
        self.volume = volume
        self.sampleRate = max(1, file.processingFormat.sampleRate)
        self.totalFrames = file.length

        graph.attach(playerNode, format: file.processingFormat)
        playerNode.volume = volume

        let clamped = Self.clampedSeconds(initialPosition, duration: Double(totalFrames) / sampleRate)
        anchoredFrame = AVAudioFramePosition((clamped * sampleRate).rounded())
        pausedTime = clamped
        scheduleFrom(frame: anchoredFrame, startPlaying: false)
    }

    func play(atHostTime hostTime: UInt64? = nil) {
        wantsPlayback = true
        pausedTime = nil
        if finished {
            scheduleFrom(frame: 0, startPlaying: true, atHostTime: hostTime)
            return
        }
        startEngineAndNodeIfNeeded(atHostTime: hostTime)
    }

    func exactEndHostTime() -> UInt64? {
        guard isPlayingState, sampleRate > 0,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              nodeTime.isHostTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0
        else { return nil }
        let playedFrames = anchoredFrame + playerTime.sampleTime
        let remainingFrames = max(0, totalFrames - playedFrames)
        let remainingSeconds = Double(remainingFrames) / sampleRate
        return nodeTime.hostTime + AVAudioTime.hostTime(forSeconds: remainingSeconds)
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
        graph.detach(playerNode)
    }

    private func scheduleFrom(frame: AVAudioFramePosition, startPlaying: Bool, atHostTime hostTime: UInt64? = nil) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        playerNode.stop()
        anchoredFrame = min(max(0, frame), totalFrames)
        finished = false

        guard totalFrames > 0, anchoredFrame < totalFrames else {
            isPlayingState = false
            if totalFrames > 0 {
                // A restored position at the end must not leave an empty node that
                // reports playing without any scheduled audio.
                finished = true
                if startPlaying {
                    wantsPlayback = false
                    onEnded?()
                }
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
            startEngineAndNodeIfNeeded(atHostTime: hostTime)
        } else {
            isPlayingState = false
        }
    }

    private func startEngineAndNodeIfNeeded(atHostTime hostTime: UInt64? = nil) {
        do {
            try graph.startIfNeeded()
        } catch {
            isPlayingState = false
            return
        }
        if let hostTime {
            playerNode.play(at: AVAudioTime(hostTime: hostTime))
        } else {
            playerNode.play()
        }
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

    nonisolated private static func makeCompletionHandler(
        node: LocalFilePlaybackNode,
        generation: Int
    ) -> AVAudioPlayerNodeCompletionHandler {
        { [weak node] _ in
            Task { @PlaybackAudioActor [weak node] in
                node?.handleSegmentCompleted(generation: generation)
            }
        }
    }

    private static func clampedSeconds(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, seconds), duration)
    }
}
