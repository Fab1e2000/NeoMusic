import AVFoundation
import XCTest
@testable import AudioStreaming

final class AudioSeekTests: XCTestCase {
    func testPausedSeekReadinessDoesNotConsumeTargetSamples() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vbr", withExtension: "mp3", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let decoder = try Decoder(data: data, hint: kAudioFileMP3Type)
        try decoder.feed(data.prefix(8192), final: false)
        decoder.entry.seekRequest.time = 3.125
        decoder.context.resumeAfterSeek.write { $0 = false }
        decoder.processor.processSeek()
        try decoder.feed(data.dropFirst(decoder.source.position))
        let render = AudioPlayerRenderProcessor(playerContext: decoder.context,
            rendererContext: decoder.renderer,
            outputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100, channels: 2, interleaved: true)!.basicStreamDescription)
        let buffered = decoder.renderer.bufferContext.frameUsedCount
        XCTAssertGreaterThan(buffered, 0)
        for _ in 0..<12 { _ = render.inRender(inNumberFrames: 4096) }
        XCTAssertEqual(decoder.context.state.value, .paused)
        XCTAssertEqual(decoder.entry.framesPlayed, 0)
        XCTAssertEqual(decoder.renderer.bufferContext.frameUsedCount, buffered)
        XCTAssertEqual(decoder.entry.progress, 3.125, accuracy: 0.00001)
        decoder.context.resumeAfterSeek.write { $0 = true }
        decoder.context.setInternalState(to: .playing)
        _ = render.inRender(inNumberFrames: 4096)
        XCTAssertGreaterThan(decoder.entry.framesPlayed, 0)
        XCTAssertGreaterThan(decoder.entry.progress, 3.125)
    }

    func testNonSeekableSourceRestartsFromBeginningAndDiscardsToTarget() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cbr", withExtension: "mp3", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let baseline = try Decoder(data: data, hint: kAudioFileMP3Type)
        try baseline.feed(data)
        let reference = baseline.samples
        let decoder = try Decoder(data: data, hint: kAudioFileMP3Type, canSeek: false)
        try decoder.feed(data.prefix(8192), final: false)
        let target = 3.125
        decoder.entry.seekRequest.time = target
        decoder.processor.processSeek()
        XCTAssertEqual(decoder.source.position, 0, "A non-seekable source must restart from the stream beginning")
        try decoder.feed(data)
        let actual = Array(decoder.samples.prefix(4096))
        let offset = Int((target * 44_100).rounded()) * 2
        let expected = Array(reference.dropFirst(offset).prefix(actual.count))
        XCTAssertGreaterThan(actual.count, 1000)
        XCTAssertEqual(actual.count, expected.count)
        let rms = sqrt(zip(actual, expected).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(max(actual.count, 1)))
        XCTAssertLessThan(rms, 0.008)
    }

    func testTruncatedHeaderFailsAtEndOfInput() throws {
        let data = Data("broken".utf8)
        let decoder = try Decoder(data: data, hint: kAudioFileWAVEType)
        XCTAssertEqual(decoder.processor.parseFileStreamBytes(data: data), noErr)
        XCTAssertEqual(decoder.processor.finishFileStream(), kAudioFileStreamError_UnsupportedDataFormat)
        XCTAssertEqual(decoder.entry.framesPlayed, 0)
    }

    func testPCMSeekRestartsContainerAndMatchesSamples() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 6))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / 44_100
            let value = Float(sin(2 * .pi * (150 * time + 37 * time * time)) * 0.3)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: url)
        let decoder = try Decoder(data: data, hint: kAudioFileWAVEType)
        try decoder.feed(data.prefix(8192), final: false)
        for target in [0.6, 3.0, 5.4, 1.325, 0, 2.437, 2.437] {
            decoder.entry.seekRequest.time = target
            decoder.processor.processSeek()
            XCTAssertEqual(decoder.source.position, 0)
            try decoder.feed(data)
            let actual = Array(decoder.samples.prefix(4096))
            XCTAssertEqual(actual.count, 4096)
            let offset = Int((target * 44_100).rounded())
            let rms = sqrt(actual.enumerated().reduce(0.0) {
                $0 + pow(Double($1.element - buffer.floatChannelData![0][offset + $1.offset / 2]), 2)
            } / Double(actual.count))
            XCTAssertLessThan(rms, 0.00001, "PCM timeline mismatch at \(target): \(rms)")
        }
    }

    func testSeekDoesNotAdvanceWhileWaitingForDecodedAudio() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vbr", withExtension: "mp3", subdirectory: "Fixtures"))
        let decoder = try Decoder(data: Data(contentsOf: url), hint: kAudioFileMP3Type)
        decoder.context.setInternalState(to: .waitingForDataAfterSeek)
        let render = AudioPlayerRenderProcessor(playerContext: decoder.context,
            rendererContext: decoder.renderer,
            outputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100, channels: 2, interleaved: true)!.basicStreamDescription)
        // More than one second of output requests with no decoded input.
        for _ in 0..<12 { _ = render.inRender(inNumberFrames: 4096) }
        XCTAssertEqual(decoder.context.state.value, .bufferring)
        XCTAssertEqual(decoder.entry.framesPlayed, 0)
    }

    func testSeekMatchesDecodedAudioForCBRAndVBRAndLossless() throws {
        for (name, ext, hint) in [
            ("cbr", "mp3", kAudioFileMP3Type),
            ("vbr", "mp3", kAudioFileMP3Type),
            ("audio", "m4a", kAudioFileM4AType),
            ("audio", "flac", kAudioFileFLACType),
        ] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            let data = try Data(contentsOf: url)
            let baseline = try Decoder(data: data, hint: hint)
            try baseline.feed(data)
            let reference = baseline.samples
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(reference.count / 2, Int(file.length), "Valid frame count: \(name).\(ext)")
            let native = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: native)
            let nativeLeft = native.floatChannelData![0]
            let baselineRMS = sqrt((0..<Int(native.frameLength)).reduce(0.0) {
                $0 + pow(Double(reference[$1 * 2] - nativeLeft[$1]), 2)
            } / Double(native.frameLength))
            XCTAssertLessThan(baselineRMS, 0.008, "Native file timeline mismatch: \(name).\(ext), RMS \(baselineRMS)")
            let decoder = try Decoder(data: data, hint: hint)
            try decoder.feed(data.prefix(8192), final: false)
            // Forward, backward, repeated and fractional-second lyric jumps.
            let duration = Double(file.length) / file.processingFormat.sampleRate
            for target in [duration * 0.1, duration * 0.5, duration * 0.9, 4.125, 1.325, 5.425, 0, 2.437, 2.437] {
                decoder.entry.seekRequest.time = target
                decoder.processor.processSeek()
                XCTAssertEqual(decoder.context.state.value, .bufferring)
                try decoder.feed(data.dropFirst(decoder.source.position))
                let actual = Array(decoder.samples.prefix(4096))
                let offset = Int((target * 44_100).rounded()) * 2
                let expected = Array(reference.dropFirst(offset).prefix(actual.count))
                XCTAssertGreaterThan(actual.count, 1000, "\(name) @ \(target)")
                XCTAssertEqual(actual.count, expected.count)
                let rms = sqrt(zip(actual, expected).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(max(actual.count, 1)))
                XCTAssertLessThan(rms, 0.008, "\(name).\(ext) @ \(target): RMS \(rms)")
            }
        }
    }
}

