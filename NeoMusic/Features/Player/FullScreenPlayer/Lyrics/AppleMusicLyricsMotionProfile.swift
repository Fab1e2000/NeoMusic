// Ported from youshen2/MeloX (GPL-3.0), commit 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import Foundation

/// Internal reconstruction of motion constants observed in Apple Music 26.6.
/// Property names describe inferred behavior; they are not public Apple API.
nonisolated struct AppleMusicLyricsMotionProfile: Equatable, Sendable {
    let firstLineStartOffset: Double
    /// Percentage of the effective viewport height used for synced-line
    /// positioning before subtracting the lyric font ascender.
    let selectedLineTopRelativePercent: Double
    /// Static-mode vertical insets; these do not combine with synced mode.
    let staticTopContentInset: Double
    let staticBottomContentInset: Double
    let paragraphSpacing: Double
    let lineSpacing: Double
    let backgroundVocalsTopSpacing: Double
    let backgroundVocalsDeselectedScale: Double
    let backgroundVocalsFontCoefficient: Double
    let translationBackgroundVocalsFontCoefficient: Double
    let transliterationBackgroundVocalsFontCoefficient: Double
    let cascadeDelay: TimeInterval
    let deselectedScale: Double
    let nonFocusedBlurRadius: Double
    let maximumNonFocusedBlurRadius: Double
    let selectedTextOpacity: Double
    let selectedUpcomingTextOpacity: Double
    let deselectedTextOpacity: Double
    let increasedContrastSelectedTextOpacity: Double
    let increasedContrastSelectedUpcomingTextOpacity: Double
    let increasedContrastDeselectedTextOpacity: Double
    /// The native line-focus blur animator also drives its brightness filter.
    let focusBlurTransitionDuration: TimeInterval
    let focusBlurTransitionControlPoint1X: Double
    let focusBlurTransitionControlPoint1Y: Double
    let focusBlurTransitionControlPoint2X: Double
    let focusBlurTransitionControlPoint2Y: Double
    let animationHeadstart: TimeInterval
    /// Timed glyph/syllable emphasis range. Never scale the complete row.
    let emphasisScaleRange: ClosedRange<Double>
    let lineFinishProgressAnimationDuration: TimeInterval
    let lineProgressionGradientFeather: Double
    let glowRadius: Double
    let syllableLift: Double
    /// Default focus and line-change solver values observed in Lyrics.Specs.
    let lineChangeSpring: LyricPhysicalSpringParameters
    /// Solver values observed on the forced/special line catch-up path.
    let forcedLineCatchUpSpring: LyricPhysicalSpringParameters
    /// Translation/transliteration reveal solver values.
    let supplementalTextShowSpring: LyricPhysicalSpringParameters
    /// Translation/transliteration removal solver values.
    let supplementalTextHideSpring: LyricPhysicalSpringParameters

    static let iOS26_6 = Self(
        firstLineStartOffset: 60,
        selectedLineTopRelativePercent: 12,
        staticTopContentInset: 22,
        staticBottomContentInset: 30,
        paragraphSpacing: 39,
        lineSpacing: 25,
        backgroundVocalsTopSpacing: 15,
        backgroundVocalsDeselectedScale: 0.9,
        backgroundVocalsFontCoefficient: 0.63,
        translationBackgroundVocalsFontCoefficient: 0.36,
        transliterationBackgroundVocalsFontCoefficient: 0.27,
        cascadeDelay: 0.05,
        deselectedScale: 0.98,
        nonFocusedBlurRadius: 2.0,
        maximumNonFocusedBlurRadius: 4.25,
        selectedTextOpacity: 1,
        selectedUpcomingTextOpacity: 0.35,
        deselectedTextOpacity: 0.175,
        increasedContrastSelectedTextOpacity: 1,
        increasedContrastSelectedUpcomingTextOpacity: 0.85,
        increasedContrastDeselectedTextOpacity: 0.4,
        focusBlurTransitionDuration: 0.26,
        focusBlurTransitionControlPoint1X: 0.25,
        focusBlurTransitionControlPoint1Y: 0.1,
        focusBlurTransitionControlPoint2X: 0.25,
        focusBlurTransitionControlPoint2Y: 1.0,
        animationHeadstart: 0.1,
        emphasisScaleRange: 1...1.14,
        lineFinishProgressAnimationDuration: 0.25,
        lineProgressionGradientFeather: 30,
        glowRadius: 5,
        syllableLift: 2,
        lineChangeSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 100,
            damping: 18
        ),
        forcedLineCatchUpSpring: LyricPhysicalSpringParameters(
            mass: 2,
            stiffness: 260,
            damping: 50
        ),
        supplementalTextShowSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 150,
            damping: 30
        ),
        supplementalTextHideSpring: LyricPhysicalSpringParameters(
            mass: 1,
            stiffness: 130,
            damping: 30
        )
    )

    var lineChangeDuration: TimeInterval { 0.30 }

    func isForwardLineChange(from previous: Int?, to next: Int?) -> Bool {
        guard let previous, let next else { return false }
        return next == previous + 1
    }

    func lineChangeDelay(rowIndex: Int, activeIndex: Int) -> TimeInterval {
        Double(max(rowIndex - activeIndex, 0)) * cascadeDelay
    }

    /// Paragraph-index blur progression using the same smoothstep falloff:
    /// upcoming rows ease from `nonFocusedBlurRadius` to `maximumNonFocusedBlurRadius`
    /// independent of active row wrapping, while past rows blur one step sooner.
    func blurRadius(rowOffset: Int) -> Double {
        if rowOffset == 0 { return 0 }
        let step = rowOffset < 0 ? Double(-rowOffset) : Double(rowOffset - 1)
        let far = min(max(step / 2, 0), 1)
        let farCurve = far * far * (3 - 2 * far)
        return nonFocusedBlurRadius
            + (maximumNonFocusedBlurRadius - nonFocusedBlurRadius) * farCurve
    }

    /// Distance between the leading lines, normalized for the displayed font size.
    /// Wrapped paragraphs therefore contribute their full height to the falloff.
    func blurRadius(verticalDistance: Double, lineHeight: Double) -> Double {
        let distance = abs(verticalDistance) / max(lineHeight + lineSpacing, 1)
        let near = min(distance, 1)
        let far = min(max((distance - 1) / 2, 0), 1)
        let nearCurve = near * near * (3 - 2 * near)
        let farCurve = far * far * (3 - 2 * far)
        return nonFocusedBlurRadius * nearCurve
            + (maximumNonFocusedBlurRadius - nonFocusedBlurRadius) * farCurve
    }
}
