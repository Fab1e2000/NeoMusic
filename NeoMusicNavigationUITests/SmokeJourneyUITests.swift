import XCTest

@MainActor
final class SmokeJourneyUITests: XCTestCase {
    func testOfflineColdLaunchAndLibraryJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-smokeJourney", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        assertScreen("资料库", in: app)
        for tab in ["主页", "搜索", "资料库"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            assertScreen(tab, in: app)
        }

        openCategory("歌曲", in: app)
        let sort = app.navigationBars.buttons["更多"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        let nameSection = app.descendants(matching: .any)["library.track.group.A"].firstMatch
        XCTAssertFalse(nameSection.exists)
        sort.tap()
        let name = app.buttons["名称"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let indexedTrack = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A Very Long Song Title")).firstMatch
        XCTAssertTrue(indexedTrack.waitForExistence(timeout: 5))
        XCTAssertTrue(nameSection.waitForExistence(timeout: 5))
        XCTAssertTrue(indexedTrack.isHittable)
        XCTAssertTrue(app.buttons["播放"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["随机播放"].firstMatch.isHittable)
        let trackID = indexedTrack.identifier
        let trackMenu = app.cells.containing(.button, identifier: trackID).firstMatch.buttons["更多"]
        XCTAssertTrue(trackMenu.isHittable)
        trackMenu.tap()
        let queue = app.buttons["添加到队列"].firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        queue.tap()

        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("zzzzsmokenomatch\n")
        let empty = app.staticTexts["没有找到结果"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertFalse(indexedTrack.exists)
        let clear = app.buttons["library.empty.clear-search"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(clear.label, "清除搜索")
        clear.tap()
        XCTAssertTrue(empty.waitForNonExistence(timeout: 5))
        XCTAssertTrue(indexedTrack.waitForExistence(timeout: 5))
        let closeSearch = app.navigationBars["歌曲"].buttons["关闭"]
        if closeSearch.exists { closeSearch.tap() }
        let songsBack = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(songsBack.waitForExistence(timeout: 5))
        songsBack.tap()
        assertScreen("资料库", in: app)

        openCategory("专辑", in: app)
        visitDetail(titlePrefix: "沿着城市边缘一直走到海边", returningTo: "专辑", in: app)
        app.navigationBars.buttons["BackButton"].tap()
        assertScreen("资料库", in: app)

        openCategory("播放列表", in: app)
        visitDetail(titlePrefix: "在漫长通勤与夜晚散步途中", returningTo: "播放列表", in: app)
        app.navigationBars.buttons["BackButton"].tap()
        assertScreen("资料库", in: app)
    }

    private func openCategory(_ title: String, in app: XCUIApplication) {
        let entry = app.buttons[title].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        assertScreen(title, in: app)
    }

    private func visitDetail(titlePrefix: String, returningTo title: String, in app: XCUIApplication) {
        let item = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", titlePrefix)).firstMatch
        for _ in 0..<2 {
            for _ in 0..<3 where !item.isHittable { app.swipeUp() }
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            XCTAssertTrue(item.isHittable)
            item.tap()
            XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
            let play = app.buttons["播放"].firstMatch
            let track = app.cells.firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            XCTAssertTrue(play.isEnabled)
            XCTAssertTrue(track.waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].tap()
            assertScreen(title, in: app)
        }
    }

    private func assertScreen(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "Expected \(title)")
    }
}
