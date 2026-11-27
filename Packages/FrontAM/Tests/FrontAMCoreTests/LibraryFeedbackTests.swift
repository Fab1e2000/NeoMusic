import UIKit
import XCTest
@testable import FrontAMCore

@MainActor
final class LibraryFeedbackTests: XCTestCase {
    func testSuccessfulFavoriteAndPinConfirmationsDoNotReplayFeedback() {
        let center = LibraryToastCenter()
        var pulses: [LibraryHaptics.Feedback] = []
        LibraryHaptics.$output.withValue(.init { pulses.append($0) }) {
            LibraryHaptics.success()
            center.show(.favorited)
            center.show(.unfavorited)
            center.show(.pinned)
            center.show(.unpinned)
            XCTAssertEqual(pulses, [.success])
        }
    }

    func testErrorWithoutRecentPositiveIsSynchronous() {
        let timing = LibraryFeedbackTiming()
        var errors = 0
        timing.error { errors += 1 }
        XCTAssertEqual(errors, 1)
    }

    func testWindowFallbackWhileKeyWindowIsChanging() {
        let first = UIWindow()
        let key = KeyWindow()
        XCTAssertTrue(LibraryHaptics.feedbackWindow(keyWindow: first, windows: [key]) === first)
        XCTAssertTrue(LibraryHaptics.feedbackWindow(keyWindow: nil, windows: [first, key]) === key)
        XCTAssertTrue(LibraryHaptics.feedbackWindow(keyWindow: nil, windows: [first]) === first)
        XCTAssertNil(LibraryHaptics.feedbackWindow(keyWindow: nil, windows: []))
    }

    func testImmediateFailureWaitsOnlyTheRemainingInterval() async {
        let start = ContinuousClock.now
        var time = start
        var deadlines: [ContinuousClock.Instant] = []
        let timing = LibraryFeedbackTiming(now: { time }, sleep: { deadline in
            deadlines.append(deadline)
            time = deadline
        })
        let fired = expectation(description: "one separated error")
        timing.recordPositive()
        time = start.advanced(by: .milliseconds(40))
        timing.error { fired.fulfill() }
        timing.error { XCTFail("A pending error pulse already covers this failure") }
        XCTAssertTrue(deadlines.isEmpty)
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertEqual(deadlines, [start.advanced(by: LibraryFeedbackTiming.separation)])
        var subsequentErrors = 0
        timing.error { subsequentErrors += 1 }
        XCTAssertEqual(subsequentErrors, 1)
    }
}

private final class KeyWindow: UIWindow {
    override var isKeyWindow: Bool { true }
}
