import XCTest
import SwiftUI
import UIKit
import LNPopupUI
@testable import NeoMusic
import FullScreenPlayer

@MainActor
final class PopupItemAccessibilityTests: XCTestCase {
    func testPlayerBarStaysMountedAcrossRestorationSignOutAndEmptyQueue() async throws {
        let window = UIWindow(windowScene: try await applicationWindowScene())
        defer { window.isHidden = true }
        let owner = PlayerTestFixtures.owner(tracks: [
            PlayerTrack(id: "netease:101:42", title: "恢复的曲目", artists: "艺人", albumTitle: "",
                        coverURL: nil, duration: 120)
        ])
        let player = PlayerState(model: owner)
        let actions = PlayerTestFixtures.actions()
        let library = PlayerTestFixtures.library()
        func content(restoring: Bool) -> some View {
            Color.clear
                .modifier(PlayerPopup(isPresented: .constant(false), isSuppressed: restoring, onClose: {}))
                .environment(player).environment(actions).environment(library)
        }
        func findBar(in view: UIView) -> LNPopupBar? {
            if let bar = view as? LNPopupBar { return bar }
            return view.subviews.lazy.compactMap { findBar(in: $0) }.first
        }

        let host = UIHostingController(rootView: content(restoring: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(1400))
        let bar = try XCTUnwrap(findBar(in: window))
        let item = try XCTUnwrap(bar.popupItem)
        XCTAssertEqual(bar.accessibilityLabel, "未在播放，迷你播放器")
        XCTAssertTrue(bar.isAccessibilityElement)
        XCTAssertTrue(bar.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(bar.popupOpenGestureRecognizer.isEnabled)

        host.rootView = content(restoring: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(findBar(in: window) === bar)
        XCTAssertTrue(bar.popupItem === item)
        XCTAssertTrue(bar.popupOpenGestureRecognizer.isEnabled)
        XCTAssertFalse(bar.isAccessibilityElement)
        XCTAssertEqual(item.accessibilityLabel, "恢复的曲目，艺人，迷你播放器")

        owner.invalidateOnlinePlayback(ownerID: nil)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(item.accessibilityLabel, "在线歌曲不可用，登录原账号后可用，迷你播放器")

        owner.queue.removeAll()
        owner.entryIDs.removeAll()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(findBar(in: window) === bar)
        XCTAssertTrue(bar.popupItem === item)
        XCTAssertEqual(item.accessibilityLabel, "未在播放，迷你播放器")
        XCTAssertTrue(bar.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(bar.popupOpenGestureRecognizer.isEnabled)
    }

    func testPublicPopupItemUpdatesAndClearsAccessibilityMetadata() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        var bar: LNPopupBar?
        let captureBar: (LNPopupBar) -> Void = { bar = $0 }
        let host = UIHostingController(rootView: PopupAccessibilityFixture(
            id: "first", label: "第一首，艺人，迷你播放器", hint: "打开正在播放", captureBar: captureBar))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(1400))
        let item = try XCTUnwrap(bar?.popupItem)
        XCTAssertEqual(item.accessibilityLabel, "第一首，艺人，迷你播放器")
        XCTAssertEqual(item.accessibilityHint, "打开正在播放")

        host.rootView = PopupAccessibilityFixture(
            id: "second", label: "第二首，另一艺人，迷你播放器", hint: "打开第二首", captureBar: captureBar)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(bar?.popupItem === item)
        XCTAssertEqual(item.accessibilityLabel, "第二首，另一艺人，迷你播放器")
        XCTAssertEqual(item.accessibilityHint, "打开第二首")

        host.rootView = PopupAccessibilityFixture(id: "legacy", label: nil, hint: nil, captureBar: captureBar)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(bar?.popupItem === item)
        XCTAssertNil(item.accessibilityLabel)
        XCTAssertNil(item.accessibilityHint)
    }

    func testExistingCustomTitleInitializerDefaultsAccessibilityMetadataToNil() {
        let item = PopupItem(id: "legacy", title: { Text("旧调用") }, buttons: {
            ToolbarItem(placement: .popupBar) { EmptyView() }
        })
        XCTAssertNil(item.accessibilityLabel)
        XCTAssertNil(item.accessibilityHint)
    }
}

private struct PopupAccessibilityFixture: View {
    let id: String
    let label: String?
    let hint: String?
    let captureBar: (LNPopupBar) -> Void

    var body: some View {
        Color.clear
            .popup(isBarPresented: .constant(true), isPopupOpen: .constant(false)) {
                Color.clear.popupItem {
                    PopupItem(id: id, accessibilityLabel: label, accessibilityHint: hint,
                              title: { Text(id) }, buttons: {
                        ToolbarItem(placement: .popupBar) { EmptyView() }
                    })
                }
            }
            .popupBarCustomizer(captureBar)
            .transaction { $0.disablesAnimations = true }
    }
}
