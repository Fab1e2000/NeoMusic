import SwiftUI
import UIKit

@Observable @MainActor
final class TrackSwipeOffsetModel {
    var value: CGFloat = 0
    var edgeStrength: Double = 0
}

struct TrackSwipeVibrantEdge: Equatable {
    let motion: TrackSwipeOffsetModel
    let baseOffset: CGFloat
    let isPinned: Bool
    let isActive: Bool
    let slotWidth: CGFloat
    let insets: TrackSwipeViewportInsets

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.motion === rhs.motion &&
        lhs.baseOffset == rhs.baseOffset &&
        lhs.isPinned == rhs.isPinned &&
        lhs.isActive == rhs.isActive &&
        lhs.slotWidth == rhs.slotWidth &&
        lhs.insets == rhs.insets
    }
}

private struct TrackSwipeVibrantEdgeKey: EnvironmentKey {
    static let defaultValue: TrackSwipeVibrantEdge? = nil
}

extension EnvironmentValues {
    var trackSwipeVibrantEdge: TrackSwipeVibrantEdge? {
        get { self[TrackSwipeVibrantEdgeKey.self] }
        set { self[TrackSwipeVibrantEdgeKey.self] = newValue }
    }
}

struct TrackSwipeViewportInsets: Equatable {
    var leadingBleed: CGFloat = 0
    var trailingBleed: CGFloat = 0
    var leadingFade: CGFloat = 14
    var trailingFade: CGFloat = 14
    var fadesOnlyWhenSliding: Bool = false

    static let header = TrackSwipeViewportInsets(
        leadingBleed: 12,
        trailingBleed: 12,
        leadingFade: 12,
        trailingFade: 12,
        fadesOnlyWhenSliding: false
    )

    static let miniPlayer = TrackSwipeViewportInsets(
        leadingBleed: 8,
        trailingBleed: 0,
        leadingFade: 8,
        trailingFade: 14,
        fadesOnlyWhenSliding: true
    )
}

@Observable @MainActor
final class TrackSwipeController {
    static let spring = Spring(duration: 0.22, bounce: 0.26)
    static let maxSpringVelocity: CGFloat = 700
    static let thresholdFraction: CGFloat = 0.3
    static let hapticRearmFraction: CGFloat = 0.22
    static let thresholdVelocity: CGFloat = 600

    var isDragging = false
    var isSettling = false
    var currentStep = 0

    private(set) var exitingSlot: (step: Int, track: PlayerTrack)?
    private(set) var pinnedArtistDuringTransition: String?
    private(set) var offsetSign = 0
    private(set) var showsPreviousSlot = false
    private(set) var showsNextSlot = false
    private(set) var allowsOppositePreviousSlot = true
    private(set) var allowsOppositeNextSlot = true

    @ObservationIgnored let motion = TrackSwipeOffsetModel()
    @ObservationIgnored private var rawDragOffset: CGFloat = 0
    @ObservationIgnored private var dragBaseOffset: CGFloat = 0
    @ObservationIgnored private var springStartOffset: CGFloat = 0
    @ObservationIgnored private var springVelocity: CGFloat = 0
    @ObservationIgnored private var springStartDate: Date = .now
    @ObservationIgnored private var springSettlingDuration: TimeInterval = 0.05
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hapticArmedDirection = 0

    @ObservationIgnored var feedbackHandler: () -> Void = { ReferenceTrackSwipeFeedback.selection() }
    @ObservationIgnored var prepareFeedbackHandler: () -> Void = { ReferenceTrackSwipeFeedback.prepare() }
    @ObservationIgnored var nowProvider: () -> Date = { .now }

    var dragOffset: CGFloat {
        get { rawDragOffset }
        set {
            rawDragOffset = newValue
            updateMotionOutput(offset: newValue)
        }
    }

    var isActive: Bool { isDragging || isSettling }

