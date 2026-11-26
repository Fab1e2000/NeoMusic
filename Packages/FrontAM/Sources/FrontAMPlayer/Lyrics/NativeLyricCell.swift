import SwiftUI
import UIKit

nonisolated struct LyricsInterludeInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }
}

nonisolated struct LyricsInterludeFrame: Equatable, Sendable {
    let scale: Double
    let groupOpacity: Double
    let dot1Opacity: Double
    let dot2Opacity: Double
    let dot3Opacity: Double

    func dotOpacity(at index: Int) -> Double {
        switch index {
        case 0: dot1Opacity
        case 1: dot2Opacity
        default: dot3Opacity
        }
    }
}

nonisolated enum LyricsInterludeTimeline {
    static let baseDotOpacity: Double = 0.30
    static let increasedContrastBaseDotOpacity: Double = 0.45
    static let litDotOpacity: Double = 1.0
    static let maxEntranceDuration: TimeInterval = 1.20
    static let entranceDurationFraction: Double = 0.22
    static let maxAnticipationDuration: TimeInterval = 0.55
    static let maxShrinkDuration: TimeInterval = 0.45
    static let exitDurationFraction: Double = 0.28
    static let exitLeadClearance: TimeInterval = 0.04
    static let breathingPeriod: TimeInterval = 4.50
    static let breathingAmplitude: Double = 0.09
    static let anticipationPeakScale: Double = 1.25

    static func dotDiameter(forFontSize fontSize: CGFloat) -> CGFloat {
        max(9, fontSize * (12.5 / 34.0))
    }

    static func dotSpacing(forFontSize fontSize: CGFloat) -> CGFloat {
        max(6, fontSize * (8.0 / 34.0))
    }

    static func evaluate(
        at time: TimeInterval,
        interval: LyricsInterludeInterval,
        reducesMotion: Bool = false,
        increasedContrast: Bool = false
    ) -> LyricsInterludeFrame {
        let baseOpacity = increasedContrast ? increasedContrastBaseDotOpacity : baseDotOpacity
        let total = interval.duration
        guard total > 0.01 else {
            return LyricsInterludeFrame(
                scale: 1,
                groupOpacity: 1,
                dot1Opacity: baseOpacity,
                dot2Opacity: baseOpacity,
                dot3Opacity: baseOpacity
            )
        }

        let clearance = min(exitLeadClearance, total * 0.05)
        let effectiveDuration = max(0.01, total - clearance)
        let elapsed = time - interval.start

        if elapsed <= 0 {
            return LyricsInterludeFrame(
                scale: reducesMotion ? 1 : 0,
                groupOpacity: 0,
                dot1Opacity: baseOpacity,
                dot2Opacity: baseOpacity,
                dot3Opacity: baseOpacity
            )
        }

        if elapsed >= effectiveDuration {
            return LyricsInterludeFrame(
                scale: reducesMotion ? 1 : 0,
                groupOpacity: 0,
                dot1Opacity: litDotOpacity,
                dot2Opacity: litDotOpacity,
                dot3Opacity: litDotOpacity
            )
        }

        let entranceDuration = min(maxEntranceDuration, effectiveDuration * entranceDurationFraction)
        let maxExitDuration = maxAnticipationDuration + maxShrinkDuration
        let exitBudget = min(maxExitDuration, effectiveDuration * exitDurationFraction)
        let shrinkDuration = exitBudget * (maxShrinkDuration / maxExitDuration)
        let anticipationDuration = exitBudget - shrinkDuration
        let exitStart = max(entranceDuration, effectiveDuration - exitBudget)
        let shrinkStart = effectiveDuration - shrinkDuration

        let progressSpan = max(exitStart - entranceDuration, 0.001)
        let progress = clamp01((elapsed - entranceDuration) / progressSpan)
        let dot1 = baseOpacity + (litDotOpacity - baseOpacity) * clamp01(progress * 3.0)
        let dot2 = baseOpacity + (litDotOpacity - baseOpacity) * clamp01(progress * 3.0 - 1.0)
        let dot3 = baseOpacity + (litDotOpacity - baseOpacity) * clamp01(progress * 3.0 - 2.0)

        let entranceFraction = entranceDuration > 0 ? clamp01(elapsed / entranceDuration) : 1
        let entranceOpacity = smoothstep(entranceFraction)

        if reducesMotion {
            let groupOpacity: Double
            if elapsed < entranceDuration {
                groupOpacity = entranceOpacity
            } else if elapsed >= shrinkStart {
                let p = shrinkDuration > 0 ? clamp01((elapsed - shrinkStart) / shrinkDuration) : 1
                groupOpacity = 1.0 - smoothstep(p)
            } else {
                groupOpacity = 1.0
            }
            return LyricsInterludeFrame(
                scale: 1.0,
                groupOpacity: groupOpacity,
                dot1Opacity: dot1,
                dot2Opacity: dot2,
                dot3Opacity: dot3
            )
        }

        let scale: Double
        let groupOpacity: Double

        if elapsed < exitStart {
            let entranceScale = elapsed < entranceDuration
                ? 1.0 - pow(1.0 - entranceFraction, 3.0)
                : 1.0
            scale = entranceScale * breathingScale(at: elapsed)
            groupOpacity = elapsed < entranceDuration ? entranceOpacity : 1.0
        } else if elapsed < shrinkStart {
            let q = anticipationDuration > 0 ? clamp01((elapsed - exitStart) / anticipationDuration) : 1
            let startScale = breathingScale(at: exitStart)
            let startTangent = breathingVelocity(at: exitStart) * anticipationDuration
            scale = hermite(q, p0: startScale, m0: startTangent, p1: anticipationPeakScale, m1: 0)
            groupOpacity = 1.0
        } else {
            let p = shrinkDuration > 0 ? clamp01((elapsed - shrinkStart) / shrinkDuration) : 1
            scale = anticipationPeakScale * (1.0 - p * p)
            let fadeP = clamp01((p - 0.25) / 0.75)
            groupOpacity = 1.0 - smoothstep(fadeP)
        }

        return LyricsInterludeFrame(
            scale: max(0, scale),
            groupOpacity: clamp01(groupOpacity),
            dot1Opacity: dot1,
            dot2Opacity: dot2,
            dot3Opacity: dot3
        )
    }

    static func breathingScale(at elapsed: TimeInterval) -> Double {
        1.0 + breathingAmplitude * sin(2.0 * .pi * elapsed / breathingPeriod)
    }

    private static func breathingVelocity(at elapsed: TimeInterval) -> Double {
        breathingAmplitude * (2.0 * .pi / breathingPeriod)
            * cos(2.0 * .pi * elapsed / breathingPeriod)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3.0 - 2.0 * t)
    }

    private static func hermite(_ t: Double, p0: Double, m0: Double, p1: Double, m1: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
    }
}

