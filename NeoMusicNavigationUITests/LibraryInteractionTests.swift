import XCTest

final class LibraryInteractionTests: XCTestCase {
    @MainActor func testAuditZoomCancellationAndReturnRepeatsFiveTimes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "library-audit",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let albums = app.buttons["专辑"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 5))
        albums.tap()
        let album = app.staticTexts["沿着城市边缘一直走到海边的那些漫长夜晚与清晨：完整现场录音特别纪念版"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        let initialFrame = album.frame
        for _ in 0..<5 {
            album.tap()
            XCTAssertTrue(app.buttons["停止下载"].firstMatch.waitForExistence(timeout: 5))
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            let shortReturn = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: shortReturn, withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertTrue(app.buttons["停止下载"].firstMatch.isHittable, "A cancelled return keeps the album active")
            app.navigationBars.buttons["BackButton"].tap()
            XCTAssertTrue(album.waitForExistence(timeout: 5))
            XCTAssertTrue(album.isHittable)
            XCTAssertEqual(album.frame.minY, initialFrame.minY, accuracy: 2)
        }
    }

    @MainActor func testAuditSheetDismissalRestoresControlsFiveTimes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "library-audit",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let settings = app.buttons["library-audit.settings"]
        for _ in 0..<5 {
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let bar = app.navigationBars["资料库核验"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
            XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
            XCTAssertTrue(settings.isHittable)
        }
    }

    @MainActor func testTabInsertionKeepsScrollAndNativeReorderHandles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-neteaseAccountPreview", "signed-in",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["account.tabs"].waitForExistence(timeout: 5))
        app.buttons["account.tabs"].tap()
        let reset = app.buttons["恢复默认"]
        for _ in 0..<8 where !reset.isHittable { app.swipeUp() }
        if reset.isEnabled { reset.tap() }

        let addFavorite = app.buttons["添加喜爱歌曲"]
        let addPlaylist = app.buttons["添加播放列表"]
        let favoriteHandle = app.buttons["对喜爱歌曲重新排序"]
        for _ in 0..<5 {
            for _ in 0..<8 where !addFavorite.isHittable || !addPlaylist.isHittable { app.swipeUp() }
            XCTAssertTrue(addFavorite.isHittable)
            XCTAssertTrue(addPlaylist.isHittable)
            addFavorite.tap()
            XCTAssertTrue(addPlaylist.isHittable, "Adding a tab must keep the current list context")
            for _ in 0..<8 where !favoriteHandle.isHittable { app.swipeDown() }
            XCTAssertTrue(favoriteHandle.isHittable, "New rows need the system reorder handle")
            app.buttons["移除喜爱歌曲"].tap()
        }
        for _ in 0..<8 where !addFavorite.isHittable { app.swipeUp() }
        addFavorite.tap()
        for _ in 0..<8 where !favoriteHandle.isHittable { app.swipeDown() }
        for index in 0..<5 {
            let target = app.buttons[index.isMultiple(of: 2) ? "对主页重新排序" : "对资料库重新排序"]
            let previousY = favoriteHandle.frame.minY
            favoriteHandle.press(forDuration: 0.2, thenDragTo: target)
            XCTAssertNotEqual(favoriteHandle.frame.minY, previousY)
        }
    }

    @MainActor func testCatalogLoadingFeedbackWaitsBeforeShowing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "catalog-loading",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let original = app.buttons["当前空白"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        app.buttons["原生进度"].tap()
        let progress = app.descendants(matching: .any).matching(identifier: "catalog.loading").firstMatch
        XCTAssertFalse(progress.waitForExistence(timeout: 1))
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        original.tap()
        XCTAssertTrue(progress.waitForNonExistence(timeout: 2))
        app.buttons["原生进度"].tap()
        XCTAssertFalse(progress.waitForExistence(timeout: 1))
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
    }

    @MainActor func testAlbumDownloadButtonsKeepIndependentActionsAtEdges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "library-audit", "-libraryAuditPage", "album",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let settings = app.buttons["library-audit.settings"]
        for position in [0.05, 0.95, 0.5, 0.05, 0.95] {
            let stop = app.buttons["停止下载"]
            let retry = app.buttons["下载失败，轻点重试"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(stop.frame.width, 28)
            XCTAssertEqual(stop.frame.height, 44, accuracy: 0.01)
            stop.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
            retry.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
            settings.tap()
            XCTAssertTrue(app.staticTexts["library-audit.count.stop"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["library-audit.count.stop"].label, "停止次数、1")
            XCTAssertEqual(app.staticTexts["library-audit.count.retry"].label, "重试次数、1")
            XCTAssertEqual(app.staticTexts["library-audit.count.play"].label, "播放次数、0")
            app.buttons["library-audit.reset"].tap()
            app.buttons["library-audit.settings.done"].tap()
        }
        app.staticTexts["停止按钮核验曲目"].firstMatch.tap()
        settings.tap()
        XCTAssertEqual(app.staticTexts["library-audit.count.play"].label, "播放次数、1")
    }

    @MainActor func testPlayerDismissButtonAcceptsRepeatedEdgeTaps() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let entry = app.buttons["音质与输出入口"]
        for position in [0.05, 0.95, 0.5, 0.05, 0.95] {
            for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
            XCTAssertTrue(entry.isHittable)
            entry.tap()
            let close = app.buttons["player.dismiss"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(close.frame.height, 44)
            XCTAssertGreaterThanOrEqual(close.frame.width, 44)
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: position)).tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
        }
    }

    @MainActor func testPlaylistRowPlaybackIndicatorAndIndependentMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["资料库"].tap()
        let playlists = app.buttons["播放列表"].firstMatch
        XCTAssertTrue(playlists.waitForExistence(timeout: 10))
        playlists.tap()
        let playlist = app.staticTexts["歌曲行验证"].firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5), "Requires the local playlist fixture")
        playlist.tap()
        app.swipeUp()
        let cell = app.cells.containing(.staticText, identifier: "湖畔、二人歌").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.staticTexts["湖畔、二人歌"].tap()
        let clearQueue = app.buttons["清除队列"]
        if clearQueue.waitForExistence(timeout: 1) { clearQueue.tap() }
        let transport = app.buttons["mini.playPause"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(transport.label, "暂停")
        let indicator = app.descendants(matching: .any)
            .matching(identifier: "playlist.playback.塌陷于38°C的蓝/湖畔、二人歌.flac").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Playlist current cover and spectrum"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        transport.tap()
        XCTAssertEqual(transport.label, "播放")
        XCTAssertTrue(indicator.exists)
        cell.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["添加到播放列表"].waitForExistence(timeout: 5))
        XCTAssertEqual(transport.label, "播放", "Opening the menu must not start playback")
        app.terminate()
    }

    @MainActor func testAllLibraryCategoryRowsNavigateAndClearSelectionOnReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        for title in ["播放列表", "艺人", "专辑", "歌曲", "已下载"] {
            let entry = app.buttons[title].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
            XCTAssertTrue(entry.isHittable)
            let row = app.cells.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(row.exists)
            XCTAssertFalse(row.isSelected)
        }
    }

    @MainActor func testLibraryZoomAndPlaylistSelectionReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let playlists = app.buttons["播放列表"].firstMatch
        XCTAssertTrue(playlists.waitForExistence(timeout: 10))
        let pinned = app.staticTexts["喜爱歌曲"].firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -50)).tap()
        let pinnedBack = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(pinnedBack.waitForExistence(timeout: 5))
        pinnedBack.tap()
        playlists.tap()
        let favorite = app.cells.containing(.staticText, identifier: "喜爱歌曲").firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertFalse(favorite.isSelected)
        back.tap()
        XCTAssertTrue(playlists.waitForExistence(timeout: 5))
        app.swipeUp()
        let album = app.staticTexts["塌陷于38°C的蓝"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        let initial = album.frame
        album.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -70)).press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["播放"].firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.80)).tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        album.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -70)).tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(playlists.waitForExistence(timeout: 5))
        XCTAssertEqual(album.frame.minY, initial.minY, accuracy: 2)
    }

    /// Uses the real local-music simulator fixture; never confirms deletion.
    @MainActor func testNativeAlbumRowPlaybackMenusAndSwipes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let albums = app.buttons["专辑"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 10)); albums.tap()
        let album = app.staticTexts["塌陷于38°C的蓝"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5), "Requires the local FLAC album fixture")
        album.tap()
        let cell = app.cells.containing(.staticText, identifier: "湖畔、二人歌").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let title = cell.staticTexts["湖畔、二人歌"].firstMatch
        title.tap()
        // A previous run may have left the track queued by the swipe-action check below.
        let clearQueue = app.buttons["清除队列"]
        if clearQueue.waitForExistence(timeout: 1) { clearQueue.tap() }
        XCTAssertTrue(app.buttons["mini.playPause"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["mini.playPause"].label, "暂停")
        cell.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["添加到播放列表"].waitForExistence(timeout: 3))
        // Dismiss by tapping the album cover, outside the menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        title.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["添加到播放列表"].waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        title.swipeRight()
        XCTAssertTrue(app.buttons["插播"].waitForExistence(timeout: 3))
        let leading = XCTAttachment(screenshot: app.screenshot()); leading.name = "Native album leading swipe"; leading.lifetime = .keepAlways; add(leading)
        app.buttons["插播"].tap()
        title.swipeLeft()
        XCTAssertFalse(app.buttons["删除"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["从资料库删除"].exists)
        let trailing = XCTAttachment(screenshot: app.screenshot()); trailing.name = "Native album trailing swipe"; trailing.lifetime = .keepAlways; add(trailing)
        app.terminate(); app.launch()
    }

    @MainActor func testPinnedEditingDoneButtonCanExitRepeatedly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let more = app.navigationBars.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            more.tap()
            let edit = app.buttons["编辑置顶"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            XCTAssertTrue(edit.isEnabled, "Requires an existing pinned item")
            edit.tap()
            let done = app.navigationBars.buttons["完成"]
            XCTAssertTrue(done.waitForExistence(timeout: 2))
            XCTAssertTrue(done.isEnabled)
            done.tap()
            XCTAssertTrue(more.waitForExistence(timeout: 2))
            XCTAssertFalse(done.exists)
        }
    }

    @MainActor func testNewPlaylistCoverMenuUsesSystemPickers() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let create = app.navigationBars.buttons["新建播放列表"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let cover = app.buttons["添加播放列表封面"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(app.buttons["拍照"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["选取照片"].exists)
        XCTAssertTrue(app.buttons["选取文件"].exists)
        let menu = XCTAttachment(screenshot: app.screenshot())
        menu.name = "New playlist native cover menu"; menu.lifetime = .keepAlways; add(menu)
        app.buttons["选取照片"].tap()
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 8))
        let photo = try XCTUnwrap(photos.allElementsBoundByIndex.first(where: \.isHittable))
        photo.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法读取图片"].exists)

        cover.tap()
        app.buttons["选取文件"].tap()
        XCTAssertTrue(app.buttons["浏览"].firstMatch.waitForExistence(timeout: 8))
        let pickerTree = XCTAttachment(string: app.debugDescription)
        pickerTree.name = "File picker accessibility"; pickerTree.lifetime = .keepAlways; add(pickerTree)
        // The remote document picker reports this visible control as not hittable.
        let cancel = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法读取图片"].exists, "Cancelling the file picker is not an import error")
        cover.tap()
        app.buttons["选取文件"].tap()
        XCTAssertTrue(app.buttons["浏览"].firstMatch.waitForExistence(timeout: 8))
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "ParityCover")).firstMatch
        if !file.waitForExistence(timeout: 2) {
            app.buttons["浏览"].firstMatch.tap()
            let location = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "iPhone")).firstMatch
            if location.waitForExistence(timeout: 1) { location.tap() }
            let folder = app.cells.containing(.staticText, identifier: "NeoMusic").firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法读取图片"].exists)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
    }

    @MainActor func testCollectionCardMenusOpenAndDismiss() throws {
        let app = XCUIApplication()
        app.launch()
        let pinned = app.staticTexts["Sunrise"].firstMatch
        guard pinned.waitForExistence(timeout: 10), pinned.frame.minY < app.frame.height / 2 else {
            throw XCTSkip("Requires the simulator fixture with a pinned Sunrise album")
        }
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -70)).press(forDuration: 0.8)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "取消置顶")).firstMatch.waitForExistence(timeout: 5))
        let pinnedPreview = XCTAttachment(screenshot: app.screenshot())
        pinnedPreview.name = "Pinned card context menu"; pinnedPreview.lifetime = .keepAlways; add(pinnedPreview)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pinned-menu-preview.png"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.80)).tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        app.buttons["专辑"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
        let album = app.staticTexts["Sunrise"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 5))
        let albumPreview = XCTAttachment(screenshot: app.screenshot())
        albumPreview.name = "Album card context menu"; albumPreview.lifetime = .keepAlways; add(albumPreview)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("album-menu-preview.png"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.80)).tap()
        XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
    }
    @MainActor func testPinnedDragOutsideCancels() throws {
        let app = XCUIApplication()
        app.launch()
        let favorite = app.staticTexts["喜爱歌曲"].firstMatch
        let album = app.staticTexts["Sunrise"].firstMatch
        guard favorite.waitForExistence(timeout: 10), album.waitForExistence(timeout: 10),
              favorite.frame.minY < app.frame.height / 2, album.frame.minY < app.frame.height / 2 else {
            throw XCTSkip("Requires the simulator fixture with pinned 喜爱歌曲 and Sunrise")
        }
        let albumWasLeft = album.frame.midX < favorite.frame.midX
        let start = album.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -70))
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.55))
        start.press(forDuration: 0.7, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(album.frame.midX < favorite.frame.midX, albumWasLeft)
        app.terminate(); app.launch()
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        XCTAssertEqual(album.frame.midX < favorite.frame.midX, albumWasLeft)
    }

    @MainActor func testPinnedDragReorderPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let favorite = app.staticTexts["喜爱歌曲"].firstMatch
        let album = app.staticTexts["Sunrise"].firstMatch
        guard favorite.waitForExistence(timeout: 10), album.waitForExistence(timeout: 10),
              favorite.frame.minY < app.frame.height / 2, album.frame.minY < app.frame.height / 2 else {
            throw XCTSkip("Requires the simulator fixture with pinned 喜爱歌曲 and Sunrise")
        }
        let albumWasLeft = album.frame.midX < favorite.frame.midX
        func drag(_ from: XCUIElement, to: XCUIElement) {
            let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -70))
            let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -70))
            // Hold beyond menu presentation before moving the same finger.
            start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        drag(album, to: favorite)
        let contextMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "轻点操作")).firstMatch
        XCTAssertTrue(contextMenu.waitForNonExistence(timeout: 5), "Dragging must leave the context menu")
        XCTAssertNotEqual(album.frame.midX < favorite.frame.midX, albumWasLeft, "Drop should reorder the pinned shelf")
        app.terminate()
        app.launch()
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        XCTAssertNotEqual(album.frame.midX < favorite.frame.midX, albumWasLeft, "The saved order should survive relaunch")
        drag(album, to: favorite)
        XCTAssertEqual(album.frame.midX < favorite.frame.midX, albumWasLeft, "Restore the simulator fixture order")
    }
    @MainActor func testPinnedZoomOpensAndReturnsRepeatedly() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let album = app.staticTexts["Sunrise"].firstMatch
        guard album.waitForExistence(timeout: 10), album.frame.minY < app.frame.height / 2 else {
            throw XCTSkip("Requires the simulator fixture with a pinned Sunrise album")
        }
        for _ in 0..<2 {
            album.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: -70)).tap()
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertEqual(back.label, "资料库")
            XCTAssertTrue(app.navigationBars.buttons["更多"].exists)
            back.tap()
            XCTAssertTrue(app.navigationBars.buttons["新建播放列表"].waitForExistence(timeout: 5))
            XCTAssertTrue(album.isHittable)
        }
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "Pinned artwork after repeated zoom return"
        returned.lifetime = .keepAlways
        add(returned)
    }

    @MainActor func testPlaylistEntryReturnAndPullToSearch() {
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<2 {
            let entry = app.buttons["播放列表"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            entry.tap()
            XCTAssertTrue(app.navigationBars["播放列表"].waitForExistence(timeout: 5))
            let initial = XCTAttachment(screenshot: app.screenshot())
            initial.name = "Playlist initial title"; initial.lifetime = .keepAlways; add(initial)
            app.swipeDown()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            app.navigationBars.buttons["BackButton"].tap()
            XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        }
    }
    @MainActor func testLibraryControlsAndActualTapNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["资料库"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["新建播放列表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["更多"].exists)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Library before tap"; before.lifetime = .keepAlways; add(before)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library-before.png"))
        print("SCREENSHOT_PATH \(NSTemporaryDirectory())")
        let albums = app.buttons["专辑"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 5))
        XCTAssertTrue(albums.isHittable)
        albums.tap()
        XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "After album tap"; after.lifetime = .keepAlways; add(after)
        XCTAssertTrue(app.navigationBars.buttons["筛选"].exists)
        XCTAssertTrue(app.navigationBars.buttons["更多"].exists)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["编辑置顶"].waitForExistence(timeout: 3))
        if app.buttons["编辑置顶"].isEnabled {
            app.buttons["编辑置顶"].tap()
            XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 3))
            app.navigationBars.buttons["完成"].tap()
        } else { app.tap() }
        app.navigationBars.buttons["新建播放列表"].tap()
        XCTAssertTrue(app.navigationBars["新建播放列表"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        app.tabBars.buttons["主页"].tap()
        XCTAssertTrue(app.navigationBars["主页"].waitForExistence(timeout: 5))
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.navigationBars.buttons["新建播放列表"].waitForExistence(timeout: 5))
    }
    @MainActor func testImportedAlbumCardOpensAndReturns() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["专辑"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["专辑"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
        guard let card = app.scrollViews.buttons.allElementsBoundByIndex.first(where: {
            $0.label.isEmpty && $0.frame.width > 100 && $0.frame.height > 100 && $0.isHittable
        }) else { throw XCTSkip("Requires local album files in the simulator library") }
        card.tap()
        let back = app.navigationBars.buttons["BackButton"]
        let returnedToAlbum = NSPredicate(format: "label == %@", "专辑")
        expectation(for: returnedToAlbum, evaluatedWith: back)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.navigationBars.buttons["更多"].exists)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Native album detail"; detail.lifetime = .keepAlways; add(detail)
        back.tap()
        XCTAssertTrue(app.navigationBars["专辑"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars.buttons["新建播放列表"].waitForExistence(timeout: 5))
    }

}
