// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

/// Timing fitted frame-by-frame against 60 fps Apple Music device recordings.
struct NowPlayingHighlightTiming {
    let duration: TimeInterval
    let delay: TimeInterval
    let easesOutOnly: Bool

    var animation: Animation {
        (easesOutOnly ? Animation.easeOut(duration: duration) : .easeInOut(duration: duration)).delay(delay)
    }

    var uiKitOptions: UIView.AnimationOptions {
        [.allowUserInteraction, .beginFromCurrentState, easesOutOnly ? .curveEaseOut : .curveEaseInOut]
    }
}

struct NowPlayingHighlightFeedback {
    let press: NowPlayingHighlightTiming
    let release: NowPlayingHighlightTiming

    func timing(highlighted: Bool) -> NowPlayingHighlightTiming { highlighted ? press : release }
}

enum NowPlayingProgressFeedbackSpec {
    static let restBarHeight: CGFloat = 7
    static let pressedBarHeight: CGFloat = 50.0 / 3.0
    static let pressedHorizontalScale: CGFloat = 1064.0 / 1014.0
    static let pressedTimeVerticalOffset: CGFloat = 9.41 / 3.0
    static let pressSpring = Animation.spring(Spring(response: 0.38, dampingRatio: 0.73))
    static let releaseSpring = Animation.spring(Spring(response: 0.41, dampingRatio: 0.61))
    /// Brightening finishes before the bar settles; dimming waits briefly after release.
    static let progressHighlight = NowPlayingHighlightFeedback(
        press: NowPlayingHighlightTiming(duration: 0.14, delay: 0, easesOutOnly: false),
        release: NowPlayingHighlightTiming(duration: 0.15, delay: 0.05, easesOutOnly: true)
    )
    static let volumeHighlight = NowPlayingHighlightFeedback(
        press: NowPlayingHighlightTiming(duration: 0.09, delay: 0, easesOutOnly: false),
        release: NowPlayingHighlightTiming(duration: 0.13, delay: 0.08, easesOutOnly: true)
    )
    /// Post-release volume flick deceleration fitted against 60 fps Apple Music recordings (`tau ≈ 82 ms`).
    static let volumeInertiaTimeConstant: TimeInterval = 0.082
    static let volumeInertiaStopVelocity: Float = 0.015
    static let volumeMinimumFlickVelocity: Float = 0.15
}

@MainActor @Observable
final class NowPlayingProgressInteraction {
    var isPressed = false
    var scrubbingProgress: TimeInterval?
    /// Retains the just-committed seek target briefly until async player progress catches up.
    var committedSeekProgress: TimeInterval?
    var committedSeekDeadline: ContinuousClock.Instant?

    func displayProgress(live: TimeInterval) -> TimeInterval {
        if let scrubbingProgress { return scrubbingProgress }
        if let committed = committedSeekProgress, let deadline = committedSeekDeadline {
            if abs(live - committed) <= 1.0 || ContinuousClock.now >= deadline {
                return live
            }
            return committed
        }
        return live
    }

    var isAwaitingCommittedSeek: Bool {
        guard let deadline = committedSeekDeadline, committedSeekProgress != nil else { return false }
        return ContinuousClock.now < deadline
    }

    func resetForTrackChange() {
        isPressed = false
        scrubbingProgress = nil
        committedSeekProgress = nil
        committedSeekDeadline = nil
    }
}

struct NowPlayingProgressControl: View {
    @Environment(PlayerState.self) private var player
    @Environment(PlayerActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var timeFontSize: CGFloat = 12.5

    @Environment(\.nowPlayingLayout) private var layout
    @Environment(NowPlayingProgressInteraction.self) private var sharedInteraction: NowPlayingProgressInteraction?
    @State private var localInteraction = NowPlayingProgressInteraction()
    let song: PlayerTrack

    private var interaction: NowPlayingProgressInteraction {
        sharedInteraction ?? localInteraction
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                progressSlider(allowsSpatialExpansion: false)
                timeLabels(allowsSpatialExpansion: false)
                progressStatus(allowsSpatialExpansion: false)
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            referenceLayout
        }
    }

    private var referenceLayout: some View {
        GeometryReader { proxy in
            ZStack {
            progressSlider(allowsSpatialExpansion: true)
            .frame(width: layout.width(338))
            .position(x: proxy.size.width / 2, y: 26 - 10.5 * layout.verticalScale)

            timeLabels(allowsSpatialExpansion: true)
            .frame(width: layout.width(337.5), height: timeLineHeight)
            .overlay { progressStatus(allowsSpatialExpansion: true) }
            .position(x: proxy.size.width / 2, y: 26 + 10.5 * layout.verticalScale + (timeLineHeight - 18) / 2)
            }
        }
        .frame(height: timeLineHeight + 34)
    }

