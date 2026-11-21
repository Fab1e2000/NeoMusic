@preconcurrency import AVFoundation

@PlaybackAudioActor final class SharedAudioGraph {
    lazy var engine = AVAudioEngine()
    private nonisolated let analyzer = ThreadSafeSpectrumAnalyzer()
    private var tapInstalled = false

    nonisolated init() {}

    func attach(_ node: AVAudioNode, format: AVAudioFormat?) {
        if node.engine !== engine {
            engine.attach(node)
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
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
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.makeTapBlock(analyzer: analyzer)
        )
        tapInstalled = true
    }

    nonisolated private static func makeTapBlock(analyzer: ThreadSafeSpectrumAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in analyzer.consume(buffer) }
    }
}

private final class ThreadSafeSpectrumAnalyzer: @unchecked Sendable {
    private let raw = AudioSpectrumAnalyzer()

    func consume(_ buffer: AVAudioPCMBuffer) {
        raw.consume(buffer)
    }

    func level(at index: Int) -> Float {
        raw.level(at: index)
    }
}
