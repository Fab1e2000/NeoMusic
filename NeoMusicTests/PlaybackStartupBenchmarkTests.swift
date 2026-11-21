import AVFoundation
import XCTest
@testable import NeoMusic

@MainActor final class PlaybackStartupBenchmarkTests: XCTestCase {
    func testLocalWAVStartupComparedWithPreciseAVPlayer() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        let activated = try await session.activate()
        XCTAssertTrue(activated)
        for repetition in 1...3 {
            for streaming in (repetition.isMultiple(of: 2) ? [true, false] : [false, true]) {
                let start = ContinuousClock.now
                let firstProgress: ContinuousClock.Instant
                if streaming {
                    let engine = LocalPlaybackEngine(activateSession: { true })
                    defer { engine.shutdown() }
                    engine.load(url: url, autoplay: true)
                    try await waitUntil {
                        let time = await engine.debugBackendState().currentPlaybackTime ?? 0
                        return !engine.isLoading && time > 0.01
                    }
                    firstProgress = .now
                    XCTAssertNil(engine.error)
                } else {
                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    defer { player.pause(); player.replaceCurrentItem(with: nil) }
                    player.play()
                    try await waitUntil { player.currentTime().seconds > 0.01 }
                    firstProgress = .now
                    XCTAssertNil(player.error)
                }
                let duration = start.duration(to: firstProgress).components
                let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                print("PLAYBACK_STARTUP source=generated_20s_wav engine=\(streaming ? "AudioStreaming" : "AVPlayerPrecise") repetition=\(repetition) first_progress_ms=\(milliseconds)")
            }
        }
    }

    func testRemoteMP3StartupComparedWithPreciseAVPlayer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NEOMUSIC_NETWORK_BENCHMARK"] == "1",
                          "Set NEOMUSIC_NETWORK_BENCHMARK=1 for the external-network benchmark")
        let url = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/youshen2/MeloX/3b937b3682f6274ef6157aef156cd59d32ba3dc5/vendor/AudioStreaming/Tests/AudioStreamingTests/Fixtures/vbr.mp3"))
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        let activated = try await session.activate()
        XCTAssertTrue(activated)
        for repetition in 1...3 {
            for streaming in (repetition.isMultiple(of: 2) ? [true, false] : [false, true]) {
                let start = ContinuousClock.now
                let firstProgress: ContinuousClock.Instant
                if streaming {
                    let engine = LocalPlaybackEngine(activateSession: { true })
                    defer { engine.shutdown() }
                    engine.load(url: url, autoplay: true)
                    try await waitUntil(seconds: 30) {
                        let time = await engine.debugBackendState().currentPlaybackTime ?? 0
                        return !engine.isLoading && time > 0.01
                    }
                    firstProgress = .now
                    XCTAssertNil(engine.error)
                    engine.pause()
                    engine.seek(to: 3.125)
                    try await waitUntil(seconds: 30) { !engine.isLoading }
                    XCTAssertNil(engine.error)
                    XCTAssertFalse(engine.isPlaying)
                    let soughtTime = await engine.debugBackendState().currentPlaybackTime
                    XCTAssertEqual(try XCTUnwrap(soughtTime), 3.125, accuracy: 0.1)
                    engine.play()
                    try await waitUntil(seconds: 30) {
                        let time = await engine.debugBackendState().currentPlaybackTime ?? 0
                        return time > 3.225
                    }
                } else {
                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    defer { player.pause(); player.replaceCurrentItem(with: nil) }
                    player.play()
                    try await waitUntil(seconds: 30) { player.currentTime().seconds > 0.01 }
                    firstProgress = .now
                    XCTAssertNil(player.error)
                }
                let duration = start.duration(to: firstProgress).components
                let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                print("PLAYBACK_STARTUP source=github_public_vbr_mp3 engine=\(streaming ? "AudioStreaming" : "AVPlayerPrecise") repetition=\(repetition) first_progress_ms=\(milliseconds)")
            }
        }
    }

    func testCancelledRemoteLoadCannotOverrideReplacement() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine(activateSession: { true })
        defer { engine.shutdown() }
        engine.load(url: URL(string: "http://127.0.0.1:1/unavailable.mp3")!, autoplay: true)
        engine.load(url: url, position: 3.125)
        try await waitUntil { !engine.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsed, 3.125, accuracy: 0.002)
        XCTAssertEqual(engine.duration, 20, accuracy: 0.1)
    }

    private func waitUntil(seconds: Int = 10, _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Playback did not reach the expected transport state within \(seconds) seconds")
        throw CancellationError()
    }
}
