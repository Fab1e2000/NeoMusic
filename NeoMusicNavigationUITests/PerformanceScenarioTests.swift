import XCTest

/// Run on the isolated simulator prepared by scripts/performance-benchmark.py.
@MainActor
final class PerformanceScenarioTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["NEOMUSIC_PERFORMANCE_FIXTURE"] == "1" else {
            throw XCTSkip("Requires the isolated performance fixture")
        }
    }

    func testLaunchToResponsive() throws {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
        XCTAssertTrue(app.buttons["歌曲"].firstMatch.waitForExistence(timeout: 10))
        try assertRestoredMiniPlayerLayout(app)
        screenshot("launch", app)
    }

    func testColdRestoredMiniPlayerTitleLayout() throws {
        let app = launch()
        try assertRestoredMiniPlayerLayout(app)
        screenshot("cold-restored-mini-player", app)
    }

    private func assertRestoredMiniPlayerLayout(_ app: XCUIApplication) throws {
        let play = app.buttons["mini.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let next = app.buttons["mini.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // LNPopup exposes the hosted title slot as a button without text children.
        // The retained launch recording and screenshot cover its rendered text.
        let title = try miniPlayerTitle(app)
        XCTAssertGreaterThan(title.frame.minX, app.frame.minX + 50)
        XCTAssertLessThan(title.frame.maxX, play.frame.minX)
        XCTAssertGreaterThan(title.frame.minY, app.frame.height * 0.7)
        XCTAssertLessThan(abs(title.frame.midY - play.frame.midY), 20)
        // On the 402 pt fixture the floating bar's 20 pt inset leaves the
        // trailing control 20...44 pt from the window edge.
        XCTAssertGreaterThan(app.frame.maxX - next.frame.maxX, 15)
        XCTAssertLessThan(app.frame.maxX - next.frame.maxX, 45)
    }

    func testSongListScroll() {
        let app = launch()
        app.buttons["歌曲"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Track 001"].firstMatch.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app),
                          XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
        screenshot("songs-scroll", app)
    }

    func testFirstDetailAndReturn() {
        let app = launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            app.buttons["播放列表"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Performance Playlist"].firstMatch.waitForExistence(timeout: 10))
            app.staticTexts["Performance Playlist"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 10))
            app.swipeUp(velocity: .fast)
            app.navigationBars.buttons["BackButton"].tap()
            app.navigationBars.buttons["BackButton"].tap()
            XCTAssertTrue(app.buttons["歌曲"].firstMatch.waitForExistence(timeout: 10))
        }
        screenshot("detail-return", app)
    }

    func testPlaylistAndLongQueueScroll() throws {
        let app = launch()
        let title = try miniPlayerTitle(app)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            app.buttons["播放列表"].firstMatch.tap()
            let playlist = app.staticTexts["Performance Playlist"].firstMatch
            XCTAssertTrue(playlist.waitForExistence(timeout: 10))
            playlist.tap()
            XCTAssertTrue(app.staticTexts["Track 001"].firstMatch.waitForExistence(timeout: 10))
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.navigationBars.buttons["BackButton"].tap()
            app.navigationBars.buttons["BackButton"].tap()
            title.tap()
            let queue = self.showQueue(app)
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            queue?.tap()
            app.buttons["收起播放器"].tap()
        }
        app.buttons["播放列表"].firstMatch.tap()
        app.staticTexts["Performance Playlist"].firstMatch.tap()
        screenshot("playlist-long-scroll", app)
        app.navigationBars.buttons["BackButton"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        title.tap()
        showQueue(app)
        screenshot("queue-long-scroll", app)
        app.buttons["收起播放器"].tap()
    }

    func testTabsAccountAndPlayer() throws {
        let app = launch()
        for tab in ["主页", "新发现", "广播", "搜索", "资料库"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.buttons["account.open"].waitForExistence(timeout: 5))
            app.buttons["account.open"].tap()
            XCTAssertTrue(app.buttons["account.close"].waitForExistence(timeout: 5))
            if tab == "主页" {
                let quality = app.buttons["account.quality"]
                XCTAssertTrue(quality.waitForExistence(timeout: 5))
                quality.tap()
                XCTAssertTrue(app.navigationBars["音质"].waitForExistence(timeout: 5))
                screenshot("quality-settings", app)
                app.navigationBars.buttons["BackButton"].tap()
            }
            app.buttons["account.close"].tap()
        }
        let mini = app.buttons["mini.playPause"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertEqual(mini.label, "暂停")
        screenshot("playing-library", app)
        mini.tap()
        XCTAssertEqual(mini.label, "播放")
    }

    func testPlayerPagesWithTimedLyrics() throws {
        guard ProcessInfo.processInfo.environment["NEOMUSIC_PERFORMANCE_LYRICS"] == "1" else {
            throw XCTSkip("Requires the separate timed-lyrics smoke fixture")
        }
        let app = launch()
        let mini = app.buttons["mini.playPause"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        if mini.label == "播放" { mini.tap() }
        let title = try miniPlayerTitle(app)
        title.tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        screenshot("player-artwork", app)
        try XCTUnwrap(app.buttons.matching(identifier: "歌词").allElementsBoundByIndex.first { $0.isHittable }).tap()
        XCTAssertTrue(app.buttons["Performance lyric one"].firstMatch.waitForExistence(timeout: 5))
        screenshot("player-lyrics", app)
        showQueue(app)
        screenshot("player-queue", app)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertEqual(mini.label, "播放")
    }

    func testFirstPlayerPageSwitches() throws {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: playerSwitchMetrics(app), options: options) {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["歌曲"].firstMatch.waitForExistence(timeout: 30))
            try? miniPlayerTitle(app).tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            let queue = app.buttons.matching(identifier: "继续播放").allElementsBoundByIndex.first { $0.isHittable }
            let lyrics = app.buttons.matching(identifier: "歌词").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(queue)
            XCTAssertEqual(lyrics?.isEnabled, true)
            startMeasuring()
            queue?.tap()
            Thread.sleep(forTimeInterval: 1)
            lyrics?.tap()
            Thread.sleep(forTimeInterval: 1)
            lyrics?.tap()
            Thread.sleep(forTimeInterval: 1)
            stopMeasuring()
        }
    }

    private func playerSwitchMetrics(_ app: XCUIApplication) -> [any XCTMetric] {
        [XCTCPUMetric(application: app), XCTHitchMetric(application: app),
         XCTOSSignpostMetric(subsystem: "com.elsterlee.NeoMusic", category: "Performance", name: "PlayerPageSwitch"),
         XCTOSSignpostMetric(subsystem: "com.elsterlee.NeoMusic", category: "Performance", name: "QueueUpdate")]
    }

    func testPlayerPageSwitches() throws {
        let app = launch()
        try miniPlayerTitle(app).tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        let queue = try XCTUnwrap(app.buttons.matching(identifier: "继续播放")
            .allElementsBoundByIndex.first { $0.isHittable })
        let lyrics = try XCTUnwrap(app.buttons.matching(identifier: "歌词")
            .allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertTrue(lyrics.isEnabled, "Seed Track 001.lrc alongside the fixture audio")
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: playerSwitchMetrics(app), options: options) {
            queue.tap()
            Thread.sleep(forTimeInterval: 1)
            lyrics.tap()
            Thread.sleep(forTimeInterval: 1)
            lyrics.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        queue.tap()
        screenshot("queue-initial", app)
        app.swipeUp(velocity: .slow)
        screenshot("queue-collapsed-header", app)
        app.swipeUp(velocity: .fast)
        screenshot("queue-middle", app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["歌曲"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    private func miniPlayerTitle(_ app: XCUIApplication) throws -> XCUIElement {
        try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
            $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
        }, "Mini-player title button")
    }

    @discardableResult
    private func showQueue(_ app: XCUIApplication) -> XCUIElement? {
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        let queue = app.buttons.matching(identifier: "继续播放").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(queue)
        queue?.tap()
        XCTAssertTrue(app.staticTexts["Track 002"].firstMatch.waitForExistence(timeout: 5))
        return queue
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
