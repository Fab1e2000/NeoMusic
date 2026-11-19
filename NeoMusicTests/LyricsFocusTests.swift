import XCTest
import SwiftUI
import UIKit
@testable import NeoMusic
@testable import FullScreenPlayer

@MainActor
final class LyricsFocusTests: XCTestCase {
    func testOffscreenLyricsDiscardPositionsAndRecoverWhenBrowsed() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scroll = try XCTUnwrap(scrollViews(in: window).first)
        XCTAssertNil(state.geometry.top(for: 0))
        XCTAssertNil(state.geometry.top(for: 79))

        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.contentInset.top), animated: false)
        scroll.layoutIfNeeded()
        let firstLineVisible = try await waitUntil { state.geometry.top(for: 0) != nil }
        XCTAssertTrue(firstLineVisible)
        XCTAssertNil(state.geometry.top(for: 40))
        XCTAssertNotNil(state.geometry.height(for: 40), "Keep measured heights for later focus alignment")
    }

    func testInactiveLyricsIgnoreScrollLayoutCallbacks() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scroll = try XCTUnwrap(scrollViews(in: window).first)
        state.isActive = false
        let inactive = try await waitUntil { state.renderedIsActive == false }
        XCTAssertTrue(inactive)
        let previousTop = state.geometry.top(for: 40)
        scroll.contentOffset.y += 100
        scroll.setNeedsLayout()
        scroll.layoutIfNeeded()
        XCTAssertEqual(state.geometry.top(for: 40), previousTop)
        state.isActive = true
        try await assertFocus(40, in: state)
    }

    func testWaveStartsAtTheOutgoingRowAndKeepsDistanceBlurReadable() {
        let motion = AppleMusicLyricsMotionProfile.iOS26_6
        XCTAssertTrue(motion.isForwardLineChange(from: 40, to: 41))
        for next in [nil, 40, 39, 62] as [Int?] {
            XCTAssertFalse(motion.isForwardLineChange(from: 40, to: next))
        }
        XCTAssertFalse(motion.isForwardLineChange(from: nil, to: 0))
        for (row, delay) in [(40, 0.0), (41, 0.0), (42, 0.05), (43, 0.10), (44, 0.15)] {
            XCTAssertEqual(motion.lineChangeDelay(rowIndex: row, activeIndex: 41), delay, accuracy: 0.0001)
        }
        let lineHeight = 40.0
        let stride = lineHeight + motion.lineSpacing
        XCTAssertEqual(motion.blurRadius(verticalDistance: 0, lineHeight: lineHeight), 0)
        XCTAssertEqual(motion.blurRadius(verticalDistance: stride, lineHeight: lineHeight), 2.0)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 2 * stride, lineHeight: lineHeight), 3.125)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 3 * stride, lineHeight: lineHeight), 4.25)
        XCTAssertEqual(motion.blurRadius(verticalDistance: 20 * stride, lineHeight: lineHeight), 4.25)
        for distance in [0.5 * stride, stride, 1.5 * stride, 2 * stride, 2.5 * stride] {
            let radius = motion.blurRadius(verticalDistance: distance, lineHeight: lineHeight)
            XCTAssertEqual(radius, motion.blurRadius(verticalDistance: -distance, lineHeight: lineHeight))
            XCTAssertGreaterThan(motion.blurRadius(verticalDistance: distance + 0.5, lineHeight: lineHeight), radius)
        }
        XCTAssertEqual(motion.blurRadius(rowOffset: 0), 0)
        XCTAssertEqual(motion.blurRadius(rowOffset: 1), 2.0, accuracy: 0.001)
        XCTAssertEqual(motion.blurRadius(rowOffset: 2), 3.125, accuracy: 0.001)
        XCTAssertEqual(motion.blurRadius(rowOffset: 3), 4.25, accuracy: 0.001)
        XCTAssertEqual(motion.blurRadius(rowOffset: -1), 3.125, accuracy: 0.001)
        XCTAssertEqual(motion.blurRadius(rowOffset: -2), 4.25, accuracy: 0.001)
        XCTAssertLessThan(motion.focusBlurTransitionDuration, motion.lineChangeDuration)
    }

    func testLyricsControlsHideAfterThreeIdleSecondsOnlyWhileWatching() {
        XCTAssertEqual(LyricsControlsIdle.duration, .seconds(3))
        XCTAssertTrue(LyricsControlsIdle.shouldScheduleHide(
            onLyricsPage: true, controlsVisible: true, voiceOver: false,
            playerActive: true, touching: false, transitioning: false))
        XCTAssertFalse(LyricsControlsIdle.shouldScheduleHide(
            onLyricsPage: true, controlsVisible: true, voiceOver: true,
            playerActive: true, touching: false, transitioning: false))
        XCTAssertFalse(LyricsControlsIdle.shouldScheduleHide(
            onLyricsPage: true, controlsVisible: true, voiceOver: false,
            playerActive: true, touching: true, transitioning: false))
        XCTAssertFalse(LyricsControlsIdle.shouldScheduleHide(
            onLyricsPage: false, controlsVisible: true, voiceOver: false,
            playerActive: true, touching: false, transitioning: false))
    }

    func testLyricsHostingKeepsHorizontalBlurOverflowAndWrappedDistance() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let scrollView = try XCTUnwrap(scrollViews(in: window).first)
        let table = try XCTUnwrap(scrollView as? NativeLyricsScrollView)
        XCTAssertFalse(table.clipsToBounds)
        let cells = table.visibleCells
        XCTAssertFalse(cells.isEmpty)
        XCTAssertLessThan(cells.count, state.lyrics.lines.count,
                          "Only visible rows plus overscan may hold hosting views")
        XCTAssertLessThan(cells.count, 40)

        let bleed = NativeLyricsScrollView.horizontalBleed
        XCTAssertEqual(table.frame.minX, -bleed, accuracy: 0.5,
                       "The row surface must extend past the viewport for blur bleed")
        let viewportWidth = table.superview?.bounds.width ?? table.bounds.width
        XCTAssertEqual(table.bounds.width, viewportWidth + 2 * bleed, accuracy: 0.5)

        let overscan = NativeLyricsScrollView.viewportOverscan
        let visualHeight = table.bounds.height - 2 * overscan
        let visualTop = table.contentOffset.y + overscan
        let fade = LyricsViewportFade(
            height: visualHeight, referenceHeight: visualHeight - 120,
            shownReferenceHeight: visualHeight - 120, topOverlayHeight: 0,
            isInterfaceHidden: false
        )
        for cell in table.visibleCells {
            XCTAssertFalse(cell.clipsToBounds)
            XCTAssertFalse(cell.contentView.clipsToBounds)
            XCTAssertEqual(cell.bounds.width, table.bounds.width, accuracy: 0.5)
            let host = try XCTUnwrap(
                cell.subviews.first { $0 is any UIContentView }
                    ?? cell.subviews.first { $0 !== cell.contentView }
            )
            XCTAssertEqual(host.bounds.width, cell.bounds.width, accuracy: 0.5)
            let textHeight = cell.bounds.height - AppleMusicLyricsMotionProfile.iOS26_6.lineSpacing
            XCTAssertEqual(cell.frame.minY - visualTop + textHeight >= fade.topStart - bleed
                           && cell.frame.minY - visualTop <= fade.bottomEnd + bleed,
                           !host.isHidden,
                           "Unclipped rows must not draw outside the vertical viewport")
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
        let overscan = NativeLyricsScrollView.viewportOverscan
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
            XCTAssertEqual(top, initialTop, accuracy: 2,
                           "Active lyric position must stay consistent across hidden and shown states")
            XCTAssertGreaterThan(top, state.topOverlayHeight)
            XCTAssertLessThan(top + height, hidden ? 600 : 480)
            let bottom: CGFloat = hidden ? 600 : 480
            let edgeSettled = try await waitUntil {
                self.edgeMasks(in: scrollView.layer).contains { owner, mask in
                    let ownerFrame = scrollView.layer.convert(owner.bounds, from: owner)
                    let frame = scrollView.layer.convert(mask.frame, from: owner)
                    return ownerFrame.intersects(scrollView.bounds)
                        && abs(frame.minY - scrollView.bounds.minY - overscan - state.topOverlayHeight) < 2
                        && abs(frame.maxY - scrollView.bounds.minY - overscan - bottom) < 2
                }
            }
            XCTAssertTrue(edgeSettled, "Leaf masks must follow the header and playback boundary")
            XCTAssertFalse(scrollView.point(inside: CGPoint(x: 20, y: scrollView.bounds.minY + overscan + 60), with: nil))
            XCTAssertEqual(scrollView.point(inside: CGPoint(x: 20, y: scrollView.bounds.minY + overscan + 490), with: nil), hidden)
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

    func testDraggingInterruptsRunningRowSpringAndClearsTransforms() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )

        state.activeID = 41
        let started = try await waitUntil { state.renderedActiveID == 41 && table.isRowTransitionAnimating }
        XCTAssertTrue(started)

        table.delegate?.scrollViewWillBeginDragging?(table)

        XCTAssertTrue(table.isScrollEnabled, "Active lyrics table must keep native scrolling enabled")
        XCTAssertFalse(table.panGestureRecognizer.delegate?.gestureRecognizer?(table.panGestureRecognizer, shouldReceive: UITouch()) == false,
                       "Scroll view pan gesture must never be blocked by a custom gesture delegate")
        XCTAssertFalse(table.isRowTransitionAnimating,
                       "Starting a user drag must immediately stop active row spring animations")
        for cell in table.visibleCells {
            XCTAssertEqual(cell.transform, .identity,
                           "Visible rows must have identity transforms once handed over to user dragging")
        }
    }

    func testBrowseRevealControlsAndIdleResumeDoesNotHang() async throws {
        let state = LyricsFocusTestState()
        state.isInterfaceHidden = true
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )

        // 1. User drags lyrics (exits blur -> browsing = true)
        table.delegate?.scrollViewWillBeginDragging?(table)
        // 2. Scroll up to reveal bottom controls
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y - 140), animated: false)
        table.delegate?.scrollViewDidScroll?(table)
        state.isInterfaceHidden = false
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)

        // 3. Wait ~3s so resumeFollowing and idle interface hide collide
        try await Task.sleep(for: .milliseconds(2950))
        state.isInterfaceHidden = true
        try await Task.sleep(for: .milliseconds(600))
        try await assertFocus(40, in: state)
    }

    func testFullScreenPlayerBrowseRevealControlsAndIdleDoesNotHang() async throws {
        let playback = HangReproPlaybackSource()
        let player = PlayerState(source: playback)
        let lyrics = LyricsFocusTestState.makeLyrics(count: 80)
        let services = PlayerServices(
            actions: PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                                   addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in }),
            lyrics: PlayerLyricsSource(load: { _ in lyrics }),
            artwork: PlayerArtworkProvider(cached: { _ in nil }, load: { _ in throw URLError(.fileDoesNotExist) })
        )
        let host = UIHostingController(
            rootView: FullScreenPlayerView(player: player, services: services, initialPage: .lyrics)
                .environment(\.scenePhase, .active)
        )
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let foundTable = try await waitUntil {
            !self.scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.isEmpty
        }
        XCTAssertTrue(foundTable)
        let table = try XCTUnwrap(scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first)

        // Wait until lyrics load and settle, and controls auto-hide after 3s
        try await Task.sleep(for: .milliseconds(3400))

        // Drag lyrics to clear blur and scroll up to reveal bottom controls
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y - 160), animated: false)
        table.delegate?.scrollViewDidScroll?(table)
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)

        // Sit idle for 4 seconds while playback ticks every 200ms
        for _ in 0..<20 {
            playback.progress += 0.2
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(table.isScrollEnabled)
    }

    func testRapidConsecutiveForwardChangesKeepTheCommittedViewport() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )

        state.activeID = 41
        let firstApplied = try await waitUntil { state.renderedActiveID == 41 }
        XCTAssertTrue(firstApplied)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(table.isRowTransitionAnimating,
                      "The first line spring must still be running for this regression")

        state.activeID = 42
        let secondApplied = try await waitUntil { state.renderedActiveID == 42 }
        XCTAssertTrue(secondApplied)
        let committedOffset = table.contentOffset.y

        let visualHeight = table.bounds.height - 2 * NativeLyricsScrollView.viewportOverscan
        var minimumGap = CGFloat.greatestFiniteMagnitude
        for _ in 0..<25 {
            let tops = table.visibleLineIDs.compactMap { row -> (row: Int, top: CGFloat, height: CGFloat)? in
                guard let top = table.presentationViewportTop(forRow: row),
                      let height = table.cellForRow(at: IndexPath(row: row, section: 0))?.bounds.height,
                      top + height > 0, top < visualHeight else { return nil }
                return (row, top, height)
            }.sorted { $0.row < $1.row }
            for (upper, lower) in zip(tops, tops.dropFirst()) where lower.row == upper.row + 1 {
                minimumGap = min(minimumGap, lower.top - (upper.top + upper.height))
            }
            try await Task.sleep(for: .milliseconds(16))
        }

        try await assertFocus(42, in: state)
        XCTAssertEqual(committedOffset, table.contentOffset.y, accuracy: 2,
                       "A line change must commit its final offset immediately; the viewport must not shift again after the spring settles")
        XCTAssertGreaterThan(minimumGap, -4,
                             "Rows must not be drawn on top of each other during a rapid line change")
    }

    func testForwardCascadeKeepsBottomRowStartingOffsetsAndDistanceBlur() async throws {
        let state = LyricsFocusTestState()
        state.isInterfaceHidden = true
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        let visualHeight = table.bounds.height - 2 * NativeLyricsScrollView.viewportOverscan
        let bottomRow = try XCTUnwrap(table.visibleLineIDs.sorted().last { row in
            guard let top = table.presentationViewportTop(forRow: row) else { return false }
            return top > visualHeight - 160 && top < visualHeight
        })
        let beforeBottomTop = try XCTUnwrap(table.presentationViewportTop(forRow: bottomRow))
        let beforeNextNextBlur = try XCTUnwrap(table.rowDistanceBlurRadius(forRow: 42))
        XCTAssertGreaterThan(beforeNextNextBlur, 2.5)

        state.activeID = 41
        let started = try await waitUntil { state.renderedActiveID == 41 }
        XCTAssertTrue(started)

        var minNextNextBlur = Double.greatestFiniteMagnitude
        var minBottomGap = CGFloat.greatestFiniteMagnitude
        for step in 0..<12 {
            if let blur = table.rowDistanceBlurRadius(forRow: 42) {
                minNextNextBlur = min(minNextNextBlur, blur)
            }
            if let bottomTop = table.presentationViewportTop(forRow: bottomRow),
               let prevTop = table.presentationViewportTop(forRow: bottomRow - 1) {
                minBottomGap = min(minBottomGap, bottomTop - prevTop)
            }
            if step == 0, let startBottomTop = table.presentationViewportTop(forRow: bottomRow) {
                XCTAssertEqual(startBottomTop, beforeBottomTop, accuracy: 8,
                               "Bottom row must start its cascade from its pre-advance position")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThan(minNextNextBlur, 1.5,
                             "Row i+2 must not dip toward zero blur during forward cascade")
        XCTAssertGreaterThan(minBottomGap, 20,
                             "Bottom row must not overlap the row above it during cascade")
        try await assertFocus(41, in: state)

        // Single-line active target (row 43 -> 44, where 43 & 44 are 1 line): row 45 must stay blurred.
        state.activeID = 43
        try await assertFocus(43, in: state)
        state.activeID = 44
        let started44 = try await waitUntil { state.renderedActiveID == 44 }
        XCTAssertTrue(started44)
        var minSingleLineNextNextBlur = Double.greatestFiniteMagnitude
        for _ in 0..<15 {
            if let blur = table.rowDistanceBlurRadius(forRow: 45) {
                minSingleLineNextNextBlur = min(minSingleLineNextNextBlur, blur)
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThan(minSingleLineNextNextBlur, 1.9,
                             "Row i+2 after a single-line row must not drop toward zero blur during forward cascade")
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
            height: 793,
            referenceHeight: 476,
            shownReferenceHeight: 476,
            topOverlayHeight: 69.25,
            isInterfaceHidden: false
        )
        XCTAssertEqual(shown.topStart, 69.25, accuracy: 0.5)
        XCTAssertEqual(shown.topEnd - shown.topStart, LyricsViewportFade.topFadeHeight, accuracy: 0.5)
        XCTAssertEqual(shown.bottomEnd, 476, accuracy: 0.5)
        XCTAssertEqual(shown.bottomEnd - shown.bottomStart, 160, accuracy: 0.5)

        let midpoint = LyricsViewportFade(
            height: 793,
            referenceHeight: 634.5,
            shownReferenceHeight: 476,
            topOverlayHeight: 69.25,
            isInterfaceHidden: false
        )
        XCTAssertEqual(midpoint.bottomEnd - midpoint.bottomStart, 167.5, accuracy: 0.5)

        let hidden = LyricsViewportFade(
            height: 793,
            referenceHeight: 793,
            shownReferenceHeight: 476,
            topOverlayHeight: 69.25,
            isInterfaceHidden: true
        )
        XCTAssertEqual(hidden.bottomEnd, 793, accuracy: 0.5)
        XCTAssertEqual(hidden.bottomEnd - hidden.bottomStart, 175, accuracy: 0.5)
    }

    func testPagePresentationMaskClipsImmediatelyDuringPageSwitches() async throws {
        let state = PresentationMaskTestState()
        let layout = ReferenceNowPlayingLayout()
        let clipHeight = layout.pageY(557)
        let host = UIHostingController(rootView: PresentationMaskTestContent(state: state, layout: layout))
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let settledUnclipped = try await waitUntil {
            !self.clippedPresentationHeights(in: host.view.layer).contains { $0 <= clipHeight + 1 }
        }
        XCTAssertTrue(settledUnclipped, "Settled lyrics page must not stay hard-clipped above controls")

        let spring = Animation.interpolatingSpring(mass: 1, stiffness: 475, damping: 45, initialVelocity: 0)
        withAnimation(spring) {
            state.isVisible = false
            state.clipsAboveControls = true
        }

        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
            let heights = clippedPresentationHeights(in: host.view.layer)
            XCTAssertFalse(heights.isEmpty, "Dismissing lyrics must keep the outer clip mask active")
            for height in heights {
                XCTAssertLessThanOrEqual(
                    height,
                    clipHeight + 1,
                    "Dismissing lyrics must clip above controls immediately without animating the mask down"
                )
            }
        }

        withAnimation(spring) {
            state.isVisible = true
            state.clipsAboveControls = true
        }

        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
            let heights = clippedPresentationHeights(in: host.view.layer)
            XCTAssertFalse(heights.isEmpty, "Entering lyrics must keep the outer clip mask active until settled")
            for height in heights {
                XCTAssertLessThanOrEqual(
                    height,
                    clipHeight + 1,
                    "Entering lyrics must stay clipped above controls while translating from below"
                )
            }
        }
    }

    private func clippedPresentationHeights(in layer: CALayer) -> [CGFloat] {
        var heights: [CGFloat] = []
        if layer.masksToBounds, layer.bounds.width >= 350 {
            heights.append((layer.presentation() ?? layer).bounds.height)
        }
        for child in layer.sublayers ?? [] {
            heights += clippedPresentationHeights(in: child)
        }
        return heights
    }

    func testFarSeekHandsOffVisibleSourceRowsAndReleasesSnapshots() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        XCTAssertEqual(table.sourceSnapshotCount, 0)
        let sourceVisible = table.visibleCells.count
        let handoffsBefore = table.sourceSnapshotHandoffCount

        state.activeID = 62
        let handedOff = try await waitUntil { table.sourceSnapshotHandoffCount > handoffsBefore }
        XCTAssertTrue(handedOff, "A far seek must hand off the leaving source rows")
        XCTAssertLessThanOrEqual(table.sourceSnapshotHandoffCount - handoffsBefore, sourceVisible,
                                 "Snapshots must stay bounded by the visible source rows")
        XCTAssertLessThanOrEqual(table.sourceSnapshotCount, sourceVisible)

        try await assertFocus(62, in: state)
        let released = try await waitUntil { table.sourceSnapshotCount == 0 }
        XCTAssertTrue(released, "Source snapshots must be released after the spring")
        XCTAssertLessThan(table.visibleCells.count, 40)
    }

    func testSeekWhileInterfaceHiddenAnimatesBoundaryInsteadOfSnapping() async throws {
        let state = LyricsFocusTestState()
        state.isInterfaceHidden = true
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        let hiddenHeight = table.bounds.height - 2 * NativeLyricsScrollView.viewportOverscan
        XCTAssertEqual(table.interfaceFadeHeight, hiddenHeight, accuracy: 2)

        table.performSeek(row: 62)

        XCTAssertFalse(state.isInterfaceHidden, "Tapping a lyric must reveal the controls")
        XCTAssertTrue(table.isInterfaceFadeAnimating,
                      "The visible boundary must animate with the seek instead of jumping immediately")
        XCTAssertTrue(table.isRowTransitionAnimating,
                      "The lyric rows themselves must use their UIKit transition, not jump to the destination")
        XCTAssertGreaterThan(table.sourceSnapshotCount, 0,
                             "A far seek from the hidden state must hand off the leaving source rows")
        let rowStillAnimating = try await waitUntil { !table.isRowTransitionAnimating }
        XCTAssertTrue(rowStillAnimating)
        let settled = try await waitUntil { !table.isInterfaceFadeAnimating }
        XCTAssertTrue(settled)
        XCTAssertEqual(table.interfaceFadeHeight, hiddenHeight - 120, accuracy: 2,
                       "The settled boundary must account for the revealed controls")
        try await assertFocus(62, in: state)
    }

    func testFirstSeekWhileInterfaceHiddenLandsAtExpectedTopWithoutInterruptingSpring() async throws {
        let state = LyricsFocusTestState()
        state.isInterfaceHidden = true
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        let targetRow = 62
        let startingOffset = table.contentOffset.y

        table.performSeek(row: targetRow)
        let lockedTargetOffset = table.contentOffset.y
        XCTAssertNotEqual(lockedTargetOffset, startingOffset, accuracy: 10)

        // Allow SwiftUI to propagate isInterfaceHidden = false and player.seek -> activeID = 62.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.contentOffset.y, lockedTargetOffset, accuracy: 1,
                       "Interface reveal during a seek must not re-run alignment or jump the target offset")

        let rowSettled = try await waitUntil { !table.isRowTransitionAnimating }
        XCTAssertTrue(rowSettled)
        XCTAssertEqual(table.contentOffset.y, lockedTargetOffset, accuracy: 2,
                       "First seek must converge to the exact destination before animating instead of snapping after settling")
        try await assertFocus(targetRow, in: state)
    }

    func testSeekFromBrowsedViewportStartsAtVisibleScrollPosition() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )

        // Move the viewport away from the playing line, as a user does while browsing.
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.scrollToRow(at: IndexPath(row: 68, section: 0), at: .top, animated: false)
        table.layoutIfNeeded()
        state.isInterfaceHidden = true
        try await Task.sleep(for: .milliseconds(150))
        let visualHeight = table.bounds.height - 2 * NativeLyricsScrollView.viewportOverscan
        let tapped = try XCTUnwrap(table.visibleLineIDs.compactMap { row -> (Int, CGFloat)? in
            guard let origin = table.transitionViewportTop(forRow: row),
                  origin >= 0, origin < visualHeight else { return nil }
            return (row, origin)
        }.first)
        let tappedRow = tapped.0
        let origin = tapped.1

        table.performSeek(row: tappedRow)

        XCTAssertTrue(table.isRowTransitionAnimating)
        let start = try XCTUnwrap(table.pendingTransitionViewportTop(forRow: tappedRow))
        XCTAssertEqual(start, origin, accuracy: 2,
                       "A tap must start from the current browsed viewport, not from the playing line")
        try await assertFocus(tappedRow, in: state)
    }

    func testSeekAfterBrowsingWithControlsAlreadyRevealedRestoresBlurImmediately() async throws {
        var interactionEvents: [Bool] = []
        let state = LyricsFocusTestState()
        state.isInterfaceHidden = true
        state.onUserInteractionChange = { interactionEvents.append($0) }
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )

        table.delegate?.scrollViewWillBeginDragging?(table)
        table.scrollToRow(at: IndexPath(row: 68, section: 0), at: .top, animated: false)
        table.layoutIfNeeded()
        XCTAssertEqual(table.isRowBrowsingAppearanceActive(forRow: 69), true)
        XCTAssertEqual(interactionEvents, [true])

        // Deceleration keeps interaction active until scrollViewDidEndDecelerating.
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)
        XCTAssertEqual(interactionEvents, [true])

        // Scrolling back up reveals controls before tapping a lyric to exit browsing.
        state.isInterfaceHidden = false
        try await Task.sleep(for: .milliseconds(150))
        let tappedRow = try XCTUnwrap(table.visibleLineIDs.first { row in
            guard let top = table.transitionViewportTop(forRow: row) else { return false }
            return top >= 100 && top < 350
        })

        table.performSeek(row: tappedRow)
        state.activeID = tappedRow

        XCTAssertEqual(interactionEvents, [true, false],
                       "Exiting browsing via seek during deceleration must balance interaction end")
        XCTAssertEqual(table.isRowBrowsingAppearanceActive(forRow: tappedRow + 1), false,
                       "Seek must clear row browsing state before updating appearances even when controls are already visible")
        XCTAssertGreaterThan(try XCTUnwrap(table.rowDistanceBlurRadius(forRow: tappedRow + 1)), 1.5,
                             "Non-active rows must restore distance blur immediately after exiting free browsing")
        try await assertFocus(tappedRow, in: state)
    }

    func testFastTrackReplacementRemovesSourceSnapshots() async throws {
        let state = LyricsFocusTestState()
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        let handoffsBefore = table.sourceSnapshotHandoffCount
        state.activeID = 62
        let handedOff = try await waitUntil { table.sourceSnapshotHandoffCount > handoffsBefore }
        XCTAssertTrue(handedOff)
        XCTAssertGreaterThan(table.sourceSnapshotCount, 0)

        state.lyrics = LyricsFocusTestState.makeLyrics(count: 80, idOffset: 10_000)
        state.activeID = 10_040
        let replaced = try await waitUntil {
            state.renderedActiveID == 10_040 && table.renderedLineCount == 80
        }
        XCTAssertTrue(replaced)
        XCTAssertEqual(table.sourceSnapshotCount, 0,
                       "Track replacement must drop the old source snapshots")
        try await assertFocus(10_040, in: state)
        XCTAssertTrue(table.visibleLineIDs.allSatisfy { $0 >= 10_000 },
                      "Old lyric snapshots must not cover the new lyrics")
        XCTAssertEqual(table.sourceSnapshotCount, 0)
    }

    func testReduceMotionDoesNotHandOffSourceSnapshots() async throws {
        let state = LyricsFocusTestState()
        state.reducesMotion = true
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(40, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        let handoffsBefore = table.sourceSnapshotHandoffCount
        state.activeID = 79
        try await assertFocus(79, in: state)
        XCTAssertEqual(table.sourceSnapshotHandoffCount, handoffsBefore)
        XCTAssertEqual(table.sourceSnapshotCount, 0)
    }

    func testThousandLineLyricsKeepRowMaterializationBounded() async throws {
        let state = LyricsFocusTestState(lineCount: 1200, activeID: 600)
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(600, in: state)
        let table = try XCTUnwrap(
            scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first
        )
        XCTAssertEqual(table.renderedLineCount, 1200)
        XCTAssertTrue(table.visibleLineIDs.contains(600))
        assertBoundedRows(table, total: 1200)

        // Basic user scrolling: a bounded window follows the offset while browsing.
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y + 1800), animated: false)
        table.layoutIfNeeded()
        XCTAssertGreaterThan(table.contentOffset.y, -table.contentInset.top)
        assertBoundedRows(table, total: 1200)
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)

        // Tap-to-seek uses the same owner path and re-focuses without a full row set.
        let visibleIDs = table.visibleLineIDs.sorted()
        guard !visibleIDs.isEmpty else {
            XCTFail("Scrolling must keep a bounded row window visible")
            return
        }
        let target = visibleIDs[visibleIDs.count / 2]
        let seeks = state.seekCount
        table.performSeek(row: target)
        XCTAssertEqual(state.seekCount, seeks + 1)
        try await assertFocus(target, in: state)
        let released = try await waitUntil { table.sourceSnapshotCount == 0 }
        XCTAssertTrue(released)
        assertBoundedRows(table, total: 1200)

        // Rapid song replacement must not leave any row from the previous lyrics.
        for (index, offset) in [10_000, 20_000, 30_000].enumerated() {
            state.lyrics = LyricsFocusTestState.makeLyrics(count: 1200, idOffset: offset)
            state.activeID = offset + 600 + index
        }
        let replaced = try await waitUntil {
            state.renderedActiveID == 30_602 && table.renderedLineCount == 1200
        }
        XCTAssertTrue(replaced)
        try await assertFocus(30_602, in: state)
        XCTAssertTrue(table.visibleLineIDs.allSatisfy { $0 >= 30_000 },
                      "Visible rows must never contain the previous song's lyrics")
        XCTAssertEqual(Set(table.visibleLineIDs).count, table.visibleCells.count,
                       "Each visible cell must carry exactly one current lyric line")
        XCTAssertEqual(table.sourceSnapshotCount, 0)
        assertBoundedRows(table, total: 1200)
    }

    private func assertBoundedRows(_ table: NativeLyricsScrollView, total: Int) {
        XCTAssertLessThan(table.visibleCells.count, 40,
                          "Only visible rows plus overscan may be materialized")
        XCTAssertLessThan(table.visibleCells.count, total / 10,
                          "Materialized rows must not scale with the lyric count")
        let residentCells = table.subviews.filter { $0 is UITableViewCell }
        XCTAssertGreaterThanOrEqual(residentCells.count, table.visibleCells.count)
        XCTAssertLessThan(residentCells.count, 40,
                          "No detached cell rows may stay resident")
    }

    func testTranslationRevealGrowsTheRowAndKeepsTheFocusedLine() async throws {
        let state = LyricsFocusTestState(lineCount: 6, activeID: 2)
        state.lyrics = PlayerLyrics(lines: (0..<6).map { index in
            PlayerLyricLine(id: index, time: Double(index), text: "Line \(index)",
                             translation: index == 1 || index == 2 ? "译文\(index)" : "")
        }, plainText: "", source: "test")
        let window = try await mount(state, size: .large)
        defer { window.isHidden = true }
        try await assertFocus(2, in: state)
        let table = try XCTUnwrap(scrollViews(in: window).compactMap { $0 as? NativeLyricsScrollView }.first)
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 2, section: 0)))
        let beforeHeight = cell.bounds.height
        let beforeTop = cell.convert(cell.bounds, to: window).minY

        state.showsTranslation = true
        let grew = try await waitUntil {
            guard let row = table.cellForRow(at: IndexPath(row: 2, section: 0)) else { return false }
            return row.bounds.height > beforeHeight + 12
        }
        XCTAssertTrue(grew)
        let shown = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 2, section: 0)))
        XCTAssertEqual(shown.convert(shown.bounds, to: window).minY, beforeTop, accuracy: 8)
        XCTAssertTrue(accessibilityLabels(in: shown).contains { $0.contains("译文2") })

        state.showsTranslation = false
        let shrank = try await waitUntil {
            guard let row = table.cellForRow(at: IndexPath(row: 2, section: 0)) else { return false }
            return row.bounds.height < beforeHeight + 4
        }
        XCTAssertTrue(shrank)
        XCTAssertFalse(accessibilityLabels(in: table).contains { $0.contains("译文2") })
    }

    private func accessibilityLabels(in view: UIView) -> [String] {
        var labels: [String] = []
        if let label = view.accessibilityLabel, !label.isEmpty { labels.append(label) }
        for element in view.accessibilityElements ?? [] {
            guard let object = element as? NSObject, let label = object.accessibilityLabel, !label.isEmpty else { continue }
            labels.append(label)
        }
        for subview in view.subviews { labels.append(contentsOf: accessibilityLabels(in: subview)) }
        return labels
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
        if let table = scrollViews(in: host.view).compactMap({ $0 as? NativeLyricsScrollView }).first {
            state.focusLineHeight = table.focusLineHeight
        }
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
    var activeID: Int
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
    var focusLineHeight: CGFloat = 0
    var reducesMotion = false
    var showsTranslation = false
    var onUserInteractionChange: ((Bool) -> Void)? = nil
    var lyrics: PlayerLyrics

    init(lineCount: Int = 80, activeID: Int = 40, idOffset: Int = 0) {
        self.activeID = activeID
        self.lyrics = Self.makeLyrics(count: lineCount, idOffset: idOffset)
    }

    static func makeLyrics(count: Int, idOffset: Int = 0) -> PlayerLyrics {
        let lines = (0..<count).map { index in
            let text: String
            switch index % 4 {
            case 0: text = "\(idOffset + index + 1)"
            case 1: text = "旋律\n回声"
            case 2: text = "沿着熟悉的街道继续向前，看远处的光渐渐亮起"
            default: text = "尾声"
            }
            return PlayerLyricLine(id: idOffset + index, time: Double(index * 4), text: text)
        }
        return PlayerLyrics(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "test")
    }

    func expectedTop(forRowHeight height: CGFloat) -> CGFloat {
        let effectiveHeight = max(viewportHeight - topOverlayHeight, 1)
        let visibleHeight = (viewportHeight - 120) - topOverlayHeight
        let leadingLineHeight = focusLineHeight > 0
            ? focusLineHeight : (geometry.height(for: 40) ?? height)
        let preferredOffset = effectiveHeight * (AppleMusicLyricsMotionProfile.iOS26_6.selectedLineTopRelativePercent / 100)
            - leadingLineHeight / 2
        return topOverlayHeight + min(max(preferredOffset, visibleHeight * 0.08),
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
            topOverlayHeight: state.topOverlayHeight, showsTranslation: state.showsTranslation,
            onUserInteractionChange: state.onUserInteractionChange,
            rowGeometry: state.geometry
        )
        .environment(\._accessibilityReduceMotion, state.reducesMotion)
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

@MainActor @Observable
private final class PresentationMaskTestState {
    var isVisible = true
    var clipsAboveControls = false
    let lyricsState = LyricsFocusTestState()
}

private struct PresentationMaskTestContent: View {
    @Bindable var state: PresentationMaskTestState
    let layout: ReferenceNowPlayingLayout

    var body: some View {
        AppleMusicLocalLyricsView(
            lyrics: state.lyricsState.lyrics,
            activeID: 40,
            bottomOverlayHeight: 280,
            isActive: state.isVisible,
            isInterfaceHidden: .constant(false),
            onSeek: { _ in },
            topOverlayHeight: 102
        )
        .frame(width: 402, height: 753)
        .modifier(
            NowPlayingPagePresentation(
                isVisible: state.isVisible,
                page: .lyrics,
                clipsAboveControls: state.clipsAboveControls
            )
        )
        .environment(\.nowPlayingLayout, layout)
    }
}

@MainActor @Observable
private final class HangReproPlaybackSource: PlayerPlaybackSource {
    let tracks: [PlayerTrack] = [
        PlayerTrack(id: "repro", title: "Test Song", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 320)
    ]
    var currentTrack: PlayerTrack? { tracks.first }
    let currentQueueIndex = 0
    var isPlaying = true
    let isLoading = false
    let issue: String? = nil
    let duration: Double = 320
    var progress: Double = 160
    let isCrossfadeEnabled = false
    let isShuffled = false
    let repeatMode: PlayerRepeatMode = .off
    let canPlayNext = false
    let canPlayPrevious = false
    let canAutomaticallyContinue = false
    let isAutomaticContinuationEnabled = false
    let automaticContinuationDescription = ""
    let previousInOrder: PlayerAdjacentTrack? = nil
    let nextInOrder: PlayerAdjacentTrack? = nil
    let upcoming: [PlayerAdjacentTrack] = []
    let upcomingQueueVersion = PlayerQueueVersion(revision: 1, index: 0, repeatMode: .off)
    let upcomingQueueEntries: [PlayerQueueEntry] = []
    func togglePlayback() { isPlaying.toggle() }
    func seek(to value: Double) { progress = value }
    func next() {}
    func previous() {}
    func skip(toQueueIndex index: Int) {}
    func playFromQueue(at index: Int) {}
    func enqueue(_ track: PlayerTrack, next: Bool) {}
    func toggleShuffle() {}
    func cycleRepeatMode() {}
    func toggleCrossfade() {}
    func toggleAutomaticContinuation() {}
    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {}
    func removeFromQueue(at index: Int) {}
}
