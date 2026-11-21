import XCTest

@MainActor
final class FullScreenPlayerPerformanceTests: XCTestCase {
    private var controls: [String: CGVector] = [:]
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["NEOMUSIC_PLAYER_PERFORMANCE"] == "1" else {
            throw XCTSkip("Requires the isolated Release player performance build")
        }
    }

    func testAutomaticScenario() throws {
        let app = launchPlayer()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
                          XCTHitchMetric(application: app)], options: options) {
            runInteractionRound(app)
        }
        for (page, label) in [("artwork", "歌词"), ("lyrics", "继续播放"), ("queue", "继续播放")] {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "performance-\(page)"
            attachment.lifetime = .keepAlways
            add(attachment)
            tapControl(label, in: app)
        }
        app.terminate()
    }

    func testPageToggleMatchesNativeButton() throws {
        let app = launchPlayer()
        defer { app.terminate() }
        tapControl("player.dismiss", in: app)
        let nativeButton = app.buttons["performance.nativeButton"]
        XCTAssertTrue(nativeButton.waitForExistence(timeout: 5))
        nativeButton.doubleTap()
        let taps = try XCTUnwrap(Int(app.staticTexts["performance.nativeTapCount"].label))
        XCTAssertTrue((1...2).contains(taps))
        print("NATIVE_DOUBLE_TAP_ACTION_COUNT=\(taps)")
        app.buttons["performance.open"].tap()
        XCTAssertTrue(app.buttons["player.dismiss"].waitForExistence(timeout: 5))
        for label in ["继续播放", "歌词"] {
            tapControl(label, in: app, count: 2)
            let selected = taps % 2 == 1
            let matchesNative = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)),
                                                         object: app.buttons[label].firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [matchesNative], timeout: 3), .completed)
            if selected {
                tapControl(label, in: app)
                XCTAssertFalse(app.buttons[label].firstMatch.isSelected)
            }
            XCTAssertTrue(app.buttons["player.dismiss"].exists)
        }
    }

    func testSteadyStateResources() {
        let app = launchPlayer()
        defer { app.terminate() }
        XCTContext.runActivity(named: "Steady artwork playback 20s") { _ in Thread.sleep(forTimeInterval: 20) }
        tapControl("歌词", in: app)
        XCTContext.runActivity(named: "Steady lyrics playback 20s") { _ in Thread.sleep(forTimeInterval: 20) }
        tapControl("歌词", in: app)
        visibleButton("暂停", in: app).tap()
        XCTContext.runActivity(named: "Paused artwork 20s") { _ in Thread.sleep(forTimeInterval: 20) }
        visibleButton("播放", in: app).tap()
        tapControl("player.dismiss", in: app)
        XCTAssertTrue(app.buttons["performance.open"].waitForExistence(timeout: 5))
        XCTContext.runActivity(named: "Collapsed playback 20s") { _ in Thread.sleep(forTimeInterval: 20) }
        XCUIDevice.shared.press(.home)
        XCTContext.runActivity(named: "Background playback 20s") { _ in Thread.sleep(forTimeInterval: 20) }
        app.activate()
        app.buttons["performance.open"].tap()
        XCTAssertTrue(app.buttons["player.dismiss"].waitForExistence(timeout: 5))
    }

    private func launchPlayer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "player-performance"]
        app.launch()
        XCTAssertTrue(app.buttons["player.dismiss"].waitForExistence(timeout: 30))
        for label in ["继续播放", "歌词", "下一首", "player.dismiss"] {
            let frame = visibleButton(label, in: app).frame
            controls[label] = CGVector(dx: frame.midX / app.frame.width, dy: frame.midY / app.frame.height)
        }
        if let delay = ProcessInfo.processInfo.environment["NEOMUSIC_TRACE_DELAY"].flatMap(Double.init) {
            print("PLAYER_PERFORMANCE_READY")
            Thread.sleep(forTimeInterval: delay)
        }
        return app
    }

    private func runInteractionRound(_ app: XCUIApplication) {
        startMeasuring()
        XCTContext.runActivity(named: "Page transitions") { _ in
            for _ in 0..<2 {
                tapControl("继续播放", in: app)
                tapControl("歌词", in: app)
                tapControl("歌词", in: app)
            }
        }
        XCTContext.runActivity(named: "Queue scrolling") { _ in
            tapControl("继续播放", in: app)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTContext.runActivity(named: "Lyrics scrolling and distant seek") { _ in
            tapControl("歌词", in: app)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
            for _ in 0..<3 {
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            }
            end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.38)).tap()
            Thread.sleep(forTimeInterval: 0.6)
            tapControl("歌词", in: app)
        }
        XCTContext.runActivity(named: "Track changes and transport") { _ in
            for _ in 0..<3 { tapControl("下一首", in: app) }
            let progress = app.sliders["播放进度"]
            XCTAssertTrue(progress.exists)
            progress.adjust(toNormalizedSliderPosition: 0.4)
            progress.adjust(toNormalizedSliderPosition: 0.1)
            let volume = app.sliders["系统音量"]
            if volume.exists {
                let original = (volume.value as? String).flatMap {
                    Double($0.filter { $0.isNumber || $0 == "." })
                }.map { CGFloat($0 / 100) }
                volume.adjust(toNormalizedSliderPosition: 0.3)
                if let original { volume.adjust(toNormalizedSliderPosition: original) }
            }
        }
        XCTContext.runActivity(named: "Collapse and expand") { _ in
            tapControl("player.dismiss", in: app)
            let open = app.buttons["performance.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            XCTAssertTrue(app.buttons["player.dismiss"].waitForExistence(timeout: 5))
        }
        stopMeasuring()
    }

    private func tapControl(_ label: String, in app: XCUIApplication, count: Int = 1) {
        guard let point = controls[label] else { XCTFail("Missing control position: \(label)"); return }
        let coordinate = app.coordinate(withNormalizedOffset: point)
        if count == 2 { coordinate.doubleTap() } else { coordinate.tap() }
    }

    private func visibleButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(identifier: label).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(button, "Expected visible control: \(label)")
        return button ?? app.buttons[label].firstMatch
    }
}

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
        let title = try miniPlayerTitle(app)
        XCTAssertGreaterThan(title.frame.minX, app.frame.minX + 50)
        XCTAssertLessThan(title.frame.maxX, play.frame.minX)
        XCTAssertGreaterThan(title.frame.minY, app.frame.height * 0.7)
        XCTAssertLessThan(abs(title.frame.midY - play.frame.midY), 20)
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

    func testMiniPlayerRetainsMinimizationAndRestoresControls() throws {
        let app = launch()
        app.buttons["歌曲"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Track 001"].firstMatch.waitForExistence(timeout: 10))
        let next = app.buttons["mini.next"]
        let play = app.buttons["mini.playPause"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let expandedY = play.frame.minY
        for cycle in 0..<3 {
            app.swipeUp(velocity: .fast)
            let minimized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: next)
            XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 5), .completed)
            XCTAssertTrue(play.isHittable)
            XCTAssertGreaterThan(play.frame.minY, expandedY + 20, "The bar must actually move into the minimized position")
            if cycle == 0 { screenshot("mini-inline", app) }
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            XCTAssertTrue(play.isHittable)
            XCTAssertTrue(next.isHittable)
        }
        screenshot("mini-restored", app)
        try miniPlayerTitle(app).tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.buttons["mini.playPause"].isHittable)
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
        for tab in ["主页", "搜索", "资料库"] {
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
