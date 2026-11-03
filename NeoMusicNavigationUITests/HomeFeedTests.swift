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

        for title in ["主页", "新发现", "广播", "资料库", "搜索"] {
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
        let hero = element("home.item.favorites", in: app)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.frame.minX, 20, accuracy: 1)
        XCTAssertEqual(hero.frame.width, 248, accuracy: 1)
        XCTAssertEqual(hero.frame.height, 330, accuracy: 1)
        XCTAssertFalse(element("home.heading.jpop", in: app).exists)
        let original = hero.frame
        attachScreenshot("Home production content", app: app)
        hero.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["喜爱歌曲"].isHittable)
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        homeTab.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["喜爱歌曲"].isHittable)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.frame.minY, original.minY, accuracy: 1)
        XCTAssertEqual(hero.frame.minX, original.minX, accuracy: 1)
        attachScreenshot("Home restored after detail", app: app)
    }

    func testPublicRecommendationOpensDetailAndRequestsLoginForPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let home = app.tabBars.buttons["主页"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let shelf = app.scrollViews["home.shelf.recommendations"]
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