@Observable final class LyricsRowAppearance {
    var focused = false
    var distanceBlurRadius: Double = 0
    var browsing = false
    var reducesMotion = false
    var increasedContrast = false
    var showsTranslation = false
    var isPageActive = true
    var timelineAnchor: PlayerTimelineAnchor = .zero
    var interludeInterval: LyricsInterludeInterval?
    @ObservationIgnored var animated = false
    @ObservationIgnored var progressInteraction: NowPlayingProgressInteraction?
    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onPressStateChange: ((Bool) -> Void)?
}

private struct LyricsInterludeDots: View {
    let appearance: LyricsRowAppearance
    let foreground: Color
    let fontSize: CGFloat

    var body: some View {
        let dotSize = LyricsInterludeTimeline.dotDiameter(forFontSize: fontSize)
        let dotSpacing = LyricsInterludeTimeline.dotSpacing(forFontSize: fontSize)
        let rowHeight = LyricsFontMetrics.boldLineHeight(size: max(fontSize, 1))
        let interaction = appearance.progressInteraction
        let scrubbingTime = interaction?.scrubbingProgress
        let awaitingCommit = interaction?.isAwaitingCommittedSeek == true
        let anchor = appearance.timelineAnchor
        let animatesLive = appearance.focused
            && appearance.isPageActive
            && appearance.interludeInterval != nil
            && anchor.rate > 0
            && scrubbingTime == nil
            && !awaitingCommit

        Group {
            if let interval = appearance.interludeInterval, appearance.focused {
                if animatesLive {
                    TimelineView(.animation) { _ in
                        let headstart = AppleMusicLyricsMotionProfile.iOS26_6.animationHeadstart
                        let frame = LyricsInterludeTimeline.evaluate(
                            at: anchor.elapsed() + headstart,
                            interval: interval,
                            reducesMotion: appearance.reducesMotion,
                            increasedContrast: appearance.increasedContrast
                        )
                        dotsRow(frame: frame, dotSize: dotSize, dotSpacing: dotSpacing)
                    }
                } else {
                    let staticTime: TimeInterval = if let scrubbingTime {
                        scrubbingTime
                    } else if awaitingCommit, let interaction {
                        interaction.displayProgress(live: anchor.elapsed())
                    } else {
                        anchor.elapsed()
                    }
                    let frame = LyricsInterludeTimeline.evaluate(
                        at: staticTime,
                        interval: interval,
                        reducesMotion: appearance.reducesMotion,
                        increasedContrast: appearance.increasedContrast
                    )
                    dotsRow(frame: frame, dotSize: dotSize, dotSpacing: dotSpacing)
                }
            } else {
                Color.clear
                    .frame(width: 3 * dotSize + 2 * dotSpacing, height: dotSize)
            }
        }
        .frame(height: rowHeight, alignment: .center)
        .accessibilityLabel(playerText("间奏"))
    }