    private func progressSlider(allowsSpatialExpansion: Bool) -> some View {
        NowPlayingProgressSliderView(
            maximum: progressMaximum,
            interaction: interaction,
            allowsSpatialExpansion: allowsSpatialExpansion
        )
    }

    private func timeLabels(allowsSpatialExpansion: Bool) -> some View {
        NowPlayingTimeLabels(
            fontSize: timeFontSize,
            interaction: interaction,
            allowsSpatialExpansion: allowsSpatialExpansion
        )
    }

    private var timeLineHeight: CGFloat { max(18, timeFontSize * 1.3) }

    private func progressStatus(allowsSpatialExpansion: Bool) -> some View {
        NowPlayingProgressStatusView(
            interaction: interaction,
            allowsSpatialExpansion: allowsSpatialExpansion
        ) {
            Group {
                if player.issue != nil {
                    Image(systemName: "exclamationmark.circle")
                        .nowPlayingPlusLighter(NowPlayingVisualHierarchy.audioQualityTextOpacity)
                } else {
                    NowPlayingAudioQualityControl(
                        quality: actions.audioQuality(for: song),
                        openAudioQualitySettings: actions.canOpenAudioQualitySettings
                            ? { actions.openAudioQualitySettings() } : nil
                    )
                    .accessibilityIdentifier("player.audioQuality")
                }
            }
            .font(.system(size: timeFontSize, weight: .medium).monospacedDigit())
        }
    }

    private var progressMaximum: TimeInterval {
        player.duration > 0 ? player.duration : max(song.duration, 1)
    }

}

/// Shared custom capsule track so bar thickness, horizontal expansion, and
/// surrounding labels/icons are driven by the exact same SwiftUI spring.
struct NowPlayingCapsuleTrack: View {
    let fraction: CGFloat
    let baseWidth: CGFloat
    let isPressed: Bool
    let allowsSpatialExpansion: Bool
    let highlightFeedback: NowPlayingHighlightFeedback
    var filledOpacity: Double = NowPlayingVisualHierarchy.progressFilledOpacity
    var filledActiveOpacity: Double = NowPlayingVisualHierarchy.progressFilledActiveOpacity
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        let expandsSpatially = isPressed && allowsSpatialExpansion && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)
        let highlightAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : highlightFeedback.timing(highlighted: isPressed).animation
        let currentHeight = expandsSpatially
            ? NowPlayingProgressFeedbackSpec.pressedBarHeight
            : NowPlayingProgressFeedbackSpec.restBarHeight
        let clampedFraction = min(max(fraction, 0), 1)
        let deltaOpacity = max(0, (isPressed ? filledActiveOpacity : filledOpacity) - NowPlayingVisualHierarchy.trackUnfilledOpacity)

        ZStack(alignment: .leading) {
            Capsule(style: .circular)
                .fill(.white.opacity(NowPlayingVisualHierarchy.trackUnfilledOpacity))
                .blendMode(.plusLighter)

            Capsule(style: .circular)
                .fill(.white)
                .animation(spatialAnimation, value: isPressed)
                .opacity(deltaOpacity)
                .animation(highlightAnimation, value: isPressed)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: baseWidth * clampedFraction)
                }
                .blendMode(.plusLighter)
        }
        .frame(width: baseWidth, height: currentHeight)
        .animation(spatialAnimation, value: isPressed)
        .scaleEffect(x: expandsSpatially ? NowPlayingProgressFeedbackSpec.pressedHorizontalScale : 1, y: 1)
        .animation(spatialAnimation, value: isPressed)
    }
}

private struct NowPlayingProgressSliderView: View {
    let maximum: TimeInterval
    let interaction: NowPlayingProgressInteraction
    let allowsSpatialExpansion: Bool
    @Environment(PlayerState.self) private var player
    @Environment(\.playerVisualsActive) private var visualsActive

