import XCTest

/// Runs the same real UI paths against the checkpoint and candidate with identical
/// local fixtures. Baseline is installed separately; no production test switches.
@MainActor
final class FunctionalParityTests: XCTestCase {
    private var versions = [
        ("baseline", "com.elsterlee.NeoMusic.ControlsBaseline"),
        ("candidate", "com.elsterlee.NeoMusic")
    ]
    private var version = ""

    private func launch(_ bundle: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) throws {
        // Screenshot API does not itself wait for SwiftUI's interruptible springs.
        Thread.sleep(forTimeInterval: 0.6)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FunctionalParity/\(version)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: root.appendingPathComponent(name + ".png"))
        if name == "41-player-rotation" || name == "45-photo-cover-picker" || name == "76-cover-file-picker" || name == "77-lyrics-file-picker" {
            let screen = XCUIScreen.main.screenshot()
            try screen.pngRepresentation.write(to: root.appendingPathComponent(name + "-screen.png"))
            let screenAttachment = XCTAttachment(screenshot: screen)
            screenAttachment.name = "\(version)-\(name)-screen"
            screenAttachment.lifetime = .keepAlways
            add(screenAttachment)
        }
        try app.debugDescription.write(to: root.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        print("PARITY_ARTIFACT \(root.path)/\(name)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(version)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func open(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), name)
        button.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), name)
    }
    private func tapVisible(_ query: XCUIElementQuery) throws {
        let target = try XCTUnwrap(query.allElementsBoundByIndex.last(where: { $0.isHittable }), "Visible control in the frontmost presentation")
        target.tap()
    }
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons["BackButton"].tap()
    }

    private func exerciseMainPagesAndMenus() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            try capture(app, "01-home")
            for category in ["播放列表", "艺人", "专辑", "歌曲", "已下载"] {
                open(category, in: app)
                try capture(app, "02-\(category)")
                if app.navigationBars.buttons["筛选"].exists {
                    app.navigationBars.buttons["筛选"].tap()
                    try capture(app, "03-\(category)-filter")
                    app.tap()
                }
                if app.navigationBars.buttons["更多"].exists {
                    app.navigationBars.buttons["更多"].tap()
                    try capture(app, "04-\(category)-more")
                    app.tap()
                }
                back(app)
                XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            }
            for tab in ["主页", "新发现", "广播", "搜索", "资料库"] {
                app.tabBars.buttons[tab].tap()
                try capture(app, "05-tab-\(tab)")
            }
            app.terminate()
        }
    }

    private func exerciseDownloadedAndArtistRoutes() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("已下载", in: app)
            for category in ["播放列表", "艺人", "专辑", "歌曲"] {
                open(category, in: app)
                try capture(app, "06-downloaded-\(category)")
                back(app)
                XCTAssertTrue(app.navigationBars["已下载"].waitForExistence(timeout: 5))
            }
            back(app)
            open("艺人", in: app)
            let artist = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Aurora")).firstMatch
            XCTAssertTrue(artist.waitForExistence(timeout: 5))
            artist.tap()
            XCTAssertTrue(app.staticTexts["Aurora"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "07-artist-detail")
            app.navigationBars.buttons["喜爱"].tap()
            XCTAssertTrue(app.navigationBars.buttons["取消喜爱"].waitForExistence(timeout: 3))
            app.navigationBars.buttons["取消喜爱"].tap()
            app.navigationBars.buttons["更多"].tap()
            try capture(app, "08-artist-menu")
            app.tap()
            back(app); back(app)
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func exerciseSearchFilterAndLayout() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            for (category, term) in [("歌曲", "Alpha"), ("专辑", "Sunrise"), ("播放列表", "Parity Mix")] {
                open(category, in: app)
                if !app.searchFields.firstMatch.isHittable { app.swipeDown() }
                let field = app.searchFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 3), "Search missing: \(category)")
                XCTAssertTrue(field.isHittable)
                field.tap(); field.typeText(term)
                XCTAssertTrue(app.staticTexts[term].firstMatch.waitForExistence(timeout: 3))
                try capture(app, "09-search-\(category)")
                field.typeText("ZZZ")
                let results = category == "歌曲" ? app.collectionViews.staticTexts[term].firstMatch : app.staticTexts[term].firstMatch
                if category == "播放列表" {
                    XCTExpectFailure("Existing in 8ab6e83: playlist query is stored but not applied to entries; tracked separately from navigation parity.") {
                        XCTAssertTrue(results.waitForNonExistence(timeout: 3))
                    }
                } else {
                    XCTAssertTrue(results.waitForNonExistence(timeout: 3))
                }
                try capture(app, "10-search-empty-\(category)")
                app.buttons["关闭"].firstMatch.tap()
                if category == "专辑" {
                    app.navigationBars.buttons["更多"].tap(); app.buttons["列表"].tap()
                    try capture(app, "11-albums-list")
                    app.navigationBars.buttons["更多"].tap(); app.buttons["名称"].tap()
                    app.navigationBars.buttons["筛选"].tap(); app.buttons["喜爱"].tap()
                    XCTAssertTrue(app.staticTexts["Sunrise"].firstMatch.exists)
                    XCTAssertFalse(app.staticTexts["Night"].firstMatch.exists)
                    try capture(app, "12-albums-favorites")
                }
                back(app)
            }
            app.terminate()
        }
    }

    private func exerciseCreateEditAndDeletePlaylist() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            app.navigationBars.buttons["新建播放列表"].tap()
            XCTAssertTrue(app.textFields["播放列表标题"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["创建"].isEnabled)
            app.textFields["播放列表标题"].typeText("Created Parity")
            try capture(app, "13-create-playlist")
            app.buttons["创建"].tap()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            open("播放列表", in: app)
            app.staticTexts["Created Parity"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars.buttons["更多"].waitForExistence(timeout: 5))
            try capture(app, "14-empty-playlist-detail")
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            XCTAssertTrue(app.textFields["播放列表标题"].waitForExistence(timeout: 5))
            try capture(app, "15-playlist-editor")
            app.buttons["编辑播放列表封面"].tap()
            try capture(app, "16-cover-menu")
            app.tap()
            let title = app.textFields["播放列表标题"]
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let oldTitle = title.value as? String ?? ""
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldTitle.count) + "Created Parity Edited")
            XCTAssertEqual(title.value as? String, "Created Parity Edited")
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertTrue(app.staticTexts["Created Parity Edited"].firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons["更多"].tap(); app.buttons["从资料库删除"].tap()
            try capture(app, "17-playlist-delete-confirmation")
            // iOS presents this confirmation as a popover; cancel by tapping outside.
            app.tap()
            XCTAssertTrue(app.staticTexts["Created Parity Edited"].firstMatch.exists)
            app.navigationBars.buttons["更多"].tap(); app.buttons["从资料库删除"].tap()
            app.buttons["删除播放列表"].tap()
            try capture(app, "17b-after-playlist-delete")
            XCTAssertTrue(app.navigationBars["播放列表"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Created Parity Edited"].exists)
            app.terminate()
        }
    }

    private func exercisePlaybackAndPlayerPages() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha")).firstMatch.tap()
            if app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 1) {
                app.alerts.buttons["清除队列"].tap()
            }
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            try capture(app, "18-mini-playing")
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            }, "Mini-player title button")
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try capture(app, "19-player-artwork")
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            try capture(app, "20-player-lyrics")
            // The fixture may retain the manual import from the independent source-priority test.
            let lyric = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["First line", "Repeated line", "Last line", "Imported parity line", "Second imported line"])).firstMatch
            XCTAssertTrue(lyric.waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            try capture(app, "21-player-queue")
            try tapVisible(app.buttons.matching(identifier: "三秒交叉淡化")); try tapVisible(app.buttons.matching(identifier: "三秒交叉淡化"))
            try tapVisible(app.buttons.matching(identifier: "随机播放"))
            XCTAssertTrue(app.buttons["关闭随机播放"].exists)
            try tapVisible(app.buttons.matching(identifier: "关闭随机播放"))
            try tapVisible(app.buttons.matching(identifier: "下一首"))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            XCTAssertTrue(app.buttons.matching(identifier: "播放").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "21b-player-after-next")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 5))
            back(app); open("专辑", in: app)
            try capture(app, "22-navigation-after-player")
            app.terminate()
        }
    }


    private func exerciseFolderCreateRenameAndDelete() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.navigationBars.buttons["新建"].tap(); app.buttons["创建新文件夹"].tap()
            XCTAssertTrue(app.alerts["新建文件夹"].waitForExistence(timeout: 3))
            app.alerts.textFields.firstMatch.typeText("Parity Folder")
            try capture(app, "23-create-folder")
            app.alerts.buttons["创建"].tap()
            app.staticTexts["Parity Folder"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Parity Folder"].waitForExistence(timeout: 5))
            try capture(app, "24-empty-folder")
            app.navigationBars.buttons["更多"].tap(); app.buttons["重新命名"].tap()
            let field = app.alerts.textFields.firstMatch
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Renamed Folder")
            XCTAssertEqual(field.value as? String, "Renamed Folder")
            app.alerts.buttons["存储"].tap()
            XCTAssertTrue(app.navigationBars["Renamed Folder"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["更多"].tap()
            try capture(app, "25-folder-menu")
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(app.alerts.buttons["删除文件夹和播放列表"].waitForExistence(timeout: 3))
            app.alerts.buttons["取消"].tap()
            XCTAssertTrue(app.navigationBars["Renamed Folder"].exists)
            app.navigationBars.buttons["更多"].tap(); app.buttons["从资料库删除"].tap()
            app.alerts.buttons["删除文件夹和播放列表"].tap()
            XCTAssertTrue(app.navigationBars["播放列表"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Renamed Folder"].exists)
            app.terminate()
        }
    }


    private func exercisePlaylistMusicSelectionAndPersistence() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            XCTAssertTrue(app.buttons["添加音乐"].waitForExistence(timeout: 5))
            app.toolbars.buttons["添加音乐"].firstMatch.tap()
            let query = app.textFields["歌曲、艺人或专辑"]
            XCTAssertTrue(query.waitForExistence(timeout: 5))
            try capture(app, "26-music-picker")
            query.tap(); query.typeText("Moon")
            let song = app.buttons["Moon，Borealis"]
            XCTAssertTrue(song.waitForExistence(timeout: 5)); song.tap()
            try capture(app, "27-music-selection")
            app.navigationBars.buttons["关闭"].tap()
            XCTAssertTrue(app.buttons["保留所选内容"].waitForExistence(timeout: 3))
            try capture(app, "28-selection-discard-confirmation")
            app.buttons["保留所选内容"].tap()
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertTrue(app.textFields["播放列表标题"].waitForExistence(timeout: 5))
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            if !app.staticTexts["Moon"].firstMatch.isHittable { app.swipeUp() }
            XCTAssertTrue(app.staticTexts["Moon"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "29-playlist-added-song")
            app.terminate()
            app.launch()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 10))
            open("播放列表", in: app); app.staticTexts["Parity Mix"].firstMatch.tap()
            if !app.staticTexts["Moon"].firstMatch.isHittable { app.swipeUp() }
            XCTAssertTrue(app.staticTexts["Moon"].firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testBaselineMainPagesAndMenus() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseMainPagesAndMenus()
    }
    func testCandidateMainPagesAndMenus() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseMainPagesAndMenus()
    }
    func testBaselineDownloadedAndArtistRoutes() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseDownloadedAndArtistRoutes()
    }
    func testCandidateDownloadedAndArtistRoutes() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseDownloadedAndArtistRoutes()
    }
    func testBaselineSearchFilterAndLayout() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseSearchFilterAndLayout()
    }
    func testCandidateSearchFilterAndLayout() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseSearchFilterAndLayout()
    }
    func testBaselineCreateEditAndDeletePlaylist() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseCreateEditAndDeletePlaylist()
    }
    func testCandidateCreateEditAndDeletePlaylist() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseCreateEditAndDeletePlaylist()
    }
    func testBaselinePlaybackAndPlayerPages() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaybackAndPlayerPages()
    }
    func testCandidatePlaybackAndPlayerPages() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaybackAndPlayerPages()
    }
    func testBaselineFolderCreateRenameAndDelete() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseFolderCreateRenameAndDelete()
    }
    func testCandidateFolderCreateRenameAndDelete() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseFolderCreateRenameAndDelete()
    }
    func testBaselinePlaylistMusicSelectionAndPersistence() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistMusicSelectionAndPersistence()
    }
    func testCandidatePlaylistMusicSelectionAndPersistence() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistMusicSelectionAndPersistence()
    }


    private func exercisePlaylistMoves() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            let source = app.staticTexts["Parity Mix"].firstMatch
            let target = app.staticTexts["Folder B"].firstMatch
            // Drag the cover within the collection cell, then dwell over the folder
            // so the collection view can resolve an insert-into drop proposal.
            let sourceCell = name == "candidate"
                ? app.staticTexts["Parity Mix"].firstMatch
                : app.collectionViews.cells.containing(.staticText, identifier: "Parity Mix").firstMatch
            let targetCell = name == "candidate"
                ? app.staticTexts["Folder B"].firstMatch
                : app.collectionViews.cells.containing(.staticText, identifier: "Folder B").firstMatch
            XCTAssertTrue(sourceCell.isHittable)
            XCTAssertTrue(targetCell.isHittable)
            let sourcePoint = name == "candidate"
                ? sourceCell.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -44, dy: 0))
                : sourceCell.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5))
            let targetPoint = name == "candidate"
                ? targetCell.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -44, dy: 0))
                : targetCell.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5))
            sourcePoint.press(forDuration: 0.5, thenDragTo: targetPoint,
                              withVelocity: .slow, thenHoldForDuration: 1)
            try capture(app, "29-after-playlist-drag")
            XCTAssertTrue(source.waitForNonExistence(timeout: 5))
            target.tap()
            XCTAssertTrue(app.navigationBars["Folder B"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.exists)
            try capture(app, "30-dragged-playlist-in-folder")
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap()
            app.buttons["移到文件夹"].tap()
            try capture(app, "31-detail-move-menu")
            try tapVisible(app.buttons.matching(identifier: "播放列表"))
            back(app); back(app)
            XCTAssertTrue(app.navigationBars["播放列表"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.exists)
            app.terminate()
        }
    }
    func testBaselinePlaylistMoves() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistMoves()
    }
    func testCandidatePlaylistMoves() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistMoves()
    }

    private func exercisePlaylistMenuMove() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.press(forDuration: 1)
            try capture(app, "34-playlist-move-context-menu")
            app.buttons["移到文件夹"].tap()
            XCTAssertTrue(app.navigationBars["所有播放列表"].waitForExistence(timeout: 5))
            try capture(app, "35-playlist-move-picker")
            try tapVisible(app.staticTexts.matching(identifier: "Folder B"))
            app.buttons["移到这里"].tap()
            XCTAssertTrue(app.navigationBars["播放列表"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Parity Mix"].firstMatch.exists)
            app.staticTexts["Folder B"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "36-playlist-menu-moved")
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap()
            app.buttons["移到文件夹"].tap()
            try capture(app, "37-playlist-detail-move-menu")
            try tapVisible(app.buttons.matching(identifier: "播放列表"))
            back(app); back(app)
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testBaselinePlaylistMenuMove() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistMenuMove()
    }
    func testCandidatePlaylistMenuMove() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistMenuMove()
    }

    private func exercisePlayerSeekRepeatAndQueueOrder() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha")).firstMatch.tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            let progress = app.sliders["播放进度"]
            // Its accessibility value is a timestamp, not a percentage. Exercise
            // the real track coordinates instead of XCTest's value-based adjustment.
            progress.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            try capture(app, "38-player-seek-paused")
            let time = try XCTUnwrap(progress.value as? String)
            let position = try XCTUnwrap(time.components(separatedBy: "，").first)
            let parts = position.split(separator: ":").compactMap { Double($0) }
            XCTAssertEqual(parts.count, 2, time)
            XCTAssertEqual(parts[0] * 60 + parts[1], 60, accuracy: 5)
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            // Normalize using visible controls, then verify each state in the cycle.
            for _ in 0..<3 {
                if app.buttons["列表循环"].exists { break }
                let label = app.buttons["循环关闭"].exists ? "循环关闭" : "单曲循环"
                try tapVisible(app.buttons.matching(identifier: label))
            }
            try tapVisible(app.buttons.matching(identifier: "列表循环"))
            XCTAssertTrue(app.buttons["单曲循环"].exists)
            try tapVisible(app.buttons.matching(identifier: "单曲循环"))
            XCTAssertTrue(app.buttons["循环关闭"].exists)
            try tapVisible(app.buttons.matching(identifier: "循环关闭"))
            XCTAssertTrue(app.buttons["列表循环"].exists)
            let echo = app.buttons["对Echo、Aurora重新排序"]
            let dawn = app.buttons["对Dawn、Aurora重新排序"]
            XCTAssertTrue(echo.waitForExistence(timeout: 5))
            echo.press(forDuration: 0.3, thenDragTo: dawn, withVelocity: .slow, thenHoldForDuration: 0.5)
            try capture(app, "39-player-reordered-queue")
            XCTAssertLessThan(echo.frame.minY, dawn.frame.minY)
            try tapVisible(app.buttons.matching(identifier: "下一首"))
            XCTAssertTrue(echo.waitForNonExistence(timeout: 5), "The reordered entry must become current, not remain upcoming")
            XCTAssertTrue(app.staticTexts.matching(identifier: "Echo").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "40-player-after-reordered-next")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            back(app)
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testBaselinePlayerSeekRepeatAndQueueOrder() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlayerSeekRepeatAndQueueOrder()
    }
    func testCandidatePlayerSeekRepeatAndQueueOrder() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlayerSeekRepeatAndQueueOrder()
    }

    private func exercisePlayerMenusAndRotation() throws {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        for (name, bundle) in versions {
            version = name
            XCUIDevice.shared.orientation = .portrait
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha")).firstMatch.tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            XCUIDevice.shared.orientation = .landscapeLeft
            try capture(app, "41-player-rotation")
            // The reference commit has no landscape player layout. Record the
            // actual rotation response without inventing a parity requirement.
            XCTAssertTrue(app.buttons["收起播放器"].isHittable)
            XCTAssertTrue(app.sliders["播放进度"].isHittable)
            XCUIDevice.shared.orientation = .portrait
            try tapVisible(app.buttons.matching(identifier: "更多"))
            try capture(app, "42-player-song-menu")
            XCTAssertTrue(app.buttons["查看专辑"].isEnabled)
            XCTAssertTrue(app.buttons["查看艺人"].isEnabled)
            app.buttons["查看专辑"].tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Sunrise"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "43-player-open-album")
            back(app)
            XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 5))
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "更多"))
            app.buttons["查看艺人"].tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Aurora"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "44-player-open-artist")
            back(app); back(app)
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testBaselinePlayerMenusAndRotation() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlayerMenusAndRotation()
    }
    func testCandidatePlayerMenusAndRotation() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlayerMenusAndRotation()
    }

    private func exercisePlaylistPhotoCover() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            app.buttons["编辑播放列表封面"].tap()
            app.buttons["选取照片"].tap()
            Thread.sleep(forTimeInterval: 2)
            try capture(app, "45-photo-cover-picker")
            let photo = try XCTUnwrap(app.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex.first(where: { $0.isHittable }),
                                     "The system photo picker must expose a visible photo")
            photo.tap()
            XCTAssertTrue(app.textFields["播放列表标题"].waitForExistence(timeout: 5))
            try capture(app, "46-photo-cover-editor")
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertTrue(app.navigationBars.buttons["更多"].waitForExistence(timeout: 5))
            try capture(app, "47-photo-cover-saved")
            app.terminate()
            app.launch()
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            try capture(app, "48-photo-cover-restored")
            app.terminate()
        }
    }
    func testBaselinePlaylistPhotoCover() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistPhotoCover()
    }
    func testCandidatePlaylistPhotoCover() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistPhotoCover()
    }

    private func exerciseAlbumFavoriteAndPin() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("专辑", in: app)
            app.staticTexts["Night"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap()
            if app.buttons["撤销喜爱"].exists {
                app.buttons["撤销喜爱"].tap(); app.navigationBars.buttons["更多"].tap()
            }
            if app.buttons["取消置顶专辑"].exists {
                app.buttons["取消置顶专辑"].tap(); app.navigationBars.buttons["更多"].tap()
            }
            try capture(app, "49-album-menu")
            app.buttons["喜爱"].tap()
            app.navigationBars.buttons["更多"].tap()
            XCTAssertTrue(app.buttons["撤销喜爱"].waitForExistence(timeout: 3))
            app.buttons["置顶专辑"].tap()
            app.navigationBars.buttons["更多"].tap()
            XCTAssertTrue(app.buttons["取消置顶专辑"].waitForExistence(timeout: 3))
            try capture(app, "50-album-favorite-pinned-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            back(app)
            XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
            back(app)
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            try capture(app, "51-home-with-pinned-album")
            let pinned = app.descendants(matching: .any).matching(identifier: "Night").firstMatch
            XCTAssertTrue(pinned.waitForExistence(timeout: 3))
            XCTAssertLessThan(pinned.frame.minY, app.buttons["播放列表"].firstMatch.frame.minY)
            open("专辑", in: app)
            app.staticTexts["Night"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["取消置顶专辑"].tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["撤销喜爱"].tap()
            app.navigationBars.buttons["更多"].tap()
            XCTAssertTrue(app.buttons["喜爱"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["置顶专辑"].exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            back(app); back(app)
            app.terminate()
        }
    }
    func testBaselineAlbumFavoriteAndPin() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseAlbumFavoriteAndPin()
    }
    func testCandidateAlbumFavoriteAndPin() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseAlbumFavoriteAndPin()
    }

    private func exercisePlaylistReorderAndRemove() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            let alpha = try XCTUnwrap(app.buttons.matching(identifier: "Alpha、Aurora").allElementsBoundByIndex.last(where: { $0.isHittable }))
            let order = try XCTUnwrap(app.buttons.matching(identifier: "调整顺序").allElementsBoundByIndex.first(where: {
                $0.isHittable && abs($0.frame.midY - alpha.frame.midY) < 15
            }))
            order.tap(); app.buttons["下移"].tap()
            let dawn = try XCTUnwrap(app.buttons.matching(identifier: "Dawn、Aurora").allElementsBoundByIndex.last(where: { $0.isHittable }))
            XCTAssertLessThan(dawn.frame.minY, alpha.frame.minY)
            try capture(app, "52-playlist-song-reordered")
            alpha.tap()
            XCTAssertTrue(app.buttons["移除所选歌曲"].isEnabled)
            app.buttons["移除所选歌曲"].tap()
            XCTAssertFalse(app.buttons.matching(identifier: "Alpha、Aurora").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "53-playlist-song-removed-editor")
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertFalse(app.collectionViews.staticTexts["Alpha"].firstMatch.exists)
            app.terminate(); app.launch()
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            XCTAssertTrue(app.collectionViews.staticTexts["Dawn"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.collectionViews.staticTexts["Alpha"].firstMatch.exists)
            try capture(app, "54-playlist-song-removal-restored")
            back(app); back(app); open("歌曲", in: app)
            XCTAssertTrue(app.staticTexts["Alpha"].firstMatch.waitForExistence(timeout: 5), "Removing from a playlist must retain the local song")
            app.terminate()
        }
    }
    func testBaselinePlaylistReorderAndRemove() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistReorderAndRemove()
    }
    func testCandidatePlaylistReorderAndRemove() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistReorderAndRemove()
    }

    /// The isolated fixture driver removes Alpha only after this stage finishes.
    private func exercisePrepareMissingFileQueue() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha")).firstMatch.tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            try capture(app, "55-queue-before-file-loss")
            app.terminate()
        }
    }
    private func exerciseMissingFileRecovery() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            XCTAssertFalse(app.buttons["暂停"].exists, "Queue restoration must remain paused")
            if app.alerts["无法播放"].waitForExistence(timeout: 2) {
                try capture(app, "55b-missing-file-on-restore")
                app.alerts.buttons["好"].tap()
            }
            XCTAssertTrue(app.buttons["播放"].firstMatch.waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "播放"))
            XCTAssertTrue(app.alerts["无法播放"].waitForExistence(timeout: 8))
            try capture(app, "56-missing-file-error")
            app.alerts.buttons["好"].tap()
            try tapVisible(app.buttons.matching(identifier: "下一首"))
            if app.buttons["播放"].firstMatch.exists {
                try tapVisible(app.buttons.matching(identifier: "播放"))
            }
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            XCTAssertFalse(app.alerts["无法播放"].exists)
            try capture(app, "57-playback-after-file-error")
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            open("歌曲", in: app)
            XCTAssertFalse(app.collectionViews.staticTexts["Alpha"].firstMatch.exists)
            XCTAssertTrue(app.collectionViews.staticTexts["Dawn"].firstMatch.exists)
            app.terminate()
        }
    }
    func testBaselinePrepareMissingFileQueue() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePrepareMissingFileQueue()
    }
    func testCandidatePrepareMissingFileQueue() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePrepareMissingFileQueue()
    }
    func testBaselineMissingFileRecovery() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseMissingFileRecovery()
    }
    func testCandidateMissingFileRecovery() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseMissingFileRecovery()
    }

    private func exerciseSongFavoritePlaylistAndAlbum() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            let dawn = app.buttons.matching(identifier: "Dawn、Aurora").firstMatch
            dawn.press(forDuration: 1)
            app.buttons["喜爱"].tap()
            dawn.press(forDuration: 1)
            XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
            try capture(app, "58-song-favorite-menu")
            app.buttons["撤销"].tap()
            dawn.press(forDuration: 1)
            app.buttons["添加到播放列表"].tap()
            XCTAssertTrue(app.navigationBars["添加到播放列表"].waitForExistence(timeout: 5))
            try capture(app, "59-add-song-destination-picker")
            try tapVisible(app.staticTexts.matching(identifier: "Folder A"))
            try tapVisible(app.staticTexts.matching(identifier: "Empty Mix"))
            XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 5))
            back(app); open("播放列表", in: app)
            app.staticTexts["Folder A"].firstMatch.tap()
            app.staticTexts["Empty Mix"].firstMatch.tap()
            XCTAssertTrue(app.collectionViews.staticTexts["Dawn"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "60-song-added-from-menu")
            back(app); back(app); back(app)
            open("歌曲", in: app)
            app.buttons.matching(identifier: "Dawn、Aurora").firstMatch.press(forDuration: 1)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "前往专辑,")).firstMatch.tap()
            try capture(app, "61-song-menu-open-album")
            XCTAssertTrue(app.staticTexts["Sunrise"].firstMatch.waitForExistence(timeout: 5))
            back(app)
            XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testBaselineSongFavoritePlaylistAndAlbum() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseSongFavoritePlaylistAndAlbum()
    }
    func testCandidateSongFavoritePlaylistAndAlbum() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseSongFavoritePlaylistAndAlbum()
    }

    private func exerciseSongQueueInsertionAndReplacement() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons.matching(identifier: "Alpha、Aurora").firstMatch.tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            app.buttons.matching(identifier: "Dawn、Aurora").firstMatch.press(forDuration: 1)
            app.buttons["插播"].tap()
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            XCTAssertEqual(app.buttons.matching(identifier: "对Dawn、Aurora重新排序").count, 2,
                           "A manually queued occurrence must coexist with the original occurrence")
            try capture(app, "62-inserted-duplicate-queue-entry")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            app.collectionViews.buttons["播放"].firstMatch.tap()
            XCTAssertTrue(app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 5))
            try capture(app, "63-replace-manual-queue-confirmation")
            app.alerts.buttons["取消"].tap()
            app.collectionViews.buttons["播放"].firstMatch.tap()
            XCTAssertTrue(app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 5))
            app.alerts.buttons["清除队列"].tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            app.terminate()
        }
    }
    func testBaselineSongQueueInsertionAndReplacement() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseSongQueueInsertionAndReplacement()
    }
    func testCandidateSongQueueInsertionAndReplacement() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseSongQueueInsertionAndReplacement()
    }

    private func exerciseLibraryDeletion() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("专辑", in: app)
            app.staticTexts["Night"].firstMatch.tap()
            let stars = app.staticTexts["Stars"].firstMatch
            XCTAssertTrue(stars.waitForExistence(timeout: 5))
            stars.press(forDuration: 1)
            app.buttons["从资料库删除"].tap()
            let message = app.staticTexts["确定要从资料库删除这首歌吗？这也会将其从你制作的所有播放列表移除。"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            try capture(app, "64-song-delete-confirmation")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
            XCTAssertTrue(stars.exists)
            stars.press(forDuration: 1)
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(stars.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Moon"].firstMatch.exists)
            try capture(app, "65-song-deleted-album-retained")
            app.terminate(); app.launch()
            open("专辑", in: app)
            app.staticTexts["Night"].firstMatch.tap()
            XCTAssertFalse(app.staticTexts["Stars"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["Moon"].firstMatch.exists)
            app.navigationBars.buttons["更多"].tap()
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "确定要从资料库删除")).firstMatch.waitForExistence(timeout: 5))
            try capture(app, "66-album-delete-confirmation")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
            XCTAssertTrue(app.staticTexts["Moon"].firstMatch.exists)
            app.navigationBars.buttons["更多"].tap()
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "确定要从资料库删除")).firstMatch.waitForExistence(timeout: 5))
            app.buttons["从资料库删除"].tap()
            XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Night"].firstMatch.exists)
            try capture(app, "67-album-deleted-return")
            app.terminate(); app.launch()
            open("歌曲", in: app)
            XCTAssertFalse(app.staticTexts["Moon"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts["Stars"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["Alpha"].firstMatch.exists)
            try capture(app, "68-deleted-library-after-relaunch")
            app.terminate()
        }
    }
    func testBaselineLibraryDeletion() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseLibraryDeletion()
    }
    func testCandidateLibraryDeletion() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseLibraryDeletion()
    }

    private func exerciseHomePinEditing() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            app.navigationBars.buttons["更多"].tap()
            app.buttons["编辑置顶"].tap()
            XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "取消置顶").count, 2)
            try capture(app, "69-home-pin-editing")
            app.buttons.matching(identifier: "取消置顶").element(boundBy: 1).tap()
            XCTAssertEqual(app.buttons.matching(identifier: "取消置顶").count, 1)
            app.navigationBars.buttons["完成"].tap()
            XCTAssertTrue(app.navigationBars.buttons["新建播放列表"].waitForExistence(timeout: 5))
            try capture(app, "70-home-pin-removed")
            open("专辑", in: app)
            app.staticTexts["Sunrise"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap()
            XCTAssertTrue(app.buttons["置顶专辑"].waitForExistence(timeout: 5))
            app.buttons["置顶专辑"].tap()
            back(app); back(app)
            app.terminate(); app.launch()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 10))
            app.navigationBars.buttons["更多"].tap()
            app.buttons["编辑置顶"].tap()
            XCTAssertEqual(app.buttons.matching(identifier: "取消置顶").count, 2)
            try capture(app, "71-home-pin-restored-after-relaunch")
            app.navigationBars.buttons["完成"].tap()
            app.terminate()
        }
    }
    func testBaselineHomePinEditing() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseHomePinEditing()
    }
    func testCandidateHomePinEditing() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseHomePinEditing()
    }

    private func exercisePinnedTapAndAppend() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            let pin: XCUIElement
            if app.staticTexts["Sunrise"].firstMatch.exists {
                pin = app.staticTexts["Sunrise"].firstMatch
            } else {
                // The checkpoint exposes native artwork tiles as unlabeled buttons.
                // Its second pinned tile occupies the right half of the first row.
                pin = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                    $0.label.isEmpty && $0.frame.width > 100 && $0.frame.width < 150
                        && $0.frame.height > 100 && $0.frame.height < 160
                        && $0.frame.minX > app.frame.width / 2 && $0.frame.minY < app.frame.height / 3
                        && $0.isHittable
                })
            }
            pin.press(forDuration: 1)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "轻点操作")).firstMatch.tap()
            try capture(app, "72-pinned-tap-action-options")
            try tapVisible(app.buttons.matching(identifier: "播放"))
            pin.tap()
            if app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 1) {
                app.alerts.buttons["清除队列"].tap()
            }
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            XCTAssertTrue(app.navigationBars["资料库"].exists)
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            try capture(app, "73-pinned-tap-plays-on-home")
            pin.press(forDuration: 1)
            app.buttons["添加到队列"].tap()
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            XCTAssertEqual(app.buttons.matching(identifier: "对Dawn、Aurora重新排序").count, 2)
            XCTAssertEqual(app.buttons.matching(identifier: "对Echo、Aurora重新排序").count, 2)
            try capture(app, "74-appended-album-queue")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            pin.press(forDuration: 1)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "轻点操作")).firstMatch.tap()
            app.buttons["前往专辑"].tap()
            pin.tap()
            XCTAssertFalse(app.navigationBars["资料库"].exists)
            XCTAssertTrue(app.staticTexts["Sunrise"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "75-pinned-tap-opens-album")
            back(app)
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testBaselinePinnedTapAndAppend() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePinnedTapAndAppend()
    }
    func testCandidatePinnedTapAndAppend() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePinnedTapAndAppend()
    }

    // Probe system-owned picker hierarchies before asserting an import workflow.
    private func exerciseFilePickerProbe() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            app.buttons["编辑播放列表封面"].tap()
            app.buttons["选取文件"].tap()
            Thread.sleep(forTimeInterval: 3)
            try capture(app, "76-cover-file-picker")
            app.terminate(); app.launch()
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            try tapVisible(app.buttons.matching(identifier: "更多"))
            app.buttons["导入本地歌词"].tap()
            Thread.sleep(forTimeInterval: 3)
            try capture(app, "77-lyrics-file-picker")
            app.terminate()
        }
    }
    func testBaselineFilePickerProbe() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseFilePickerProbe()
    }
    func testCandidateFilePickerProbe() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseFilePickerProbe()
    }

    private func chooseFixtureDocument(_ stem: String, in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["浏览"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["浏览"].firstMatch.tap()
        try capture(app, "78-file-browser-locations")
        let location = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "iPhone")).firstMatch
        if location.waitForExistence(timeout: 1) { location.tap() }
        try capture(app, "79-file-browser-local-folders")
        let folder = app.cells.containing(.staticText, identifier: "NeoMusic").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        try capture(app, "80-file-browser-app-documents")
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", stem)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
    }
    private func exerciseFileCoverImport() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            app.buttons["编辑播放列表封面"].tap(); app.buttons["选取文件"].tap()
            try chooseFixtureDocument("ParityCover", in: app)
            XCTAssertTrue(app.textFields["播放列表标题"].waitForExistence(timeout: 5))
            try capture(app, "81-file-cover-editor")
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertTrue(app.navigationBars.buttons["更多"].waitForExistence(timeout: 5))
            app.terminate(); app.launch()
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            try capture(app, "82-file-cover-restored")
            app.terminate()
        }
    }
    func testBaselineFileCoverImport() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseFileCoverImport()
    }
    func testCandidateFileCoverImport() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseFileCoverImport()
    }

    private func exerciseLyricsImport() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            func expandPlayer() throws {
                let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                    $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                        && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
                })
                mini.tap()
                XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            }
            try expandPlayer()
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            try tapVisible(app.buttons.matching(identifier: "更多"))
            app.buttons["导入本地歌词"].tap()
            try chooseFixtureDocument("ParityLyrics", in: app)
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            let imported = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Imported parity line")).firstMatch
            XCTAssertTrue(imported.waitForExistence(timeout: 8))
            XCTAssertFalse(app.staticTexts["First line"].exists)
            try capture(app, "83-imported-lyrics-priority")
            app.terminate(); app.launch()
            try expandPlayer()
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            XCTAssertTrue(imported.waitForExistence(timeout: 8))
            try capture(app, "84-imported-lyrics-after-relaunch")
            app.terminate()
        }
    }
    func testBaselineLyricsImport() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseLyricsImport()
    }
    func testCandidateLyricsImport() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseLyricsImport()
    }

    private func exercisePlaylistSearchScroll() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            try capture(app, "85-playlist-search-initial")
            app.collectionViews.firstMatch.swipeUp()
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            try capture(app, "86-playlist-search-scrolled")
            app.collectionViews.firstMatch.swipeDown()
            try capture(app, "87-playlist-search-pulled-down")
            app.navigationBars.buttons["更多"].tap(); app.buttons["网格"].tap()
            try capture(app, "88-playlists-grid")
            app.navigationBars.buttons["更多"].tap(); app.buttons["列表"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            Thread.sleep(forTimeInterval: 2)
            try capture(app, "89-playlists-back-to-list")
            XCTAssertTrue(app.navigationBars.staticTexts["播放列表"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    func testBaselinePlaylistSearchScroll() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exercisePlaylistSearchScroll()
    }
    func testCandidatePlaylistSearchScroll() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaylistSearchScroll()
    }

    /// External fixture staging only; no production file injection switches.
    private func waitForScanFixture(_ phase: String) throws {
        let ready = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(version)-\(phase).ready")
        try? FileManager.default.removeItem(at: ready)
        print("PARITY_SCAN_MUTATION \(version) \(phase) \(ready.path)")
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "External isolated fixture was not staged")
    }

    private func exerciseEmptyLibraryAndRefresh() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            XCTAssertTrue(app.buttons["在文件中打开"].waitForExistence(timeout: 8))
            try capture(app, "90-empty-library-home")
            for category in ["歌曲", "专辑", "艺人", "播放列表", "已下载"] {
                open(category, in: app)
                if category == "歌曲" || category == "专辑" {
                    XCTAssertTrue(app.buttons["播放"].firstMatch.exists)
                    XCTAssertFalse(app.buttons["播放"].firstMatch.isEnabled)
                }
                XCTAssertFalse(app.staticTexts["Alpha"].exists)
                try capture(app, "91-empty-" + category)
                back(app)
            }
            XCUIDevice.shared.press(.home)
            try waitForScanFixture("background")
            app.activate()
            XCTAssertTrue(app.staticTexts["ScanAudit"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["在文件中打开"].exists)
            open("歌曲", in: app)
            XCTAssertTrue(app.staticTexts["Refresh Audit"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "92-foreground-auto-scan")
            back(app)
            try waitForScanFixture("foreground")
            try capture(app, "92b-before-manual-refresh")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 2)
            try capture(app, "92c-after-manual-refresh")
            open("歌曲", in: app)
            XCTAssertTrue(app.staticTexts["Second Audit"].firstMatch.waitForExistence(timeout: 10))
            try capture(app, "93-pull-to-refresh-scan")
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Refresh Audit")).firstMatch.tap()
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 8))
            app.buttons["暂停"].firstMatch.tap()
            app.terminate()
            app.launch()
            open("歌曲", in: app)
            XCTAssertTrue(app.staticTexts["Refresh Audit"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Second Audit"].firstMatch.exists)
            XCTAssertFalse(app.buttons["暂停"].exists)
            try capture(app, "94-scanned-library-relaunch")
            app.terminate()
        }
    }
    func testBaselineEmptyLibraryAndRefresh() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseEmptyLibraryAndRefresh()
    }
    func testCandidateEmptyLibraryAndRefresh() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseEmptyLibraryAndRefresh()
    }

    private func exerciseSongSwipesAndLyricSeek() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons["Alpha、Aurora"].firstMatch.tap()
            if app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 1) {
                app.alerts.buttons["清除队列"].tap()
            }
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            let dawn = app.collectionViews.cells.containing(.button, identifier: "Dawn、Aurora").firstMatch
            XCTAssertTrue(dawn.isHittable)
            dawn.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: dawn.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
            XCTAssertTrue(app.buttons["插播"].waitForExistence(timeout: 5))
            try capture(app, "95-song-leading-swipe")
            app.buttons["插播"].tap()
            dawn.swipeLeft()
            XCTAssertTrue(app.buttons["下载"].waitForExistence(timeout: 5))
            try capture(app, "96-song-trailing-swipe")
            // UIKit exposes this disabled SwiftUI swipe action as AX-enabled in
            // both versions. Check its actual no-op behavior separately.
            app.buttons["下载"].tap()
            XCTAssertTrue(app.navigationBars["歌曲"].exists)
            XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.exists)
            XCTAssertFalse(app.buttons["暂停"].exists)
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "继续播放"))
            XCTAssertEqual(app.buttons.matching(identifier: "对Dawn、Aurora重新排序").count, 2)
            try capture(app, "97-swipe-inserted-duplicate")
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            let second = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Second imported line"))
            XCTAssertTrue(second.firstMatch.waitForExistence(timeout: 5))
            try tapVisible(second)
            try capture(app, "98-lyric-tapped-second-line")
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            let progress = app.sliders["播放进度"]
            let value = try XCTUnwrap(progress.value as? String)
            let components = try XCTUnwrap(value.components(separatedBy: "，").first).split(separator: ":").compactMap { Double($0) }
            XCTAssertEqual(components.count, 2, value)
            XCTAssertEqual(components[0] * 60 + components[1], 5, accuracy: 1)
            XCTAssertFalse(app.buttons.matching(identifier: "暂停").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "99-lyric-seek-paused-time")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            app.terminate()
        }
    }
    func testBaselineSongSwipesAndLyricSeek() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseSongSwipesAndLyricSeek()
    }
    func testCandidateSongSwipesAndLyricSeek() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseSongSwipesAndLyricSeek()
    }

    func testReducedMotionParity() throws {
        continueAfterFailure = false
        version = "settings"
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if !settings.switches["REDUCE_MOTION"].exists {
            if settings.buttons["com.apple.settings.accessibility"].exists {
                settings.buttons["com.apple.settings.accessibility"].tap()
            }
            settings.buttons["MOTION_TITLE"].tap()
        }
        let toggle = settings.switches["REDUCE_MOTION"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(toggle.value as? String)
        XCTAssertTrue(["0", "1"].contains(original))
        try capture(settings, "102-motion-original")
        let restored = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FunctionalParity/settings/104-motion-restored")
        addTeardownBlock {
            await MainActor.run {
                settings.activate()
                if toggle.value as? String != original {
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                }
                XCTAssertEqual(toggle.value as? String, original)
                try? settings.screenshot().pngRepresentation.write(to: restored.appendingPathExtension("png"))
                try? settings.debugDescription.write(to: restored.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                print("PARITY_ARTIFACT \(restored.path)")
                settings.terminate()
            }
        }
        if original != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        try capture(settings, "103-motion-enabled")
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline"), ("candidate", "com.elsterlee.NeoMusic")]
        try exercisePlaybackAndPlayerPages()
        try exercisePlaylistSearchScroll()
    }

    private func exerciseMiniPlayerSwipes() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("歌曲", in: app)
            app.buttons["Alpha、Aurora"].firstMatch.tap()
            if app.alerts["播放此项目将清除队列。"].waitForExistence(timeout: 1) {
                app.alerts.buttons["清除队列"].tap()
            }
            XCTAssertTrue(app.buttons["暂停"].firstMatch.waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "暂停"))
            func mini() throws -> XCUIElement {
                try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                    $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                        && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
                })
            }
            for (left, expected) in [(true, "Dawn"), (false, "Alpha")] {
                let title = try mini()
                title.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.5)))
                try mini().tap()
                XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts.matching(identifier: expected).allElementsBoundByIndex.contains { $0.isHittable })
                try capture(app, left ? "105-mini-swipe-next" : "106-mini-swipe-previous")
                if app.buttons.matching(identifier: "暂停").allElementsBoundByIndex.contains(where: { $0.isHittable }) {
                    try tapVisible(app.buttons.matching(identifier: "暂停"))
                }
                try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            }
            let title = try mini()
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.4)
            try mini().tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(identifier: "Alpha").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "107-mini-short-drag-cancelled")
            XCTAssertTrue(app.buttons["AirPlay"].exists)
            app.buttons["AirPlay"].tap()
            try capture(app, "108-airplay-picker")
            let screen = XCUIScreen.main.screenshot()
            let artifact = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FunctionalParity/\(version)/108-airplay-picker-screen.png")
            try screen.pngRepresentation.write(to: artifact)
            app.terminate()
        }
    }
    func testBaselineMiniPlayerSwipes() throws {
        versions = [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline")]
        try exerciseMiniPlayerSwipes()
    }
    func testCandidateMiniPlayerSwipes() throws {
        versions = [("candidate", "com.elsterlee.NeoMusic")]
        try exerciseMiniPlayerSwipes()
    }
    func testCandidateSongEllipsisAlbumRoute() throws {
        continueAfterFailure = false
        version = "candidate"
        let app = launch("com.elsterlee.NeoMusic")
        open("歌曲", in: app)
        let row = app.collectionViews.cells.containing(.button, identifier: "Alpha、Aurora").firstMatch
        row.buttons["更多"].tap()
        try capture(app, "109-song-ellipsis-menu")
        try tapVisible(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "前往专辑")))
        XCTAssertTrue(app.staticTexts["Sunrise"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Echo"].firstMatch.exists)
        try capture(app, "110-song-ellipsis-album-route")
        back(app)
        XCTAssertTrue(app.navigationBars["歌曲"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testAirPlayPresentationProbe() throws {
        continueAfterFailure = false
        for (name, bundle) in [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline"), ("candidate", "com.elsterlee.NeoMusic")] {
            version = name
            let app = launch(bundle)
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["AirPlay"].waitForExistence(timeout: 5))
            app.buttons["AirPlay"].tap()
            Thread.sleep(forTimeInterval: 3)
            try capture(app, "111-airplay-after-wait")
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FunctionalParity/\(version)")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: root.appendingPathComponent("111-airplay-after-wait-screen.png"))
            try XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription.write(to: root.appendingPathComponent("111-springboard.txt"), atomically: true, encoding: .utf8)
            app.terminate()
        }
    }

    func testEmptyLibraryFilesEntry() throws {
        continueAfterFailure = false
        var missingMusicDirectories: [String] = []
        for (name, bundle) in [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline"), ("candidate", "com.elsterlee.NeoMusic")] {
            version = name
            let app = launch(bundle)
            XCTAssertTrue(app.buttons["在文件中打开"].waitForExistence(timeout: 8))
            app.buttons["在文件中打开"].tap()
            let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
            XCTAssertTrue(files.wait(for: .runningForeground, timeout: 10))
            let reachedMusic = files.navigationBars.buttons["音乐, 操作菜单"].waitForExistence(timeout: 10)
            try capture(files, "112-empty-library-files-entry")
            if !reachedMusic { missingMusicDirectories.append(name) }
            app.activate()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            open("专辑", in: app)
            try capture(app, "113-return-from-files")
            back(app)
            app.terminate()
        }
        XCTAssertTrue(missingMusicDirectories.isEmpty, "Files did not reach music folder: \(missingMusicDirectories)")
    }

    func testLyricsResumeFollowing() throws {
        continueAfterFailure = false
        for (name, bundle) in [("baseline", "com.elsterlee.NeoMusic.ControlsBaseline"), ("candidate", "com.elsterlee.NeoMusic")] {
            version = name
            let app = launch(bundle)
            let mini = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
                $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 30 && $0.frame.height < 60
                    && $0.frame.minY > app.frame.height * 0.7 && $0.isHittable
            })
            mini.tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            try tapVisible(app.buttons.matching(identifier: "歌词"))
            let line = app.buttons["Second imported line"]
            XCTAssertTrue(line.waitForExistence(timeout: 5))
            line.tap()
            Thread.sleep(forTimeInterval: 0.5)
            let initial = line.frame.minY
            try capture(app, "114-lyrics-before-scroll")
            let start = line.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            let moved = line.frame.minY
            XCTAssertGreaterThan(abs(moved - initial), 30)
            try capture(app, "115-lyrics-manual-scroll")
            Thread.sleep(forTimeInterval: 4)
            let restored = line.frame.minY
            XCTAssertEqual(restored, initial, accuracy: 8)
            XCTAssertTrue(line.isSelected)
            print("LYRIC_FOLLOW \(name) initial=\(initial) moved=\(moved) restored=\(restored)")
            try capture(app, "116-lyrics-follow-restored")
            try tapVisible(app.buttons.matching(identifier: "收起播放器"))
            app.terminate()
        }
    }

    func testAlbumInteractiveReturnProbe() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("专辑", in: app)
            app.staticTexts["Sunrise"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "117-album-before-return-gesture")
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            try capture(app, "118-album-short-return-gesture")
            XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.isHittable)
            app.navigationBars.buttons["更多"].tap()
            try capture(app, "119-album-menu-after-return-gesture")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            back(app)
            XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
            app.staticTexts["Sunrise"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.waitForExistence(timeout: 5))
            back(app); back(app)
            open("歌曲", in: app)
            XCTAssertTrue(app.buttons["Alpha、Aurora"].firstMatch.waitForExistence(timeout: 5))
            try capture(app, "120-navigation-after-return-gesture")
            app.terminate()
        }
    }

    func testPlaylistDiscardChanges() throws {
        continueAfterFailure = false
        for (name, bundle) in versions {
            version = name
            let app = launch(bundle)
            open("播放列表", in: app)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            let title = app.textFields["播放列表标题"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let oldTitle = title.value as? String ?? ""
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldTitle.count) + "Discard Audit")
            XCTAssertEqual(title.value as? String, "Discard Audit")
            try tapVisible(app.navigationBars.buttons.matching(identifier: "取消"))
            XCTAssertTrue(app.buttons["放弃更改"].waitForExistence(timeout: 3))
            try capture(app, "121-playlist-discard-edit")
            app.buttons["放弃更改"].tap()
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons["更多"].tap(); app.buttons["编辑"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Parity Mix")
            app.toolbars.buttons["添加音乐"].firstMatch.tap()
            let query = app.textFields["歌曲、艺人或专辑"]
            XCTAssertTrue(query.waitForExistence(timeout: 5))
            query.tap(); query.typeText("Alpha")
            let song = app.buttons["Alpha，Aurora"]
            XCTAssertTrue(song.waitForExistence(timeout: 5)); song.tap()
            app.navigationBars.buttons["关闭"].tap()
            XCTAssertTrue(app.buttons["放弃所选内容"].waitForExistence(timeout: 3))
            try capture(app, "122-playlist-discard-selection")
            app.buttons["放弃所选内容"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            try tapVisible(app.navigationBars.buttons.matching(identifier: "完成"))
            XCTAssertTrue(app.staticTexts["Parity Mix"].firstMatch.waitForExistence(timeout: 5))
            app.terminate(); app.launch()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 10))
            open("播放列表", in: app)
            XCTAssertFalse(app.staticTexts["Discard Audit"].exists)
            app.staticTexts["Parity Mix"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Dawn"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Echo"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(identifier: "Alpha").allElementsBoundByIndex.contains { $0.isHittable })
            try capture(app, "123-playlist-after-discard-relaunch")
            app.terminate()
        }
    }

}
