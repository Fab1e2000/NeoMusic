import XCTest
@testable import NeoMusic

@MainActor
final class NowPlayingLyricsLoadingTests: XCTestCase {
    func testLoadingFeedbackWaitsThreeSeconds() async throws {
        let feedback = NowPlayingLyricsLoadingFeedback()
        let started = ContinuousClock.now
        let task = Task { await feedback.waitToShow(for: "first") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(feedback.visibleTrackID)
        await task.value
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(3))
        XCTAssertEqual(feedback.visibleTrackID, "first")
    }

    func testCancelledPreviousTrackCannotReplaceCurrentFeedback() async {
        let feedback = NowPlayingLyricsLoadingFeedback()
        let delay = LyricsFeedbackDelay(started: expectation(description: "Old delay started"))
        let oldTask = Task { await feedback.waitToShow(for: "old", wait: delay.wait) }
        await fulfillment(of: [delay.started], timeout: 1)
        oldTask.cancel()

        await feedback.waitToShow(for: "new", wait: {})
        XCTAssertEqual(feedback.visibleTrackID, "new")
        delay.finish()
        await oldTask.value
        XCTAssertEqual(feedback.visibleTrackID, "new")
    }

    func testFinishingOrHidingLoadCancelsDelayedFeedback() async {
        let feedback = NowPlayingLyricsLoadingFeedback()
        let delay = LyricsFeedbackDelay(started: expectation(description: "Visible load started"))
        let task = Task { await feedback.waitToShow(for: "song", wait: delay.wait) }
        await fulfillment(of: [delay.started], timeout: 1)
        task.cancel()
        feedback.reset()
        delay.finish()
        await task.value
        XCTAssertNil(feedback.visibleTrackID)

        await feedback.waitToShow(for: "song", wait: {})
        XCTAssertEqual(feedback.visibleTrackID, "song")
        feedback.reset()
        XCTAssertNil(feedback.visibleTrackID)
    }
}

@MainActor
private final class LyricsFeedbackDelay {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