    func syncTrack(song: PlayerTrack, queueIndex: Int) {
        let key = "\(queueIndex):\(song.id)"
        guard let lastTrackKey else {
            self.lastTrackKey = key
            return
        }
        guard key != lastTrackKey else { return }
        self.lastTrackKey = key
        cancelMotion()
    }

    func currentOffset(at date: Date) -> CGFloat {
        if isDragging { return rawDragOffset }
        guard isSettling else { return 0 }
        let dt = max(0, date.timeIntervalSince(springStartDate))
        return springStartOffset + Self.spring.value(
            target: -springStartOffset,
            initialVelocity: springVelocity,
            time: dt
        )
    }

    func isArtistPinned(
        at offset: CGFloat,
        song: PlayerTrack,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) -> Bool {
        if let pinnedArtistDuringTransition, !song.artists.isEmpty, pinnedArtistDuringTransition == song.artists {
            return true
        }
        guard !song.artists.isEmpty else { return false }
        if offset > 0, let previous {
            return previous.track.artists == song.artists
        }
        if offset < 0, let next {
            return next.track.artists == song.artists
        }
        return false
    }

    func panBegan(
        translation: CGFloat,
        distance: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) {
        let now = nowProvider()
        let live = currentOffset(at: now)
        stopSpringDrivers()
        isSettling = false
        isDragging = true
        dragBaseOffset = live

        let safeDistance = max(distance, 1)
        let threshold = safeDistance * Self.thresholdFraction
        if live >= threshold, previous != nil {
            hapticArmedDirection = 1
        } else if live <= -threshold, next != nil {
            hapticArmedDirection = -1
        } else {
            hapticArmedDirection = 0
        }

        prepareFeedbackHandler()
        applyDrag(translation: translation, distance: safeDistance, previous: previous, next: next)
    }

    func panChanged(
        translation: CGFloat,
        distance: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) {
        if !isDragging {
            panBegan(translation: translation, distance: distance, previous: previous, next: next)
            return
        }
        applyDrag(translation: translation, distance: max(distance, 1), previous: previous, next: next)
    }

    static func resolveCommit(
        rawDragOffset: CGFloat,
        dragBaseOffset: CGFloat,
        translation: CGFloat,
        velocity: CGFloat,
        distance: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) -> (entry: PlayerAdjacentTrack, direction: CGFloat)? {
        let safeDistance = max(distance, 1)
        let threshold = safeDistance * Self.thresholdFraction
        let rearm = safeDistance * Self.hapticRearmFraction

        let canCommitPrevious = previous != nil && (
            dragBaseOffset < rearm ||
            translation > 12 ||
            velocity > Self.thresholdVelocity ||
            rawDragOffset > safeDistance * 0.5
        )
        let canCommitNext = next != nil && (
            dragBaseOffset > -rearm ||
            translation < -12 ||
            velocity < -Self.thresholdVelocity ||
            rawDragOffset < -safeDistance * 0.5
        )

        if let next, canCommitNext,
           rawDragOffset <= -threshold || (velocity < -Self.thresholdVelocity && (rawDragOffset <= 0 || translation < -12)) {
            return (next, -1)
        } else if let previous, canCommitPrevious,
                  rawDragOffset >= threshold || (velocity > Self.thresholdVelocity && (rawDragOffset >= 0 || translation > 12)) {
            return (previous, 1)
        }
        return nil
    }

