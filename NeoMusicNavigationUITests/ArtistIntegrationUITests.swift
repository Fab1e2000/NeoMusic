import XCTest

final class ArtistIntegrationUITests: XCTestCase {
    @MainActor func testCaptureArtistBackdrop() throws {
        let app = XCUIApplication()
        for (name, arguments) in [("approved", ["-artistPagePreview", "home"]),
                                  ("production", ["-catalogArtist", "13223"])] {
            app.launchArguments = arguments
            app.launch()
            XCTAssertTrue(app.buttons["歌曲排行"].waitForExistence(timeout: 40))
            // Wait for actual image pixels, so a successful capture cannot contain an empty header.
            let artworkVisible = NSPredicate { _, _ in
                guard let image = app.screenshot().image.cgImage,
                      let crop = image.cropping(to: CGRect(x: image.width / 3, y: image.height / 7,
                                                         width: image.width / 3, height: image.height / 7)),
                      let data = crop.dataProvider?.data else { return false }
                let bytes = CFDataGetBytePtr(data)!
                var low = 255, high = 0
                for row in stride(from: 0, to: crop.height, by: 8) {
                    for column in stride(from: 0, to: crop.width, by: 8) {
                        let value = Int(bytes[row * crop.bytesPerRow + column * crop.bitsPerPixel / 8])
                        low = min(low, value); high = max(high, value)
                    }
                }
                return high - low > 50
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: artworkVisible, object: nil)], timeout: 45), .completed)
            func capture(_ phase: String) {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "artist-\(name)-\(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            capture("top")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            capture("up")
            end.press(forDuration: 0.1, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.2)
            capture("returned")
            app.terminate()
        }
    }

    @MainActor func testArtistChartBiographyAndAlbumNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-catalogArtist", "6452"]
        app.launch()
        let chart = app.buttons["歌曲排行"]
        XCTAssertTrue(chart.waitForExistence(timeout: 40))
        app.buttons["艺人简介"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        chart.tap()
        XCTAssertTrue(app.navigationBars["歌曲排行"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["艺人简介"].waitForExistence(timeout: 5))
        let release = app.buttons.containing(.staticText, identifier: "太阳之子").firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        release.tap()
        XCTAssertTrue(app.staticTexts["13 首歌曲"].waitForExistence(timeout: 20) || app.buttons["随机播放"].waitForExistence(timeout: 20))
    }
}
