import SwiftUI

/// 播放页和迷你播放器的播放/暂停图标。使用原生 SF Symbols（保持与系统音乐一致的利落圆角），
/// 切换时旧图标迅速缩小淡出、新图标零模糊从中心放大并以单次轻微过冲回稳。
public struct NowPlayingPlayPauseIcon: View {
    let isPlaying: Bool
    let reducesMotion: Bool
    /// 播放三角相对容器的水平视觉补偿（对齐暂停双竖条重心）。
    var playOffsetX: CGFloat = 1.8

    public init(isPlaying: Bool, reducesMotion: Bool, playOffsetX: CGFloat = 1.8) {
        self.isPlaying = isPlaying; self.reducesMotion = reducesMotion; self.playOffsetX = playOffsetX
    }

    public var body: some View {
        ZStack {
            if isPlaying {
                Image(systemName: "pause.fill")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .transition(morphTransition)
            } else {
                Image(systemName: "play.fill")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(0.99)
                    .offset(x: playOffsetX)
                    .transition(morphTransition)
            }
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.50, bounce: 0.36), value: isPlaying)
    }

    private var morphTransition: AnyTransition {
        if reducesMotion {
            return .opacity
        }
        return AnyTransition(NowPlayingPlayPauseTransition())
    }
}

private struct NowPlayingPlayPauseTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let isDisappearing = phase == .didDisappear
        let scale: CGFloat = switch phase {
        case .willAppear: 0.14
        case .identity: 1.0
        case .didDisappear: 0.10
        }
        content
            .scaleEffect(scale)
            .animation(
                isDisappearing
                    ? .easeInOut(duration: 0.15)
                    : .spring(duration: 0.50, bounce: 0.36),
                value: phase
            )
            .opacity(phase == .identity ? 1 : 0)
            .animation(
                isDisappearing
                    ? .linear(duration: 0.13)
                    : .easeOut(duration: 0.19),
                value: phase
            )
    }
}

/// 圆角三角形（尖朝右）：路径先往里收一个圆角半径，再用同色圆角描边撑回原大小，三个角就是圆的。
/// 上一首/下一首的双三角使用它。
struct NowPlayingPlayGlyph: View {
    let cornerRadius: CGFloat
    /// 上下各留的比例，照 SF Symbols：播放三角形留 5%，上一首/下一首的三角形留 8%。
    var verticalInset: CGFloat = 0.05

    var body: some View {
        let shape = NowPlayingPlayShape(inset: cornerRadius, verticalInset: verticalInset)
        ZStack {
            shape.fill()
            shape.stroke(style: StrokeStyle(lineWidth: cornerRadius * 2, lineJoin: .round))
        }
        // 先合成一层再做过渡的透明、模糊：否则填充和描边各自半透明，重叠处会显出一圈层纹。
        .compositingGroup()
    }
}

private struct NowPlayingPlayShape: Shape {
    let inset: CGFloat
    let verticalInset: CGFloat

    func path(in bounds: CGRect) -> Path {
        let vertical = bounds.height * verticalInset
        let rect = bounds.insetBy(dx: inset, dy: inset + vertical)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