    func panEnded(
        translation: CGFloat,
        velocity: CGFloat,
        distance: CGFloat,
        song: PlayerTrack,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?,
        reduceMotion: Bool,
        select: (Int) -> Void
    ) {
        guard isDragging else { return }
        let safeDistance = max(distance, 1)

        if let chosen = Self.resolveCommit(
            rawDragOffset: rawDragOffset,
            dragBaseOffset: dragBaseOffset,
            translation: translation,
            velocity: velocity,
            distance: safeDistance,
            previous: previous,
            next: next
        ) {
            let entry = chosen.entry
            let direction = chosen.direction
            let expectedArm = direction == 1 ? 1 : -1
            if hapticArmedDirection != expectedArm {
                feedbackHandler()
            }
            let sameArtists = !song.artists.isEmpty && song.artists == entry.track.artists
            pinnedArtistDuringTransition = sameArtists ? song.artists : nil
            exitingSlot = (step: currentStep, track: song)
            currentStep += direction < 0 ? 1 : -1
            lastTrackKey = "\(entry.index):\(entry.track.id)"

            let rebased = rawDragOffset - direction * safeDistance
            isDragging = false
            rawDragOffset = 0
            dragBaseOffset = 0
            hapticArmedDirection = 0

            startSpring(from: rebased, velocity: velocity, reduceMotion: reduceMotion)
            select(entry.index)
            return
        }

        if rawDragOffset > 0, let previous, !song.artists.isEmpty, song.artists == previous.track.artists {
            pinnedArtistDuringTransition = song.artists
        } else if rawDragOffset < 0, let next, !song.artists.isEmpty, song.artists == next.track.artists {
            pinnedArtistDuringTransition = song.artists
        } else {
            pinnedArtistDuringTransition = nil
        }

        let releaseOffset = rawDragOffset
        isDragging = false
        rawDragOffset = 0
        dragBaseOffset = 0
        hapticArmedDirection = 0
        startSpring(from: releaseOffset, velocity: velocity, reduceMotion: reduceMotion)
    }

    func panCancelled(reduceMotion: Bool) {
        guard isDragging else { return }
        let releaseOffset = rawDragOffset
        isDragging = false
        rawDragOffset = 0
        dragBaseOffset = 0
        hapticArmedDirection = 0
        startSpring(from: releaseOffset, velocity: 0, reduceMotion: reduceMotion)
    }

    func finishSettling() {
        stopSpringDrivers()
        isSettling = false
        exitingSlot = nil
        pinnedArtistDuringTransition = nil
        updateMotionOutput(offset: 0)
    }

    private func applyDrag(
        translation: CGFloat,
        distance: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) {
        let raw = dragBaseOffset + translation
        let canPrevious = previous != nil
        let canNext = next != nil

        if (raw > 0 && !canPrevious) || (raw < 0 && !canNext) {
            rawDragOffset = Self.rubberBand(raw, dimension: distance)
        } else {
            rawDragOffset = raw
        }

        if let exiting = exitingSlot {
            if (exiting.step < currentStep && rawDragOffset < -2) || (exiting.step > currentStep && rawDragOffset > 2) {
                exitingSlot = nil
                pinnedArtistDuringTransition = nil
            }
        } else if pinnedArtistDuringTransition != nil, abs(translation) > 8 {
            pinnedArtistDuringTransition = nil
        }

        let threshold = distance * Self.thresholdFraction
        let rearm = distance * Self.hapticRearmFraction
        if rawDragOffset >= threshold, canPrevious {
            if hapticArmedDirection != 1 {
                hapticArmedDirection = 1
                feedbackHandler()
            }
        } else if rawDragOffset <= -threshold, canNext {
            if hapticArmedDirection != -1 {
                hapticArmedDirection = -1
                feedbackHandler()
            }
        } else if abs(rawDragOffset) <= rearm {
            hapticArmedDirection = 0
        }

        updateMotionOutput(offset: rawDragOffset)
    }

    private func startSpring(from offset: CGFloat, velocity: CGFloat, reduceMotion: Bool) {
        stopSpringDrivers()
        if reduceMotion || (abs(offset) < 0.1 && abs(velocity) < 1) {
            isSettling = false
            exitingSlot = nil
            pinnedArtistDuringTransition = nil
            updateMotionOutput(offset: 0)
            return
        }

        let clampedVelocity = max(-Self.maxSpringVelocity, min(Self.maxSpringVelocity, velocity))
        springStartOffset = offset
        springVelocity = clampedVelocity
        let startDate = nowProvider()
        springStartDate = startDate
        springSettlingDuration = max(
            Self.spring.settlingDuration(target: -offset, initialVelocity: clampedVelocity, epsilon: 0.1),
            0.05
        )
        isSettling = true
        updateMotionOutput(offset: offset)
        startDisplayLink()
        scheduleSettleTask(after: springSettlingDuration + 0.05)
    }

