// Adapted from MeloX AppleMusicLyricsView (GPL-3.0), commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a. Typography and timing follow
// the supplied Music references; UIKit owns scrolling and row animations.
import SwiftUI
import UIKit

struct AppleMusicLocalLyricsView: View {
    let lyrics: PlayerLyrics
    let activeID: Int?
    let bottomOverlayHeight: CGFloat
    let topOverlayHeight: CGFloat
    let isActive: Bool
    @Binding var isInterfaceHidden: Bool
    let onSeek: (Double) -> Void
    var fixedFontSize: CGFloat? = nil
    var foreground: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric private var scaledFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.primaryFontSize
    @State private var rowGeometry: LyricsRowGeometry

    init(lyrics: PlayerLyrics, activeID: Int?, bottomOverlayHeight: CGFloat,
         isActive: Bool, isInterfaceHidden: Binding<Bool>, onSeek: @escaping (Double) -> Void,
         topOverlayHeight: CGFloat = 0, fixedFontSize: CGFloat? = nil,
         foreground: Color = .white, rowGeometry: LyricsRowGeometry = LyricsRowGeometry()) {
        self.lyrics = lyrics
        self.activeID = activeID
        self.bottomOverlayHeight = bottomOverlayHeight
        self.topOverlayHeight = topOverlayHeight
        self.isActive = isActive
        _isInterfaceHidden = isInterfaceHidden
        self.onSeek = onSeek
        self.fixedFontSize = fixedFontSize
        self.foreground = foreground
        _rowGeometry = State(initialValue: rowGeometry)
    }

