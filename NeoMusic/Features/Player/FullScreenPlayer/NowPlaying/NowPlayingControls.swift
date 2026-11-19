// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import AVFoundation
import MediaPlayer
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

    var body: some View {
        let displayProgress = interaction.displayProgress(live: player.progress)
        let fraction = maximum > 0 ? CGFloat(displayProgress / maximum) : 0

        GeometryReader { proxy in
            ZStack {
                NowPlayingCapsuleTrack(
                    fraction: fraction,
                    baseWidth: proxy.size.width,
                    isPressed: interaction.isPressed,
                    allowsSpatialExpansion: allowsSpatialExpansion,
                    highlightFeedback: NowPlayingProgressFeedbackSpec.progressHighlight
                )
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
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
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
        if !slider.isTracking && !context.coordinator.isEditing {
            let displayProgress = context.coordinator.resolvedExternalProgress(from: player.progress)
            slider.value = Float(min(displayProgress, maximum))
        }
        slider.accessibilityValue = "\(formatPlaybackTime(player.progress))，共 \(formatPlaybackTime(maximum))"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NowPlayingScrubbingSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 338, height: 43)
    }

    @MainActor final class Coordinator: NSObject {
        var player: PlayerState
        var interaction: NowPlayingProgressInteraction
        private let scrub = NowPlayingProgressScrub()
        private var hasDraggedValue = false
        private var pendingSeekTarget: Double?
        private var pendingSeekDeadline: ContinuousClock.Instant?
        var isEditing: Bool { scrub.isEditing }

        init(player: PlayerState, interaction: NowPlayingProgressInteraction) {
            self.player = player
            self.interaction = interaction
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
    @Environment(PlayerState.self) private var player

    var body: some View {
        let isPressed = interaction.isPressed
        let expandsSpatially = isPressed && allowsSpatialExpansion && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)
        let currentProgress = interaction.displayProgress(live: player.progress)
        let elapsedText = formatPlaybackTime(currentProgress)
        let remainingText = "−\(formatPlaybackTime(max(player.duration - currentProgress, 0)))"

        HStack {
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

@MainActor @Observable
private final class NowPlayingVolumeState {
    var isPressed = false
    var volumeFraction = CGFloat(AVAudioSession.sharedInstance().outputVolume)
}

struct NowPlayingVolumeControl: View {
    var isInterfaceHidden = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.nowPlayingLayout) private var layout
    @State private var volumeState = NowPlayingVolumeState()

    var body: some View {
        let isPressed = volumeState.isPressed
        let expandsSpatially = isPressed && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)
        let trackWidth = layout.width(279)

        GeometryReader { proxy in
            ZStack {
                ZStack {
                    ZStack {
                        Image(systemName: "speaker.fill")
                            .resizable().scaledToFit()
                            .frame(width: 8, height: 13)
                            .position(x: layout.x(38.25), y: 21)
                        Image(systemName: "speaker.wave.3.fill")
                            .resizable().scaledToFit()
                            .frame(width: 18, height: 14)
                            .position(x: layout.x(358.5), y: 21)
                    }
                    .nowPlayingPlusLighter(
                        isPressed ? NowPlayingVisualHierarchy.volumeIconActiveOpacity : NowPlayingVisualHierarchy.volumeIconOpacity
                    )
                    .animation(
                        accessibilityReduceMotion
                            ? nil : NowPlayingProgressFeedbackSpec.volumeHighlight.timing(highlighted: isPressed).animation,
                        value: isPressed
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(expandsSpatially ? NowPlayingProgressFeedbackSpec.pressedHorizontalScale : 1)
                    .animation(spatialAnimation, value: isPressed)

                    NowPlayingCapsuleTrack(
                        fraction: volumeState.volumeFraction,
                        baseWidth: trackWidth,
                        isPressed: isPressed,
                        allowsSpatialExpansion: true,
                        highlightFeedback: NowPlayingProgressFeedbackSpec.volumeHighlight,
                        filledOpacity: NowPlayingVisualHierarchy.volumeFilledOpacity,
                        filledActiveOpacity: NowPlayingVisualHierarchy.volumeFilledActiveOpacity
                    )
                    .position(x: layout.x(196.5), y: 21)
                }
                .opacity(isInterfaceHidden ? 0 : 1)
                .animation(
                    NowPlayingInterfaceTransition.controlOpacityAnimation(
                        isVisible: !isInterfaceHidden,
                        reducesMotion: accessibilityReduceMotion
                    ),
                    value: isInterfaceHidden
                )

                SystemVolumeSlider(volumeState: volumeState)
                    .frame(width: trackWidth, height: 43)
                    .position(x: layout.x(196.5), y: 21)
                    .accessibilityLabel("系统音量")
            }
        }
        .frame(height: 42)
    }
}

final class AlignedSystemVolumeView: MPVolumeView {
    // MPVolumeView stays at alpha = 1 with hidden slider subviews so iOS
    // reliably handles hardware volume and HUD suppression without drawing UIKit's track.
    private let clearImage = NowPlayingScrubbingSlider.clearTrackImage
    private var volumeObserver: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isVolumeDisplayActive = true
    private var lastHUDRefreshID: Int?
    private var isDragging = false
    private var isCoasting = false
    private var hasActiveSliderInteraction = false
    private var suppressObserverUntil: ContinuousClock.Instant = .now
    private var lastReportedFraction = AVAudioSession.sharedInstance().outputVolume
    private var inertiaLink: CADisplayLink?
    private var inertiaVelocity: Float = 0
    private var lastInertiaTimestamp: CFTimeInterval = 0
    fileprivate weak var volumeState: NowPlayingVolumeState?
    var onHighlightChanged: ((Bool) -> Void)?
    private(set) var isTrackHighlighted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    isolated deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopInertia(commitTouchUp: hasActiveSliderInteraction)
            isDragging = false
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && isVolumeDisplayActive {
            refreshHUDVisibility()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0, isUserInteractionEnabled, self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    func syncVolumeDisplayVisibility(isActive: Bool, refreshID: Int) {
        let stateChanged = isVolumeDisplayActive != isActive || lastHUDRefreshID != refreshID
        isVolumeDisplayActive = isActive
        lastHUDRefreshID = refreshID
        guard stateChanged else { return }
        if isActive {
            if isHidden { isHidden = false }
            refreshHUDVisibility()
        } else {
            stopInertia(commitTouchUp: hasActiveSliderInteraction)
            isDragging = false
            if !isHidden { isHidden = true }
        }
    }

    private func refreshHUDVisibility() {
        guard isVolumeDisplayActive, window != nil else { return }
        if isHidden { isHidden = false }
        // Calling setAlpha on MPVolumeView/MPVolumeSlider triggers MPVolumeHUDController
        // to re-evaluate ancestor visibility after popup open transitions or route changes.
        alpha = 1
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            slider.alpha = 1
            for subview in slider.subviews where subview.alpha != 0 {
                subview.alpha = 0
            }
        }
    }

    private func configureAppearance() {
        for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
            setVolumeThumbImage(clearImage, for: state)
            setMinimumVolumeSliderImage(clearImage, for: state)
            setMaximumVolumeSliderImage(clearImage, for: state)
        }
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            let volume = session.outputVolume
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore delayed / quantized AVAudioSession IPC echoes while dragging,
                // coasting on flick inertia, or during the brief post-release settle window.
                guard !self.isDragging, !self.isCoasting, ContinuousClock.now >= self.suppressObserverUntil else { return }
                let changed = abs(volume - self.lastReportedFraction) > 0.0001
                self.lastReportedFraction = volume
                if changed && !UIAccessibility.isReduceMotionEnabled {
                    withAnimation(.smooth(duration: 0.22)) {
                        self.volumeState?.volumeFraction = CGFloat(volume)
                    }
                } else {
                    self.volumeState?.volumeFraction = CGFloat(volume)
                }
            }
        }
        let refreshNames: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            AVAudioSession.routeChangeNotification
        ]
        notificationTokens = refreshNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHUDVisibility() }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            if slider.alpha != 1 { slider.alpha = 1 }
            if !slider.isUserInteractionEnabled { slider.isUserInteractionEnabled = true }
            if slider.sliderStyle != .default { slider.sliderStyle = .default }
            slider.minimumTrackTintColor = .clear
            slider.maximumTrackTintColor = .clear
            slider.thumbTintColor = .clear
            for state: UIControl.State in [.normal, .highlighted, .disabled, .selected] {
                if slider.thumbImage(for: state) !== clearImage { slider.setThumbImage(clearImage, for: state) }
            }
            for subview in slider.subviews where subview.alpha != 0 {
                subview.alpha = 0
            }
        }
        configureTouchTrackingIfNeeded()
    }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect { bounds }

    func setTrackHighlightedForTesting(_ highlighted: Bool) {
        updateTrackHighlight(highlighted)
    }

    private func configureTouchTrackingIfNeeded() {
        if gestureRecognizers?.contains(where: { $0 is VolumeSliderTouchObserver }) != true {
            let observer = VolumeSliderTouchObserver(
                onTouchStateChanged: { [weak self] isPressed in
                    self?.updateTrackHighlight(isPressed)
                },
                onBeginDrag: { [weak self] in
                    self?.beginDrag() ?? AVAudioSession.sharedInstance().outputVolume
                },
                onRelativeDrag: { [weak self] newValue in
                    self?.applyVolumeValue(newValue)
                },
                onEndDrag: { [weak self] releaseVelocity in
                    self?.endDrag(velocity: releaseVelocity)
                }
            )
            addGestureRecognizer(observer)
        }
    }

    private func beginDrag() -> Float {
        refreshHUDVisibility()
        stopInertia(commitTouchUp: false)
        isDragging = true
        if !hasActiveSliderInteraction {
            hasActiveSliderInteraction = true
            for slider in subviews.compactMap({ $0 as? UISlider }) {
                slider.sendActions(for: .touchDown)
            }
        }
        return lastReportedFraction
    }

    private func applyVolumeValue(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        lastReportedFraction = clamped
        volumeState?.volumeFraction = CGFloat(clamped)
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            slider.setValue(clamped, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }

    private func endDrag(velocity: Float) {
        isDragging = false
        let pushesPastBounds = (lastReportedFraction <= 0 && velocity < 0) || (lastReportedFraction >= 1 && velocity > 0)
        if abs(velocity) >= NowPlayingProgressFeedbackSpec.volumeMinimumFlickVelocity && !pushesPastBounds {
            startInertia(velocity: velocity)
        } else {
            finishSliderInteraction()
        }
    }

    private func finishSliderInteraction() {
        let finalValue = lastReportedFraction
        for slider in subviews.compactMap({ $0 as? UISlider }) {
            slider.setValue(finalValue, animated: false)
            slider.sendActions(for: .valueChanged)
            if hasActiveSliderInteraction {
                slider.sendActions(for: .touchUpInside)
            }
        }
        hasActiveSliderInteraction = false
        suppressObserverUntil = .now + .milliseconds(350)
    }

    private func startInertia(velocity: Float) {
        stopInertia(commitTouchUp: false)
        isCoasting = true
        inertiaVelocity = velocity
        lastInertiaTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(
            target: VolumeDisplayLinkTarget(owner: self),
            selector: #selector(VolumeDisplayLinkTarget.step(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    fileprivate func stepInertia(_ displayLink: CADisplayLink) {
        guard isCoasting, !isDragging else {
            stopInertia(commitTouchUp: !isDragging && hasActiveSliderInteraction)
            return
        }
        let dt = min(max(displayLink.targetTimestamp - lastInertiaTimestamp, 0), 1.0 / 20.0)
        lastInertiaTimestamp = displayLink.targetTimestamp
        let tau = NowPlayingProgressFeedbackSpec.volumeInertiaTimeConstant
        let decay = exp(-dt / tau)
        let delta = Float(Double(inertiaVelocity) * tau * (1.0 - decay))
        let nextValue = min(max(lastReportedFraction + delta, 0), 1)
        inertiaVelocity *= Float(decay)
        applyVolumeValue(nextValue)

        let hitBoundary = (nextValue <= 0 && inertiaVelocity < 0) || (nextValue >= 1 && inertiaVelocity > 0)
        if hitBoundary || abs(inertiaVelocity) < NowPlayingProgressFeedbackSpec.volumeInertiaStopVelocity {
            stopInertia(commitTouchUp: true)
        }
    }

    private func stopInertia(commitTouchUp: Bool) {
        inertiaLink?.invalidate()
        inertiaLink = nil
        isCoasting = false
        inertiaVelocity = 0
        if commitTouchUp {
            finishSliderInteraction()
        }
    }

    private func updateTrackHighlight(_ highlighted: Bool) {
        guard isTrackHighlighted != highlighted else { return }
        isTrackHighlighted = highlighted
        volumeState?.isPressed = highlighted
        onHighlightChanged?(highlighted)
    }
}

@MainActor
private final class VolumeDisplayLinkTarget {
    private weak var owner: AlignedSystemVolumeView?

    init(owner: AlignedSystemVolumeView) {
        self.owner = owner
    }

    @objc func step(_ displayLink: CADisplayLink) {
        guard let owner else {
            displayLink.invalidate()
            return
        }
        owner.stepInertia(displayLink)
    }
}

private final class VolumeSliderTouchObserver: UIGestureRecognizer {
    private struct TouchSample {
        let timestamp: TimeInterval
        let x: CGFloat
    }

    private let onTouchStateChanged: (Bool) -> Void
    private let onBeginDrag: () -> Float
    private let onRelativeDrag: (Float) -> Void
    private let onEndDrag: (Float) -> Void
    private var activeTouch: UITouch?
    private var startX: CGFloat = 0
    private var startVolume: Float = 0
    private var hasDragged = false
    private var touchSamples: [TouchSample] = []
    private var lastMotionTimestamp: TimeInterval = 0

    init(
        onTouchStateChanged: @escaping (Bool) -> Void,
        onBeginDrag: @escaping () -> Float,
        onRelativeDrag: @escaping (Float) -> Void,
        onEndDrag: @escaping (Float) -> Void
    ) {
        self.onTouchStateChanged = onTouchStateChanged
        self.onBeginDrag = onBeginDrag
        self.onRelativeDrag = onRelativeDrag
        self.onEndDrag = onEndDrag
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard activeTouch == nil, let touch = touches.first, let view else { return }
        activeTouch = touch
        let x = touch.location(in: view).x
        startX = x
        startVolume = onBeginDrag()
        hasDragged = false
        touchSamples = [TouchSample(timestamp: touch.timestamp, x: x)]
        lastMotionTimestamp = touch.timestamp
        state = .began
        onTouchStateChanged(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch), let view else { return }
        recordSamples(from: event.coalescedTouches(for: touch) ?? [touch], in: view)
        let x = touch.location(in: view).x
        if abs(x - startX) > 0.25 { hasDragged = true }
        let width = max(view.bounds.width, 1)
        let delta = Float((x - startX) / width)
        let newVolume = min(max(startVolume + delta, 0), 1)
        state = .changed
        onRelativeDrag(newVolume)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        if let view {
            recordSamples(from: event.coalescedTouches(for: touch) ?? [touch], in: view)
            let x = touch.location(in: view).x
            if hasDragged || abs(x - startX) > 0.25 {
                let width = max(view.bounds.width, 1)
                let delta = Float((x - startX) / width)
                onRelativeDrag(min(max(startVolume + delta, 0), 1))
            }
        }
        let releaseVelocity = computeReleaseVelocity(at: touch.timestamp, in: view)
        resetTrackingState()
        state = .ended
        onEndDrag(releaseVelocity)
        onTouchStateChanged(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        resetTrackingState()
        state = .cancelled
        onEndDrag(0)
        onTouchStateChanged(false)
    }

    override func reset() {
        super.reset()
        if activeTouch != nil {
            resetTrackingState()
            onEndDrag(0)
            onTouchStateChanged(false)
        }
    }

    private func resetTrackingState() {
        activeTouch = nil
        hasDragged = false
        touchSamples.removeAll(keepingCapacity: true)
    }

    private func recordSamples(from touches: [UITouch], in view: UIView) {
        for sample in touches {
            let x = sample.location(in: view).x
            let timestamp = sample.timestamp
            if let previous = touchSamples.last {
                if abs(x - previous.x) > 0.25 {
                    lastMotionTimestamp = timestamp
                } else if touchSamples.count >= 2 || timestamp <= previous.timestamp {
                    continue
                }
            }
            touchSamples.append(TouchSample(timestamp: timestamp, x: x))
        }
        if let latest = touchSamples.last?.timestamp {
            touchSamples.removeAll { latest - $0.timestamp > 0.15 }
        }
    }

    private func computeReleaseVelocity(at endTimestamp: TimeInterval, in view: UIView?) -> Float {
        guard let view, view.bounds.width > 1,
              touchSamples.count >= 2,
              endTimestamp - lastMotionTimestamp < 0.05,
              let endSample = touchSamples.last
        else {
            return 0
        }
        let reference = touchSamples.dropLast().last(where: { endSample.timestamp - $0.timestamp >= 0.030 })
            ?? touchSamples[0]
        let dt = endSample.timestamp - reference.timestamp
        guard dt >= 0.006 else { return 0 }
        let velocity = Float((endSample.x - reference.x) / view.bounds.width / dt)
        return min(max(velocity, -12), 12)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    let volumeState: NowPlayingVolumeState
    @Environment(\.playerVisualsActive) private var playerVisualsActive
    @Environment(\.playerVolumeHUDRefreshID) private var volumeHUDRefreshID

    func makeUIView(context: Context) -> AlignedSystemVolumeView {
        let volumeView = AlignedSystemVolumeView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 43)
        )
        volumeView.backgroundColor = .clear
        volumeView.showsVolumeSlider = true
        volumeView.volumeState = volumeState
        volumeView.syncVolumeDisplayVisibility(
            isActive: playerVisualsActive,
            refreshID: volumeHUDRefreshID
        )
        return volumeView
    }

    func updateUIView(
        _ volumeView: AlignedSystemVolumeView,
        context: Context
    ) {
        volumeView.volumeState = volumeState
        volumeView.syncVolumeDisplayVisibility(
            isActive: playerVisualsActive,
            refreshID: volumeHUDRefreshID
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AlignedSystemVolumeView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? 200,
            height: proposal.height ?? 43
        )
    }
}

struct NowPlayingPageSelector: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(PlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    let page: NowPlayingPage
    let onPageTap: (NowPlayingPage) -> Void
    let hasLyrics: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // A selected lyrics page remains dismissible while the next track loads.
                pageButton(page: .lyrics, systemImage: "quote.bubble", accessibilityLabel: "歌词")
                    .disabled(!hasLyrics && page != .lyrics)
                    .opacity(hasLyrics || page == .lyrics ? 1 : 0.32)
                    .position(x: layout.x(87), y: 25)
                ReferenceAirPlayButton(opacity: NowPlayingVisualHierarchy.airPlayOpacity)
                    .frame(width: 44, height: 44)
                    .position(x: proxy.size.width / 2, y: 25)
                pageButton(page: .queue, systemImage: "list.bullet", accessibilityLabel: "继续播放",
                           badgeSystemImage: page == .queue ? nil : player.queueModeBadgeSystemImage)
                    .position(x: layout.x(315), y: 25)
            }
        }
        .frame(height: 50)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25), value: hasLyrics)
    }

    private func pageButton(
        page destination: NowPlayingPage,
        systemImage: String,
        accessibilityLabel: String,
        badgeSystemImage: String? = nil
    ) -> some View {
        let isSelected = page == destination

        return Button {
            onPageTap(destination)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isSelected {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(NowPlayingVisualHierarchy.bottomButtonSelectedFillOpacity))
                                .frame(width: 38, height: 38)
                            Image(systemName: systemImage)
                                .resizable()
                                .symbolVariant(.fill)
                                .fontWeight(.medium)
                                .scaledToFit()
                                .frame(width: destination == .queue ? 20 : 21,
                                       height: destination == .queue ? 15 : 21.5)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .blendMode(.plusLighter)
                        .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: systemImage)
                            .resizable()
                            .symbolVariant(.none)
                            .fontWeight(.medium)
                            .scaledToFit()
                            .frame(width: destination == .queue ? 20 : 21,
                                   height: destination == .queue ? 15 : 21.5)
                            .frame(width: 44, height: 44)
                            .nowPlayingPlusLighter(NowPlayingVisualHierarchy.bottomButtonUnselectedOpacity)
                    }
                }
                .offset(y: isSelected && destination == .lyrics ? 1 : 0)

                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .font(.system(size: 9, weight: .bold))
                        .nowPlayingPlusLighter(0.85)
                        .frame(width: 17, height: 17)
                        .background {
                            Circle()
                                .fill(.white.opacity(NowPlayingVisualHierarchy.repeatBadgeOpacity))
                                .blendMode(.plusLighter)
                        }
                        .offset(x: 1, y: 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.1), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
