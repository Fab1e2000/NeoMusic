import XCTest

@MainActor
final class HomeFeedTests: XCTestCase {
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testRootAccountToolbarMatchesLibraryAcrossAllTabs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let libraryTab = app.tabBars.buttons["资料库"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        let account = app.buttons["account.open"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        let libraryFrame = account.frame

        for title in ["主页", "资料库", "搜索"] {
            app.tabBars.buttons[title].tap()
            let navigationBar = app.navigationBars[title]
            XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
            XCTAssertTrue(account.isHittable, "Missing account entry in \(title)")
            let frame = account.frame
            XCTAssertEqual(frame.minX, libraryFrame.minX, accuracy: 1, "\(title) account x")
            XCTAssertEqual(frame.minY, libraryFrame.minY, accuracy: 1, "\(title) account y")
            XCTAssertEqual(frame.width, libraryFrame.width, accuracy: 1, "\(title) account width")
            XCTAssertEqual(frame.height, libraryFrame.height, accuracy: 1, "\(title) account height")
            attachScreenshot("\(title) account toolbar", app: app)

            account.tap()
            let identity = app.buttons["account.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            let close = app.buttons["account.close"]
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(identity.waitForNonExistence(timeout: 5))
            XCTAssertTrue(navigationBar.isHittable)
            XCTAssertTrue(account.isHittable)
        }
    }

    func testHomeLayoutAndIndependentDetailNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let homeTab = app.tabBars.buttons["主页"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        homeTab.tap()
        let hero = element("home.quick-action.dailySongs", in: app)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.frame.minX, 20, accuracy: 1)
        XCTAssertEqual(hero.frame.width, 248, accuracy: 1)
        XCTAssertEqual(hero.frame.height, 330, accuracy: 1)
        XCTAssertFalse(element("home.heading.jpop", in: app).exists)
        XCTAssertFalse(element("home.item.favorites", in: app).exists)
        let quickActions = app.scrollViews["home.quick-actions"]
        XCTAssertTrue(quickActions.exists)
        attachScreenshot("Home production content", app: app)
        quickActions.swipeLeft(velocity: .slow)
        let hot = element("home.quick-action.hotSongs", in: app)
        XCTAssertTrue(hot.isHittable)
        let original = hot.frame
        hot.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["热歌榜"].waitForExistence(timeout: 10))
        attachScreenshot("Home hot chart cover", app: app)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let partialReturn = app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: partialReturn, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["热歌榜"].isHittable)
        attachScreenshot("Home hot chart after cancelled return", app: app)
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        homeTab.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["热歌榜"].isHittable)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(hot.waitForExistence(timeout: 5))
        XCTAssertEqual(hot.frame.minY, original.minY, accuracy: 1)
        XCTAssertEqual(hot.frame.minX, original.minX, accuracy: 1)
        app.scrollViews["home.feed"].swipeUp(velocity: .slow)
        XCTAssertFalse(app.buttons["载入更多"].exists)
        attachScreenshot("Home restored after detail", app: app)
    }

    func testPublicRecommendationOpensDetailAndRequestsLoginForPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let home = app.tabBars.buttons["主页"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let shelf = app.scrollViews["home.shelf.recommendedPlaylists"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 30))
        app.scrollViews["home.feed"].swipeUp(velocity: .slow)
        let recommendation = shelf.buttons.firstMatch
        XCTAssertTrue(recommendation.waitForExistence(timeout: 5))
        attachScreenshot("Home recommendation artwork", app: app)
        recommendation.tap()
        let play = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "播放", "mini.playPause")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        attachScreenshot("Public recommendation detail", app: app)
        play.tap()
        XCTAssertTrue(app.buttons["account.login.complete"].waitForExistence(timeout: 10))
        app.navigationBars["登录网易云音乐"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["account.close"].waitForExistence(timeout: 5))
        app.buttons["account.close"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["mini.playPause"].label, "播放")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