    var body: some View {
        let anchor = player.timelineAnchor
        let animatesLive = anchor.rate > 0 && visualsActive && interaction.scrubbingProgress == nil

        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animatesLive)) { _ in
                    let displayProgress = interaction.displayProgress(live: anchor.elapsed())
                    let fraction = maximum > 0 ? CGFloat(displayProgress / maximum) : 0
                    NowPlayingCapsuleTrack(
                        fraction: fraction,
                        baseWidth: proxy.size.width,
                        isPressed: interaction.isPressed,
                        allowsSpatialExpansion: allowsSpatialExpansion,
                        highlightFeedback: NowPlayingProgressFeedbackSpec.progressHighlight
                    )
                }
                NowPlayingProgressSlider(maximum: maximum, interaction: interaction)
                    .frame(width: proxy.size.width, height: 43)
            }
            .frame(width: proxy.size.width, height: 43)
        }
        .frame(height: 43)
    }
}

private struct NowPlayingProgressStatusView<Content: View>: View {
    let interaction: NowPlayingProgressInteraction
    let allowsSpatialExpansion: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        interaction: NowPlayingProgressInteraction,
        allowsSpatialExpansion: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.interaction = interaction
        self.allowsSpatialExpansion = allowsSpatialExpansion
        self.content = content()
    }

    var body: some View {
        let isPressed = interaction.isPressed
        let expandsSpatially = isPressed && allowsSpatialExpansion && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)

        content
            .scaleEffect(expandsSpatially ? NowPlayingProgressFeedbackSpec.pressedHorizontalScale : 1)
            .animation(spatialAnimation, value: isPressed)
    }
}

/// Only the slider and time readout subscribe to the periodic playback clock.
/// The quality control and surrounding page layout retain their existing inputs.
private struct NowPlayingProgressSlider: UIViewRepresentable {
    let maximum: TimeInterval
    let interaction: NowPlayingProgressInteraction
    @Environment(PlayerState.self) private var player

    func makeCoordinator() -> Coordinator { Coordinator(player: player, interaction: interaction) }

    func makeUIView(context: Context) -> NowPlayingScrubbingSlider {
        let slider = NowPlayingScrubbingSlider()
        slider.onHighlightChanged = { [interaction] highlighted in
            interaction.isPressed = highlighted
        }
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end(_:)),
                         for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(context.coordinator, action: #selector(Coordinator.cancel(_:)), for: .touchCancel)
        slider.accessibilityLabel = "播放进度"
        return slider
    }

    func updateUIView(_ slider: NowPlayingScrubbingSlider, context: Context) {
        context.coordinator.player = player
        context.coordinator.interaction = interaction
        slider.onHighlightChanged = { [interaction] highlighted in
            interaction.isPressed = highlighted
        }
        slider.maximumValue = Float(maximum)
        let trackKey = player.currentTrackTransitionKey
        if context.coordinator.lastTrackTransitionKey != trackKey {
            context.coordinator.lastTrackTransitionKey = trackKey
            context.coordinator.resetForTrackChange(slider: slider)
        }
        let liveProgress = player.timelineAnchor.elapsed()
        if !slider.isTracking && !context.coordinator.isEditing {
            let displayProgress = context.coordinator.resolvedExternalProgress(from: liveProgress)
            slider.value = Float(min(displayProgress, maximum))
        }
        slider.accessibilityValue = "\(formatPlaybackTime(liveProgress))，共 \(formatPlaybackTime(maximum))"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NowPlayingScrubbingSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 338, height: 43)
    }

    @MainActor final class Coordinator: NSObject {
        var player: PlayerState
        var interaction: NowPlayingProgressInteraction
        var lastTrackTransitionKey: String
        private let scrub = NowPlayingProgressScrub()
        private var hasDraggedValue = false
        private var pendingSeekTarget: Double?
        private var pendingSeekDeadline: ContinuousClock.Instant?
        var isEditing: Bool { scrub.isEditing }

        init(player: PlayerState, interaction: NowPlayingProgressInteraction) {
            self.player = player
            self.interaction = interaction
            self.lastTrackTransitionKey = player.currentTrackTransitionKey
        }

        func resetForTrackChange(slider: NowPlayingScrubbingSlider) {
            hasDraggedValue = false
            pendingSeekTarget = nil
            pendingSeekDeadline = nil
            scrub.setEditing(false)
            interaction.resetForTrackChange()
            slider.cancelTracking(with: nil)
        }

        /// Prevents stale `player.progress` ticks emitted before an async `seek` settles
        /// from snapping the slider backward during rapid repeated drags.
        func resolvedExternalProgress(from liveProgress: Double) -> Double {
            guard let target = pendingSeekTarget, let deadline = pendingSeekDeadline else {
                return liveProgress
            }
            if abs(liveProgress - target) <= 1.0 || ContinuousClock.now >= deadline {
                pendingSeekTarget = nil
                pendingSeekDeadline = nil
                return liveProgress
            }
            return target
        }

        @objc func begin(_ slider: NowPlayingScrubbingSlider) {
            scrub.setEditing(true)
            hasDraggedValue = false
            if let target = pendingSeekTarget, let deadline = pendingSeekDeadline, ContinuousClock.now < deadline {
                slider.syncDragBaseline(to: Float(target))
            } else if player.timelineAnchor.rate > 0 {
                slider.syncDragBaseline(to: Float(min(player.timelineAnchor.elapsed(), Double(slider.maximumValue))))
            }
        }

        @objc func end(_ slider: NowPlayingScrubbingSlider) {
            if hasDraggedValue {
                let committed = Double(slider.value)
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
                pendingSeekTarget = committed
                pendingSeekDeadline = deadline
                interaction.committedSeekProgress = committed
                interaction.committedSeekDeadline = deadline
                scrub.propose(committed) { player.seek(to: $0) }
            }
            hasDraggedValue = false
            scrub.setEditing(false)
            interaction.scrubbingProgress = nil
        }

        @objc func cancel(_ slider: NowPlayingScrubbingSlider) {
            hasDraggedValue = false
            scrub.setEditing(false)
            interaction.scrubbingProgress = nil
            interaction.isPressed = false
            let liveProgress = player.timelineAnchor.elapsed()
            slider.value = Float(min(liveProgress, Double(slider.maximumValue)))
        }

        @objc func changed(_ slider: NowPlayingScrubbingSlider) {
            // While dragging, drive the visual bar/time from the finger only and
            // commit a single AVPlayer seek on release so background time ticks
            // and mid-drag seeks never fight the user's finger.
            if slider.isTracking {
                let value = Double(slider.value)
                scrub.setEditing(true)
                hasDraggedValue = true
                pendingSeekTarget = nil
                pendingSeekDeadline = nil
                interaction.committedSeekProgress = nil
                interaction.committedSeekDeadline = nil
                interaction.scrubbingProgress = value
            } else {
                // VoiceOver adjustable increment/decrement.
                scrub.setEditing(true)
                scrub.propose(Double(slider.value)) { player.seek(to: $0) }
                scrub.setEditing(false)
                interaction.scrubbingProgress = nil
            }
        }
    }
}

