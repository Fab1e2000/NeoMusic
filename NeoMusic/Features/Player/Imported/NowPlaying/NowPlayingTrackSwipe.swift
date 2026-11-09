import SwiftUI
import UIKit

/// 全屏播放器里“歌名 + 作者”这一块：左右滑动切到上一首/下一首（和系统音乐一样，任何页面都可以）。
///
/// 拖动时当前歌名跟手，相邻一首的歌名从旁边淡入；松手过线或甩得够快就切歌并振动，否则弹回。
/// 没有相邻曲目的方向会有阻尼。手势只认横向拖动，不影响下拉收起播放器和点作者名弹菜单。
struct NowPlayingTrackSwipe<Content: View>: View {
    let song: ReferenceTrack
    /// 相邻歌名离当前歌名的距离；不传时用这一块自己的宽度再留一点间隔。
    var pageDistance: CGFloat? = nil
    /// LN hosts title content in a separate controller; give that slot an explicit touch surface.
    var usesUIKitTouchSurface = false
    /// `interactive` 为 false 时是相邻曲目的预览，只显示文字，不响应点击。
    @ViewBuilder let content: (_ track: ReferenceTrack, _ interactive: Bool) -> Content

    @Environment(ReferencePlayerState.self) private var player
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var offset: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0
    @State private var isCommitting = false

    private static var spacing: CGFloat { 24 }

    var body: some View {
        let previous = player.previousInOrder
        let next = player.nextInOrder
        let distance = max(pageDistance ?? (measuredWidth + Self.spacing), 1)

        ZStack(alignment: .topLeading) {
            if offset > 0, let previous {
                neighbor(previous.track, at: offset - distance, distance: distance)
            }
            content(song, true)
                .offset(x: offset)
                .opacity(Self.visibility(at: offset, distance: distance))
            if offset < 0, let next {
                neighbor(next.track, at: offset + distance, distance: distance)
            }
        }
        .modifier(ReferenceTrackSwipeEdgeFade(displacement: offset, pageDistance: distance, width: measuredWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .modifier(TrackSwipeGestureModifier(
            usesUIKitTouchSurface: usesUIKitTouchSurface,
            pan: NowPlayingHorizontalPan(
                onChange: { translation in
                    guard !isCommitting else { return }
                    let hasNeighbor = translation < 0 ? next != nil : previous != nil
                    // 没有相邻曲目的方向加阻尼。
                    offset = hasNeighbor ? translation : translation * 0.25
                },
                onEnd: { translation, velocity in
                    finish(translation: translation, velocity: velocity,
                           previous: previous, next: next, distance: distance)
                },
                onCancel: {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { offset = 0 }
                },
                onStart: { ReferenceTrackSwipeFeedback.prepare() }
            )
        ))
    }

    private func neighbor(_ track: ReferenceTrack, at x: CGFloat, distance: CGFloat) -> some View {
        content(track, false)
            .offset(x: x)
            .opacity(Self.visibility(at: x, distance: distance))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 离原位越远越透明。静止时透明度正好是 1：作者名的叠加提亮只在透明度为 1 时生效。
    private static func visibility(at x: CGFloat, distance: CGFloat) -> Double {
        max(0, 1 - abs(x) / distance)
    }

    private func finish(
        translation: CGFloat,
        velocity: CGFloat,
        previous: ReferenceUpcomingTrack?,
        next: ReferenceUpcomingTrack?,
        distance: CGFloat
    ) {
        guard !isCommitting else { return }
        let threshold = distance * 0.3
        let target: (entry: ReferenceUpcomingTrack, direction: CGFloat)?
        if (translation < -threshold || velocity < -600), translation <= 0, let next {
            target = (next, -1)
        } else if (translation > threshold || velocity > 600), translation >= 0, let previous {
            target = (previous, 1)
        } else {
            target = nil
        }

        guard let target else {
            withAnimation(accessibilityReduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)) {
                offset = 0
            }
            return
        }

        isCommitting = true
        ReferenceTrackSwipeFeedback.selection()
        let commit = {
            player.skip(toQueueIndex: target.entry.index)
            // 新的当前曲目就是刚滑过来的那一首，瞬间归位看不出跳动。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { offset = 0 }
            isCommitting = false
        }
        if accessibilityReduceMotion {
            commit()
        } else {
            withAnimation(.spring(duration: 0.28, bounce: 0), completionCriteria: .logicallyComplete) {
                offset = target.direction * distance
            } completion: {
                commit()
            }
        }
    }
}

/// 只认横向拖动的平移手势。用 UIKit 手势是为了在作者名（原生按钮）上拖动也能识别。
private struct NowPlayingHorizontalPan: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancel: () -> Void
    /// 手势开始时预热切歌触感，触发那一刻延迟更低。
    var onStart: (() -> Void)? = nil

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        // Shared explicitly with LN's external-source dismissal recognizer.
        pan.name = "NeoDizzy.NowPlayingTrackSwipe"
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        handle(recognizer)
    }

    func handle(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onStart?()
            onChange(translation)
        case .changed:
            onChange(translation)
        case .ended:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Use accumulated travel, leaving diagonal intent to the player pan.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view?.window)
            return abs(translation.x) > abs(translation.y) * 1.25
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.name == "LNPopupExternalDismissPan"
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

/// Only the miniature title slot gets this clear view. Its ancestor LN tap/pan
/// recognizers still receive taps and vertical drags; artwork is a sibling.
private struct TrackSwipeTouchSurface: UIViewRepresentable {
    let pan: NowPlayingHorizontalPan

    func makeCoordinator() -> Coordinator { Coordinator(pan: pan) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        gesture.name = "NeoDizzy.NowPlayingTrackSwipe"
        gesture.delegate = context.coordinator.directionDelegate
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.pan = pan }

    @MainActor final class Coordinator: NSObject {
        var pan: NowPlayingHorizontalPan
        let directionDelegate = NowPlayingHorizontalPan.Coordinator()
        init(pan: NowPlayingHorizontalPan) { self.pan = pan }
        @objc func handle(_ gesture: UIPanGestureRecognizer) { pan.handle(gesture) }
    }
}

/// Both player surfaces share one selection generator: swiping between tracks is a
/// value change, matching the system selection pattern. The gesture prepares it on
/// start for low-latency firing, and firing re-prepares for back-to-back swipes.
@MainActor enum ReferenceTrackSwipeFeedback {
    private static let generator = UISelectionFeedbackGenerator()
    static func prepare() { generator.prepare() }
    static func selection() {
        generator.selectionChanged()
        generator.prepare()
    }
}

nonisolated private struct ReferenceTrackSwipeEdgeFade: ViewModifier, Animatable {
    var displacement: CGFloat
    let pageDistance: CGFloat
    let width: CGFloat
    var animatableData: CGFloat {
        get { displacement }
        set { displacement = newValue }
    }
    func body(content: Content) -> some View {
        let safeWidth = max(width, 1)
        let fadeWidth = min(CGFloat(10), safeWidth / 4)
        let travel = abs(displacement - (displacement / pageDistance).rounded() * pageDistance)
        let edgeOpacity = 1 - min(travel / fadeWidth, 1)
        content.mask {
            LinearGradient(stops: [
                .init(color: .black.opacity(edgeOpacity), location: 0),
                .init(color: .black, location: fadeWidth / safeWidth),
                .init(color: .black, location: 1 - fadeWidth / safeWidth),
                .init(color: .black.opacity(edgeOpacity), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}