    var body: some View {
        NativeLyricsScrollContent(
            lyrics: lyrics, activeID: activeID, bottomOverlayHeight: bottomOverlayHeight,
            topOverlayHeight: topOverlayHeight, isActive: isActive,
            isInterfaceHidden: $isInterfaceHidden, onSeek: onSeek,
            fontSize: fixedFontSize ?? scaledFontSize, foreground: foreground,
            reducesMotion: reducesMotion, increasedContrast: contrast == .increased,
            rowGeometry: rowGeometry
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativeLyricsScrollContent: UIViewRepresentable {
    let lyrics: PlayerLyrics
    let activeID: Int?
    let bottomOverlayHeight: CGFloat
    let topOverlayHeight: CGFloat
    let isActive: Bool
    @Binding var isInterfaceHidden: Bool
    let onSeek: (Double) -> Void
    let fontSize: CGFloat
    let foreground: Color
    let reducesMotion: Bool
    let increasedContrast: Bool
    let rowGeometry: LyricsRowGeometry

    func makeUIView(context: Context) -> NativeLyricsScrollView { NativeLyricsScrollView() }
    func updateUIView(_ view: NativeLyricsScrollView, context: Context) { view.update(self) }
    static func dismantleUIView(_ view: NativeLyricsScrollView, coordinator: ()) { view.stop() }
}

/// A single scroll owner commits the destination and every row's starting position
/// together. Independent UIKit springs then reveal the stagger without another scroll animation.
@objc(NeoMusicLyricsScrollView)
private final class NativeLyricsScrollView: UIScrollView, UIScrollViewDelegate {
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private var input: NativeLyricsScrollContent?
    private var rows: [NativeLyricRowView] = []
    private var renderedLines: [PlayerLyricLine] = []
    private var renderedFontSize: CGFloat = 0
    private var renderedForeground = Color.white
    private var lastSize = CGSize.zero
    private var focusedIndex: Int?
    private var needsFocus = true
    private var wasActive = false
    private var positioning = false
    private var refreshing = false
    fileprivate var isRefreshing: Bool { refreshing }
    private var browsing = false
    private var resumeTask: Task<Void, Never>?
    private var visibility = LyricsScrollInterfaceVisibilityTracker()
    private var previousOffset: CGFloat = 0
    private var animators: [UUID: UIViewPropertyAnimator] = [:]
    private var displayLink: CADisplayLink?
    private let fadeGuide = UIView()
    private var fadeAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        clipsToBounds = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        fadeGuide.isUserInteractionEnabled = false
        fadeGuide.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(fadeGuide)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ value: NativeLyricsScrollContent) {
        let previous = input
        let replaced = renderedLines != value.lyrics.lines
            || renderedFontSize != value.fontSize || renderedForeground != value.foreground
        let interfaceChanged = previous?.isInterfaceHidden != value.isInterfaceHidden
        let geometryChanged = previous?.topOverlayHeight != value.topOverlayHeight
            || previous?.bottomOverlayHeight != value.bottomOverlayHeight
        input = value
        isScrollEnabled = value.isActive
        isUserInteractionEnabled = value.isActive
        if !value.isActive {
            if wasActive { stop() }
            wasActive = false
            return
        }
        if replaced {
            stop()
            for row in rows { row.removeFromSuperview() }
            rows = value.lyrics.lines.enumerated().map { index, line in
                let row = NativeLyricRowView(line: line, fontSize: value.fontSize, foreground: value.foreground)
                row.onTap = { [weak self] in self?.seek(index) }
                addSubview(row)
                return row
            }
            renderedLines = value.lyrics.lines
            renderedFontSize = value.fontSize
            renderedForeground = value.foreground
            lastSize = .zero
            focusedIndex = nil
            needsFocus = true
        }
        if value.reducesMotion && previous?.reducesMotion != true { needsFocus = true }
        if !wasActive || replaced { suppressedPreSeekActiveID = nil }
        if !wasActive {
            browsing = false
            needsFocus = true
        }
        let next = activeRowIndex(for: value.activeID, updatingSuppression: true)
        let changed = next != focusedIndex
        let canAnimate = wasActive && !replaced && !value.reducesMotion && lastSize == bounds.size
        let cascades = canAnimate && !needsFocus && !browsing
            && !interfaceChanged && !geometryChanged
            && motion.isForwardLineChange(from: focusedIndex, to: next)
        if bounds.width > 0, bounds.height > 0 {
            layoutRowsIfNeeded()
            updateAppearances(activeIndex: next, animated: changed && wasActive && !value.reducesMotion)
            if interfaceChanged || geometryChanged || replaced || needsFocus {
                updateFade(animated: interfaceChanged && wasActive && !value.reducesMotion)
            }
            if !browsing && (changed || needsFocus || interfaceChanged || geometryChanged) {
                let animates = canAnimate && (focusedIndex != nil || interfaceChanged || geometryChanged)
                let spring: LyricPhysicalSpringParameters = if cascades || geometryChanged {
                    motion.lineChangeSpring
                } else if interfaceChanged && !changed {
                    Self.interfaceSyncSpring
                } else {
                    motion.forcedLineCatchUpSpring
                }
                // Avoid restarting an in-flight tap/seek catch-up animation when only the
                // interface visibility changed and the target scroll offset stays the same.
                let keepsRunningAnimation = !changed && !needsFocus && !animators.isEmpty
                    && next.map { abs(targetOffset(for: $0, activeID: rows[$0].line.id) - contentOffset.y) < 0.5 } == true
                if !keepsRunningAnimation {
                    align(to: next, cascade: cascades, animated: animates, spring: spring)
                }
            }
        }
        wasActive = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let input, input.isActive, !positioning else { return }
        if lastSize != bounds.size {
            freezeRows()
            layoutRowsIfNeeded()
            let activeIndex = activeRowIndex(for: input.activeID, updatingSuppression: false)
            updateAppearances(activeIndex: activeIndex, animated: false)
            updateFade(animated: false)
            if !browsing { align(to: activeIndex, cascade: false) }
        } else if needsFocus && !browsing {
            align(to: activeRowIndex(for: input.activeID, updatingSuppression: false), cascade: false)
        }
        refreshVisualGeometry()
    }

    private var suppressedPreSeekActiveID: Int?
    private var pendingStartTransforms: [ObjectIdentifier: CGAffineTransform] = [:]
    private var fadePendingStartHeight: CGFloat?
    private var pendingTransformCommitObserver: CFRunLoopObserver?

    /// Ignore stale pre-tap active line updates emitted while parent SwiftUI state catches up to a seek.
    private func activeRowIndex(for activeID: Int?, updatingSuppression: Bool) -> Int? {
        if let suppressed = suppressedPreSeekActiveID {
            if activeID != suppressed {
                if updatingSuppression { suppressedPreSeekActiveID = nil }
                return rows.firstIndex { $0.line.id == activeID }
            }
            return focusedIndex ?? rows.firstIndex { $0.line.id == activeID }
        }
        return rows.firstIndex { $0.line.id == activeID }
    }

    private func targetOffset(for index: Int, activeID: Int? = nil, interfaceHidden: Bool? = nil) -> CGFloat {
        let topInset = max(focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden), motion.firstLineStartOffset)
        return max(-topInset, min(rows[index].center.y - rows[index].bounds.height / 2
                                  - focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden),
                                  max(contentSize.height - bounds.height, 0)))
    }

