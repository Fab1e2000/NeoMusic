// Adapted from MeloX AppleMusicLyricsView (GPL-3.0), commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a. Typography and timing follow
// the supplied Music references; UIKit owns scrolling and row animations.
//
// The lyric list is a UITableView with the scroll view as the same owner:
// content offset, focus alignment, browsing resume and tap-to-seek all stay on
// one UIScrollView subclass. Only visible rows (plus a small overscan) hold
// hosting views, so long songs no longer allocate one row per lyric line.
// Large jumps hand the leaving visible rows to lightweight snapshots for the
// duration of their exit spring; the snapshots are never resident cells.
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
    var showsTranslation: Bool = false
    var onInterfaceInteraction: (() -> Void)? = nil
    var onUserInteractionChange: ((Bool) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .title) private var scaledFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.primaryFontSize
    @ScaledMetric(relativeTo: .title) private var scaledTranslationFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.translationFontSize
    @State private var rowGeometry: LyricsRowGeometry

    init(lyrics: PlayerLyrics, activeID: Int?, bottomOverlayHeight: CGFloat,
         isActive: Bool, isInterfaceHidden: Binding<Bool>, onSeek: @escaping (Double) -> Void,
         topOverlayHeight: CGFloat = 0, fixedFontSize: CGFloat? = nil,
         foreground: Color = .white, showsTranslation: Bool = false,
         onInterfaceInteraction: (() -> Void)? = nil,
         onUserInteractionChange: ((Bool) -> Void)? = nil,
         rowGeometry: LyricsRowGeometry = LyricsRowGeometry()) {
        self.lyrics = lyrics
        self.activeID = activeID
        self.bottomOverlayHeight = bottomOverlayHeight
        self.topOverlayHeight = topOverlayHeight
        self.isActive = isActive
        _isInterfaceHidden = isInterfaceHidden
        self.onSeek = onSeek
        self.fixedFontSize = fixedFontSize
        self.foreground = foreground
        self.showsTranslation = showsTranslation
        self.onInterfaceInteraction = onInterfaceInteraction
        self.onUserInteractionChange = onUserInteractionChange
        _rowGeometry = State(initialValue: rowGeometry)
    }

    private var translationFontSize: CGFloat {
        if let fixedFontSize {
            let profile = AppleMusicLyricsTypographyProfile.iOS26_6
            return fixedFontSize * profile.translationFontSize / profile.primaryFontSize
        }
        return scaledTranslationFontSize
    }

    var body: some View {
        NativeLyricsScrollContent(
            lyrics: lyrics, activeID: activeID, bottomOverlayHeight: bottomOverlayHeight,
            topOverlayHeight: topOverlayHeight, isActive: isActive,
            isInterfaceHidden: $isInterfaceHidden, onSeek: onSeek,
            fontSize: fixedFontSize ?? scaledFontSize, translationFontSize: translationFontSize,
            showsTranslation: showsTranslation,
            onInterfaceInteraction: onInterfaceInteraction,
            onUserInteractionChange: onUserInteractionChange,
            foreground: foreground,
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
    let translationFontSize: CGFloat
    let showsTranslation: Bool
    let onInterfaceInteraction: (() -> Void)?
    let onUserInteractionChange: ((Bool) -> Void)?
    let foreground: Color
    let reducesMotion: Bool
    let increasedContrast: Bool
    let rowGeometry: LyricsRowGeometry

    func makeUIView(context: Context) -> NativeLyricsViewportView { NativeLyricsViewportView() }
    func updateUIView(_ view: NativeLyricsViewportView, context: Context) { view.lyricsView.update(self) }
    static func dismantleUIView(_ view: NativeLyricsViewportView, coordinator: ()) { view.lyricsView.stop() }
}

/// Extends the table past the visible viewport horizontally and vertically.
/// Horizontal bleed keeps the blur halo inside a hosting surface without
/// changing the text width; vertical overscan lets rows participating in a
/// line-change spring stay alive while the owner scrolls.
final class NativeLyricsViewportView: UIView {
    let lyricsView = NativeLyricsScrollView(frame: .zero, style: .plain)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        addSubview(lyricsView)
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let bleed = NativeLyricsScrollView.horizontalBleed
        let overscan = NativeLyricsScrollView.viewportOverscan
        let frame = CGRect(x: -bleed, y: -overscan,
                           width: width + 2 * bleed, height: height + 2 * overscan)
        if lyricsView.frame != frame { lyricsView.frame = frame }
    }
}

/// A single scroll owner commits the destination and every visible row's
/// starting position together. Independent UIKit springs then reveal the
/// stagger without another scroll animation.
@objc(NeoMusicLyricsScrollView)
final class NativeLyricsScrollView: UITableView, UITableViewDataSource, UITableViewDelegate {
    /// Room for the blur halo on each side; the text keeps the view's width.
    static let horizontalBleed: CGFloat = 24
    /// Rows just outside the viewport stay materialized for the line spring.
    static let viewportOverscan: CGFloat = 160
    /// Synthetic row ID used for a leading intro interlude (`•••`) when the first sung line starts after 4s.
    static let introInterludeLineID = -1

    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private var input: NativeLyricsScrollContent?
    private var sourceLines: [PlayerLyricLine] = []
    private var renderedLines: [PlayerLyricLine] = []
    private var lineIndices: [Int: Int] = [:]
    private var renderedFontSize: CGFloat = 0
    private var renderedTranslationFontSize: CGFloat = 0
    private var renderedShowsTranslation = false
    private var hasAppliedLyricsInput = false
    private var renderedForeground = Color.white
    private var translationAnimator: UIViewPropertyAnimator?
    /// Holds the focused line at the position left by the translation spring until the next line change.
    private var holdsTranslationAnchor = false
    var onUserInteractionChange: ((Bool) -> Void)?
    private var lastVisualSize = CGSize.zero
    private var visualHeight: CGFloat = 0
    private var estimatedHeight: CGFloat = 56
    private var focusedIndex: Int?
    private var needsFocus = true
    private var wasActive = false
    private var positioning = false
    private var refreshing = false
    private var browsing = false
    private var reportsUserInteraction = false
    private var resumeTask: Task<Void, Never>?
    private var visibility = LyricsScrollInterfaceVisibilityTracker()
    private var previousOffset: CGFloat = 0
    private var animators: [UUID: RowAnimation] = [:]
    private var displayLink: CADisplayLink?
    private let fadeGuide = UIView()
    private var fadeAnimator: UIViewPropertyAnimator?
    private var fadeTargetHeight: CGFloat?
    private var backgroundTapDelegate: BackgroundTapDelegate?