    private func scheduleSettleTask(after delay: TimeInterval) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.finishSettling()
        }
    }

    func cancelMotion() {
        stopSpringDrivers()
        isSettling = false
        isDragging = false
        rawDragOffset = 0
        dragBaseOffset = 0
        exitingSlot = nil
        pinnedArtistDuringTransition = nil
        hapticArmedDirection = 0
        updateMotionOutput(offset: 0)
    }

    private func startDisplayLink() {
        let link = CADisplayLink(
            target: TrackSwipeDisplayLinkTarget(owner: self),
            selector: #selector(TrackSwipeDisplayLinkTarget.step(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopSpringDrivers() {
        settleTask?.cancel()
        settleTask = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func stepDisplayLink(_ displayLink: CADisplayLink) {
        guard isSettling else {
            displayLink.invalidate()
            if self.displayLink === displayLink { self.displayLink = nil }
            return
        }
        let lookahead = min(max(displayLink.targetTimestamp - CACurrentMediaTime(), 0), 0.05)
        let sampleDate = nowProvider().addingTimeInterval(lookahead)
        stepSpringFrame(at: sampleDate)
    }

    /// Samples the release spring on the same real timeline as touch-up, so a main-thread
    /// stall consumes the settle instead of being absorbed and replayed later.
    func stepSpringFrame(at sampleDate: Date) {
        guard isSettling else { return }
        let dt = max(0, sampleDate.timeIntervalSince(springStartDate))
        if dt >= springSettlingDuration {
            finishSettling()
            return
        }
        updateMotionOutput(offset: currentOffset(at: sampleDate))
    }

    private func updateMotionOutput(offset: CGFloat) {
        if motion.value != offset {
            motion.value = offset
        }
        let nextStrength = min(Double(abs(offset)) / 6.0, 1.0)
        if motion.edgeStrength != nextStrength {
            motion.edgeStrength = nextStrength
        }
        syncDiscreteState(offset: offset)
    }

    private func syncDiscreteState(offset: CGFloat) {
        let sign = offset > 0 ? 1 : (offset < 0 ? -1 : 0)
        if offsetSign != sign { offsetSign = sign }

        let showPrevious = offset > 0.25
        if showsPreviousSlot != showPrevious { showsPreviousSlot = showPrevious }

        let showNext = offset < -0.25
        if showsNextSlot != showNext { showsNextSlot = showNext }

        let allowOppositePrevious: Bool
        let allowOppositeNext: Bool
        if !isDragging, let exiting = exitingSlot {
            let isExitingLeft = exiting.step < currentStep
            allowOppositePrevious = isExitingLeft || abs(offset) > 12
            allowOppositeNext = !isExitingLeft || abs(offset) > 12
        } else {
            allowOppositePrevious = true
            allowOppositeNext = true
        }
        if allowsOppositePreviousSlot != allowOppositePrevious {
            allowsOppositePreviousSlot = allowOppositePrevious
        }
        if allowsOppositeNextSlot != allowOppositeNext {
            allowsOppositeNextSlot = allowOppositeNext
        }
    }

    private static func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        let absOffset = abs(offset)
        let damped = (1 - 1 / ((absOffset * 0.55 / dimension) + 1)) * dimension * 0.45
        return offset >= 0 ? damped : -damped
    }
}

