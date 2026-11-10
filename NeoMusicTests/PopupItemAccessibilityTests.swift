import XCTest
import SwiftUI
import UIKit
import LNPopupUI

@MainActor
final class PopupItemAccessibilityTests: XCTestCase {
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