    private var focusTop: CGFloat {
        focusTop(forActiveID: input?.activeID)
    }

    private func focusTop(forActiveID activeID: Int?, interfaceHidden: Bool? = nil) -> CGFloat {
        guard let input else { return 0 }
        let hidden = interfaceHidden ?? input.isInterfaceHidden
        let bottom = hidden ? bounds.height : max(bounds.height - input.bottomOverlayHeight, 1)
        let visible = max(bottom - input.topOverlayHeight, 1)
        let lineHeight = LyricsFontMetrics.boldLineHeight(size: input.fontSize)
        let height = rows.first(where: { $0.line.id == activeID })?.bounds.height ?? lineHeight
        return input.topOverlayHeight + min(max(visible * 0.233 - lineHeight / 2, visible * 0.08),
                                            max(visible * 0.08, visible * 0.84 - height))
    }

    private func layoutRowsIfNeeded() {
        guard input != nil, lastSize != bounds.size else { return }
        positioning = true
        defer { positioning = false }
        lastSize = bounds.size
        var y: CGFloat = 0
        for row in rows {
            let height = row.height(forWidth: bounds.width)
            row.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: max(height, 1))
            row.center = CGPoint(x: bounds.width / 2, y: y + row.bounds.height / 2)
            row.layoutIfNeeded()
            y += row.bounds.height + motion.lineSpacing
        }
        contentSize = CGSize(width: bounds.width, height: y + bounds.height)
        needsFocus = true
    }

    private func updateAppearances(activeIndex: Int?, animated: Bool) {
        guard let input else { return }
        for (index, row) in rows.enumerated() {
            let appearance = row.appearance
            if appearance.animated != animated { appearance.animated = animated }
            let focused = index == activeIndex
            if appearance.focused != focused { appearance.focused = focused }
            if appearance.browsing != browsing { appearance.browsing = browsing }
            if appearance.reducesMotion != input.reducesMotion { appearance.reducesMotion = input.reducesMotion }
            if appearance.increasedContrast != input.increasedContrast { appearance.increasedContrast = input.increasedContrast }
        }
    }

    private func align(to index: Int?, cascade: Bool, animated: Bool = false,
                       spring: LyricPhysicalSpringParameters? = nil, interfaceHidden: Bool? = nil) {
        guard let index, rows.indices.contains(index), let input else { return }
        freezeRows()
        let activeID = rows[index].line.id
        let oldOffset = contentOffset.y
        let topInset = max(focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden), motion.firstLineStartOffset)
        let target = targetOffset(for: index, activeID: activeID, interfaceHidden: interfaceHidden)
        let delta = target - oldOffset
        let animates = (cascade || animated)
            && (cascade || abs(delta) >= 0.5 || rows.contains { $0.transform != .identity })
        positioning = true
        UIView.performWithoutAnimation {
            contentInset.top = topInset
            setContentOffset(CGPoint(x: 0, y: target), animated: false)
            for row in rows {
                row.transform = animates ? row.transform.translatedBy(x: 0, y: delta) : .identity
            }
        }
        positioning = false
        focusedIndex = index
        needsFocus = false
        input.rowGeometry.focus(on: activeID)
        if animates {
            let timingSpring = spring ?? motion.lineChangeSpring
            for (rowIndex, row) in rows.enumerated() {
                let destination = row.center.y - row.bounds.height / 2 - target
                let current = destination + row.transform.ty
                guard max(current, destination) + row.bounds.height > 0,
                      min(current, destination) < bounds.height else {
                    row.transform = .identity
                    continue
                }
                pendingStartTransforms[ObjectIdentifier(row)] = row.transform
                let animator = UIViewPropertyAnimator(duration: motion.lineChangeDuration, timingParameters:
                    UISpringTimingParameters(mass: timingSpring.mass, stiffness: timingSpring.stiffness,
                                             damping: timingSpring.damping, initialVelocity: .zero))
                let id = UUID()
                animators[id] = animator
                row.isMoving = true
                animator.addAnimations { row.transform = .identity }
                animator.addCompletion { [weak self, weak row] _ in
                    row?.isMoving = false
                    self?.animators.removeValue(forKey: id)
                    self?.refreshVisualGeometry()
                    self?.stopDisplayLinkIfIdle()
                }
                animator.startAnimation(afterDelay: cascade ? motion.lineChangeDelay(rowIndex: rowIndex, activeIndex: index) : 0)
            }
            schedulePendingTransformClear()
            startDisplayLink()
        }
        updateVisualGeometry(presentation: animates)
    }

    private func freezeRows() {
        let preCommit = pendingStartTransforms
        pendingStartTransforms.removeAll()
        schedulePendingTransformClear()
        guard !animators.isEmpty else { return }
        let transforms = rows.map {
            preCommit[ObjectIdentifier($0)]
                ?? $0.layer.presentation()?.affineTransform()
                ?? $0.transform
        }
        for animator in animators.values { animator.stopAnimation(true) }
        animators.removeAll()
        UIView.performWithoutAnimation {
            for (row, transform) in zip(rows, transforms) {
                row.isMoving = false
                row.transform = transform
            }
        }
    }

    /// Keep pre-commit transforms and fade bounds until Core Animation flushes the current transaction.
    private func schedulePendingTransformClear() {
        guard !pendingStartTransforms.isEmpty || fadePendingStartHeight != nil else {
            cancelPendingTransformCommitObserver()
            return
        }
        guard pendingTransformCommitObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { [weak self] _, _ in
            self?.pendingTransformCommitObserver = nil
            self?.pendingStartTransforms.removeAll()
            self?.fadePendingStartHeight = nil
        }
        pendingTransformCommitObserver = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func cancelPendingTransformCommitObserver() {
        guard let observer = pendingTransformCommitObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        pendingTransformCommitObserver = nil
    }

    private static let interfaceSyncSpring: LyricPhysicalSpringParameters = {
        let spring = Spring.smooth(duration: 0.36)
        return LyricPhysicalSpringParameters(
            mass: spring.mass,
            stiffness: spring.stiffness,
            damping: spring.damping
        )
    }()

    private func updateFade(animated: Bool) {
        guard let input else { return }
        let height = input.isInterfaceHidden ? bounds.height : max(bounds.height - input.bottomOverlayHeight, 1)
        let current = fadeBottom
        fadeAnimator?.stopAnimation(true)
        fadeGuide.bounds.size.height = current
        if animated, abs(current - height) >= 0.5 {
            fadePendingStartHeight = current
            let spring = Spring.smooth(duration: input.isInterfaceHidden ? 0.22 : 0.28)
            let timing = UISpringTimingParameters(
                mass: spring.mass,
                stiffness: spring.stiffness,
                damping: spring.damping,
                initialVelocity: .zero
            )
            let animator = UIViewPropertyAnimator(duration: spring.settlingDuration, timingParameters: timing)
            animator.addAnimations {
                self.fadeGuide.bounds.size.height = height
            }
            fadeAnimator = animator
            animator.addCompletion { [weak self] _ in
                self?.fadeAnimator = nil
                self?.fadePendingStartHeight = nil
                self?.refreshVisualGeometry()
                self?.stopDisplayLinkIfIdle()
            }
            animator.startAnimation()
            schedulePendingTransformClear()
            startDisplayLink()
        } else {
            fadeAnimator = nil
            fadePendingStartHeight = nil
            schedulePendingTransformClear()
            fadeGuide.bounds.size.height = height
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshVisualGeometry))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    private func stopDisplayLinkIfIdle() {
        if animators.isEmpty && fadeAnimator == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc fileprivate func refreshVisualGeometry() {
        // The presentation tree can still contain pre-layout frames on first mount.
        // Only our running row animations need its interpolated coordinates.
        updateVisualGeometry(presentation: !animators.isEmpty)
    }

    private var fadeBottom: CGFloat {
        if let pending = fadePendingStartHeight {
            return pending
        }
        if fadeAnimator != nil, let presentation = fadeGuide.layer.presentation() {
            return presentation.bounds.height
        }
        return fadeGuide.bounds.height
    }

    private func visualMinY(for row: NativeLyricRowView, presentation: Bool) -> CGFloat {
        if presentation && row.isMoving {
            if let pending = pendingStartTransforms[ObjectIdentifier(row)] {
                return row.center.y - row.bounds.height / 2 + pending.ty
            }
            if let layerMinY = row.layer.presentation()?.frame.minY {
                return layerMinY
            }
        }
        return row.frame.minY
    }

    private func updateVisualGeometry(presentation: Bool) {
        guard let input, input.isActive, bounds.height > 0, !positioning, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let bottom = fadeBottom
        let shownBottom = max(bounds.height - input.bottomOverlayHeight, 1)
        let fade = LyricsViewportFade(
            height: bounds.height,
            referenceHeight: bottom,
            shownReferenceHeight: shownBottom,
            topOverlayHeight: input.topOverlayHeight,
            isInterfaceHidden: false
        )
        let focusedRow = focusedIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        let focusedTop = focusedRow.map { visualMinY(for: $0, presentation: presentation) }
            ?? (contentOffset.y + focusTop)
        let lineHeight = LyricsFontMetrics.boldLineHeight(size: input.fontSize)
        for row in rows {
            let top = visualMinY(for: row, presentation: presentation)
            let viewportTop = top - contentOffset.y
            let bleed = NativeLyricRowView.horizontalBleed
            let intersectsFade = viewportTop + row.bounds.height >= fade.topStart - bleed
                && viewportTop <= fade.bottomEnd + bleed
            // Horizontal overflow stays visible; offscreen rows remain hidden vertically.
            if row.content.isHidden == intersectsFade { row.content.isHidden = !intersectsFade }
            if intersectsFade {
                if !row.appearance.focused {
                    let radius = motion.blurRadius(
                        verticalDistance: Double(top - focusedTop), lineHeight: Double(lineHeight)
                    )
                    if row.appearance.distanceBlurRadius != radius { row.appearance.distanceBlurRadius = radius }
                }
                input.rowGeometry.record(.init(height: row.bounds.height, top: viewportTop), for: row.line.id)
                row.applyEdgeFade(fade, viewportTop: viewportTop, in: self, presentation: presentation)
            } else {
                input.rowGeometry.discardPosition(for: row.line.id)
            }
        }
    }

    private func seek(_ index: Int) {
        guard let input, input.isActive, rows.indices.contains(index) else { return }
        resumeTask?.cancel()
        browsing = false
        needsFocus = false
        input.isInterfaceHidden = false
        input.onSeek(rows[index].line.time)
        let animates = wasActive && !input.reducesMotion && lastSize == bounds.size
        if bounds.width > 0, bounds.height > 0 {
            let tappedID = rows[index].line.id
            suppressedPreSeekActiveID = (input.activeID != nil && input.activeID != tappedID) ? input.activeID : nil
            layoutRowsIfNeeded()
            updateAppearances(activeIndex: index, animated: animates)
            align(to: index, cascade: false, animated: animates, spring: motion.forcedLineCatchUpSpring,
                  interfaceHidden: false)
        } else {
            suppressedPreSeekActiveID = nil
            needsFocus = true
            setNeedsLayout()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        suppressedPreSeekActiveID = nil
        browsing = true
        resumeTask?.cancel()
        visibility.begin(isInterfaceVisible: !(input?.isInterfaceHidden ?? false))
        previousOffset = contentOffset.y
        updateAppearances(activeIndex: focusedIndex, animated: true)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !positioning else { return }
        if isDragging || isDecelerating {
            if let visible = visibility.update(offsetDelta: contentOffset.y - previousOffset, hideThreshold: 120) {
                input?.isInterfaceHidden = !visible
            }
            previousOffset = contentOffset.y
        }
        setNeedsLayout()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resumeFollowing() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { resumeFollowing() }
    private func resumeFollowing() {
        visibility.end()
        guard browsing else { return }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, let input = self.input, input.isActive, self.browsing else { return }
            self.suppressedPreSeekActiveID = nil
            self.browsing = false
            self.needsFocus = true
            self.update(input)
        }
    }
    func stop() {
        resumeTask?.cancel()
        fadePendingStartHeight = nil
        freezeRows()
        fadeAnimator?.stopAnimation(true)
        fadeAnimator = nil
        displayLink?.invalidate()
        displayLink = nil
        visibility.end()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let input else { return false }
        let bottom = fadeBottom
        return super.point(inside: point, with: event)
            && point.y >= bounds.minY + input.topOverlayHeight && point.y <= bounds.minY + bottom
    }
}

@Observable private final class LyricsRowAppearance {
    var focused = false
    var distanceBlurRadius: Double = 0
    var browsing = false
    var reducesMotion = false
    var increasedContrast = false
    // Read alongside focus/opacity changes; changing timing alone must not redraw every row.
    @ObservationIgnored var animated = false
    @ObservationIgnored var onTap: (() -> Void)?
}

private struct LocalLyricsRow: View {
    let line: PlayerLyricLine
    let fontSize: CGFloat
    let foreground: Color
    let appearance: LyricsRowAppearance
    let onTap: () -> Void
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6

    var body: some View {
        let radius = appearance.browsing || appearance.reducesMotion || appearance.increasedContrast
            ? 0 : appearance.distanceBlurRadius
        let opacity = appearance.focused ? 1 : (appearance.browsing ? NowPlayingVisualHierarchy.lyricBrowsingOpacity
            : (appearance.increasedContrast ? motion.increasedContrastDeselectedTextOpacity
                : NowPlayingVisualHierarchy.lyricInactiveBlurredOpacity))
        let animation: Animation? = appearance.animated && !appearance.reducesMotion ? .timingCurve(
            motion.focusBlurTransitionControlPoint1X, motion.focusBlurTransitionControlPoint1Y,
            motion.focusBlurTransitionControlPoint2X, motion.focusBlurTransitionControlPoint2Y,
            duration: motion.focusBlurTransitionDuration) : nil
        let backgroundHorizontalOutset = min(14, fontSize * 0.42)
        let backgroundVerticalOutset = min(14, fontSize * 0.42)
        let backgroundCornerRadius = min(16, fontSize * 0.47)
        LyricPressInteraction(isSelected: false, allowsLongPress: false, onTap: onTap, onLongPress: {}) { progress in
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: fontSize, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(foreground.opacity(opacity))
                .modifier(LyricsFocusBlur(radius: radius, amount: appearance.focused ? 0 : 1))
                .blendMode(foreground == .white && !appearance.focused ? .plusLighter : .normal)
                .background {
                    RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                        .fill(foreground.opacity(progress * 0.12))
                        .blendMode(foreground == .white ? .plusLighter : .normal)
                        .padding(.horizontal, -backgroundHorizontalOutset)
                        .padding(.vertical, -backgroundVerticalOutset)
                }
        }
        .scaleEffect(appearance.focused ? 1 : motion.deselectedScale, anchor: .topLeading)
        .animation(animation, value: appearance.focused)
        .animation(animation, value: opacity)
        .accessibilityAddTraits(appearance.focused ? .isSelected : [])
    }
}

/// Animate focus independently so per-frame distance updates retain the 120ms focus curve.
nonisolated private struct LyricsFocusBlur: ViewModifier, Animatable {
    let radius: Double
    var amount: Double

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content.blur(radius: radius * amount)
    }
}

private final class NativeLyricRowView: UIView {
    // Keep the blur halo inside the hosting surface even if an internal host clips.
    static let horizontalBleed: CGFloat = 24
    let line: PlayerLyricLine
    let appearance: LyricsRowAppearance
    let content: UIView
    var isMoving = false
    var onTap: (() -> Void)? {
        get { appearance.onTap }
        set { appearance.onTap = newValue }
    }

    init(line: PlayerLyricLine, fontSize: CGFloat, foreground: Color) {
        self.line = line
        let appearance = LyricsRowAppearance()
        self.appearance = appearance
        content = UIHostingConfiguration {
            LocalLyricsRow(line: line, fontSize: fontSize, foreground: foreground, appearance: appearance) {
                appearance.onTap?()
            }
            .padding(.horizontal, NativeLyricRowView.horizontalBleed)
        }.margins(.all, 0).minSize(width: 0, height: 0).makeContentView()
        super.init(frame: .zero)
        clipsToBounds = false
        content.clipsToBounds = false
        addSubview(content)
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat {
        content.systemLayoutSizeFitting(
            CGSize(width: width + 2 * Self.horizontalBleed, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds.insetBy(dx: -Self.horizontalBleed, dy: 0)
    }
    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        // UIKit coalesces row layout changes into the scroll view's next layout pass.
        // A row must not synchronously refresh every other row's geometry.
        if let scrollView = superview as? NativeLyricsScrollView, !scrollView.isRefreshing {
            scrollView.setNeedsLayout()
        }
    }

    func applyEdgeFade(_ fade: LyricsViewportFade, viewportTop: CGFloat, in scroll: UIScrollView, presentation: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if !presentation, viewportTop >= fade.topEnd, viewportTop + bounds.height <= fade.bottomStart {
            removeEdgeMask(in: layer)
            return
        }
        var targets: [CALayer] = []
        collectTargets(in: layer, targets: &targets)
        for target in targets {
            let mask = (target.mask as? LyricsEdgeMaskLayer) ?? LyricsEdgeMaskLayer()
            let destination = (presentation ? target.presentation() : nil) ?? target
            let source = destination === target ? scroll.layer : (scroll.layer.presentation() ?? scroll.layer)
            let rect = CGRect(x: source.bounds.minX - 64, y: source.bounds.minY + fade.topStart,
                              width: scroll.bounds.width + 128, height: max(fade.bottomEnd - fade.topStart, 1))
            mask.frame = destination.convert(rect, from: source)
            let flipped = destination.convert(CGPoint(x: 0, y: rect.minY), from: source).y
                > destination.convert(CGPoint(x: 0, y: rect.maxY), from: source).y
            mask.startPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
            mask.endPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
            mask.setStops(fade)
            if target.mask !== mask { target.mask = mask }
        }
    }

    private func removeEdgeMask(in layer: CALayer) {
        if layer.mask is LyricsEdgeMaskLayer { layer.mask = nil }
        for child in layer.sublayers ?? [] { removeEdgeMask(in: child) }
    }

    /// Match the queue: mask blend/compositing leaves, preserving existing custom masks.
    @discardableResult private func collectTargets(in layer: CALayer, targets: inout [CALayer]) -> Bool {
        let start = targets.count
        let hasFilter = layer.compositingFilter != nil
        var childHasFilter = false
        for child in layer.sublayers ?? [] {
            let filtered = collectTargets(in: child, targets: &targets)
            childHasFilter = childHasFilter || filtered
        }
        let customMask = layer.mask != nil && !(layer.mask is LyricsEdgeMaskLayer)
        if (hasFilter || !childHasFilter) && !customMask {
            for child in targets[start...] where child.mask is LyricsEdgeMaskLayer { child.mask = nil }
            targets.removeSubrange(start...)
            targets.append(layer)
        } else if layer.mask is LyricsEdgeMaskLayer { layer.mask = nil }
        return hasFilter || childHasFilter
    }
}

private final class LyricsEdgeMaskLayer: CAGradientLayer {
    override init() {
        super.init()
        colors = [UIColor.clear, .black.withAlphaComponent(0.35), .black.withAlphaComponent(0.8),
                  .black, .black, .black.withAlphaComponent(0.8), .black.withAlphaComponent(0.35), .clear].map(\.cgColor)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func setStops(_ fade: LyricsViewportFade) {
        let height = max(fade.bottomEnd - fade.topStart, 1)
        let top = min(max((fade.topEnd - fade.topStart) / height, 0), 1)
        let bottom = min(max((fade.bottomStart - fade.topStart) / height, top), 1)
        let stops: [NSNumber] = [0, NSNumber(value: Double(top * 0.3)), NSNumber(value: Double(top * 0.65)),
                     NSNumber(value: Double(top)), NSNumber(value: Double(bottom)),
                     NSNumber(value: Double(bottom + (1 - bottom) * 0.35)),
                     NSNumber(value: Double(bottom + (1 - bottom) * 0.7)), 1]
        if locations != stops { locations = stops }
    }
}

nonisolated struct LyricsViewportFade: Equatable, Sendable {
    static let shownBottomFadeHeight: CGFloat = 160
    static let hiddenBottomFadeHeight: CGFloat = 56

    var topStart: CGFloat = 0
    var topEnd: CGFloat = 0
    var bottomStart: CGFloat = .greatestFiniteMagnitude
    var bottomEnd: CGFloat = .greatestFiniteMagnitude

    init(
        height: CGFloat,
        referenceHeight: CGFloat,
        shownReferenceHeight: CGFloat? = nil,
        topOverlayHeight: CGFloat,
        isInterfaceHidden: Bool
    ) {
        bottomEnd = isInterfaceHidden ? height : referenceHeight
        topStart = min(topOverlayHeight, bottomEnd)
        topEnd = min(topStart + NowPlayingQueueList.topFadeHeight, bottomEnd)
        let shownBottom = shownReferenceHeight ?? referenceHeight
        let overlayShownFade = min(
            Self.shownBottomFadeHeight,
            max(Self.hiddenBottomFadeHeight, max(shownBottom - topEnd, 0) * 0.48)
        )
        let span = height - shownBottom
        let hiddenFraction: CGFloat = span > 0.5
            ? min(max((bottomEnd - shownBottom) / span, 0), 1)
            : 1
        let bottomFade = overlayShownFade
            + (Self.hiddenBottomFadeHeight - overlayShownFade) * hiddenFraction
        bottomStart = max(topEnd, bottomEnd - bottomFade)
    }
}