    private func dotsRow(frame: LyricsInterludeFrame, dotSize: CGFloat, dotSpacing: CGFloat) -> some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(foreground.opacity(frame.dotOpacity(at: index) * frame.groupOpacity))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .scaleEffect(frame.scale, anchor: .center)
    }
}

private struct LocalLyricsRow: View {
    let line: PlayerLyricLine
    let fontSize: CGFloat
    let translationFontSize: CGFloat
    let foreground: Color
    let appearance: LyricsRowAppearance
    let onTap: () -> Void
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private let typography = AppleMusicLyricsTypographyProfile.iOS26_6

    var body: some View {
        let trimmedText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isInterlude = trimmedText.isEmpty
        let radius = isInterlude || appearance.browsing || appearance.reducesMotion || appearance.increasedContrast
            ? 0 : appearance.distanceBlurRadius
        let opacity = isInterlude ? 1 : (appearance.focused ? 1 : (appearance.browsing ? NowPlayingVisualHierarchy.lyricBrowsingOpacity
            : (appearance.increasedContrast ? motion.increasedContrastDeselectedTextOpacity
                : NowPlayingVisualHierarchy.lyricInactiveBlurredOpacity)))
        let animation: Animation? = appearance.animated && !appearance.reducesMotion ? .timingCurve(
            motion.focusBlurTransitionControlPoint1X, motion.focusBlurTransitionControlPoint1Y,
            motion.focusBlurTransitionControlPoint2X, motion.focusBlurTransitionControlPoint2Y,
            duration: motion.focusBlurTransitionDuration) : nil
        let backgroundHorizontalOutset = min(14, fontSize * 0.42)
        let backgroundVerticalOutset = min(14, fontSize * 0.42)
        let backgroundCornerRadius = min(16, fontSize * 0.47)
        let translation = appearance.showsTranslation
            ? line.translation.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let translationOpacity = appearance.focused
            ? typography.translationOpacity
            : min(0.85, typography.translationOpacity * 1.45)

        if isInterlude {
            LyricsInterludeDots(
                appearance: appearance,
                foreground: foreground,
                fontSize: fontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .blendMode(foreground == .white ? .plusLighter : .normal)
            .accessibilityAddTraits(appearance.focused ? .isSelected : [])
        } else {
            LyricPressInteraction(
                isSelected: false,
                allowsLongPress: false,
                scaleAnchor: .center,
                onTap: onTap,
                onLongPress: {},
                onPressStateChange: { appearance.onPressStateChange?($0) }
            ) { progress in
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.text)
                        .font(.system(size: fontSize, weight: .bold))
                    if !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: translationFontSize, weight: .medium))
                            .opacity(translationOpacity)
                            .padding(.top, typography.translationTopSpacing)
                            .accessibilityIdentifier("lyric.translation")
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(foreground.opacity(opacity))
                .modifier(LyricsFocusBlur(radius: radius, amount: appearance.focused ? 0 : 1))
                .blendMode(foreground == .white ? .plusLighter : .normal)
                .background {
                    RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                        .fill(foreground.opacity(progress * 0.12))
                        .blendMode(foreground == .white ? .plusLighter : .normal)
                        .padding(.horizontal, -backgroundHorizontalOutset)
                        .padding(.vertical, -backgroundVerticalOutset)
                }
            }
            .scaleEffect(appearance.focused ? 1 : motion.deselectedScale, anchor: .topLeading)
            .animation(
                appearance.animated && !appearance.reducesMotion
                    ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.25) : nil,
                value: appearance.focused
            )
            .animation(animation, value: opacity)
            .animation(animation, value: radius)
            .accessibilityAddTraits(appearance.focused ? .isSelected : [])
        }
    }
}

