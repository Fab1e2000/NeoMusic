import XCTest
import SwiftUI
import UIKit
@testable import NeoMusic

@MainActor
final class LyricsFocusTests: XCTestCase {
    func testWaveStartsAtTheOutgoingRowAndKeepsDistanceBlurReadable() {
        let motion = AppleMusicLyricsMotionProfile.iOS26_6
        XCTAssertTrue(motion.isForwardLineChange(from: 40, to: 41))
        for next in [nil, 40, 39, 62] as [Int?] {
            XCTAssertFalse(motion.isForwardLineChange(from: 40, to: next))
        }
        XCTAssertFalse(motion.isForwardLineChange(from: nil, to: 0))
        for (row, delay) in [(40, 0.0), (41, 0.05), (42, 0.10), (43, 0.15), (44, 0.20)] {
            XCTAssertEqual(motion.lineChangeDelay(rowIndex: row, activeIndex: 41), delay, accuracy: 0.0001)
        }
        let lineHeight = 40.0
        let stride = lineHeight + motion.lineSpacing
        XCTAssertEqual(motion.blurRadius(verticalDistance: 0, lineHeight: lineHeight), 0)
        XCTAssertEqual(motion.blurRadius(verticalDistance: stride, lineHeight: lineHeight), 2.5)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 2 * stride, lineHeight: lineHeight), 4)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 3 * stride, lineHeight: lineHeight), 5.5)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 20 * stride, lineHeight: lineHeight), 5.5)
        for distance in [0.5 * stride, stride, 1.5 * stride, 2 * stride, 2.5 * stride] {
            let radius = motion.blurRadius(verticalDistance: distance, lineHeight: lineHeight)
            XCTAssertEqual(radius, motion.blurRadius(verticalDistance: -distance, lineHeight: lineHeight))
            XCTAssertGreaterThan(motion.blurRadius(verticalDistance: distance + 0.5, lineHeight: lineHeight), radius)
        }
        XCTAssertLessThan(motion.focusBlurTransitionDuration, motion.lineChangeDuration)
    }

    func testLyricsHostingKeepsHorizontalBlurOverflowAndWrappedDistance() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)
        XCTAssertFalse(scrollView.clipsToBounds)
        let rows = scrollView.subviews.filter { $0.subviews.first is any UIContentView }
        XCTAssertEqual(rows.count, state.lyrics.lines.count)
        for row in rows {
            let host = try XCTUnwrap(row.subviews.first)
            XCTAssertFalse(row.clipsToBounds)
            XCTAssertFalse(host.clipsToBounds)
            XCTAssertLessThan(host.frame.minX, row.bounds.minX)
            XCTAssertGreaterThan(host.frame.maxX, row.bounds.maxX)
            if row.frame.maxY < scrollView.bounds.minY - 24 || row.frame.minY > scrollView.bounds.maxY + 24 {
                XCTAssertTrue(host.isHidden, "Unclipped rows must not draw outside the vertical viewport")
            }
        }
        let focus = try XCTUnwrap(state.geometry.top(for: 40))
        let wrappedTop = try XCTUnwrap(state.geometry.top(for: 42))
        let lineHeight = try XCTUnwrap(state.geometry.height(for: 40))
        let motion = AppleMusicLyricsMotionProfile.iOS26_6
        let wrappedBlur = motion.blurRadius(verticalDistance: Double(wrappedTop - focus), lineHeight: Double(lineHeight))
        let twoSingleLines = motion.blurRadius(verticalDistance: 2 * (Double(lineHeight) + motion.lineSpacing),
                                               lineHeight: Double(lineHeight))
        XCTAssertGreaterThan(wrappedBlur, twoSingleLines, "Wrapped text must contribute its actual height to distance blur")
    }

    func testHeaderAndProgressBoundariesSurviveInterfaceVisibilityChanges() async throws {
        let state = LyricsFocusTestState()
        state.topOverlayHeight = 69.25
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)
        // Re-layout before another render commit must retain the current model position.
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        let initialHeight = try XCTUnwrap(state.geometry.height(for: 40))
        let initialTop = try XCTUnwrap(state.geometry.top(for: 40))
        XCTAssertEqual(initialTop, state.expectedTop(forRowHeight: initialHeight), accuracy: 2)
        for hidden in [false, true, false] {
            state.isInterfaceHidden = hidden
            try await assertFocus(40, in: state)
            let top = try XCTUnwrap(state.geometry.top(for: 40))
            let height = try XCTUnwrap(state.geometry.height(for: 40))
            XCTAssertGreaterThan(top, state.topOverlayHeight)
            XCTAssertLessThan(top + height, hidden ? 600 : 480)
            let bottom: CGFloat = hidden ? 600 : 480
            let edgeSettled = try await waitUntil {
                self.edgeMasks(in: scrollView.layer).contains { owner, mask in
                    let ownerFrame = scrollView.layer.convert(owner.bounds, from: owner)
                    let frame = scrollView.layer.convert(mask.frame, from: owner)
                    return ownerFrame.intersects(scrollView.bounds)
                        && abs(frame.minY - scrollView.bounds.minY - state.topOverlayHeight) < 2
                        && abs(frame.maxY - scrollView.bounds.minY - bottom) < 2
                }
            }
            XCTAssertTrue(edgeSettled, "Leaf masks must follow the header and playback boundary")
            XCTAssertFalse(scrollView.point(inside: CGPoint(x: 20, y: scrollView.bounds.minY + 60), with: nil))
            XCTAssertEqual(scrollView.point(inside: CGPoint(x: 20, y: scrollView.bounds.minY + 490), with: nil), hidden)
        }
    }

    private func edgeMasks(in layer: CALayer) -> [(CALayer, CAGradientLayer)] {
        var masks: [(CALayer, CAGradientLayer)] = []
        if let mask = layer.mask as? CAGradientLayer { masks.append((layer, mask)) }
        for child in layer.sublayers ?? [] { masks += edgeMasks(in: child) }
        return masks
    }

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

    func testNonAdjacentJumpAnimatesBeforeSettling() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)
        let rows = scrollView.subviews.filter { $0.subviews.first is any UIContentView }

        state.activeID = 44
        let animating = try await waitUntil {
            state.renderedActiveID == 44 && rows.contains { !($0.layer.animationKeys() ?? []).isEmpty }
        }
        XCTAssertTrue(animating, "Non-adjacent line jump must drive UIKit row spring animations")
        try await assertFocus(44, in: state)
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

    func testBottomFadeDepthAndInterfaceMotionMatchSynchronizedSpec() {
        let motion = NowPlayingMotionSpec.appleMusic26.interface
        XCTAssertEqual(motion.coreShow.duration, 0.36, accuracy: 0.001)
        XCTAssertEqual(motion.coreHide.duration, 0.36, accuracy: 0.001)
        XCTAssertEqual(motion.controlOpacityAnimation(isVisible: true).duration, 0.36, accuracy: 0.001)
        XCTAssertEqual(motion.controlOpacityAnimation(isVisible: false).duration, 0.18, accuracy: 0.001)
        for layer in [NowPlayingInterfaceLayer.progress, .transport, .volume, .pageSelector] {
            for visible in [false, true] {
                let spec = motion.controlAnimation(for: layer, isVisible: visible)
                XCTAssertEqual(spec.duration, 0.36, accuracy: 0.001)
                XCTAssertEqual(spec.delay, 0, accuracy: 0.001)
            }
        }
        XCTAssertEqual(motion.progress.hiddenOffset, 245)
        XCTAssertEqual(motion.transport.hiddenOffset, 220)
        XCTAssertEqual(motion.volume.hiddenOffset, 198)
        XCTAssertEqual(motion.pageSelector.hiddenOffset, 98)

        let shown = LyricsViewportFade(
            height: 753,
            referenceHeight: 473,
            shownReferenceHeight: 473,
            topOverlayHeight: 102,
            isInterfaceHidden: false
        )
        XCTAssertEqual(shown.bottomEnd, 473, accuracy: 0.5)
        XCTAssertEqual(shown.bottomEnd - shown.bottomStart, 160, accuracy: 0.5)

        let midpoint = LyricsViewportFade(
            height: 753,
            referenceHeight: 613,
            shownReferenceHeight: 473,
            topOverlayHeight: 102,
            isInterfaceHidden: false
        )
        XCTAssertEqual(midpoint.bottomEnd - midpoint.bottomStart, 108, accuracy: 0.5)

        let hidden = LyricsViewportFade(
            height: 753,
            referenceHeight: 753,
            shownReferenceHeight: 473,
            topOverlayHeight: 102,
            isInterfaceHidden: true
        )
        XCTAssertEqual(hidden.bottomEnd, 753, accuracy: 0.5)
        XCTAssertEqual(hidden.bottomEnd - hidden.bottomStart, 56, accuracy: 0.5)
    }

    private func mount(_ state: LyricsFocusTestState, size: DynamicTypeSize) async throws -> UIWindow {
        let content = LyricsFocusTestContent(state: state)
            .dynamicTypeSize(size)
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
    var topOverlayHeight: CGFloat = 0

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
        let visibleHeight = (isInterfaceHidden ? viewportHeight : viewportHeight - 120) - topOverlayHeight
        let leadingLineHeight = geometry.height(for: 40) ?? height
        return topOverlayHeight + min(max(visibleHeight * 0.233 - leadingLineHeight / 2, visibleHeight * 0.08),
                   max(visibleHeight * 0.08, visibleHeight * 0.84 - height))
    }
}

private struct LyricsFocusTestContent: View {
    @Bindable var state: LyricsFocusTestState

    var body: some View {
        AppleMusicLocalLyricsView(
            lyrics: state.lyrics,
            activeID: state.activeID, bottomOverlayHeight: 120, isActive: state.isActive,
            isInterfaceHidden: $state.isInterfaceHidden,
            onSeek: {
                state.seekCount += 1
                state.activeID = state.lyrics.activeLine(at: $0) ?? 0
            },
            topOverlayHeight: state.topOverlayHeight, rowGeometry: state.geometry
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
