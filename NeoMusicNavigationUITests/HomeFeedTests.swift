import XCTest

@MainActor
final class HomeFeedTests: XCTestCase {
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testHomeLayoutCarouselsAndTabState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let homeTab = app.tabBars.buttons["主页"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10))
        homeTab.tap()

        let hero = element("home.item.featured.favorites", in: app)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        let recent = element("home.item.recent.album-17", in: app)
        XCTAssertEqual(hero.frame.minX, 20, accuracy: 1 / 3)
        XCTAssertEqual(hero.frame.width, 248, accuracy: 1 / 3)
        XCTAssertEqual(hero.frame.height, 330, accuracy: 1 / 3)
        XCTAssertEqual(recent.frame.minX, 20, accuracy: 1 / 3)
        XCTAssertEqual(recent.frame.width, 161, accuracy: 1 / 3)
        if app.frame.width == 402 {
            XCTAssertEqual(hero.frame.minY, 169, accuracy: 1 / 3)
            XCTAssertEqual(recent.frame.minY, 569, accuracy: 1 / 3)
        }
        attachScreenshot("Home first screen", app: app)

        app.buttons["home.account"].tap()
        let identity = app.buttons["account.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(identity.label.contains("登录网易云音乐"))
        identity.tap()
        let completeLogin = app.buttons["account.login.complete"]
        XCTAssertTrue(completeLogin.waitForExistence(timeout: 5))
        completeLogin.tap()
        XCTAssertTrue(element("account.login.error", in: app).waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        app.buttons["account.close"].tap()

        let originalHero = hero.frame
        let originalRecent = recent.frame
        app.scrollViews["home.shelf.featured"].swipeLeft(velocity: .slow)
        XCTAssertLessThan(hero.frame.minX, originalHero.minX - 100)
        XCTAssertEqual(hero.frame.minY, originalHero.minY, accuracy: 1)
        XCTAssertEqual(recent.frame, originalRecent)
        let scrolledHero = hero.frame

        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["新建播放列表"].isHittable)
        XCTAssertTrue(app.buttons["更多"].isHittable)
        XCTAssertTrue(app.buttons["account.open"].isHittable)
        app.buttons["account.open"].tap()
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(identity.label.contains("登录网易云音乐"))
        app.buttons["account.close"].tap()
        homeTab.tap()
        XCTAssertEqual(hero.frame, scrolledHero)
        XCTAssertEqual(recent.frame, originalRecent)

        let feed = app.scrollViews["home.feed"]
        let sections = ["recent", "jpop", "playlists", "fans", "stations", "moods",
                        "chinese-rock", "mandarin", "vocaloid", "2000s", "anime",
                        "games", "jrock", "2010s"]
        for section in sections {
            let heading = element("home.heading.\(section)", in: app)
            for _ in 0..<5 {
                if heading.isHittable { break }
                feed.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(heading.isHittable, "Missing home section: \(section)")
            if section == "moods" { attachScreenshot("Home moods", app: app) }
        }

        let lastCard = element("home.item.2010s.album-14", in: app)
        feed.swipeUp(velocity: .slow)
        XCTAssertTrue(lastCard.isHittable)
        XCTAssertLessThanOrEqual(lastCard.frame.maxY, app.tabBars.firstMatch.frame.minY)
        let miniPlayer = app.buttons["mini.playPause"]
        if miniPlayer.exists {
            XCTAssertLessThanOrEqual(lastCard.frame.maxY, miniPlayer.frame.minY)
        }
        attachScreenshot("Home final section", app: app)

        let title = app.staticTexts["home.title"]
        for _ in 0..<18 {
            if title.isHittable { break }
            feed.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(title.isHittable)
        XCTAssertEqual(recent.frame, originalRecent)
        XCTAssertTrue(homeTab.isHittable)
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