/// Native `UIControl` relative progress scrubber with zero post-release inertia.
final class NowPlayingScrubbingSlider: UIControl {
    static let clearTrackImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    var onHighlightChanged: ((Bool) -> Void)?
    private(set) var isTrackHighlighted = false

    var value: Float = 0 {
        didSet {
            let clamped = min(max(value, 0), max(maximumValue, 0))
            if value != clamped { value = clamped }
        }
    }
    var maximumValue: Float = 1 {
        didSet {
            if maximumValue < 0 { maximumValue = 0 }
            if value > maximumValue { value = maximumValue }
        }
    }

    private var dragStartX: CGFloat = 0
    private var dragStartValue: Float = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ newValue: Float, animated: Bool) {
        value = newValue
    }

    func syncDragBaseline(to baseline: Float) {
        value = baseline
        dragStartValue = value
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragStartX = touch.location(in: self).x
        dragStartValue = value
        updateTrackHighlight(true)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let width = max(bounds.width, 1)
        let deltaX = touch.location(in: self).x - dragStartX
        let deltaValue = Float(deltaX / width) * maximumValue
        let nextValue = min(max(dragStartValue + deltaValue, 0), maximumValue)
        if abs(nextValue - value) > 0.0001 {
            value = nextValue
            sendActions(for: .valueChanged)
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            let width = max(bounds.width, 1)
            let deltaX = touch.location(in: self).x - dragStartX
            let deltaValue = Float(deltaX / width) * maximumValue
            let nextValue = min(max(dragStartValue + deltaValue, 0), maximumValue)
            if abs(nextValue - value) > 0.0001 {
                value = nextValue
                sendActions(for: .valueChanged)
            }
        }
        updateTrackHighlight(false)
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        updateTrackHighlight(false)
        super.cancelTracking(with: event)
    }

    override func accessibilityIncrement() {
        let step = max(maximumValue * 0.05, 5)
        value = min(value + step, maximumValue)
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        let step = max(maximumValue * 0.05, 5)
        value = max(value - step, 0)
        sendActions(for: .valueChanged)
    }

    func setTrackHighlightedForTesting(_ highlighted: Bool) {
        updateTrackHighlight(highlighted)
    }

    private func updateTrackHighlight(_ highlighted: Bool) {
        guard isTrackHighlighted != highlighted else { return }
        isTrackHighlighted = highlighted
        onHighlightChanged?(highlighted)
    }
}

