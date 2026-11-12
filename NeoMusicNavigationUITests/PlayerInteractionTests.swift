import XCTest

final class PlayerInteractionTests: XCTestCase {
    @MainActor func testShortTrackDragsReturnToCurrentSongForFiveRounds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "player-motion"]
        app.launch()
        let title = app.staticTexts["窗边的光"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let originalFrame = title.frame
        for round in 0..<5 {
            let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let finish = start.withOffset(CGVector(dx: round.isMultiple(of: 2) ? -35 : 35, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(title.exists, "A short drag must keep the current song")
            XCTAssertEqual(title.frame.minX, originalFrame.minX, accuracy: 1)
            XCTAssertEqual(title.frame.minY, originalFrame.minY, accuracy: 1)
        }
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["沿着海岸"].firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Five short drags followed by next track"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