nonisolated private struct LyricsFocusBlur: ViewModifier, Animatable {
    var radius: Double
    var amount: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(radius, amount) }
        set {
            radius = newValue.first
            amount = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.blur(radius: radius * amount)
    }
}

final class NativeLyricCell: UITableViewCell {
    static let reuseIdentifier = "NativeLyricCell"
    static let horizontalBleed = NativeLyricsScrollView.horizontalBleed
    let appearance = LyricsRowAppearance()
    var onPrepareForReuse: (() -> Void)?
    var isMoving = false
    private let cachedFadeTargets = NSPointerArray.weakObjects()
    private var needsFadeTargetDiscovery = true
    private var hasActiveEdgeMask = false
    private var contentShouldBeHidden = false
    private var lastLayoutHeight: CGFloat = -1

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false
        selectionStyle = .none
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { nil }

    var contentHost: UIView? {
        subviews.first { $0 is any UIContentView }
            ?? subviews.first { $0 !== contentView }
            ?? contentView.subviews.first
    }

    func configure(line: PlayerLyricLine, fontSize: CGFloat, translationFontSize: CGFloat,
                   showsTranslation: Bool, foreground: Color, spacing: CGFloat,
                   focused: Bool, browsing: Bool, reducesMotion: Bool, increasedContrast: Bool,
                   isPageActive: Bool = true,
                   timelineAnchor: PlayerTimelineAnchor = .zero,
                   interludeInterval: LyricsInterludeInterval? = nil,
                   progressInteraction: NowPlayingProgressInteraction? = nil,
                   initialBlurRadius: Double = 0,
                   preservesMotion: Bool = false) {
        if !preservesMotion {
            appearance.animated = false
            appearance.distanceBlurRadius = initialBlurRadius
        }
        appearance.focused = focused
        appearance.browsing = browsing
        appearance.reducesMotion = reducesMotion
        appearance.increasedContrast = increasedContrast
        appearance.showsTranslation = showsTranslation
        appearance.isPageActive = isPageActive
        appearance.timelineAnchor = timelineAnchor
        appearance.interludeInterval = interludeInterval
        appearance.progressInteraction = progressInteraction
        isHidden = false
        isUserInteractionEnabled = interludeInterval == nil
        accessibilityElementsHidden = false
        needsFadeTargetDiscovery = true
        lastLayoutHeight = -1
        let appearance = self.appearance
        contentConfiguration = UIHostingConfiguration {
            LocalLyricsRow(
                line: line, fontSize: fontSize, translationFontSize: translationFontSize,
                foreground: foreground,
                appearance: appearance
            ) {
                appearance.onTap?()
            }
            .padding(.horizontal, Self.horizontalBleed)
            .padding(.bottom, spacing)
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }

    func configureCollapsed() {
        appearance.animated = false
        appearance.focused = false
        appearance.interludeInterval = nil
        appearance.progressInteraction = nil
        appearance.onTap = nil
        appearance.onPressStateChange = nil
        contentConfiguration = nil
        removeEdgeMask(in: layer)
        hasActiveEdgeMask = false
        cachedFadeTargets.count = 0
        needsFadeTargetDiscovery = true
        lastLayoutHeight = 0
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        setContentHidden(true)
    }

    func updateShowsTranslation(_ showsTranslation: Bool) {
        guard appearance.showsTranslation != showsTranslation else { return }
        appearance.showsTranslation = showsTranslation
        needsFadeTargetDiscovery = true
    }

    override func prepareForReuse() {
        onPrepareForReuse?()
        isMoving = false
        transform = .identity
        isHidden = false
        isUserInteractionEnabled = true
        accessibilityElementsHidden = false
        appearance.animated = false
        appearance.focused = false
        appearance.browsing = false
        appearance.reducesMotion = false
        appearance.increasedContrast = false
        appearance.showsTranslation = false
        appearance.isPageActive = true
        appearance.timelineAnchor = .zero
        appearance.interludeInterval = nil
        appearance.progressInteraction = nil
        appearance.distanceBlurRadius = 0
        appearance.onTap = nil
        appearance.onPressStateChange = nil
        removeEdgeMask(in: layer)
        hasActiveEdgeMask = false
        cachedFadeTargets.count = 0
        needsFadeTargetDiscovery = true
        setContentHidden(false)
        super.prepareForReuse()
    }

    func setContentHidden(_ hidden: Bool) {
        contentShouldBeHidden = hidden
        contentHost?.isHidden = hidden
    }

    var isContentHidden: Bool {
        contentShouldBeHidden
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentHost?.isHidden = contentShouldBeHidden
        needsFadeTargetDiscovery = true
        if abs(bounds.height - lastLayoutHeight) > 0.5 {
            lastLayoutHeight = bounds.height
            (superview as? NativeLyricsScrollView)?.setNeedsLayout()
        }
    }

    func invalidateFadeTargets() {
        needsFadeTargetDiscovery = true
    }

    func applyEdgeFade(_ fade: LyricsViewportFade, viewportTop: CGFloat, in scroll: UIScrollView, presentation: Bool) {
        if !presentation, viewportTop >= fade.topEnd, viewportTop + bounds.height <= fade.bottomStart {
            guard hasActiveEdgeMask else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeEdgeMask(in: layer)
            CATransaction.commit()
            hasActiveEdgeMask = false
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inEdgeFadeZone = viewportTop < fade.topEnd || viewportTop + bounds.height > fade.bottomStart
        var targets = cachedFadeTargets.allObjects.compactMap { $0 as? CALayer }.filter { $0.superlayer != nil }
        if needsFadeTargetDiscovery || inEdgeFadeZone || targets.isEmpty {
            targets.removeAll(keepingCapacity: true)
            collectTargets(in: layer, targets: &targets)
            cachedFadeTargets.count = 0
            for target in targets {
                cachedFadeTargets.addPointer(Unmanaged.passUnretained(target).toOpaque())
            }
            needsFadeTargetDiscovery = false
        }
        hasActiveEdgeMask = !targets.isEmpty
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

final class LyricsEdgeMaskLayer: CAGradientLayer {
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
    static let topFadeHeight: CGFloat = 68
    static let shownBottomFadeHeight: CGFloat = 160
    static let hiddenBottomFadeHeight: CGFloat = 175
    private static let minimumShownBottomFadeHeight: CGFloat = 56

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
        topEnd = min(topStart + Self.topFadeHeight, bottomEnd)
        let shownBottom = shownReferenceHeight ?? referenceHeight
        let overlayShownFade = min(
            Self.shownBottomFadeHeight,
            max(Self.minimumShownBottomFadeHeight, max(shownBottom - topEnd, 0) * 0.48)
        )
        let span = height - shownBottom
        let hiddenFraction: CGFloat = span > 0.5
            ? min(max((bottomEnd - shownBottom) / span, 0), 1)
            : 1
        let bottomFade = overlayShownFade
            + (Self.hiddenBottomFadeHeight - overlayShownFade) * hiddenFraction
        bottomStart = max(topEnd, bottomEnd - bottomFade)
    }

    func shifted(by offset: CGFloat) -> LyricsViewportFade {
        var shifted = self
        shifted.topStart += offset
        shifted.topEnd += offset
        shifted.bottomStart += offset
        shifted.bottomEnd += offset
        return shifted
    }
}