struct NowPlayingTrackSwipe<Title: View, Artist: View>: View {
    let song: PlayerTrack
    /// 相邻歌名离当前歌名的距离；不传时用这一块自己的宽度再留一点间隔。
    var pageDistance: CGFloat? = nil
    /// 可选固定槽高度；用于在迷你条中将手势热区撑满完整行高。
    var slotHeight: CGFloat? = nil
    /// 行间距；为 nil 时标题和歌手叠放在同一槽内由调用方精确定位。
    var rowSpacing: CGFloat? = 2
    /// 视口边缘羽化与溢出距离。
    var viewportInsets: TrackSwipeViewportInsets = .header
    /// 已知视口宽度时可直接传入，避免切页入场首帧从 0 度量再触发遮罩分支切换。
    var viewportWidth: CGFloat? = nil
    /// LN hosts title content in a separate controller; give that slot an explicit touch surface.
    var usesUIKitTouchSurface = false
    /// `marqueeActive` controls scrolling title; `interactive` controls button clicks on current track.
    @ViewBuilder let title: (_ track: PlayerTrack, _ marqueeActive: Bool) -> Title
    @ViewBuilder let artist: (_ track: PlayerTrack, _ interactive: Bool) -> Artist

    @Environment(PlayerState.self) private var player
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var controller = TrackSwipeController()
    @State private var measuredWidth: CGFloat = 0

    private static var spacing: CGFloat { 24 }

    private struct Slot: Identifiable {
        let id: String
        let step: Int
        let track: PlayerTrack
        let baseOffset: CGFloat
        let isCurrent: Bool
        let keepMarqueeActive: Bool
    }

    private var verticalMaskOverflow: CGFloat {
        rowSpacing == nil ? 0 : 8
    }

    private var activeWidth: CGFloat {
        viewportWidth ?? measuredWidth
    }

