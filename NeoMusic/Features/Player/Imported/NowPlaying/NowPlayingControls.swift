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
}

struct NowPlayingProgressControl: View {
    @Environment(ReferencePlayerState.self) private var player
    @Environment(ReferencePlayerActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var timeFontSize: CGFloat = 12.5

    @Environment(\.nowPlayingLayout) private var layout
    @State private var interaction = NowPlayingProgressInteraction()
    let song: ReferenceTrack

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
                if player.isPreview {
                    Text("试听")
                        .nowPlayingPlusLighter(0.65)
                } else if player.issue != nil {
                    Image(systemName: "exclamationmark.circle")
                        .nowPlayingPlusLighter(NowPlayingVisualHierarchy.audioQualityTextOpacity)
                } else if let quality = actions.audioQuality(for: song) {
                    NowPlayingAudioQualityControl(quality: quality,
                        openAudioQualitySettings: actions.canOpenAudioQualitySettings
                            ? { actions.openAudioQualitySettings() } : nil)
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
private struct NowPlayingCapsuleTrack: View {
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

            if clampedFraction > 0 {
                Capsule(style: .circular)
                    .fill(.white)
                    .animation(spatialAnimation, value: isPressed)
                    .opacity(deltaOpacity)
                    .animation(highlightAnimation, value: isPressed)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: baseWidth * clampedFraction)
                            Spacer(minLength: 0)
                        }
                    }
                    .blendMode(.plusLighter)
            }
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
    @Environment(ReferencePlayerState.self) private var player

    var body: some View {
        let displayProgress = interaction.scrubbingProgress ?? player.progress
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
    @Environment(ReferencePlayerState.self) private var player

    func makeCoordinator() -> Coordinator { Coordinator(player: player, interaction: interaction) }

    func makeUIView(context: Context) -> UISlider {
        let slider = NowPlayingScrubbingSlider()
        slider.sliderStyle = .thumbless
        slider.alpha = 0.02
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
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

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.player = player
        context.coordinator.interaction = interaction
        if let scrubbingSlider = slider as? NowPlayingScrubbingSlider {
            scrubbingSlider.onHighlightChanged = { [interaction] highlighted in
                interaction.isPressed = highlighted
            }
        }
        slider.maximumValue = Float(maximum)
        if !slider.isTracking && !context.coordinator.isEditing {
            slider.value = Float(min(player.progress, maximum))
        }
        slider.accessibilityValue = "\(formatPlaybackTime(player.progress))，共 \(formatPlaybackTime(maximum))"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 338, height: 43)
    }

    @MainActor final class Coordinator: NSObject {
        var player: ReferencePlayerState
        var interaction: NowPlayingProgressInteraction
        private let scrub = NowPlayingProgressScrub()
        private var hasDraggedValue = false
        var isEditing: Bool { scrub.isEditing }

        init(player: ReferencePlayerState, interaction: NowPlayingProgressInteraction) {
            self.player = player
            self.interaction = interaction
        }

        @objc func begin(_ slider: UISlider) {
            scrub.setEditing(true)
            hasDraggedValue = false
        }

        @objc func end(_ slider: UISlider) {
            if hasDraggedValue {
                scrub.propose(Double(slider.value)) { player.seek(to: $0) }
            }
            hasDraggedValue = false
            scrub.setEditing(false)
            interaction.scrubbingProgress = nil
        }

        @objc func changed(_ slider: UISlider) {
            // While dragging, drive the visual bar/time from the finger only and
            // commit a single AVPlayer seek on release so background time ticks
            // and mid-drag seeks never fight the user's finger.
            if slider.isTracking {
                scrub.setEditing(true)
                hasDraggedValue = true
                interaction.scrubbingProgress = Double(slider.value)
            } else {
                scrub.setEditing(true)
                scrub.propose(Double(slider.value)) { player.seek(to: $0) }
                scrub.setEditing(false)
                interaction.scrubbingProgress = nil
            }
        }
    }
}

