import XCTest

final class SearchInteractionTests: XCTestCase {
    @MainActor func testNativeFocusTypingSubmitAndCancel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-searchPreview", "-searchPreviewPage", "recent"]
        app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThan(keyboard.frame.minY, 600)
        capture(app, "recent-keyboard")
        app.buttons["清除"].tap()
        XCTAssertTrue(app.staticTexts["无最近搜索"].exists)
        capture(app, "recent-empty")
        field.typeText("洛天依")
        XCTAssertEqual(field.value as? String, "洛天依")
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThan(keyboard.frame.minY, 600)
        let typing = XCTAttachment(screenshot: app.screenshot())
        typing.name = "Search native keyboard and suggestions"
        typing.lifetime = .keepAlways
        add(typing)
        field.typeText("\n")
        XCTAssertTrue(app.buttons["综合"].waitForExistence(timeout: 5))
        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.exists)
        close.tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["综合"].exists)
    }

    @MainActor func testPreviewStatesAndCategoryReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for screen in ["browse", "results", "songs", "category", "syncing", "error", "dark-results"] {
            let mode = screen == "dark-results" ? "results" : screen
            app.launchArguments = ["-searchPreview", "-searchPreviewPage", mode]
            if screen == "dark-results" { app.launchArguments += ["-searchPreviewDark"] }
            app.launch()
            if mode == "browse" {
                let category = app.buttons["流行"].firstMatch
                XCTAssertTrue(category.waitForExistence(timeout: 20))
                category.tap()
                XCTAssertTrue(app.navigationBars["流行"].waitForExistence(timeout: 5))
                app.navigationBars.buttons["BackButton"].tap()
                XCTAssertTrue(category.waitForExistence(timeout: 5))
            } else if mode != "category" {
                XCTAssertTrue(app.buttons["综合"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "洛天依")).firstMatch.waitForExistence(timeout: 20))
            } else {
                XCTAssertTrue(app.navigationBars["流行"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.scrollViews.buttons.firstMatch.waitForExistence(timeout: 20))
            }
            capture(app, screen)
            app.terminate()
        }
    }

    @MainActor func testProductionSearchNavigationAndStateRetention() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let category = app.buttons["流行"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        capture(app, "production-browse")
        category.tap()
        XCTAssertTrue(app.navigationBars["流行"].waitForExistence(timeout: 5))
        let playlist = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 25))
        playlist.tap()
        XCTAssertTrue(app.buttons["随机播放"].waitForExistence(timeout: 15))
        capture(app, "production-playlist")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["流行"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        let field = app.searchFields.firstMatch
        field.tap(); field.typeText("洛天依\n")
        XCTAssertTrue(app.buttons["综合"].waitForExistence(timeout: 10))
        let artist = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "洛天依")).firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 25))
        capture(app, "production-combined")
        app.buttons["艺人"].firstMatch.tap()
        XCTAssertTrue(artist.waitForExistence(timeout: 20))
        let artistResult = app.collectionViews["search.results.100"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result.100:")).firstMatch
        waitUntilHittable(artistResult)
        artistResult.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 10))
        capture(app, "production-artist")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertEqual(field.value as? String, "洛天依")
        app.tabBars.buttons["资料库"].tap()
        app.tabBars.buttons["搜索"].tap()
        XCTAssertEqual(field.value as? String, "洛天依")
        app.buttons["专辑"].firstMatch.tap()
        let albumResult = app.collectionViews["search.results.10"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result.10:")).firstMatch
        waitUntilHittable(albumResult)
        albumResult.tap()
        XCTAssertTrue(app.buttons["随机播放"].waitForExistence(timeout: 15))
        capture(app, "production-album")
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["歌曲"].firstMatch.tap()
        let song = app.collectionViews["search.results.1"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result.1:")).firstMatch
        waitUntilHittable(song)
        capture(app, "production-songs")
        song.tap()
        XCTAssertTrue(app.staticTexts["登录网易云音乐"].waitForExistence(timeout: 10))
    }

    @MainActor private func waitUntilHittable(_ element: XCUIElement) {
        let ready = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: element)
        wait(for: [ready], timeout: 25)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