private final class MemorySource: CoreAudioStreamSource {
    var position = 0
    let length: Int
    let audioFileHint: AudioFileTypeID
    let canSeek: Bool
    weak var delegate: AudioStreamSourceDelegate?
    let underlyingQueue = DispatchQueue(label: "seek-test")
    init(length: Int, hint: AudioFileTypeID, canSeek: Bool = true) {
        self.length = length
        self.audioFileHint = hint
        self.canSeek = canSeek
    }
    func seek(at offset: Int) { position = offset }
    func close() {}
    func suspend() {}
    func resume() {}
}

private final class Decoder {
    let source: MemorySource
    let context = AudioPlayerContext()
    let renderer: AudioRendererContext
    let entry: AudioEntry
    let processor: AudioFileStreamProcessor
    var failure: AudioPlayerError?

    init(data: Data, hint: AudioFileTypeID, canSeek: Bool = true) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
        source = MemorySource(length: data.count, hint: hint, canSeek: canSeek)
        entry = AudioEntry(source: source, entryId: AudioEntryId(id: "fixture"), outputAudioFormat: format)
        renderer = AudioRendererContext(configuration: AudioPlayerConfiguration(bufferSizeInSeconds: 8), outputAudioFormat: format)
        context.audioPlayingEntry = entry
        context.audioReadingEntry = entry
        processor = AudioFileStreamProcessor(playerContext: context, rendererContext: renderer, outputAudioFormat: format.basicStreamDescription)
        processor.fileStreamCallback = { [weak self] effect in
            if case let .raiseError(error) = effect { self?.failure = error }
        }
        XCTAssertEqual(processor.openFileStream(with: hint), noErr)
    }
    deinit { processor.closeFileStreamIfNeeded(); renderer.clean() }
    func feed(_ data: Data, final: Bool = true) throws {
        let status = processor.parseFileStreamBytes(data: data)
        XCTAssertEqual(status, noErr)
        XCTAssertNil(failure)
        if final { XCTAssertEqual(processor.finishFileStream(), noErr) }
    }
    var samples: [Float] {
        guard let data = renderer.audioBuffer.mData else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(renderer.bufferContext.frameUsedCount) * 2))
    }
}
