import XCTest

final class FrontendHitTargetTests: XCTestCase {
    @MainActor func testRecentSearchRemovalAcceptsTheMinimumTouchRegion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-searchPreview", "-searchPreviewPage", "recent",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        for offset in [CGVector(dx: -13, dy: 0), CGVector(dx: 13, dy: 0),
                       CGVector(dx: 0, dy: -13), CGVector(dx: 0, dy: 13)] {
            app.launch()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            let remove = app.buttons["移除洛天依"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(offset).tap()
            XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["移除初音未来"].exists, "Removal must keep adjacent search history")
            XCTAssertFalse(app.buttons["综合"].exists, "The touch must remove history without submitting the row")
            app.terminate()
        }
    }
}