    var body: some View {
        let previous = player.previousInOrder
        let next = player.nextInOrder
        let distance = max(pageDistance ?? (activeWidth + Self.spacing), 1)
        let pinnedArtist = controller.isArtistPinned(
            at: CGFloat(controller.offsetSign),
            song: song,
            previous: previous,
            next: next
        )
        let slots = visibleSlots(
            distance: distance,
            previous: previous,
            next: next
        )

        trackLayers(slots: slots, pinnedArtist: pinnedArtist)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: slotHeight, alignment: rowSpacing == nil ? .topLeading : .leading)
            .padding(.leading, viewportInsets.leadingBleed)
            .padding(.trailing, viewportInsets.trailingBleed)
            .clipped()
            .padding(.leading, -viewportInsets.leadingBleed)
            .padding(.trailing, -viewportInsets.trailingBleed)
            .contentShape(.rect)
            .modifier(TrackSwipeGestureModifier(
                usesUIKitTouchSurface: usesUIKitTouchSurface,
                pan: NowPlayingHorizontalPan(
                    onStart: { translation in
                        controller.panBegan(
                            translation: translation,
                            distance: distance,
                            previous: previous,
                            next: next
                        )
                    },
                    onChange: { translation in
                        controller.panChanged(
                            translation: translation,
                            distance: distance,
                            previous: previous,
                            next: next
                        )
                    },
                    onEnd: { translation, velocity in
                        controller.panEnded(
                            translation: translation,
                            velocity: velocity,
                            distance: distance,
                            song: song,
                            previous: previous,
                            next: next,
                            reduceMotion: accessibilityReduceMotion,
                            select: player.skip(toQueueIndex:)
                        )
                    },
                    onCancel: {
                        controller.panCancelled(reduceMotion: accessibilityReduceMotion)
                    }
                )
            ))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                guard viewportWidth == nil, measuredWidth != width else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { measuredWidth = width }
            }
            .onChange(of: "\(player.currentQueueIndex):\(song.id)", initial: true) { _, _ in
                controller.syncTrack(song: song, queueIndex: player.currentQueueIndex)
            }
            .onDisappear {
                controller.cancelMotion()
            }
    }

    @ViewBuilder
    private func trackLayers(slots: [Slot], pinnedArtist: Bool) -> some View {
        let titleStack = applyEdgeFade(
            ZStack(alignment: rowSpacing == nil ? .topLeading : .leading) {
                ForEach(slots) { slot in
                    title(slot.track, slot.keepMarqueeActive)
                        .modifier(TrackSwipeSlotOffsetModifier(
                            motion: controller.motion,
                            baseOffset: slot.baseOffset,
                            isPinned: false
                        ))
                        .allowsHitTesting(slot.isCurrent)
                        .accessibilityHidden(!slot.isCurrent)
                }
            },
            isStationary: false
        )

        let rawArtistStack = ZStack(alignment: rowSpacing == nil ? .topLeading : .leading) {
            ForEach(slots) { slot in
                let slotPinned = slot.isCurrent && pinnedArtist
                let hidden = !slot.isCurrent && pinnedArtist
                artist(slot.track, slot.isCurrent)
                    .environment(
                        \.trackSwipeVibrantEdge,
                        viewportInsets.fadesOnlyWhenSliding
                            ? nil
                            : TrackSwipeVibrantEdge(
                                motion: controller.motion,
                                baseOffset: slot.baseOffset,
                                isPinned: slotPinned || hidden,
                                isActive: controller.isActive,
                                slotWidth: activeWidth,
                                insets: viewportInsets
                            )
                    )
                    .modifier(TrackSwipeSlotOffsetModifier(
                        motion: controller.motion,
                        baseOffset: slot.baseOffset,
                        isPinned: slotPinned || hidden
                    ))
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(slot.isCurrent)
                    .accessibilityHidden(!slot.isCurrent)
            }
        }

        // Only mask the mini bar artist layer (no `.plusLighter`); fullscreen/header artist fade runs inside the shader to preserve backdrop vibrancy.
        let artistStack = applyArtistEdgeFade(rawArtistStack, isStationary: pinnedArtist)

        if let rowSpacing {
            VStack(alignment: .leading, spacing: rowSpacing) {
                titleStack
                artistStack
            }
        } else {
            ZStack(alignment: .topLeading) {
                titleStack
                artistStack
            }
        }
    }

    @ViewBuilder
    private func applyArtistEdgeFade<Layer: View>(_ layer: Layer, isStationary: Bool) -> some View {
        if viewportInsets.fadesOnlyWhenSliding {
            applyEdgeFade(layer, isStationary: isStationary)
        } else {
            layer
        }
    }

    private func applyEdgeFade<Layer: View>(_ layer: Layer, isStationary: Bool) -> some View {
        layer
            .frame(maxWidth: .infinity, alignment: rowSpacing == nil ? .topLeading : .leading)
            .padding(.leading, viewportInsets.leadingBleed)
            .padding(.trailing, viewportInsets.trailingBleed)
            .modifier(ReferenceTrackSwipeEdgeFade(
                enabled: true,
                slotWidth: activeWidth,
                insets: viewportInsets,
                verticalOverflow: verticalMaskOverflow,
                motion: viewportInsets.fadesOnlyWhenSliding ? controller.motion : nil,
                isStationary: isStationary
            ))
            .padding(.leading, -viewportInsets.leadingBleed)
            .padding(.trailing, -viewportInsets.trailingBleed)
    }

    private func visibleSlots(
        distance: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?
    ) -> [Slot] {
        let currentStep = controller.currentStep
        var result: [Slot] = []

        if controller.showsPreviousSlot {
            let exiting = controller.exitingSlot?.step == currentStep - 1 ? controller.exitingSlot : nil
            let track = exiting?.track ?? (controller.allowsOppositePreviousSlot ? previous?.track : nil)
            if let track {
                result.append(Slot(
                    id: "\(currentStep - 1):\(track.id)",
                    step: currentStep - 1,
                    track: track,
                    baseOffset: -distance,
                    isCurrent: false,
                    keepMarqueeActive: exiting != nil
                ))
            }
        }

        result.append(Slot(
            id: "\(currentStep):\(song.id)",
            step: currentStep,
            track: song,
            baseOffset: 0,
            isCurrent: true,
            keepMarqueeActive: true
        ))

        if controller.showsNextSlot {
            let exiting = controller.exitingSlot?.step == currentStep + 1 ? controller.exitingSlot : nil
            let track = exiting?.track ?? (controller.allowsOppositeNextSlot ? next?.track : nil)
            if let track {
                result.append(Slot(
                    id: "\(currentStep + 1):\(track.id)",
                    step: currentStep + 1,
                    track: track,
                    baseOffset: distance,
                    isCurrent: false,
                    keepMarqueeActive: exiting != nil
                ))
            }
        }

        return result
    }

    /// Commits at release for unit-level threshold/velocity verification, sharing the single source of truth with `panEnded`.
    static func selectTarget(
        translation: CGFloat,
        velocity: CGFloat,
        previous: PlayerAdjacentTrack?,
        next: PlayerAdjacentTrack?,
        distance: CGFloat,
        select: (Int) -> Void
    ) -> CGFloat? {
        guard let target = TrackSwipeController.resolveCommit(
            rawDragOffset: translation,
            dragBaseOffset: 0,
            translation: translation,
            velocity: velocity,
            distance: distance,
            previous: previous,
            next: next
        ) else { return nil }
        select(target.entry.index)
        return translation - target.direction * distance
    }
}

