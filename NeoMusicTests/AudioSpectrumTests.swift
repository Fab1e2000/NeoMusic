import XCTest
import AVFoundation
@testable import NeoMusic

final class AudioSpectrumTests: XCTestCase {
    func testSilenceProducesZeroLevels() {
        let samples = [Float](repeating: 0, count: 2048)
        let data = samples.withUnsafeBytes { Data($0) }
        XCTAssertEqual(AudioSpectrumAnalyzer.levels(forPCM: data, sampleRate: 44100).map(\.floatValue), [0,0,0,0,0])
    }

    func testFiveTonesLandInTheirOwnFrequencyBands() {
        for (band, frequency) in [70.0, 200, 600, 1800, 6000].enumerated() {
            let samples = (0..<2048).map { Float(0.1 * sin(2 * .pi * frequency * Double($0) / 44100)) }
            let data = samples.withUnsafeBytes { Data($0) }
            let levels = AudioSpectrumAnalyzer.levels(forPCM: data, sampleRate: 44100).map(\.floatValue)
            XCTAssertEqual(levels.firstIndex(of: levels.max()!), band)
            XCTAssertGreaterThan(levels[band], 0.03)
            XCTAssertTrue(levels.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    func testAmplitudeDifferencesRemainVisibleWithoutFrameNormalization() {
        func level(_ amplitude: Double) -> Float {
            let samples = (0..<2048).map { Float(amplitude * sin(2 * .pi * 200 * Double($0) / 44100)) }
            let data = samples.withUnsafeBytes { Data($0) }
            return AudioSpectrumAnalyzer.levels(forPCM: data, sampleRate: 44100)[1].floatValue
        }
        let quiet = level(0.01)
        let medium = level(0.04)
        let loud = level(0.16)
        XCTAssertGreaterThan(medium - quiet, 0.05)
        XCTAssertGreaterThan(loud - medium, 0.05)
        XCTAssertLessThan(loud, 1, "Ordinary signals must not all saturate")
        XCTAssertEqual(level(0.0000001), 0, "Do not normalize silence/noise up to full height")
    }

    @MainActor func testStopAndMissingFileCannotPublishSpectrum() async {
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: URL(fileURLWithPath: "/missing-spectrum-input.wav"), autoplay: true)
        XCTAssertNotNil(engine.error)
        XCTAssertEqual(engine.spectrumLevels(), [0,0,0,0,0])
        engine.stop()
        await Task.yield()
        XCTAssertEqual(engine.spectrumLevels(), [0,0,0,0,0])
    }

    @MainActor func testLateTrackLoadAfterStopStaysSilent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for i in 0..<44100 { buffer.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * 450 * Double(i) / 44100)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: url, nextURL: url, autoplay: true)
        engine.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.spectrumLevels(), [0,0,0,0,0])
    }

    private func writeTone(_ frequency: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames: AVAudioFrameCount = 44100 * 12
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * frequency * Double(i) / 44100))
        }
        // Close the writer before handing the file to AVPlayer.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    @MainActor private func awaitBand(_ band: Int, engine: LocalPlaybackEngine,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let levels = engine.spectrumLevels()
            if let peak = levels.max(), peak > 0.03, levels.firstIndex(of: peak) == band { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("No live spectrum in band \(band): \(engine.spectrumLevels()); error: \(engine.error ?? "none")", file: file, line: line)
    }

    @MainActor func testLivePlaybackPauseResumeAndPreparedAdvanceUseActualItemSpectrum() async throws {
        let first = try writeTone(200)
        let second = try writeTone(1800)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: first, nextURL: second, autoplay: true)
        try await awaitBand(1, engine: engine)
        engine.pause()
        XCTAssertEqual(engine.spectrumLevels(), [0,0,0,0,0])
        engine.play()
        try await awaitBand(1, engine: engine)
        XCTAssertTrue(engine.advancePrepared())
        try await awaitBand(3, engine: engine)
        engine.stop()
        XCTAssertEqual(engine.spectrumLevels(), [0,0,0,0,0])
    }
}
