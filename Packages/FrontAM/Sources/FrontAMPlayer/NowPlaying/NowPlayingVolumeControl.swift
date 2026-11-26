import AVFoundation
import MediaPlayer
import SwiftUI

struct VolumeInertiaPhysics: Sendable, Equatable {
    struct TouchSample: Sendable, Equatable {
        let timestamp: TimeInterval
        let x: CGFloat
    }

    struct StepResult: Sendable, Equatable {
        let value: Float
        let velocity: Float
        let shouldStop: Bool
    }

    static let maxStepDuration: TimeInterval = 1.0 / 20.0
    static let velocityWindow: TimeInterval = 0.030
    static let minimumVelocityInterval: TimeInterval = 0.006
    static let maximumStaleInterval: TimeInterval = 0.05
    static let maxVelocity: Float = 12

    static func step(
        value: Float,
        velocity: Float,
        dt rawDt: TimeInterval,
        timeConstant tau: TimeInterval = NowPlayingProgressFeedbackSpec.volumeInertiaTimeConstant,
        stopVelocity: Float = NowPlayingProgressFeedbackSpec.volumeInertiaStopVelocity
    ) -> StepResult {
        let dt = min(max(rawDt, 0), maxStepDuration)
        let decay = exp(-dt / tau)
        let delta = Float(Double(velocity) * tau * (1.0 - decay))
        let nextValue = min(max(value + delta, 0), 1)
        let nextVelocity = velocity * Float(decay)
        let hitBoundary = (nextValue <= 0 && nextVelocity < 0) || (nextValue >= 1 && nextVelocity > 0)
        let shouldStop = hitBoundary || abs(nextVelocity) < stopVelocity
        return StepResult(value: nextValue, velocity: nextVelocity, shouldStop: shouldStop)
    }

    static func releaseVelocity(
        samples: [TouchSample],
        lastMotionTimestamp: TimeInterval,
        endTimestamp: TimeInterval,
        trackWidth: CGFloat
    ) -> Float {
        guard trackWidth > 1,
              samples.count >= 2,
              endTimestamp - lastMotionTimestamp < maximumStaleInterval,
              let endSample = samples.last
        else {
            return 0
        }
        let reference = samples.dropLast().last(where: { endSample.timestamp - $0.timestamp >= velocityWindow })
            ?? samples[0]
        let dt = endSample.timestamp - reference.timestamp
        guard dt >= minimumVelocityInterval else { return 0 }
        let velocity = Float((endSample.x - reference.x) / trackWidth / dt)
        return min(max(velocity, -maxVelocity), maxVelocity)
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
            updateTrackHighlight(false)
            if !isHidden { isHidden = true }
        }
    }

    private func refreshHUDVisibility() {
        guard isVolumeDisplayActive, window != nil else { return }
        if isHidden { isHidden = false }
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
        let dt = displayLink.targetTimestamp - lastInertiaTimestamp
        lastInertiaTimestamp = displayLink.targetTimestamp
        let step = VolumeInertiaPhysics.step(value: lastReportedFraction, velocity: inertiaVelocity, dt: dt)
        inertiaVelocity = step.velocity
        applyVolumeValue(step.value)

        if step.shouldStop {
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
        guard let view else { return 0 }
        let samples = touchSamples.map { VolumeInertiaPhysics.TouchSample(timestamp: $0.timestamp, x: $0.x) }
        return VolumeInertiaPhysics.releaseVelocity(
            samples: samples,
            lastMotionTimestamp: lastMotionTimestamp,
            endTimestamp: endTimestamp,
            trackWidth: view.bounds.width
        )
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