    private final class BackgroundTapDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var owner: NativeLyricsScrollView?
        init(owner: NativeLyricsScrollView) { self.owner = owner }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let owner, let input = owner.input, input.isActive, input.isInterfaceHidden else {
                return false
            }
            let location = touch.location(in: owner)
            // Only reveal controls when tapping outside any lyric row so row taps still seek directly.
            return owner.indexPathForRow(at: location) == nil
        }
    }

    private struct RowAnimation {
        weak var cell: NativeLyricCell?
        let animator: UIViewPropertyAnimator
    }

    private struct CapturedSourceRow {
        let view: UIView
        let row: Int
        let screenFrame: CGRect
        let transform: CGAffineTransform
    }

    private final class SnapshotAnimation {
        let view: UIView
        let animator: UIViewPropertyAnimator

        init(view: UIView, animator: UIViewPropertyAnimator) {
            self.view = view
            self.animator = animator
        }
    }

    private var sourceSnapshotAnimations: [UUID: SnapshotAnimation] = [:]
    private var sourceSnapshotContainer: UIView?
    /// Lifetime count of handed-off rows; diagnostics for regression coverage.
    private(set) var sourceSnapshotHandoffCount = 0
    var sourceSnapshotCount: Int { sourceSnapshotAnimations.count }

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        dataSource = self
        delegate = self
        backgroundColor = .clear
        clipsToBounds = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        separatorStyle = .none
        sectionHeaderHeight = 0
        sectionFooterHeight = 0
        rowHeight = UITableView.automaticDimension
        estimatedRowHeight = 56
        register(NativeLyricCell.self, forCellReuseIdentifier: NativeLyricCell.reuseIdentifier)
        fadeGuide.isUserInteractionEnabled = false
        fadeGuide.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(fadeGuide)
        let tapDelegate = BackgroundTapDelegate(owner: self)
        backgroundTapDelegate = tapDelegate
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        backgroundTap.cancelsTouchesInView = false
        backgroundTap.delegate = tapDelegate
        addGestureRecognizer(backgroundTap)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func handleBackgroundTap() {
        guard let input, input.isActive, input.isInterfaceHidden else { return }
        input.onInterfaceInteraction?()
    }

    private var visibleRows: [NativeLyricCell] {
        visibleCells.compactMap { $0 as? NativeLyricCell }
    }

    // MARK: - SwiftUI input

    fileprivate func update(_ value: NativeLyricsScrollContent) {
        let previous = input
        let replaced = sourceLines != value.lyrics.lines
            || renderedFontSize != value.fontSize
            || renderedTranslationFontSize != value.translationFontSize
            || renderedForeground != value.foreground
        let interfaceChanged = previous?.isInterfaceHidden != value.isInterfaceHidden
        let geometryChanged = previous?.topOverlayHeight != value.topOverlayHeight
            || previous?.bottomOverlayHeight != value.bottomOverlayHeight
        let translationChanged = hasAppliedLyricsInput && !replaced
            && renderedShowsTranslation != value.showsTranslation
        input = value
        onUserInteractionChange = value.onUserInteractionChange
        isScrollEnabled = value.isActive
        isUserInteractionEnabled = value.isActive
        if !value.isActive {
            if wasActive { stop() }
            wasActive = false
            return
        }
        if replaced {
            stop()
            cancelAllAnimations()
            sourceLines = value.lyrics.lines
            let display = Self.displayLines(from: sourceLines)
            renderedLines = display.lines
            renderedFontSize = value.fontSize
            renderedTranslationFontSize = value.translationFontSize
            renderedShowsTranslation = value.showsTranslation
            renderedForeground = value.foreground
            lineIndices = display.indices
            lastVisualSize = .zero
            focusedIndex = nil
            holdsTranslationAnchor = false
            needsFocus = true
            reloadData()
        } else if translationChanged {
            revealTranslations(value.showsTranslation, animated: !value.reducesMotion && wasActive)
        }
        hasAppliedLyricsInput = true
        if value.reducesMotion && previous?.reducesMotion != true { needsFocus = true }
        if !wasActive || replaced { suppressedPreSeekActiveID = nil }
        if !wasActive {
            browsing = false
            needsFocus = true
        }
        let next = activeRowIndex(for: value.activeID, updatingSuppression: true)
        let changed = next != focusedIndex
        let exitedBrowsing = !browsing && visibleRows.contains { $0.appearance.browsing }
        let appearanceAnimated = (changed || exitedBrowsing) && wasActive && !value.reducesMotion
        let currentVisualSize = CGSize(
            width: bounds.width,
            height: max(bounds.height - 2 * Self.viewportOverscan, 0)
        )
        let canAnimate = wasActive && !replaced && !value.reducesMotion
            && lastVisualSize != .zero && currentVisualSize == lastVisualSize
        if bounds.width > 0, bounds.height > 0 {
            updateMetricsIfNeeded()
            updateAppearances(activeIndex: next, animated: appearanceAnimated)
            if interfaceChanged || geometryChanged || replaced || needsFocus {
                updateFade(animated: interfaceChanged && wasActive && !value.reducesMotion)
            }
            if !browsing && (changed || needsFocus || geometryChanged) {
                let animates = canAnimate && (focusedIndex != nil || geometryChanged)
                align(to: next, cascade: animates, animated: animates, spring: motion.lineChangeSpring,
                      appearanceAnimated: appearanceAnimated)
            }
        }
        wasActive = true
        setNeedsLayout()
    }

    /// Filters out production credit rows, short blank timestamp rows, and trailing
    /// blank rows, keeping at most one interlude row when the gap to the next sung
    /// line exceeds 4 seconds (including a leading intro interlude before the first sung line).
    /// Filtered row IDs map to the preceding kept row so focus never drops.
    static func displayLines(
        from source: [PlayerLyricLine],
        minimumInterludeDuration: TimeInterval = 4.0
    ) -> (lines: [PlayerLyricLine], indices: [Int: Int]) {
        func isBlank(_ line: PlayerLyricLine) -> Bool {
            line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && line.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let creditIndices = LyricsCreditFilter.creditLineIndices(in: source)
        let firstSungOffset = source.indices.first { !creditIndices.contains($0) && !isBlank(source[$0]) }

        var rendered: [PlayerLyricLine] = []
        rendered.reserveCapacity(source.count + 1)
        var indices: [Int: Int] = [:]
        indices.reserveCapacity(source.count + 1)

        if let firstSungOffset, source[firstSungOffset].time > minimumInterludeDuration {
            rendered.append(PlayerLyricLine(id: Self.introInterludeLineID, time: 0, text: ""))
            indices[Self.introInterludeLineID] = 0
        }

        var previousWasBlank = false
        for (i, line) in source.enumerated() {
            // Everything before the first sung line (credits / leading blanks) collapses
            // into the intro interlude if one was inserted, or is skipped if the song starts promptly.
            if let firstSungOffset, i < firstSungOffset {
                if !rendered.isEmpty, indices[line.id] == nil {
                    indices[line.id] = 0
                }
                continue
            }

            if creditIndices.contains(i) {
                if !rendered.isEmpty, indices[line.id] == nil {
                    indices[line.id] = rendered.count - 1
                }
                continue
            }

            if !isBlank(line) {
                let targetIndex = rendered.count
                rendered.append(line)
                if indices[line.id] == nil { indices[line.id] = targetIndex }
                previousWasBlank = false
                continue
            }

            if !previousWasBlank,
               let nextNonBlank = source[(i + 1)...].enumerated().first(where: { offset, candidate in
                   !creditIndices.contains(i + 1 + offset) && !isBlank(candidate)
               })?.element,
               nextNonBlank.time - line.time > minimumInterludeDuration {
                let targetIndex = rendered.count
                rendered.append(line)
                if indices[line.id] == nil { indices[line.id] = targetIndex }
            } else if !rendered.isEmpty, indices[line.id] == nil {
                indices[line.id] = rendered.count - 1
            }
            previousWasBlank = true
        }
        return (rendered, indices)
    }

    // MARK: - Table data

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        renderedLines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NativeLyricCell.reuseIdentifier, for: indexPath
        ) as! NativeLyricCell
        configure(cell, at: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard renderedLines.indices.contains(indexPath.row) else { return estimatedHeight }
        if let height = input?.rowGeometry.height(for: renderedLines[indexPath.row].id) {
            return height + motion.lineSpacing
        }
        return estimatedHeight
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell,
                   forRowAt indexPath: IndexPath) {
        guard let cell = cell as? NativeLyricCell else { return }
        cancelAnimations(for: cell)
        if renderedLines.indices.contains(indexPath.row) {
            input?.rowGeometry.discardPosition(for: renderedLines[indexPath.row].id)
        }
    }

    private func configure(_ cell: NativeLyricCell, at index: Int) {
        guard let input, renderedLines.indices.contains(index) else { return }
        let line = renderedLines[index]
        let focused = index == focusedIndex
        let initialBlurRadius: Double = if !focused, let focusedIndex {
            motion.blurRadius(rowOffset: index - focusedIndex)
        } else {
            0
        }
        cell.configure(
            line: line, fontSize: renderedFontSize, translationFontSize: renderedTranslationFontSize,
            showsTranslation: renderedShowsTranslation, foreground: renderedForeground,
            spacing: motion.lineSpacing, focused: focused,
            browsing: browsing, reducesMotion: input.reducesMotion,
            increasedContrast: input.increasedContrast,
            initialBlurRadius: initialBlurRadius,
            preservesMotion: translationAnimator != nil
        )
        cell.appearance.onTap = { [weak self, weak cell] in
            guard let self, let cell, let indexPath = self.indexPath(for: cell) else { return }
            self.seek(indexPath.row)
        }
        cell.appearance.onPressStateChange = { [weak self, weak cell] _ in
            cell?.invalidateFadeTargets()
            self?.setNeedsLayout()
            DispatchQueue.main.async { [weak self, weak cell] in
                cell?.invalidateFadeTargets()
                self?.refreshVisualGeometry()
            }
        }
        cell.onPrepareForReuse = { [weak self, weak cell] in
            self?.cancelAnimations(for: cell)
        }
        // Overscan rows must not flash outside the viewport before the next
        // geometry refresh. New cells are always at their final position.
        let viewportTop = cell.frame.minY - contentOffset.y - Self.viewportOverscan
        let fade = currentFade()
        let intersects = viewportTop + textHeight(of: cell) >= fade.topStart - NativeLyricCell.horizontalBleed
            && viewportTop <= fade.bottomEnd + NativeLyricCell.horizontalBleed
        cell.setContentHidden(!intersects)
        if intersects {
            cell.applyEdgeFade(
                fade.shifted(by: Self.viewportOverscan),
                viewportTop: viewportTop + Self.viewportOverscan,
                in: self, presentation: false
            )
        }
    }

    /// Expands or collapses translations with the Music supplemental-text spring.
    /// The focused row stays on screen; rows below move with the table's height animation.
    private func revealTranslations(_ showsTranslation: Bool, animated: Bool) {
        let anchor = translationAnchorRow()
        let before = anchor.flatMap { rectForRow(at: IndexPath(row: $0, section: 0)).minY }
        renderedShowsTranslation = showsTranslation
        holdsTranslationAnchor = anchor != nil
        guard animated else {
            UIView.performWithoutAnimation {
                reconfigureVisibleTranslations()
                layoutIfNeeded()
                holdTranslationAnchor(anchor, before: before)
            }
            return
        }
        let spring = showsTranslation
            ? motion.supplementalTextShowSpring
            : motion.supplementalTextHideSpring
        let timing = UISpringTimingParameters(
            mass: CGFloat(spring.mass),
            stiffness: CGFloat(spring.stiffness),
            damping: CGFloat(spring.damping),
            initialVelocity: .zero
        )
        translationAnimator?.stopAnimation(false)
        let animator = UIViewPropertyAnimator(duration: 0.5, timingParameters: timing)
        translationAnimator = animator
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.reconfigureVisibleTranslations()
            self.layoutIfNeeded()
            self.holdTranslationAnchor(anchor, before: before)
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.translationAnimator === animator else { return }
            self.translationAnimator = nil
            self.updateVisualGeometry(presentation: false)
        }
        animator.startAnimation()
    }

    private func translationAnchorRow() -> Int? {
        if !browsing, let focusedIndex { return focusedIndex }
        return visibleRows.compactMap { indexPath(for: $0)?.row }.min()
    }

    private func reconfigureVisibleTranslations() {
        performBatchUpdates {
            for cell in self.visibleRows {
                cell.updateShowsTranslation(self.renderedShowsTranslation)
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
        }
    }

    private func holdTranslationAnchor(_ anchor: Int?, before: CGFloat?) {
        guard let anchor, let before else { return }
        let after = rectForRow(at: IndexPath(row: anchor, section: 0)).minY
        let delta = after - before
        guard abs(delta) > 0.5 else { return }
        contentOffset.y += delta
    }

    // MARK: - Layout

    override func layoutSubviews() {
        // Rows carry a line-change translation while the table lays out. UIKit
        // assigns `frame` through the active transform, which would rewrite the
        // row's center and commit overlapping row positions; lay out without the
        // translation and put it back afterwards.
        let residentCells = subviews.compactMap { $0 as? NativeLyricCell }
        let rowTransforms = residentCells.map(\.transform)
        UIView.performWithoutAnimation {
            for cell in residentCells where cell.transform != .identity {
                cell.transform = .identity
            }
        }
        super.layoutSubviews()
        UIView.performWithoutAnimation {
            for (cell, transform) in zip(residentCells, rowTransforms)
            where cell.transform != transform {
                cell.transform = transform
            }
        }
        guard let input, input.isActive, !positioning else { return }
        let visualSize = CGSize(width: bounds.width,
                                height: max(bounds.height - 2 * Self.viewportOverscan, 0))
        if visualSize != lastVisualSize {
            let firstLayout = lastVisualSize == .zero
            freezeRows()
            positioning = true
            lastVisualSize = visualSize
            updateMetrics()
            if !firstLayout { reloadData() }
            layoutIfNeeded()
            positioning = false
            let activeIndex = activeRowIndex(for: input.activeID, updatingSuppression: false)
            updateAppearances(activeIndex: activeIndex, animated: false)
            updateFade(animated: false)
            if !browsing { align(to: activeIndex, cascade: false) }
        } else if needsFocus && !browsing {
            align(to: activeRowIndex(for: input.activeID, updatingSuppression: false), cascade: false)
        }
        refreshVisualGeometry()
        correctSettledFocusIfNeeded()
    }

    private func updateMetricsIfNeeded() {
        let visualSize = CGSize(width: bounds.width,
                                height: max(bounds.height - 2 * Self.viewportOverscan, 0))
        guard lastVisualSize == .zero else { return }
        lastVisualSize = visualSize
        updateMetrics()
    }

    private func updateMetrics() {
        visualHeight = max(bounds.height - 2 * Self.viewportOverscan, 0)
        let footerHeight = max(visualHeight + Self.viewportOverscan, 1)
        if let footer = tableFooterView, abs(footer.frame.height - footerHeight) < 0.5 {
            if abs(footer.frame.width - max(bounds.width, 1)) > 0.5 {
                footer.frame.size.width = max(bounds.width, 1)
            }
        } else {
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: footerHeight))
            footer.backgroundColor = .clear
            tableFooterView = footer
        }
        let lineHeight = LyricsFontMetrics.boldLineHeight(size: max(renderedFontSize, 1))
        let estimate = max(lineHeight + motion.lineSpacing, 1)
        if abs(estimatedHeight - estimate) > 0.5 {
            estimatedHeight = estimate
            estimatedRowHeight = estimate
        }
        if fadeGuide.superview == nil { addSubview(fadeGuide) }
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
                return resolvedRowIndex(for: activeID)
            }
            return focusedIndex ?? resolvedRowIndex(for: activeID)
        }
        return resolvedRowIndex(for: activeID)
    }

    private func resolvedRowIndex(for activeID: Int?) -> Int? {
        if let activeID { return lineIndices[activeID] }
        return renderedLines.first?.id == Self.introInterludeLineID ? 0 : nil
    }

    private func targetOffset(for index: Int, activeID: Int? = nil,
                              interfaceHidden: Bool? = nil) -> CGFloat {
        guard renderedLines.indices.contains(index) else { return contentOffset.y }
        let focus = focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden)
        let topInset = max(focus, motion.firstLineStartOffset) + Self.viewportOverscan
        let rowTop = rectForRow(at: IndexPath(row: index, section: 0)).minY
        return clampedOffset(rowTop - focus - Self.viewportOverscan, topInset: topInset)
    }

    private func clampedOffset(_ offset: CGFloat, topInset: CGFloat) -> CGFloat {
        let maxOffset = max(contentSize.height - bounds.height, 0)
        return max(-topInset, min(offset, maxOffset))
    }

    /// Far jumps land outside the table's estimated window. Step by the
    /// heights already measured in the visible window until the destination
    /// row exists, so the focused row is never replaced by an estimate.
    private func materializeRow(_ index: Int, focus: CGFloat, topInset: CGFloat,
                                target: inout CGFloat) -> NativeLyricCell? {
        var cell = displayedCell(forRow: index)
        if cell == nil {
            // The table owns row materialization; ask it to bring the row
            // into the viewport instead of scrolling an estimate by hand.
            scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            setNeedsLayout()
            layoutIfNeeded()
            cell = displayedCell(forRow: index)
            target = contentOffset.y
        }
        var attempts = 0
        while cell == nil, attempts < 6 {
            guard let (nearRow, nearCell) = nearestVisibleRow(to: index) else { break }
            let heights = visibleRows.map(\.bounds.height)
            let average = max(heights.reduce(0, +) / CGFloat(max(heights.count, 1)), 1)
            let step = CGFloat(index - nearRow) * average
            let next = clampedOffset(
                modelTop(of: nearCell) + step - focus - Self.viewportOverscan,
                topInset: topInset
            )
            attempts += 1
            guard abs(next - target) > 0.5 else { break }
            target = next
            setContentOffset(CGPoint(x: 0, y: target), animated: false)
            setNeedsLayout()
            layoutIfNeeded()
            cell = displayedCell(forRow: index)
        }
        return cell
    }

    private func nearestVisibleRow(to index: Int) -> (row: Int, cell: NativeLyricCell)? {
        var best: (row: Int, cell: NativeLyricCell)?
        for cell in visibleRows {
            guard let row = indexPath(for: cell)?.row else { continue }
            if best == nil || abs(row - index) < abs(best!.row - index) {
                best = (row, cell)
            }
        }
        return best
    }

    private var focusTop: CGFloat {
        focusTop(forActiveID: input?.activeID)
    }

    private func focusTop(forActiveID activeID: Int?, interfaceHidden: Bool? = nil,
                          rowHeight: CGFloat? = nil) -> CGFloat {
        guard let input else { return 0 }
        let effectiveHeight = max(visualHeight - input.topOverlayHeight, 1)
        let bottom = max(visualHeight - input.bottomOverlayHeight, 1)
        let shownVisible = max(bottom - input.topOverlayHeight, 1)
        let lineHeight = LyricsFontMetrics.boldLineHeight(size: input.fontSize)
        let height = rowHeight ?? activeRowHeight(for: activeID) ?? lineHeight
        let preferredOffset = effectiveHeight * (motion.selectedLineTopRelativePercent / 100) - lineHeight / 2
        return input.topOverlayHeight + min(max(preferredOffset, shownVisible * 0.08),
                                            max(shownVisible * 0.08, shownVisible * 0.84 - height))
    }

    private func activeRowHeight(for activeID: Int?) -> CGFloat? {
        guard let activeID else { return nil }
        if let index = lineIndices[activeID], let cell = displayedCell(forRow: index) {
            return textHeight(of: cell)
        }
        return input?.rowGeometry.height(for: activeID)
    }

    private func textHeight(of cell: NativeLyricCell) -> CGFloat {
        max(cell.bounds.height - motion.lineSpacing, 1)
    }

    /// `frame` includes an in-flight line-change spring; the row's committed
    /// layout position is center minus half its bounds.
    private func modelTop(of cell: UIView) -> CGFloat {
        cell.center.y - cell.bounds.height / 2
    }

    private func modelFrame(of cell: UIView) -> CGRect {
        CGRect(x: cell.center.x - cell.bounds.width / 2, y: modelTop(of: cell),
               width: cell.bounds.width, height: cell.bounds.height)
    }

    private func visibleCell(forRow row: Int) -> NativeLyricCell? {
        guard renderedLines.indices.contains(row) else { return nil }
        return cellForRow(at: IndexPath(row: row, section: 0)) as? NativeLyricCell
    }

    /// `cellForRow` can transiently return a cell the table has already
    /// detached while self-sizing settles; only displayed cells may drive
    /// focus corrections or geometry recording.
    private func displayedCell(forRow row: Int) -> NativeLyricCell? {
        guard let cell = visibleCell(forRow: row) else { return nil }
        return visibleRows.contains { $0 === cell } ? cell : nil
    }

    private func updateAppearances(activeIndex: Int?, animated: Bool) {
        guard let input else { return }
        for cell in visibleRows {
            guard let row = indexPath(for: cell)?.row else { continue }
            let appearance = cell.appearance
            if appearance.animated != animated { appearance.animated = animated }
            let focused = row == activeIndex
            if appearance.focused != focused { appearance.focused = focused }
            if appearance.browsing != browsing { appearance.browsing = browsing }
            if appearance.reducesMotion != input.reducesMotion {
                appearance.reducesMotion = input.reducesMotion
            }
            if appearance.increasedContrast != input.increasedContrast {
                appearance.increasedContrast = input.increasedContrast
            }
        }
    }

    private func align(to index: Int?, cascade: Bool, animated: Bool = false,
                       spring: LyricPhysicalSpringParameters? = nil,
                       interfaceHidden: Bool? = nil,
                       appearanceAnimated: Bool = false,
                       endsBrowsing: Bool = false) {
        guard let index, renderedLines.indices.contains(index), input != nil else { return }
        freezeRows()
        let activeID = renderedLines[index].id
        let oldOffset = contentOffset.y
        var focus: CGFloat = focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden)
        var topInset: CGFloat = max(focus, motion.firstLineStartOffset) + Self.viewportOverscan
        var target: CGFloat = targetOffset(for: index, activeID: activeID, interfaceHidden: interfaceHidden)
        // Capture the visible source rows before the offset changes. Large
        // jumps otherwise recycle them before their exit spring can run.
        let capturesHandoff = input?.reducesMotion != true && (cascade || animated)
            && abs(target - oldOffset) > Self.viewportOverscan
        let capturedSourceRows = capturesHandoff ? captureSourceRowsForHandoff() : []
        if focusedIndex != index { holdsTranslationAnchor = false }
        focusedIndex = index
        needsFocus = false

        positioning = true
        contentInset.top = topInset
        setContentOffset(CGPoint(x: 0, y: target), animated: false)
        setNeedsLayout()
        layoutIfNeeded()

        // Hosting cells report their final height during layout. Materialize
        // the destination row (stepping by measured heights when a far jump
        // lands outside the estimated window), then converge against measured
        // heights so newly self-sized surrounding rows do not leave the first
        // jump off-target.
        if let cell = materializeRow(index, focus: focus, topInset: topInset, target: &target) {
            convergeMeasuredTarget(for: cell, activeID: activeID, interfaceHidden: interfaceHidden,
                                   focus: &focus, topInset: &topInset, target: &target)
        }

        // UITableView materializes the destination window on the next layout pass.
        // End the positioning lock first so the row animations target the new cells
        // instead of the old visible window that is already off-screen.
        positioning = false
        setNeedsLayout()
        layoutIfNeeded()
        if let cell = displayedCell(forRow: index) {
            positioning = true
            convergeMeasuredTarget(for: cell, activeID: activeID, interfaceHidden: interfaceHidden,
                                   focus: &focus, topInset: &topInset, target: &target)
        }
        target = contentOffset.y
        positioning = true
        let delta = target - oldOffset
        let cells = visibleRows
        let animates = (cascade || animated)
            && (cascade || abs(delta) >= 0.5 || cells.contains { $0.transform != .identity })
        UIView.performWithoutAnimation {
            for cell in cells {
                cell.transform = animates ? cell.transform.translatedBy(x: 0, y: delta) : .identity
            }
        }
        positioning = false
        if endsBrowsing { browsing = false }
        input?.rowGeometry.focus(on: activeID)
        updateAppearances(activeIndex: index, animated: appearanceAnimated)
        updateVisualGeometry(presentation: animates)
        guard animates else {
            setNeedsLayout()
            return
        }
        let timingSpring = spring ?? motion.lineChangeSpring
        var animatedEntries: [(cell: NativeLyricCell, row: Int)] = []
        animatedEntries.reserveCapacity(cells.count)
        for cell in cells {
            guard let row = indexPath(for: cell)?.row else {
                cell.transform = .identity
                continue
            }
            // `frame` includes the transform that is being animated, so using it here
            // double-counts the displacement and makes every far target look off-screen.
            let destination = cell.center.y - cell.bounds.height / 2 - target - Self.viewportOverscan
            let current = destination + cell.transform.ty
            guard max(current, destination) + cell.bounds.height > -NativeLyricCell.horizontalBleed,
                  min(current, destination) < visualHeight + NativeLyricCell.horizontalBleed else {
                cell.transform = .identity
                continue
            }
            animatedEntries.append((cell, row))
        }
        // Directional wave cascade matching Apple Music:
        // - Moving up (delta >= 0, forward/long tap): top-most visible row in the fade window leads.
        // - Moving down (delta < 0, reverse jump): rows just below the target lead so lower lines
        //   peel away first without stalling the tapped upper line at the header edge.
        let fade = currentFade()
        let visibleFadeRows = animatedEntries.compactMap { entry -> Int? in
            let top = entry.cell.center.y - entry.cell.bounds.height / 2 + entry.cell.transform.ty
                - target - Self.viewportOverscan
            let height = textHeight(of: entry.cell)
            return (top + height > fade.topStart && top < fade.bottomEnd) ? entry.row : nil
        }
        let movingUp = delta >= 0
        let cascadeAnchorRow: Int = if movingUp {
            visibleFadeRows.min() ?? animatedEntries.map(\.row).min() ?? index
        } else {
            min(visibleFadeRows.max() ?? animatedEntries.map(\.row).max() ?? index, index + 2)
        }
        let stepDelay: TimeInterval = movingUp ? motion.cascadeDelay : 0.035
        let maxCascadeDelay: TimeInterval = movingUp ? 0.30 : 0.14
        var createdAnimator = false
        for (cell, row) in animatedEntries {
            pendingStartTransforms[ObjectIdentifier(cell)] = cell.transform
            let animator = UIViewPropertyAnimator(duration: motion.lineChangeDuration, timingParameters:
                UISpringTimingParameters(mass: timingSpring.mass, stiffness: timingSpring.stiffness,
                                         damping: timingSpring.damping, initialVelocity: .zero))
            let id = UUID()
            animators[id] = RowAnimation(cell: cell, animator: animator)
            createdAnimator = true
            cell.isMoving = true
            animator.addAnimations { [weak cell] in cell?.transform = .identity }
            animator.addCompletion { [weak self, weak cell] _ in
                cell?.isMoving = false
                self?.animators.removeValue(forKey: id)
                self?.refreshVisualGeometry()
                self?.stopDisplayLinkIfIdle()
                self?.settleFocusAfterAnimationIfNeeded()
            }
            let rank = movingUp ? max(row - cascadeAnchorRow, 0) : max(cascadeAnchorRow - row, 0)
            let delay: TimeInterval = cascade ? min(Double(rank) * stepDelay, maxCascadeDelay) : 0
            animator.startAnimation(afterDelay: delay)
        }
        if animates, abs(delta) > Self.viewportOverscan {
            installSourceSnapshots(capturedSourceRows, delta: delta, spring: timingSpring,
                                   cascade: cascade, activeIndex: index)
        }
        if createdAnimator {
            schedulePendingTransformClear()
            startDisplayLink()
        }
        updateVisualGeometry(presentation: createdAnimator)
        setNeedsLayout()
    }

    private func convergeMeasuredTarget(for cell: NativeLyricCell, activeID: Int,
                                        interfaceHidden: Bool?, focus: inout CGFloat,
                                        topInset: inout CGFloat, target: inout CGFloat) {
        for _ in 0..<4 {
            let height = textHeight(of: cell)
            let measuredFocus = focusTop(forActiveID: activeID, interfaceHidden: interfaceHidden,
                                         rowHeight: height)
            let measuredTopInset = max(measuredFocus, motion.firstLineStartOffset)
                + Self.viewportOverscan
            let desired = modelTop(of: cell) - measuredFocus - Self.viewportOverscan
            let clamped = clampedOffset(desired, topInset: measuredTopInset)
            let insetDelta = abs(measuredTopInset - contentInset.top)
            let offsetDelta = abs(clamped - contentOffset.y)
            focus = measuredFocus
            topInset = measuredTopInset
            target = clamped
            guard insetDelta > 0.5 || offsetDelta > 0.5 else { break }
            contentInset.top = topInset
            setContentOffset(CGPoint(x: 0, y: target), animated: false)
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    private func freezeRows() {
        removeSourceSnapshots()
        let preCommit = pendingStartTransforms
        pendingStartTransforms.removeAll()
        schedulePendingTransformClear()
        guard !animators.isEmpty else { return }
        let cells = visibleRows
        let transforms = cells.map {
            preCommit[ObjectIdentifier($0)]
                ?? $0.layer.presentation()?.affineTransform()
                ?? $0.transform
        }
        for animation in animators.values { animation.animator.stopAnimation(true) }
        animators.removeAll()
        UIView.performWithoutAnimation {
            for (cell, transform) in zip(cells, transforms) {
                cell.isMoving = false
                cell.transform = transform
            }
        }
    }

    private func cancelAnimations(for cell: NativeLyricCell?) {
        guard let cell else { return }
        let matching = animators.filter { $0.value.cell === cell }
        for (id, animation) in matching {
            animation.animator.stopAnimation(true)
            animators.removeValue(forKey: id)
        }
        pendingStartTransforms.removeValue(forKey: ObjectIdentifier(cell))
        cell.isMoving = false
        cell.transform = .identity
        if animators.isEmpty { stopDisplayLinkIfIdle() }
    }

    private func cancelAllAnimations() {
        translationAnimator?.stopAnimation(true)
        translationAnimator = nil
        for animation in animators.values { animation.animator.stopAnimation(true) }
        animators.removeAll()
        pendingStartTransforms.removeAll()
        for cell in visibleRows {
            cell.isMoving = false
            cell.transform = .identity
        }
        removeSourceSnapshots()
    }

    // MARK: - Source-row snapshot handoff

    /// Only rows inside the visual viewport are captured; the count is bounded
    /// by the visible row window.
    private func captureSourceRowsForHandoff() -> [CapturedSourceRow] {
        guard let wrapper = superview else { return [] }
        let visualTop = contentOffset.y + Self.viewportOverscan
        let visualBottom = visualTop + visualHeight
        var captured: [CapturedSourceRow] = []
        for cell in visibleRows {
            guard let row = indexPath(for: cell)?.row else { continue }
            let modelFrame = modelFrame(of: cell)
            guard modelFrame.maxY > visualTop, modelFrame.minY < visualBottom else { continue }
            guard let snapshot = cell.snapshotView(afterScreenUpdates: false)
                ?? imageSnapshot(of: cell) else { continue }
            snapshot.isUserInteractionEnabled = false
            snapshot.isAccessibilityElement = false
            captured.append(CapturedSourceRow(
                view: snapshot,
                row: row,
                screenFrame: wrapper.convert(modelFrame, from: self),
                transform: cell.transform
            ))
        }
        return captured
    }

    private func imageSnapshot(of view: UIView) -> UIView? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        let imageView = UIImageView(image: image)
        imageView.backgroundColor = .clear
        imageView.isUserInteractionEnabled = false
        return imageView
    }

    private func installSourceSnapshots(_ captured: [CapturedSourceRow], delta: CGFloat,
                                        spring: LyricPhysicalSpringParameters,
                                        cascade: Bool, activeIndex: Int) {
        guard !captured.isEmpty, let wrapper = superview else { return }
        let destinationRows = Set(visibleRows.compactMap { indexPath(for: $0)?.row })
        let sourceOnly = captured.filter { !destinationRows.contains($0.row) }
        guard !sourceOnly.isEmpty else { return }
        removeSourceSnapshots()
        let container = UIView(frame: CGRect(
            x: -Self.horizontalBleed, y: 0,
            width: bounds.width, height: visualHeight
        ))
        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        let fade = currentFade()
        let mask = LyricsEdgeMaskLayer()
        mask.frame = container.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.setStops(fade)
        container.layer.mask = mask
        wrapper.addSubview(container)
        sourceSnapshotContainer = container

        let timing = UISpringTimingParameters(
            mass: spring.mass, stiffness: spring.stiffness,
            damping: spring.damping, initialVelocity: .zero
        )
        let movingUp = delta >= 0
        let sourceAnchorRow: Int = if movingUp {
            sourceOnly.map(\.row).min() ?? activeIndex
        } else {
            sourceOnly.map(\.row).max() ?? activeIndex
        }
        let maxSnapshotDelay: TimeInterval = 0.25
        for source in sourceOnly {
            source.view.frame = source.screenFrame.offsetBy(
                dx: -container.frame.minX, dy: -container.frame.minY
            )
            source.view.transform = source.transform
            container.addSubview(source.view)
            let animator = UIViewPropertyAnimator(
                duration: motion.lineChangeDuration, timingParameters: timing
            )
            let id = UUID()
            sourceSnapshotAnimations[id] = SnapshotAnimation(view: source.view, animator: animator)
            sourceSnapshotHandoffCount += 1
            animator.addAnimations { [weak view = source.view] in
                view?.transform = CGAffineTransform(translationX: 0, y: -delta)
                view?.alpha = 0
            }
            animator.addCompletion { [weak self] _ in self?.removeSourceSnapshot(id: id) }
            let rank = movingUp ? max(source.row - sourceAnchorRow, 0) : max(sourceAnchorRow - source.row, 0)
            let delay: TimeInterval = cascade ? min(Double(rank) * motion.cascadeDelay, maxSnapshotDelay) : 0
            animator.startAnimation(afterDelay: delay)
        }
    }

    private func removeSourceSnapshot(id: UUID) {
        guard let animation = sourceSnapshotAnimations.removeValue(forKey: id) else { return }
        animation.view.removeFromSuperview()
        if sourceSnapshotAnimations.isEmpty {
            sourceSnapshotContainer?.removeFromSuperview()
            sourceSnapshotContainer = nil
        }
    }

    private func removeSourceSnapshots() {
        let animations = sourceSnapshotAnimations
        sourceSnapshotAnimations.removeAll()
        for animation in animations.values { animation.animator.stopAnimation(true) }
        for animation in animations.values { animation.view.removeFromSuperview() }
        sourceSnapshotContainer?.removeFromSuperview()
        sourceSnapshotContainer = nil
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

    private func currentFade() -> LyricsViewportFade {
        let bottom = fadeBottom
        let shownBottom = max(visualHeight - (input?.bottomOverlayHeight ?? 0), 1)
        return LyricsViewportFade(
            height: visualHeight,
            referenceHeight: bottom,
            shownReferenceHeight: shownBottom,
            topOverlayHeight: input?.topOverlayHeight ?? 0,
            isInterfaceHidden: false
        )
    }

    private func updateFade(animated: Bool, interfaceHidden: Bool? = nil) {
        guard let input else { return }
        let hidden = interfaceHidden ?? input.isInterfaceHidden
        let height = hidden ? visualHeight
            : max(visualHeight - input.bottomOverlayHeight, 1)
        if animated, fadeAnimator != nil, let fadeTargetHeight, abs(fadeTargetHeight - height) < 0.5 {
            return
        }
        let current = fadeBottom
        fadeAnimator?.stopAnimation(true)
        fadeGuide.bounds.size.height = current
        if animated, abs(current - height) >= 0.5 {
            fadeTargetHeight = height
            fadePendingStartHeight = current
            let interfaceSpec = NowPlayingMotionSpec.appleMusic26.interface
            let duration = hidden ? interfaceSpec.coreHide.duration : interfaceSpec.coreShow.duration
            let spring = Spring.smooth(duration: duration)
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
                self?.fadeTargetHeight = nil
                self?.fadePendingStartHeight = nil
                self?.refreshVisualGeometry()
                self?.stopDisplayLinkIfIdle()
            }
            animator.startAnimation()
            schedulePendingTransformClear()
            startDisplayLink()
        } else {
            fadeAnimator = nil
            fadeTargetHeight = nil
            fadePendingStartHeight = nil
            schedulePendingTransformClear()
            fadeGuide.bounds.size.height = height
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshVisualGeometry))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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

    private func visualMinY(for cell: NativeLyricCell, presentation: Bool) -> CGFloat {
        if presentation && cell.isMoving {
            if let pending = pendingStartTransforms[ObjectIdentifier(cell)] {
                return cell.center.y - cell.bounds.height / 2 + pending.ty
            }
            if let layerMinY = cell.layer.presentation()?.frame.minY {
                return layerMinY
            }
        }
        return cell.frame.minY
    }

    private func updateVisualGeometry(presentation: Bool) {
        guard let input, input.isActive, visualHeight > 0, !positioning, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let fade = currentFade()
        let cells = visibleRows
        let lineHeight = LyricsFontMetrics.boldLineHeight(size: input.fontSize)
        let tableFade = fade.shifted(by: Self.viewportOverscan)
        for cell in cells {
            guard let row = indexPath(for: cell)?.row, renderedLines.indices.contains(row) else { continue }
            let id = renderedLines[row].id
            let top = visualMinY(for: cell, presentation: presentation)
            let viewportTop = top - contentOffset.y - Self.viewportOverscan
            let bleed = NativeLyricCell.horizontalBleed
            let height = textHeight(of: cell)
            let intersectsFade = viewportTop + height >= fade.topStart - bleed
                && viewportTop <= fade.bottomEnd + bleed
            // Horizontal overflow stays visible; offscreen rows remain hidden vertically.
            if cell.isContentHidden == intersectsFade { cell.setContentHidden(!intersectsFade) }
            if intersectsFade {
                if !cell.appearance.focused {
                    let radius = if let focusedIndex {
                        motion.blurRadius(rowOffset: row - focusedIndex)
                    } else {
                        motion.blurRadius(
                            verticalDistance: Double(top - (contentOffset.y + Self.viewportOverscan + focusTop)),
                            lineHeight: Double(lineHeight)
                        )
                    }
                    if cell.appearance.distanceBlurRadius != radius {
                        cell.appearance.distanceBlurRadius = radius
                    }
                }
                input.rowGeometry.record(
                    .init(height: height, top: viewportTop), for: id
                )
                cell.applyEdgeFade(
                    tableFade, viewportTop: viewportTop + Self.viewportOverscan,
                    in: self, presentation: presentation
                )
            } else {
                input.rowGeometry.discardPosition(for: id)
            }
        }
    }

    private func correctSettledFocusIfNeeded() {
        guard let input, input.isActive, !browsing, animators.isEmpty, translationAnimator == nil,
              !holdsTranslationAnchor,
              let index = focusedIndex, renderedLines.indices.contains(index) else { return }
        let id = renderedLines[index].id
        let cell = displayedCell(forRow: index)
        let height = cell.map(textHeight(of:)) ?? input.rowGeometry.height(for: id)
        let focus = focusTop(forActiveID: id, rowHeight: height)
        let topInset = max(focus, motion.firstLineStartOffset) + Self.viewportOverscan
        let maxOffset = max(contentSize.height - bounds.height, 0)
        let rowTop: CGFloat
        if let cell {
            rowTop = modelTop(of: cell)
        } else if let (nearRow, nearCell) = nearestVisibleRow(to: index) {
            // The table's estimated rect can lag behind a tall self-sized row;
            // extrapolate from a displayed neighbour's measured position.
            let heights = visibleRows.map(\.bounds.height)
            let average = max(heights.reduce(0, +) / CGFloat(max(heights.count, 1)), 1)
            rowTop = modelTop(of: nearCell) + CGFloat(index - nearRow) * average
        } else {
            rowTop = rectForRow(at: IndexPath(row: index, section: 0)).minY
        }
        let desired = rowTop - focus - Self.viewportOverscan
        let clamped = max(-topInset, min(desired, maxOffset))
        guard abs(clamped - contentOffset.y) > 0.5 else { return }
        positioning = true
        UIView.performWithoutAnimation {
            contentInset.top = topInset
            setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
        }
        positioning = false
        input.rowGeometry.focus(on: id)
        updateVisualGeometry(presentation: false)
        setNeedsLayout()
    }

    private func settleFocusAfterAnimationIfNeeded() {
        guard animators.isEmpty else { return }
        setNeedsLayout()
        layoutIfNeeded()
        correctSettledFocusIfNeeded()
    }

    // MARK: - Seeking and browsing

    func seek(_ index: Int) {
        guard let input, input.isActive, renderedLines.indices.contains(index) else { return }
        resumeTask?.cancel()
        visibility.end()
        endUserInteractionIfNeeded()
        // Keep browsing active until the alignment has captured its origin and
        // finished layout convergence. Release it right before updating row
        // appearances so non-active blur and opacity immediately restore.
        needsFocus = false
        input.isInterfaceHidden = false
        input.onSeek(renderedLines[index].time)
        let animates = wasActive && !input.reducesMotion && lastVisualSize != .zero
        if bounds.width > 0, bounds.height > 0 {
            let tappedID = renderedLines[index].id
            suppressedPreSeekActiveID = (input.activeID != nil && input.activeID != tappedID)
                ? input.activeID : nil
            updateFade(animated: animates, interfaceHidden: false)
            align(to: index, cascade: animates, animated: animates,
                  spring: motion.lineChangeSpring, interfaceHidden: false,
                  appearanceAnimated: animates, endsBrowsing: true)
        } else {
            browsing = false
            suppressedPreSeekActiveID = nil
            needsFocus = true
            setNeedsLayout()
        }
    }

    /// Same path as a row tap; kept internal for regression coverage.
    func performSeek(row: Int) {
        seek(row)
    }

    var visibleLineIDs: [Int] {
        visibleRows.compactMap { cell in
            guard let row = indexPath(for: cell)?.row,
                  renderedLines.indices.contains(row) else { return nil }
            return renderedLines[row].id
        }
    }

    var renderedLineCount: Int { renderedLines.count }

    /// Visible boundary height and its transition state, exposed for interaction regressions.
    var interfaceFadeHeight: CGFloat { fadeBottom }
    var isInterfaceFadeAnimating: Bool { fadeAnimator != nil }
    var isRowTransitionAnimating: Bool { !animators.isEmpty }
    /// Current animated viewport position of a row, used to assert the starting edge of a seek.
    func transitionViewportTop(forRow row: Int) -> CGFloat? {
        guard let cell = displayedCell(forRow: row) else { return nil }
        return cell.center.y - cell.bounds.height / 2 + cell.transform.ty
            - contentOffset.y - Self.viewportOverscan
    }

    /// Pre-commit transform captured before UIKit replaces the model value with its target.
    func pendingTransitionViewportTop(forRow row: Int) -> CGFloat? {
        guard let cell = displayedCell(forRow: row),
              let transform = pendingStartTransforms[ObjectIdentifier(cell)] else { return nil }
        return cell.center.y - cell.bounds.height / 2 + transform.ty
            - contentOffset.y - Self.viewportOverscan
    }

    func rowDistanceBlurRadius(forRow row: Int) -> Double? {
        displayedCell(forRow: row)?.appearance.distanceBlurRadius
    }

    func isRowBrowsingAppearanceActive(forRow row: Int) -> Bool? {
        displayedCell(forRow: row)?.appearance.browsing
    }

    func presentationViewportTop(forRow row: Int) -> CGFloat? {
        guard let cell = displayedCell(forRow: row) else { return nil }
        return visualMinY(for: cell, presentation: !animators.isEmpty)
            - contentOffset.y - Self.viewportOverscan
    }

    /// Font-derived line height used by the focus formula; exposed for tests.
    var focusLineHeight: CGFloat {
        LyricsFontMetrics.boldLineHeight(size: input?.fontSize ?? 0)
    }

    private func settleRunningAnimationsForDrag() {
        removeSourceSnapshots()
        guard !animators.isEmpty else { return }
        freezeRows()
        UIView.performWithoutAnimation {
            for cell in visibleRows where cell.transform != .identity {
                cell.transform = .identity
            }
        }
        stopDisplayLinkIfIdle()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        settleRunningAnimationsForDrag()
        suppressedPreSeekActiveID = nil
        browsing = true
        resumeTask?.cancel()
        if !reportsUserInteraction {
            reportsUserInteraction = true
            onUserInteractionChange?(true)
        }
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
        if !decelerate {
            endUserInteractionIfNeeded()
            stopDisplayLinkIfIdle()
            resumeFollowing()
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        endUserInteractionIfNeeded()
        stopDisplayLinkIfIdle()
        resumeFollowing()
    }
    private func endUserInteractionIfNeeded() {
        guard reportsUserInteraction else { return }
        reportsUserInteraction = false
        onUserInteractionChange?(false)
    }
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
        endUserInteractionIfNeeded()
        fadePendingStartHeight = nil
        fadeTargetHeight = nil
        freezeRows()
        cancelAllAnimations()
        fadeAnimator?.stopAnimation(true)
        fadeAnimator = nil
        displayLink?.invalidate()
        displayLink = nil
        visibility.end()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let input else { return false }
        let bottom = fadeBottom
        let visualTop = bounds.minY + Self.viewportOverscan
        return super.point(inside: point, with: event)
            && point.y >= visualTop + input.topOverlayHeight
            && point.y <= visualTop + bottom
    }
}
