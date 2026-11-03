import XCTest

final class ArtistIntegrationUITests: XCTestCase {
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
