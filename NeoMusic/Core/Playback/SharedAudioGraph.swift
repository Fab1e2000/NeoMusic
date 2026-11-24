@preconcurrency import AVFoundation

@PlaybackAudioActor final class SharedAudioGraph {
    lazy var engine = AVAudioEngine()
    nonisolated let analyzer = ThreadSafeSpectrumAnalyzer()
    private var tapInstalled = false

    nonisolated init() {}

    func attach(_ node: AVAudioNode, format: AVAudioFormat?) throws {
        let needsAttachment = node.engine !== engine
        if needsAttachment { engine.attach(node) }
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
        } catch {
            if needsAttachment { engine.detach(node) }
            throw error
        }
        engine.prepare()
    }

    func detach(_ node: AVAudioNode) {
        guard node.engine === engine else { return }
        engine.disconnectNodeOutput(node)
        engine.detach(node)
    }

    func startIfNeeded() throws {
        installTapIfNeeded()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func pause() {
        if engine.isRunning {
            engine.pause()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()
    }

    nonisolated func spectrumLevels() -> [Float] {
        (0..<5).map { analyzer.level(at: $0) }
    }

    var currentHostTime: UInt64? {
        guard engine.isRunning else { return nil }
        if let renderTime = engine.mainMixerNode.lastRenderTime, renderTime.isHostTimeValid {
            return renderTime.hostTime
        }
        return mach_absolute_time()
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        // Both tap APIs document a 100 ms minimum. Keep the previous request when it meets that minimum.
        let bufferSize = AVAudioFrameCount(max(1024, (format.sampleRate / 10).rounded(.up)))
        do {
            try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: bufferSize, format: format) { [analyzer] buffer, _ in
                analyzer.consume(buffer)
            }
            tapInstalled = true
        } catch {
            AppLogger.failure(AppLogger.playback, "spectrum.tap.install", error: error)
        }
    }
}

final class ThreadSafeSpectrumAnalyzer: @unchecked Sendable {
    private let raw = AudioSpectrumAnalyzer()

    func subscribe() -> Subscription { Subscription(raw) }

    final class Subscription {
        private let raw: AudioSpectrumAnalyzer
        fileprivate init(_ raw: AudioSpectrumAnalyzer) {
            self.raw = raw
            raw.addConsumer()
        }
        deinit { raw.removeConsumer() }
    }

    func consume(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let frameCount = AVAudioFrameCount(buffer.frameLength)
        let format = buffer.format
        buffer.withUnsafeAudioBufferList { buffers in
            raw.consume(buffers, frameCount: frameCount, format: format)
        }
    }

    func level(at index: Int) -> Float {
        raw.level(at: index)
    }
}
