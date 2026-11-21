import AVFoundation
import XCTest
@testable import NeoMusic

@MainActor final class PlayerEngineTests: XCTestCase {
    func testMissingFileDoesNotPretendToPlay() {
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: URL(fileURLWithPath: "/nonexistent/track.wav"), autoplay: true)
        XCTAssertNotNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isLoading)
    }
    func testSuccessfulLoadSeekPauseAndCancellation() async throws {
        let url = try PlayerTestFixtures.silentAudio()
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio(seconds: 6)
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio(seconds: 6)
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
        let first = try PlayerTestFixtures.silentAudio(), second = try PlayerTestFixtures.silentAudio(seconds: 4)
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio()
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
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
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
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
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
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let results: [Result<Bool, Error>] = [
            .success(false),
            .failure(URLError(.cannotConnectToHost)),
            .failure(NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.insufficientPriority.rawValue))
        ]
        for result in results {
            let activation = SessionActivation()
            let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
            defer { engine.shutdown() }
            engine.load(url: url, autoplay: true)
            try await waitUntil({ await activation.count == 1 })
            try await activation.complete(with: result)
            try await waitUntil({ !engine.isActivating })
            XCTAssertFalse(engine.isPlaying)
            XCTAssertEqual(engine.error, "暂时无法播放，请稍后再试")
        }
    }

    func testAutomaticResumeFailureStaysPausedWithoutErrorAndAllowsManualRetry() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let results: [Result<Bool, Error>] = [
            .success(false),
            .failure(NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.insufficientPriority.rawValue))
        ]
        for result in results {
            let activation = SessionActivation()
            let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
            defer { engine.shutdown() }
            engine.load(url: url, position: 1.25, autoplay: true)
            try await waitUntil({ await activation.count == 1 })
            try await activation.complete()
            try await waitUntil({ engine.isPlaying && !engine.isLoading })
            engine.handleInterruption(began: true)
            let paused = engine.elapsed
            engine.handleInterruption(began: false, shouldResume: true)
            let automaticResume = engine.activation
            try await waitUntil({ await activation.count == 2 })
            try await activation.complete(1, with: result)
            await automaticResume?.value
            XCTAssertFalse(engine.isPlaying)
            XCTAssertFalse(engine.isActivating)
            XCTAssertNil(engine.error)
            XCTAssertEqual(engine.elapsed, paused, accuracy: 0.05)
            let backendState = await engine.debugBackendState()
            XCTAssertEqual(backendState.rate, 0)

            engine.play()
            try await waitUntil({ await activation.count == 3 })
            try await activation.complete(2)
            try await waitUntil({ engine.isPlaying })
            XCTAssertNil(engine.error)
        }
    }

    func testManualPlayDuringAutomaticResumeReportsActivationFailure() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        try await activation.complete()
        try await waitUntil({ engine.isPlaying && !engine.isLoading })
        engine.handleInterruption(began: true)
        engine.handleInterruption(began: false, shouldResume: true)
        try await waitUntil({ await activation.count == 2 })
        let automaticResume = engine.activation
        engine.play()
        try await activation.complete(1, with: .success(false))
        await automaticResume?.value
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isActivating)
        XCTAssertEqual(engine.error, "暂时无法播放，请稍后再试")
        let requests = await activation.count
        XCTAssertEqual(requests, 2)
    }

    func testUserPauseCancelsAutomaticResumeWithoutPublishingLateFailure() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil({ await activation.count == 1 })
        try await activation.complete()
        try await waitUntil({ engine.isPlaying && !engine.isLoading })
        engine.handleInterruption(began: true)
        engine.handleInterruption(began: false, shouldResume: true)
        try await waitUntil({ await activation.count == 2 })
        let automaticResume = engine.activation
        engine.pause()
        try await activation.complete(1, with: .failure(URLError(.cancelled)))
        await automaticResume?.value
        engine.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isActivating)
        XCTAssertNil(engine.error)
        let requests = await activation.count
        XCTAssertEqual(requests, 2)
    }

    func testCancelledSessionActivationCannotResumeAfterUserOrSystemStop() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
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
        let url = try PlayerTestFixtures.silentAudio(seconds: 4)
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio(seconds: 6)
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio(seconds: 6)
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
        let first = try PlayerTestFixtures.silentAudio(seconds: 4), second = try PlayerTestFixtures.silentAudio(seconds: 6)
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
        let url = try PlayerTestFixtures.silentAudio(seconds: 80)
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
        XCTAssertEqual(engine.elapsed, position, accuracy: 0.001)
        try await waitUntil({ !engine.isLoading })
        XCTAssertNil(engine.error)
        let loadedState = await engine.debugBackendState()
        XCTAssertEqual((loadedState.currentPlaybackTime ?? 0), position, accuracy: 0.002)
        XCTAssertEqual(loadedState.rate, 0)
        XCTAssertTrue(samples.allSatisfy { abs($0 - position) < 0.002 }, "Pending restoration must not publish the item's initial zero time")

        engine.play()
        try await waitUntil({
            let state = await engine.debugBackendState()
            return (state.currentPlaybackTime ?? 0) > position + 0.1
        })
        engine.pause()
        let pausedState = await engine.debugBackendState()
        XCTAssertEqual(engine.elapsed, (pausedState.currentPlaybackTime ?? 0), accuracy: 0.05)
    }

    func testRapidSeeksAndItemReplacementKeepOnlyLatestNativePosition() async throws {
        let first = try PlayerTestFixtures.silentAudio(seconds: 12), second = try PlayerTestFixtures.silentAudio(seconds: 16)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: first)
        try await waitUntil({ !engine.isLoading })
        let original = await engine.debugBackendState().itemID
        for _ in 0..<5 {
            for target in [7.0, 2.0, 9.0, 3.125] { engine.seek(to: target) }
        }
        XCTAssertEqual(engine.elapsed, 3.125, accuracy: 0.001)
        try await waitUntil({ !engine.isLoading })
        XCTAssertNil(engine.error)
        let soughtState = await engine.debugBackendState()
        XCTAssertEqual((soughtState.currentPlaybackTime ?? 0), 3.125, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 3.125, accuracy: 0.002)

        engine.seek(to: 9)
        engine.load(url: second, position: 5.25)
        try await waitUntil({ !engine.isLoading })
        let replacedState = await engine.debugBackendState()
        XCTAssertNotEqual(replacedState.itemID, original)
        XCTAssertNil(engine.error)
        XCTAssertEqual((replacedState.currentPlaybackTime ?? 0), 5.25, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 5.25, accuracy: 0.002)
        XCTAssertEqual(engine.duration, 16, accuracy: 0.1)
    }

    func testResourceReplacementCapturesNativePositionAndAcceptsLaterSeek() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil({
            let state = await engine.debugBackendState()
            return (state.currentPlaybackTime ?? 0) > 0.47
        })
        let originalState = await engine.debugBackendState()
        let originalID = originalState.itemID
        let before = originalState.currentPlaybackTime ?? 0
        try await engine.replaceResource(url: url, shouldResume: { true })
        let replacementState = await engine.debugBackendState()
        XCTAssertNotEqual(replacementState.itemID, originalID)
        XCTAssertGreaterThanOrEqual((replacementState.currentPlaybackTime ?? 0), before - 0.02,
                                    "Resource handover must not rewind to an earlier periodic sample")
        engine.pause()

        var redirected = false
        engine.onStateChange = { [weak engine] in
            guard let engine, !redirected, engine.isLoading else { return }
            redirected = true
            engine.seek(to: 8.375)
        }
        try await engine.replaceResource(url: url, shouldResume: { false })
        try await waitUntil({ !engine.isLoading })
        XCTAssertTrue(redirected)
        XCTAssertNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
        let finalState = await engine.debugBackendState()
        XCTAssertEqual((finalState.currentPlaybackTime ?? 0), 8.375, accuracy: 0.002)
        XCTAssertEqual(engine.elapsed, 8.375, accuracy: 0.002)
    }

    func testCancelledResourcePreparationAndHandoverKeepCurrentAudioPlaying() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.onStateChange = nil; engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil({
            let state = await engine.debugBackendState()
            return (state.currentPlaybackTime ?? 0) > 0.2
        })
        let originalID = await engine.debugBackendState().itemID
        let discarded = Task { try await engine.replaceResource(url: url, shouldResume: { true }) }
        discarded.cancel()
        do {
            try await discarded.value
            XCTFail("A cancelled candidate must not replace current audio")
        } catch is CancellationError { }
        let afterCancel = await engine.debugBackendState()
        XCTAssertEqual(afterCancel.itemID, originalID)
        let uninterrupted = afterCancel.currentPlaybackTime ?? 0
        try await waitUntil({
            let state = await engine.debugBackendState()
            return (state.currentPlaybackTime ?? 0) > uninterrupted + 0.2
        })

        var replacement: Task<Void, Error>?
        var cancelled = false
        engine.onStateChange = { [weak engine] in
            guard let engine, !cancelled, engine.isLoading else { return }
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
        let resumedAt = (await engine.debugBackendState().currentPlaybackTime) ?? 0
        try await waitUntil({
            let state = await engine.debugBackendState()
            return (state.currentPlaybackTime ?? 0) > resumedAt + 0.2
        })
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.error)
    }

    @MainActor func testRemoteStreamAttachesStandardFormatSourceNodeWithoutCrashing() async throws {
        let engine = LocalPlaybackEngine(activateSession: { true })
        defer { engine.shutdown() }
        engine.load(url: URL(string: "https://example.invalid/stream.mp3")!, autoplay: true)
        try await waitUntil({
            let state = await engine.debugBackendState()
            return state.itemID != nil
        })
        try await Task.sleep(for: .milliseconds(100))
        engine.stop()
    }

    func testTimelineAnchorAdvancesWithoutMainThreadTickStorm() async throws {
        let url = try PlayerTestFixtures.silentAudio(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LocalPlaybackEngine()
        defer { engine.shutdown() }
        var timeCallbacks = 0
        engine.onTimeChange = { timeCallbacks += 1 }
        engine.load(url: url, autoplay: true)
        try await waitUntil({ engine.isPlaying && !engine.isLoading && engine.timelineAnchor.rate > 0 })
        let callbacksAfterStart = timeCallbacks
        let startElapsed = engine.elapsed
        try await Task.sleep(for: .milliseconds(450))
        let laterElapsed = engine.elapsed
        XCTAssertGreaterThan(laterElapsed, startElapsed + 0.3, "Timeline anchor must advance elapsed smoothly")
        XCTAssertLessThanOrEqual(timeCallbacks - callbacksAfterStart, 3, "Main thread must not receive 60Hz tick storms")
    }
}