final class NowPlayingScrubbingSlider: UISlider {
    static let clearTrackImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    var onHighlightChanged: ((Bool) -> Void)?
    private(set) var isTrackHighlighted = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep .thumbless full-track hit testing while hiding UIKit's rendered subviews.
        for subview in subviews where subview.alpha != 0 {
            subview.alpha = 0
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let tracking = super.beginTracking(touch, with: event)
        if tracking { updateTrackHighlight(true) }
        return tracking
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        updateTrackHighlight(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        updateTrackHighlight(false)
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        updateTrackHighlight(false)
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
    @Environment(ReferencePlayerState.self) private var player

    var body: some View {
        let isPressed = interaction.isPressed
        let expandsSpatially = isPressed && allowsSpatialExpansion && !accessibilityReduceMotion
        let spatialAnimation: Animation? = accessibilityReduceMotion
            ? nil
            : (isPressed ? NowPlayingProgressFeedbackSpec.pressSpring : NowPlayingProgressFeedbackSpec.releaseSpring)
        let elapsedText = formatPlaybackTime(interaction.scrubbingProgress ?? player.progress)
        let remainingText = "−\(formatPlaybackTime(max(player.duration - (interaction.scrubbingProgress ?? player.progress), 0)))"

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
    @Environment(ReferencePlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    @State private var showsLoadingIndicator = false
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
                ZStack {
                    NowPlayingPlayPauseIcon(
                        isPlaying: player.isPlaying,
                        reducesMotion: accessibilityReduceMotion
                    )
                    .nowPlayingPrimary()
                    .frame(width: 32, height: 40)
                    .opacity(showsLoadingIndicator ? 0 : 1)
                    .scaleEffect(showsLoadingIndicator ? 0.6 : 1)

                    if showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.large)
                            .tint(NowPlayingVisualHierarchy.primaryColor)
                            .transition(.opacity)
                    }
                }
                .frame(width: 64, height: 64)
                // 加载很快结束时不闪转圈：持续 0.3 秒以上才换成转圈。
                .task(id: player.isLoading) {
                    if player.isLoading {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                    }
                    withAnimation(accessibilityReduceMotion ? nil : .smooth(duration: 0.2)) {
                        showsLoadingIndicator = player.isLoading
                    }
                }
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
                    NowPlayingInterfaceTransition.controlAnimation(
                        for: .volume,
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
                self.lastReportedFraction = volume
                self.volumeState?.volumeFraction = CGFloat(volume)
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
    @Environment(ReferencePlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    @Binding var page: NowPlayingPage
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
            let targetPage: NowPlayingPage =
                isSelected ? .artwork : destination
            page = targetPage
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
                                .scaledToFit()
                                .frame(width: destination == .queue ? 20.67 : 22.5,
                                       height: destination == .queue ? 15.33 : 23.5)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .blendMode(.plusLighter)
                        .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: systemImage)
                            .resizable()
                            .symbolVariant(.none)
                            .scaledToFit()
                            .frame(width: destination == .queue ? 20.67 : 22.5,
                                   height: destination == .queue ? 15.33 : 23.5)
                            .frame(width: 44, height: 44)
                            .nowPlayingPlusLighter(NowPlayingVisualHierarchy.bottomButtonUnselectedOpacity)
                    }
                }
                .offset(y: isSelected && destination == .lyrics ? 1 : 0)

                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .font(.system(size: 7, weight: .bold))
                        .nowPlayingPlusLighter(0.85)
                        .frame(width: 20, height: 20)
                        .background {
                            Circle()
                                .fill(.white.opacity(NowPlayingVisualHierarchy.repeatBadgeOpacity))
                                .blendMode(.plusLighter)
                        }
                        .offset(x: 8, y: -5)
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

#if DEBUG
private struct NowPlayingControlsFeedbackPreview: View {
    @State private var player: ReferencePlayerState
    private let song: ReferenceTrack
    private let actions: ReferencePlayerActions

    init() {
        let item = LibrarySongItem(
            id: "controls-preview",
            title: "STYX HELIX",
            artist: "MYTH & ROID",
            album: "STYX HELIX",
            albumArtist: "MYTH & ROID",
            trackNumber: 1,
            artwork: .missing,
            duration: 290
        )
        let model = NowPlayingModel(queue: [item], currentIndex: 0, isPlaying: true, elapsed: 48)
        _player = State(initialValue: ReferencePlayerState(model: model))
        self.song = ReferenceTrack(
            id: "controls-preview",
            title: "STYX HELIX",
            artists: "MYTH & ROID",
            albumTitle: "STYX HELIX",
            coverURL: nil,
            duration: 290
        )
        self.actions = ReferencePlayerActions(
            isFavorite: { _ in false },
            toggleFavorite: { _ in },
            addToPlaylist: { _ in },
            openAlbum: { _ in },
            openArtist: { _ in },
            audioQuality: { _ in PlayerAudioQuality(title: "无损") }
        )
    }

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            VStack(spacing: 48) {
                NowPlayingProgressControl(song: song)
                    .padding(.horizontal, 32)
                NowPlayingVolumeControl()
            }
        }
        .environment(player)
        .environment(actions)
        .preferredColorScheme(.dark)
    }
}

#Preview("进度条与音量条") {
    NowPlayingControlsFeedbackPreview()
}
#endif
