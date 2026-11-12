import XCTest
import SwiftUI
import UIKit
@testable import NeoMusic

@MainActor
final class LyricsFocusTests: XCTestCase {
    func testNativeFocusAlignsDistantAndMultilineTargetsAtDefaultAndAccessibilitySizes() async throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let state = LyricsFocusTestState()
            let window = try await mount(state, size: size)
            defer { window.isHidden = true }

            for id in [40, 79, 0, 41, 55, 40] {
                state.activeID = id
                try await assertFocus(id, in: state)
            }
            if size == .large {
                state.activeID = 62
                try await assertFocus(62, in: state)
            }
        }
    }

    func testNativeFocusUsesLatestTargetAfterHiddenPageAndTrackReplacement() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)

        state.isActive = false
        state.activeID = 0
        let hiddenUpdateApplied = try await waitUntil {
            state.renderedActiveID == 0 && state.renderedIsActive == false
        }
        XCTAssertTrue(hiddenUpdateApplied)
        XCTAssertGreaterThan(scrollView.contentOffset.y, 600,
                             "The hidden page must keep its current position instead of following line zero")

        state.activeID = 79
        state.isActive = true
        try await assertFocus(79, in: state)

        for _ in 0..<5 {
            for id in [41, 42, 40] {
                state.activeID = id
                let updateApplied = try await waitUntil { state.renderedActiveID == id }
                XCTAssertTrue(updateApplied)
            }
            try await assertFocus(40, in: state)
        }

        state.geometry = LyricsRowGeometry()
        state.activeID = 0
        state.trackIdentity += 1
        try await assertFocus(0, in: state)
    }

    func testLeavingLyricsKeepsTheFocusedLineWhenThePageScales() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)
        let offset = scrollView.contentOffset.y
        let top = try XCTUnwrap(state.geometry.top(for: 40))
        let seeksBefore = state.seekCount

        state.isActive = false
        state.presentationScale = 0.9
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(state.geometry.top(for: 40) ?? -1, top, accuracy: 2)
        XCTAssertEqual(scrollView.contentOffset.y, offset, accuracy: 2)
        XCTAssertEqual(state.seekCount, seeksBefore)
        XCTAssertEqual(state.activeID, 40)
    }

    private func mount(_ state: LyricsFocusTestState, size: DynamicTypeSize) async throws -> UIWindow {
        let suite = "LyricsFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(0.5, forKey: LyricsFocus.storageKey)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let content = LyricsFocusTestContent(state: state)
            .dynamicTypeSize(size)
            .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: content)
        host.traitOverrides.preferredContentSizeCategory = size == .large
            ? .large : .accessibilityExtraExtraExtraLarge
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        let laidOut = try await waitUntil { state.viewportHeight == 600 }
        XCTAssertTrue(laidOut)
        return window
    }

    private func assertFocus(_ id: Int, in state: LyricsFocusTestState) async throws {
        let aligned = try await waitUntil {
            guard let height = state.geometry.height(for: id),
                  let top = state.geometry.top(for: id) else { return false }
            return abs(top - state.expectedTop(forRowHeight: height)) <= 2
        }
        let height = try XCTUnwrap(state.geometry.height(for: id), "Target \(id) must be measured")
        let top = try XCTUnwrap(state.geometry.top(for: id), "Target \(id) must be visible")
        XCTAssertTrue(aligned, "Target \(id), height=\(height), top=\(top)")
        XCTAssertEqual(top, state.expectedTop(forRowHeight: height), accuracy: 2)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

@MainActor @Observable
private final class LyricsFocusTestState {
    var activeID = 40
    var isActive = true
    var isInterfaceHidden = false
    var trackIdentity = 0
    var geometry = LyricsRowGeometry()
    var viewportHeight: CGFloat = 0
    var renderedActiveID: Int?
    var renderedIsActive: Bool?
    var presentationScale: CGFloat = 1
    var seekCount = 0

    let lyrics: ReferenceLyrics = {
        let lines = (0..<80).map { index in
            let text: String
            switch index % 4 {
            case 0: text = "\(index + 1)"
            case 1: text = "旋律\n回声"
            case 2: text = "沿着熟悉的街道继续向前，看远处的光渐渐亮起"
            default: text = "尾声"
            }
            return LyricsLine(id: index, time: Double(index * 4), text: text)
        }
        return ReferenceLyrics(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "test")
    }()

    func expectedTop(forRowHeight height: CGFloat) -> CGFloat {
        let visibleHeight = isInterfaceHidden ? viewportHeight : viewportHeight - 120
        return min(max(viewportHeight * 0.5 - height / 2, visibleHeight * 0.08),
                   max(visibleHeight * 0.08, visibleHeight * 0.84 - height))
    }
}

private struct LyricsFocusTestContent: View {
    @Bindable var state: LyricsFocusTestState

    var body: some View {
        AppleMusicLocalLyricsView(
            lyrics: state.lyrics, playerFrame: CGRect(x: 0, y: 0, width: 338, height: 600),
            activeID: state.activeID, bottomOverlayHeight: 120, isActive: state.isActive,
            isInterfaceHidden: $state.isInterfaceHidden,
            onSeek: {
                state.seekCount += 1
                state.activeID = state.lyrics.activeLine(at: $0) ?? 0
            },
            playerCoordinateSpace: .named("LyricsFocusTests"), rowGeometry: state.geometry
        )
        .id(state.trackIdentity)
        .scaleEffect(state.presentationScale, anchor: .center)
        .frame(width: 338, height: 600)
        .coordinateSpace(name: "LyricsFocusTests")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.viewportHeight = $0 }
        .onChange(of: state.activeID, initial: true) { _, id in state.renderedActiveID = id }
        .onChange(of: state.isActive, initial: true) { _, active in state.renderedIsActive = active }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
