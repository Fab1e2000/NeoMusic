import XCTest
import SwiftUI
@testable import NeoMusic

@MainActor
final class LibraryToastTests: XCTestCase {
    private var singlePlaylist: LibraryToast {
        .addedToPlaylist(count: 2, title: "夜晚散步", artwork: .missing, playlistID: "night")
    }

    func testAllExistingToastTypesUseTheirConfirmedDisplayPolicy() {
        let short: [LibraryToast] = [.favorited, .unfavorited, .pinned, .unpinned, .playingNext, .addedToQueue]
        for toast in short {
            XCTAssertEqual(toast.dismissalDelay(voiceOverEnabled: false), Duration.seconds(1.5))
            XCTAssertEqual(toast.dismissalDelay(voiceOverEnabled: true), Duration.seconds(1.5))
        }
        for toast in [singlePlaylist, .error("连接暂时中断")] {
            XCTAssertEqual(toast.dismissalDelay(voiceOverEnabled: false), Duration.seconds(5))
            XCTAssertNil(toast.dismissalDelay(voiceOverEnabled: true))
        }
        let multiple = LibraryToast.addedToPlaylists(count: 2, playlistCount: 3)
        XCTAssertEqual(multiple.dismissalDelay(voiceOverEnabled: false), Duration.seconds(5))
        XCTAssertEqual(multiple.dismissalDelay(voiceOverEnabled: true), Duration.seconds(5))
    }

    func testSameToastTypeGetsNewIdentityAndOldDismissalKeepsTheReplacement() throws {
        let center = LibraryToastCenter(voiceOverEnabled: true)
        center.show(.error("连接暂时中断"))
        let first = try XCTUnwrap(center.current)
        center.show(.error("连接暂时中断"))
        let second = try XCTUnwrap(center.current)
        XCTAssertNotEqual(first.id, second.id)
        center.dismiss(first)
        XCTAssertEqual(center.current?.id, second.id)
        center.dismiss(second)
        XCTAssertNil(center.current)
    }

    func testCancelledTimerCannotDismissANewerPresentation() async throws {
        let sleeper = ToastSleepProbe()
        let center = LibraryToastCenter(voiceOverEnabled: false, sleep: sleeper.sleep)
        defer {
            if let current = center.current { center.dismiss(current) }
            sleeper.finishAll()
        }
        let firstScheduled = expectation(description: "First toast schedules its timer")
        sleeper.onScheduled = { firstScheduled.fulfill() }
        center.show(.favorited)
        await fulfillment(of: [firstScheduled], timeout: 1)

        let nextScheduled = expectation(description: "Replacement schedules a fresh timer")
        sleeper.onScheduled = { nextScheduled.fulfill() }
        center.show(.addedToQueue)
        let replacement = try XCTUnwrap(center.current)
        await fulfillment(of: [nextScheduled], timeout: 1)
        sleeper.finish(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(center.current?.id, replacement.id)
        sleeper.finish(1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(center.current)
    }

    func testVoiceOverChangesSuspendAndRestartTheCurrentErrorTimer() async throws {
        let sleeper = ToastSleepProbe()
        let center = LibraryToastCenter(voiceOverEnabled: false, sleep: sleeper.sleep)
        defer {
            if let current = center.current { center.dismiss(current) }
            sleeper.finishAll()
        }
        let initialScheduled = expectation(description: "Error initially schedules five seconds")
        sleeper.onScheduled = { initialScheduled.fulfill() }
        center.show(.error("未能保存，请回到歌曲操作重试"))
        let presentation = try XCTUnwrap(center.current)
        await fulfillment(of: [initialScheduled], timeout: 1)
        XCTAssertEqual(sleeper.delays, [.seconds(5)])

        center.updateVoiceOverEnabled(true)
        sleeper.finish(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(center.current?.id, presentation.id)
        XCTAssertEqual(sleeper.delays.count, 1)

        let restarted = expectation(description: "Disabling VoiceOver gives the error a full new interval")
        sleeper.onScheduled = { restarted.fulfill() }
        center.updateVoiceOverEnabled(false)
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(sleeper.delays, [.seconds(5), .seconds(5)])
        sleeper.finish(1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(center.current)
    }

    func testVoiceOverDoesNotRestartAnOrdinarySuccessTimer() async throws {
        let sleeper = ToastSleepProbe()
        let center = LibraryToastCenter(voiceOverEnabled: false, sleep: sleeper.sleep)
        defer {
            if let current = center.current { center.dismiss(current) }
            sleeper.finishAll()
        }
        let scheduled = expectation(description: "Success schedules once")
        sleeper.onScheduled = { scheduled.fulfill() }
        center.show(.favorited)
        await fulfillment(of: [scheduled], timeout: 1)
        center.updateVoiceOverEnabled(true)
        center.updateVoiceOverEnabled(false)
        XCTAssertEqual(sleeper.delays, [.seconds(1.5)])
        sleeper.finish(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(center.current)
    }

    func testAnnouncementsAreConsumedOncePerPresentationAndIncludeThePlaylistName() throws {
        let center = LibraryToastCenter(voiceOverEnabled: false)
        center.show(singlePlaylist)
        defer { if let current = center.current { center.dismiss(current) } }
        XCTAssertNil(center.takeAccessibilityAnnouncement())
        center.updateVoiceOverEnabled(true)
        let announcement = try XCTUnwrap(center.takeAccessibilityAnnouncement())
        XCTAssertEqual(String(announcement.characters), "已添加2首歌曲，夜晚散步")
        XCTAssertEqual(announcement.accessibilitySpeechAnnouncementPriority, .low)
        XCTAssertNil(center.takeAccessibilityAnnouncement())
        center.updateVoiceOverEnabled(false)
        center.updateVoiceOverEnabled(true)
        XCTAssertNil(center.takeAccessibilityAnnouncement())

        center.show(.error("连接中断"))
        let error = try XCTUnwrap(center.takeAccessibilityAnnouncement())
        XCTAssertEqual(String(error.characters), "连接中断")
        XCTAssertEqual(error.accessibilitySpeechAnnouncementPriority, .default)
        XCTAssertNil(center.takeAccessibilityAnnouncement())
        center.show(.error("连接中断"))
        XCTAssertNotNil(center.takeAccessibilityAnnouncement())
    }

    func testOpeningThePlaylistDismissesItsPresentationBeforeRouting() throws {
        let center = LibraryToastCenter(voiceOverEnabled: true)
        center.show(singlePlaylist)
        let presentation = try XCTUnwrap(center.current)
        var opened: LibraryRoute?
        let view = LibraryToastView(toast: presentation.toast, dismiss: { center.dismiss(presentation) },
                                    openRoute: OpenLibraryRouteAction { route in
            XCTAssertNil(center.current)
            opened = route
        })
        view.openPlaylist("night")
        XCTAssertEqual(opened, .playlist("night"))
        XCTAssertNil(center.current)
    }
}

@MainActor
private final class ToastSleepProbe {
    private(set) var delays: [Duration] = []
    var onScheduled: (() -> Void)?
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            let index = delays.count
            delays.append(duration)
            pending[index] = continuation
            onScheduled?()
        }
    }

    func finish(_ index: Int) {
        pending.removeValue(forKey: index)?.resume()
    }

    func finishAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