private struct NowPlayingTimeLabels: View {
    let fontSize: CGFloat
    let interaction: NowPlayingProgressInteraction
    let allowsSpatialExpansion: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(PlayerState.self) private var player

    var body: some View {
        let anchor = player.timelineAnchor
        let animatesLive = anchor.rate > 0 && visualsActive && interaction.scrubbingProgress == nil

        TimelineView(.animation(minimumInterval: 0.5, paused: !animatesLive)) { _ in
            labelsBody(liveProgress: anchor.elapsed(), totalDuration: anchor.duration > 0 ? anchor.duration : player.duration)
        }
    }

    private func labelsBody(liveProgress: TimeInterval, totalDuration: TimeInterval) -> some View {
        let isPressed = interaction.isPressed
        let expandsSpatially = isPressed && allowsSpatialExpansion && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)
        let currentProgress = interaction.displayProgress(live: liveProgress)
        let elapsedText = formatPlaybackTime(currentProgress)
        let remainingText = "−\(formatPlaybackTime(max(totalDuration - currentProgress, 0)))"

        return HStack {
            Text(elapsedText)
            Spacer()
            Text(remainingText)
        }
        .font(.system(size: fontSize, weight: .medium).monospacedDigit())
        .nowPlayingPlusLighter(
            isPressed ? NowPlayingVisualHierarchy.timeLabelActiveOpacity : NowPlayingVisualHierarchy.timeLabelOpacity
        )
        .animation(
            accessibilityReduceMotion
                ? nil : NowPlayingProgressFeedbackSpec.progressHighlight.timing(highlighted: isPressed).animation,
            value: isPressed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(expandsSpatially ? NowPlayingProgressFeedbackSpec.pressedHorizontalScale : 1)
        .offset(y: expandsSpatially ? NowPlayingProgressFeedbackSpec.pressedTimeVerticalOffset * layout.verticalScale : 0)
        .animation(spatialAnimation, value: isPressed)
    }
}

private func formatPlaybackTime(_ value: TimeInterval) -> String {
    guard value.isFinite else { return "0:00" }
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Forwards values only during a user-originated slider edit.
@MainActor final class NowPlayingProgressScrub {
    private(set) var isEditing = false

    func setEditing(_ editing: Bool) {
        isEditing = editing
    }

    func propose(_ value: Double, seek: (Double) -> Void) {
        guard isEditing, value.isFinite else { return }
        seek(value)
    }
}

struct NowPlayingTransportControls: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    /// 每点一次上一首/下一首加一，触发图标的推进动画。
    @State private var previousTrigger = 0
    @State private var nextTrigger = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {

            Button {
                previousTrigger += 1
                player.previous()
            } label: {
                NowPlayingSkipIcon(
                    direction: .backward,
                    trigger: previousTrigger,
                    reducesMotion: accessibilityReduceMotion
                )
                .nowPlayingPrimary()
                .frame(width: 40.67, height: 27.39)
                .offset(y: -0.5)
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion
                )
            )
            .accessibilityLabel("上一首")
            .position(x: layout.x(94.25), y: 41)

            Button {
                player.togglePlayback()
            } label: {
                NowPlayingPlayPauseIcon(
                    isPlaying: player.isPlaying,
                    reducesMotion: accessibilityReduceMotion
                )
                .nowPlayingPrimary()
                .frame(width: 32, height: 40)
                .frame(width: 64, height: 64)
                .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion,
                    springsBack: true
                )
            )
            .accessibilityLabel(
                player.isPlaying
                    ? "暂停"
                    : "播放"
            )
            .position(x: proxy.size.width / 2, y: 41)

            Button {
                nextTrigger += 1
                player.next()
            } label: {
                NowPlayingSkipIcon(
                    direction: .forward,
                    trigger: nextTrigger,
                    reducesMotion: accessibilityReduceMotion
                )
                .nowPlayingPrimary()
                .frame(width: 40.67, height: 27.39)
                .offset(y: -0.5)
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(
                NowPlayingTransportButtonStyle(
                    reducesMotion: accessibilityReduceMotion
                )
            )
            .accessibilityLabel("下一首")
            .disabled(!player.canPlayNext)
            .position(x: layout.x(307.75), y: 41)
            }
        }
        .frame(height: 82)
    }
}
