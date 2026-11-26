import XCTest

final class PlayerInteractionTests: XCTestCase {
    @MainActor func testQueueArtworkReturnsToTheCurrentTrackFromBothScrollDirections() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "player-performance"]
        app.launch()
        XCTAssertTrue(app.buttons["player.dismiss"].waitForExistence(timeout: 15))
        defer { app.terminate() }

        let next = app.buttons["下一首"].firstMatch
        let titles = ["窗边的光", "沿着海岸", "晚风经过"]
        for number in 2...13 {
            let title = "\(number) · \(titles[(number - 1) % titles.count])"
            next.tap()
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 3))
        }
        let currentTitle = "13 · 窗边的光"
        let current = app.staticTexts[currentTitle].firstMatch
        let upcoming = app.staticTexts["14 · 沿着海岸"].firstMatch
        let queue = try XCTUnwrap(app.buttons.matching(identifier: "继续播放").allElementsBoundByIndex.first {
            $0.isHittable
        })
        let queueButton = app.coordinate(withNormalizedOffset:
            CGVector(dx: queue.frame.midX / app.frame.width, dy: queue.frame.midY / app.frame.height)
        )
        let artworkTitleY = current.frame.minY
        queueButton.tap()
        XCTAssertTrue(upcoming.waitForExistence(timeout: 5))
        let queueTitleY = current.frame.minY
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.18))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.60))

        func leaveAndReturn() {
            queueButton.tap()
            XCTAssertTrue(current.waitForExistence(timeout: 3))
            XCTAssertEqual(current.frame.minY, artworkTitleY, accuracy: 2)
            queueButton.tap()
            XCTAssertTrue(upcoming.waitForExistence(timeout: 3))
            XCTAssertEqual(current.frame.minY, queueTitleY, accuracy: 2)
        }

        lower.press(forDuration: 0.04, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertFalse(current.isHittable)
        leaveAndReturn()

        for _ in 0..<2 {
            upper.press(forDuration: 0.04, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(app.buttons["player.dismiss"].exists)
        XCTAssertFalse(upcoming.isHittable)
        XCTAssertFalse(current.isHittable)
        leaveAndReturn()
    }

    @MainActor func testShortTrackDragsReturnToCurrentSongForFiveRounds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "player-motion"]
        app.launch()
        let title = app.staticTexts["窗边的光"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let originalFrame = title.frame
        for round in 0..<5 {
            let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let finish = start.withOffset(CGVector(dx: round.isMultiple(of: 2) ? -35 : 35, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(title.exists, "A short drag must keep the current song")
            XCTAssertEqual(title.frame.minX, originalFrame.minX, accuracy: 1)
            XCTAssertEqual(title.frame.minY, originalFrame.minY, accuracy: 1)
        }
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["沿着海岸"].firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Five short drags followed by next track"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor func testTitleAndArtistDragSwitchTracksImmediatelyAndArtworkDragDoesNot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-frontendReviewPreview", "player-motion"]
        app.launch()

        let firstTitle = app.staticTexts["窗边的光"].firstMatch
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 8))
        let artist = app.buttons["NeoMusic 示例"].firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        let artistX = artist.frame.minX

        let titleStart = firstTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        titleStart.press(forDuration: 0.05, thenDragTo: titleStart.withOffset(CGVector(dx: -140, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.staticTexts["沿着海岸"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(artist.frame.minX, artistX, accuracy: 1)

        let artistStart = artist.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        artistStart.press(forDuration: 0.05, thenDragTo: artistStart.withOffset(CGVector(dx: -140, dy: 0)),
                          withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.staticTexts["晚风经过"].firstMatch.waitForExistence(timeout: 2))

        let artworkStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        artworkStart.press(forDuration: 0.05, thenDragTo: artworkStart.withOffset(CGVector(dx: -160, dy: 0)))
        XCTAssertTrue(app.staticTexts["晚风经过"].firstMatch.exists)

        let thirdTitle = app.staticTexts["晚风经过"].firstMatch
        let rightStart = thirdTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        rightStart.press(forDuration: 0.05, thenDragTo: rightStart.withOffset(CGVector(dx: 140, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.staticTexts["沿着海岸"].firstMatch.waitForExistence(timeout: 2))
        app.terminate()
    }

    @MainActor func testMiniPlayerAndQueueHeaderTrackSwipeOnLiveShell() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-onlineLibraryPreview", "playlists",
            "-playerSwipeQueue",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        app.launch()

        let playPause = app.buttons["mini.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))

        let miniTitleArea = try XCTUnwrap(app.buttons.allElementsBoundByIndex.first {
            $0.frame.width > 80 && $0.frame.height > 26 && $0.frame.height < 64
                && abs($0.frame.midY - playPause.frame.midY) < 14
                && $0.frame.maxX <= playPause.frame.minX + 12
                && $0.isHittable
        }, "Mini-player title area")

        let track0Predicate = NSPredicate(format: "label CONTAINS %@", "物語りのワルツ")
        let track1Predicate = NSPredicate(format: "label CONTAINS %@", "Midnight Echo Across The Harbor")
        let track2Predicate = NSPredicate(format: "label CONTAINS %@", "Sunburst Skyline")
        XCTAssertTrue(app.descendants(matching: .any).matching(track0Predicate).firstMatch.waitForExistence(timeout: 3))

        let miniCenter = miniTitleArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        miniCenter.press(forDuration: 0.02, thenDragTo: miniCenter.withOffset(CGVector(dx: -120, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.02)
        XCTAssertTrue(app.descendants(matching: .any).matching(track1Predicate).firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["收起播放器"].exists)

        miniCenter.press(forDuration: 0.02, thenDragTo: miniCenter.withOffset(CGVector(dx: -120, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.02)
        XCTAssertTrue(app.descendants(matching: .any).matching(track2Predicate).firstMatch.waitForExistence(timeout: 2))

        let artworkX = max(16, miniTitleArea.frame.minX - 24)
        let artworkCenter = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: artworkX, dy: miniTitleArea.frame.midY))
        artworkCenter.press(forDuration: 0.02, thenDragTo: artworkCenter.withOffset(CGVector(dx: 120, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0.02)
        XCTAssertTrue(app.descendants(matching: .any).matching(track2Predicate).firstMatch.exists)

        miniCenter.press(forDuration: 0.02, thenDragTo: miniCenter.withOffset(CGVector(dx: 120, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.02)
        XCTAssertTrue(app.descendants(matching: .any).matching(track1Predicate).firstMatch.waitForExistence(timeout: 2))

        miniTitleArea.tap()
        let dismiss = app.buttons["收起播放器"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))

        let queueButton = try XCTUnwrap(app.buttons.matching(identifier: "继续播放").allElementsBoundByIndex.first { $0.isHittable })
        queueButton.tap()
        let headerTitle = app.staticTexts["Midnight Echo Across The Harbor"].firstMatch
        XCTAssertTrue(headerTitle.waitForExistence(timeout: 3))
        let headerStart = headerTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        headerStart.press(forDuration: 0.03, thenDragTo: headerStart.withOffset(CGVector(dx: 140, dy: 0)),
                          withVelocity: .slow, thenHoldForDuration: 0.03)
        XCTAssertTrue(app.staticTexts["物語りのワルツ"].firstMatch.waitForExistence(timeout: 2))

        dismiss.tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        miniCenter.press(forDuration: 0.02, thenDragTo: miniCenter.withOffset(CGVector(dx: 0, dy: -220)),
                         withVelocity: .default, thenHoldForDuration: 0.02)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        app.terminate()
    }
}