/// 只认横向拖动的平移手势。用 UIKit 手势是为了在作者名（原生按钮）和迷你条上拖动也能流畅仲裁并触发。
private struct NowPlayingHorizontalPan: UIGestureRecognizerRepresentable {
    let onStart: (CGFloat) -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancel: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.name = PlayerInteraction.trackSwipeGestureName
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        handle(recognizer)
    }

    func handle(_ recognizer: UIPanGestureRecognizer) {
        handle(
            recognizer.state,
            translation: recognizer.translation(in: recognizer.view).x,
            velocity: recognizer.velocity(in: recognizer.view).x,
            from: recognizer.view
        )
    }

    func handle(
        _ state: UIGestureRecognizer.State,
        translation: CGFloat,
        velocity: CGFloat = 0,
        from view: UIView? = nil
    ) {
        switch state {
        case .began:
            Self.cancelPopupBarHighlight(from: view)
            onStart(translation)
        case .changed:
            onChange(translation)
        case .ended:
            onEnd(translation, velocity)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }

    /// 第三方 LNPopupController 手势私有类名前缀契约；上游升级时集中在此核对。
    private enum LNPopupGestureClassName {
        static let longPress = "LNPopupLongPress"
        static let interactionPan = "LNPopupInteractionPan"
        static let openTap = "LNPopupOpenTap"
    }

    private static func cancelPopupBarHighlight(from view: UIView?) {
        var cursor = view
        while let current = cursor {
            for recognizer in current.gestureRecognizers ?? []
            where recognizer is UILongPressGestureRecognizer
                && NSStringFromClass(type(of: recognizer)).contains(LNPopupGestureClassName.longPress)
                && recognizer.isEnabled {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            cursor = current.superview
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let host = pan.view?.window ?? pan.view
            let translation = pan.translation(in: host)
            let dx = abs(translation.x)
            let dy = abs(translation.y)
            if dx > 0 || dy > 0 {
                return dx > dy * 1.15
            }
            let velocity = pan.velocity(in: host)
            return abs(velocity.x) > abs(velocity.y) * 1.15
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard otherGestureRecognizer !== gestureRecognizer else { return false }
            let otherClass = NSStringFromClass(type(of: otherGestureRecognizer))
            return otherClass.contains(LNPopupGestureClassName.interactionPan)
                || otherClass.contains(LNPopupGestureClassName.openTap)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            NSStringFromClass(type(of: otherGestureRecognizer)).contains(LNPopupGestureClassName.longPress)
        }
    }
}

private struct TrackSwipeGestureModifier: ViewModifier {
    let usesUIKitTouchSurface: Bool
    let pan: NowPlayingHorizontalPan

    @ViewBuilder func body(content: Content) -> some View {
        if usesUIKitTouchSurface {
            content.overlay { TrackSwipeTouchSurface(pan: pan) }
        } else {
            content.gesture(pan)
        }
    }
}

/// Gives mini-bar title slots a dedicated UIKit pan surface that cooperates with LNPopup gestures.
struct TrackSwipeTouchSurface: UIViewRepresentable {
    fileprivate let pan: NowPlayingHorizontalPan

    func makeCoordinator() -> Coordinator { Coordinator(pan: pan) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let gesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        gesture.name = PlayerInteraction.trackSwipeGestureName
        gesture.cancelsTouchesInView = true
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.pan = pan }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        fileprivate var pan: NowPlayingHorizontalPan
        private let directionDelegate = NowPlayingHorizontalPan.Coordinator()
        fileprivate init(pan: NowPlayingHorizontalPan) { self.pan = pan }
        @objc func handle(_ gesture: UIPanGestureRecognizer) { pan.handle(gesture) }

        func handle(
            _ state: UIGestureRecognizer.State,
            translation: CGFloat,
            velocity: CGFloat = 0,
            from view: UIView? = nil
        ) {
            pan.handle(state, translation: translation, velocity: velocity, from: view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            directionDelegate.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            directionDelegate.gestureRecognizer(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            directionDelegate.gestureRecognizer(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer)
        }
    }
}

/// Both player surfaces share one selection generator: swiping between tracks is a
/// value change, matching the system selection pattern.
@MainActor enum ReferenceTrackSwipeFeedback {
    private static let generator = UISelectionFeedbackGenerator()
    static func prepare() { generator.prepare() }
    static func selection() {
        generator.selectionChanged()
        generator.prepare()
    }
}

@MainActor
private final class TrackSwipeDisplayLinkTarget {
    private weak var owner: TrackSwipeController?

    init(owner: TrackSwipeController) {
        self.owner = owner
    }

    @objc func step(_ displayLink: CADisplayLink) {
        guard let owner else {
            displayLink.invalidate()
            return
        }
        owner.stepDisplayLink(displayLink)
    }
}

private struct TrackSwipeSlotOffsetModifier: ViewModifier {
    let motion: TrackSwipeOffsetModel
    let baseOffset: CGFloat
    let isPinned: Bool

    func body(content: Content) -> some View {
        content.offset(x: isPinned ? 0 : motion.value + baseOffset)
    }
}

private struct ReferenceTrackSwipeEdgeFade: ViewModifier {
    let enabled: Bool
    let slotWidth: CGFloat
    let insets: TrackSwipeViewportInsets
    var verticalOverflow: CGFloat = 0
    var motion: TrackSwipeOffsetModel? = nil
    var isStationary = false

    func body(content: Content) -> some View {
        let totalWidth = insets.leadingBleed + slotWidth + insets.trailingBleed
        let hasValidBounds = enabled && slotWidth > 1 && totalWidth > 1
        let strength: Double = {
            guard hasValidBounds else { return 0.0 }
            guard insets.fadesOnlyWhenSliding else { return 1.0 }
            guard !isStationary, let motion else { return 0.0 }
            return motion.edgeStrength
        }()
        let leadStop = hasValidBounds ? min(Double(insets.leadingFade / totalWidth), 0.45) : 0.0
        let trailStop = hasValidBounds ? max(1.0 - min(Double(insets.trailingFade / totalWidth), 0.45), leadStop) : 1.0
        let edgeAlpha = 1.0 - strength
        content
            .padding(.vertical, verticalOverflow)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(edgeAlpha), location: 0),
                        .init(color: .black, location: leadStop),
                        .init(color: .black, location: trailStop),
                        .init(color: .black.opacity(edgeAlpha), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .padding(.vertical, -verticalOverflow)
    }
}
