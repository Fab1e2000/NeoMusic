import SwiftUI
import UIKit

@Observable final class LyricsRowAppearance {
    var focused = false
    var distanceBlurRadius: Double = 0
    var browsing = false
    var reducesMotion = false
    var increasedContrast = false
    var showsTranslation = false
    // Read alongside focus/opacity changes; changing timing alone must not redraw every row.
    @ObservationIgnored var animated = false
    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onPressStateChange: ((Bool) -> Void)?
}

private struct LyricsInterludeDots: View {
    let focused: Bool
    let reducesMotion: Bool
    let fontSize: CGFloat

    @State private var pulse = false

    var body: some View {
        let dotSize = max(8, fontSize * 0.28)
        HStack(spacing: dotSize * 0.85) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(focused && !reducesMotion ? (pulse ? 1.06 : 0.92) : 0.94)
                    .opacity(focused ? (pulse ? 0.95 : 0.55) : 0.45)
                    .animation(
                        focused && !reducesMotion
                            ? .easeInOut(duration: 1.1)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.18)
                            : .easeOut(duration: 0.2),
                        value: pulse
                    )
            }
        }
        .padding(.leading, 2)
        .padding(.vertical, max(4, fontSize * 0.16))
        .accessibilityLabel("间奏")
        .onAppear {
            if focused && !reducesMotion { pulse = true }
        }
        .onChange(of: focused) { _, isFocused in
            pulse = isFocused && !reducesMotion
        }
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
        let trimmedText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = appearance.showsTranslation
            ? line.translation.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let translationOpacity = appearance.focused
            ? typography.translationOpacity
            : min(0.85, typography.translationOpacity * 1.45)
        LyricPressInteraction(
            isSelected: false,
            allowsLongPress: false,
            scaleAnchor: .center,
            onTap: onTap,
            onLongPress: {},
            onPressStateChange: { appearance.onPressStateChange?($0) }
        ) { progress in
            VStack(alignment: .leading, spacing: 0) {
                if trimmedText.isEmpty {
                    LyricsInterludeDots(
                        focused: appearance.focused,
                        reducesMotion: appearance.reducesMotion,
                        fontSize: fontSize
                    )
                } else {
                    Text(line.text)
                        .font(.system(size: fontSize, weight: .bold))
                }
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

/// Animate focus independently so per-frame distance updates retain the 120ms focus curve.
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
    // Keep the blur halo inside the hosting surface even if an internal host clips.
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
        // iOS 27 installs UIHostingConfiguration's content view directly on
        // the cell; earlier versions put it in contentView.
        subviews.first { $0 is any UIContentView }
            ?? subviews.first { $0 !== contentView }
            ?? contentView.subviews.first
    }

    func configure(line: PlayerLyricLine, fontSize: CGFloat, translationFontSize: CGFloat,
                   showsTranslation: Bool, foreground: Color, spacing: CGFloat,
                   focused: Bool, browsing: Bool, reducesMotion: Bool, increasedContrast: Bool,
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

    func updateShowsTranslation(_ showsTranslation: Bool) {
        guard appearance.showsTranslation != showsTranslation else { return }
        appearance.showsTranslation = showsTranslation
        needsFadeTargetDiscovery = true
    }

    override func prepareForReuse() {
        onPrepareForReuse?()
        isMoving = false
        transform = .identity
        appearance.animated = false
        appearance.focused = false
        appearance.browsing = false
        appearance.reducesMotion = false
        appearance.increasedContrast = false
        appearance.showsTranslation = false
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
        // Hosting sizes settle during layout. Let the owner run one more pass
        // so focus correction and edge masks see the final row height.
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
        // Rows overlapping the top/bottom fade zone may gain dynamic press-highlight
        // backing layers on touch; re-discover targets so the highlight is always masked.
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

    /// The table's content coordinates are shifted by its vertical overscan.
    func shifted(by offset: CGFloat) -> LyricsViewportFade {
        var shifted = self
        shifted.topStart += offset
        shifted.topEnd += offset
        shifted.bottomStart += offset
        shifted.bottomEnd += offset
        return shifted
    }
}
