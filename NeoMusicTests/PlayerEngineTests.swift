import AVFoundation
import XCTest
@testable import NeoMusic

actor SessionActivation {
    enum RequestError: Error { case missingRequest }
    private var requests: [CheckedContinuation<Bool, Error>?] = []
    var count: Int { requests.count }

    func activate(started: @Sendable () -> Void = {}) async throws -> Bool {
        try await withCheckedThrowingContinuation {
            requests.append($0)
            started()
        }
    }

    func complete(_ index: Int = 0, with result: Result<Bool, Error> = .success(true)) throws {
        guard requests.indices.contains(index), let request = requests[index] else { throw RequestError.missingRequest }
        request.resume(with: result)
        requests[index] = nil
    }
}

@MainActor final class PlayerEngineTests: XCTestCase {
    private func audioFile(seconds: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * seconds))!
        buffer.frameLength = AVAudioFrameCount(44100 * seconds)
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
        return url
    }
    func testMissingFileDoesNotPretendToPlay() {
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: URL(fileURLWithPath: "/nonexistent/track.wav"), autoplay: true)
        XCTAssertNotNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isLoading)
    }
    func testSuccessfulLoadSeekPauseAndCancellation() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: url)
        for _ in 0..<50 where engine.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(engine.error)
        XCTAssertFalse(engine.isLoading)
        engine.seek(to: 0.5)
        XCTAssertEqual(engine.elapsed, 0.5)
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.load(url: url)
        engine.load(url: URL(fileURLWithPath: "/nonexistent/track.wav"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(engine.error)
        XCTAssertFalse(engine.isLoading)
        engine.stop()
        XCTAssertNil(engine.error)
        XCTAssertEqual(engine.elapsed, 0)
    }
    func testCrossfadeDefaultsOffAndCancelsWhenStopped() throws {
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        XCTAssertFalse(engine.crossfadeEnabled)
        engine.crossfadeEnabled = true
        engine.stop()
        XCTAssertFalse(engine.isCrossfading)
        XCTAssertFalse(engine.isPlaying)
    }
    private func waitUntil(_ predicate: @MainActor () async -> Bool, seconds: Double = 6) async throws {
        for _ in 0..<Int(seconds * 50) {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for transport state")
        throw CancellationError()
    }

    func testCrossfadePromotesPlayingIncomingOnce() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        var advances = 0
        engine.onAdvanced = { advances += 1 }
        engine.crossfadeEnabled = true
        engine.load(url: first, nextURL: second, autoplay: true)
        try await waitUntil({ engine.isCrossfading })
        try await waitUntil({ advances == 1 })
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isCrossfading)
        XCTAssertGreaterThan(engine.elapsed, 1)
        XCTAssertEqual(engine.duration, 6, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(advances, 1)
    }

    func testFadePauseSeekDisableAndReplacement() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        var advances = 0
        engine.onAdvanced = { advances += 1 }
        engine.crossfadeEnabled = true
        engine.load(url: first, nextURL: second, autoplay: true)
        try await waitUntil({ engine.isCrossfading })
        engine.pause()
        let paused = engine.elapsed
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engine.elapsed, paused, accuracy: 0.25)
        XCTAssertTrue(engine.isCrossfading)
        engine.seek(to: 0)
        XCTAssertFalse(engine.isCrossfading)
        engine.play()
        try await waitUntil({ engine.isCrossfading })
        engine.crossfadeEnabled = false
        XCTAssertFalse(engine.isCrossfading)
        engine.crossfadeEnabled = true
        try await waitUntil({ engine.isCrossfading })
        engine.load(url: second)
        XCTAssertFalse(engine.isCrossfading)
        XCTAssertFalse(engine.isPlaying)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(advances, 0)
    }

    func testPreparedNextAdvancesWithoutCrossfade() async throws {
        let first = try audioFile(), second = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        var advances = 0
        engine.onAdvanced = { advances += 1 }
        engine.load(url: first, nextURL: second, autoplay: true)
        try await waitUntil({ advances == 1 })
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.duration, 4, accuracy: 0.1)
        XCTAssertFalse(engine.advancePrepared())
        XCTAssertEqual(advances, 1)
    }

    func testShortIncomingSurvivesFadePromotion() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        var advances = 0, finished = 0
        engine.onAdvanced = { advances += 1 }
        engine.onFinished = { finished += 1 }
        engine.crossfadeEnabled = true
        engine.load(url: first, nextURL: second, autoplay: true)
        try await waitUntil({ advances == 1 })
        XCTAssertLessThan(engine.elapsed, 1)
        XCTAssertEqual(engine.duration, 1, accuracy: 0.1)
        try await waitUntil({ finished == 1 })
        XCTAssertEqual(advances, 1)
        XCTAssertFalse(engine.isPlaying)
    }

    func testInterruptionResumesOnlyPreservedIntent() async throws {
        let url = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        engine.handleInterruption(began: true)
        XCTAssertFalse(engine.isPlaying)
        engine.handleInterruption(began: false, shouldResume: true)
        try await waitUntil({ engine.isPlaying })
        XCTAssertTrue(engine.isPlaying)
        engine.handleInterruption(began: true)
        engine.pause()
        engine.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        engine.handleInterruption(began: true)
        engine.handleInterruption(began: false, shouldResume: false)
        XCTAssertFalse(engine.isPlaying)
    }

    func testSessionActivationPublishesPlayingOnlyAfterSuccessAndSharesPendingRequest() async throws {
        let url = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        XCTAssertTrue(engine.isActivating)
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        try await waitUntil({ await activation.count == 1 })
        try await activation.complete()
        try await waitUntil({ engine.isPlaying })
        XCTAssertFalse(engine.isActivating)
        XCTAssertNil(engine.error)
        engine.play()
        let requests = await activation.count
        XCTAssertEqual(requests, 1)
    }

    func testFailedAndDeclinedSessionActivationStayPaused() async throws {
        let url = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let results: [Result<Bool, Error>] = [.success(false), .failure(URLError(.cannotConnectToHost))]
        for result in results {
            let activation = SessionActivation()
            let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
            defer { engine.shutdown() }
            engine.load(url: url, autoplay: true)
            try await waitUntil({ await activation.count == 1 })
            try await activation.complete(with: result)
            try await waitUntil({ !engine.isActivating })
            XCTAssertFalse(engine.isPlaying)
            XCTAssertNotNil(engine.error)
        }
    }

    func testCancelledSessionActivationCannotResumeAfterUserOrSystemStop() async throws {
        let url = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let stops: [(String, (LocalPlaybackEngine) -> Void)] = [
            ("pause", { $0.pause() }),
            ("stop", { $0.stop() }),
            ("shutdown", { $0.shutdown() }),
            ("replacement", { $0.load(url: url) }),
            ("interruption", { $0.handleInterruption(began: true) }),
            ("route", { _ in
                NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                    object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            })
        ]
        for (name, stop) in stops {
            let activation = SessionActivation()
            let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
            defer { engine.shutdown() }
            engine.load(url: url, autoplay: true)
            try await waitUntil({ await activation.count == 1 })
            let pending = engine.activation
            stop(engine)
            XCTAssertFalse(engine.isActivating, name)
            try await activation.complete()
            await pending?.value
            XCTAssertFalse(engine.isPlaying, name)
            XCTAssertFalse(engine.isActivating, name)
            XCTAssertNil(engine.error, name)
        }
    }

    func testNewPlayRequestSurvivesLateFailureFromPreviousActivation() async throws {
        let url = try audioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        let previous = engine.activation
        engine.pause()
        engine.play()
        try await waitUntil({ await activation.count == 2 })
        try await activation.complete(1)
        try await waitUntil({ engine.isPlaying })
        try await activation.complete(0, with: .failure(URLError(.cancelled)))
        await previous?.value
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isActivating)
        XCTAssertNil(engine.error)
    }

    func testSwitchingTracksDuringActivationUsesOnlyTheNewRequest() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: first, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        let previous = engine.activation
        engine.load(url: second, autoplay: true)
        try await waitUntil({ await activation.count == 2 })
        try await activation.complete(0)
        await previous?.value
        XCTAssertTrue(engine.isActivating)
        XCTAssertFalse(engine.isPlaying)
        try await activation.complete(1)
        try await waitUntil({ engine.isPlaying && !engine.isLoading && engine.duration > 0 })
        XCTAssertEqual(engine.duration, 6, accuracy: 0.1)
    }

    func testPreparedAdvancePreservesPendingPlaybackIntent() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        var advances = 0
        engine.onAdvanced = { advances += 1 }
        engine.load(url: first, nextURL: second, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        XCTAssertTrue(engine.advancePrepared())
        try await waitUntil({ await activation.count == 2 })
        try await activation.complete(0)
        try await activation.complete(1)
        try await waitUntil({ engine.isPlaying && engine.duration > 0 })
        XCTAssertEqual(engine.duration, 6, accuracy: 0.1)
        XCTAssertEqual(advances, 1)
    }

    func testResourceReplacementPreservesPendingPlaybackIntent() async throws {
        let first = try audioFile(seconds: 4), second = try audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: first, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        let previous = engine.activation
        try await engine.replaceResource(url: second, shouldResume: { true })
        try await waitUntil({ await activation.count == 2 })
        try await activation.complete(1)
        try await waitUntil({ engine.isPlaying && engine.duration > 0 })
        try await activation.complete(0, with: .failure(URLError(.cancelled)))
        await previous?.value
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.error)
        XCTAssertEqual(engine.duration, 6, accuracy: 0.1)
    }

    func testRestorationSeeksNativeItemBeforeStartingAndKeepsDisplayedPosition() async throws {
        let url = try audioFile(seconds: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        let position = 67.475
        var samples: [Double] = []
        let record: () -> Void = { [weak engine] in
            if let engine { samples.append(engine.elapsed) }
        }
        engine.onStateChange = record
        engine.onTimeChange = record
        engine.load(url: url, position: position)
        samples.removeAll()
        let native = try nativePlayer(in: engine)
        XCTAssertEqual(engine.elapsed, position, accuracy: 0.001)
        try await waitUntil({ !engine.isLoading })
        XCTAssertNil(engine.error)
        XCTAssertEqual(native.currentTime().seconds, position, accuracy: 0.002)
        XCTAssertEqual(native.rate, 0)
        XCTAssertTrue(samples.allSatisfy { abs($0 - position) < 0.002 }, "Pending restoration must not publish the item's initial zero time")

        engine.play()
        try await waitUntil({ native.currentTime().seconds > position + 0.1 })
        engine.pause()
        XCTAssertEqual(engine.elapsed, native.currentTime().seconds, accuracy: 0.002)
    }

    func testRapidSeeksAndItemReplacementKeepOnlyLatestNativePosition() async throws {
        let first = try audioFile(seconds: 12), second = try audioFile(seconds: 16)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: first)
        try await waitUntil({ !engine.isLoading })
        let native = try nativePlayer(in: engine)
        let original = native.currentItem
        for _ in 0..<5 {
            for target in [7.0, 2.0, 9.0, 3.125] { engine.seek(to: target) }
        }
        XCTAssertEqual(engine.elapsed, 3.125, accuracy: 0.001)
        try await waitUntil({ !engine.isLoading })
        XCTAssertNil(engine.error)
        XCTAssertEqual(native.currentTime().seconds, 3.125, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 3.125, accuracy: 0.002)

        engine.seek(to: 9)
        engine.load(url: second, position: 5.25)
        try await waitUntil({ !engine.isLoading })
        XCTAssertFalse(native.currentItem === original)
        XCTAssertNil(engine.error)
        XCTAssertEqual(native.currentTime().seconds, 5.25, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 5.25, accuracy: 0.002)
        XCTAssertEqual(engine.duration, 16, accuracy: 0.1)
    }

    func testResourceReplacementCapturesNativePositionAndAcceptsLaterSeek() async throws {
        let url = try audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        let original = try nativePlayer(in: engine)
        try await waitUntil({ original.currentTime().seconds > 0.47 })
        let before = original.currentTime().seconds
        try await engine.replaceResource(url: url, shouldResume: { true })
        let replacement = try nativePlayer(in: engine)
        XCTAssertFalse(replacement === original)
        XCTAssertGreaterThanOrEqual(replacement.currentTime().seconds, before - 0.002,
                                    "Resource handover must not rewind to an earlier periodic sample")
        engine.pause()

        var redirected = false
        engine.onStateChange = { [weak engine] in
            guard let engine, !redirected,
                  let current = try? self.nativePlayer(in: engine), current !== replacement else { return }
            redirected = true
            engine.seek(to: 8.375)
        }
        try await engine.replaceResource(url: url, shouldResume: { false })
        try await waitUntil({ !engine.isLoading })
        XCTAssertTrue(redirected)
        XCTAssertNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(try nativePlayer(in: engine).currentTime().seconds, 8.375, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 8.375, accuracy: 0.002)
    }

    func testCancelledResourcePreparationAndHandoverKeepCurrentAudioPlaying() async throws {
        let url = try audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.onStateChange = nil; engine.shutdown() }
        engine.load(url: url, autoplay: true)
        let original = try nativePlayer(in: engine)
        try await waitUntil({ original.currentTime().seconds > 0.2 })
        let discarded = Task { try await engine.replaceResource(url: url, shouldResume: { true }) }
        discarded.cancel()
        do {
            try await discarded.value
            XCTFail("A cancelled candidate must not replace current audio")
        } catch is CancellationError { }
        XCTAssertTrue(try nativePlayer(in: engine) === original)
        let uninterrupted = original.currentTime().seconds
        try await waitUntil({ original.currentTime().seconds > uninterrupted + 0.2 })

        var replacement: Task<Void, Error>?
        var cancelled = false
        engine.onStateChange = { [weak engine] in
            guard let engine, !cancelled,
                  let current = try? self.nativePlayer(in: engine), current !== original else { return }
            cancelled = true
            replacement?.cancel()
        }
        let operation = Task { try await engine.replaceResource(url: url, shouldResume: { true }) }
        replacement = operation
        do {
            try await operation.value
            XCTFail("The superseded resource task must report cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(cancelled)
        let current = try nativePlayer(in: engine)
        let resumedAt = current.currentTime().seconds
        try await waitUntil({ current.currentTime().seconds > resumedAt + 0.2 })
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.error)
    }

    private func nativePlayer(in engine: LocalPlaybackEngine) throws -> AVQueuePlayer {
        try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "player" }?.value as? AVQueuePlayer)
    }
}
