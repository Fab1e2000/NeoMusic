import SwiftUI

/// 播放页和迷你播放器的播放/暂停图标。切换时旧图标缩小、变模糊并淡出，
/// 新图标从模糊中放大、变清晰（接近系统替换图标的质感）。
/// 尺寸由外部的 frame 决定。图形自己画，圆角比 SF Symbols 的 play.fill / pause.fill 更大。
struct NowPlayingPlayPauseIcon: View {
    let isPlaying: Bool
    let reducesMotion: Bool
    /// 圆角半径，图标越小设得越小；模糊半径跟着它按比例变化。
    var cornerRadius: CGFloat = 5

    var body: some View {
        ZStack {
            Group {
                if isPlaying {
                    NowPlayingPauseGlyph(cornerRadius: cornerRadius)
                } else {
                    NowPlayingPlayGlyph(cornerRadius: cornerRadius)
                }
            }
            .transition(
                .modifier(
                    active: NowPlayingBlurScale(scale: 0.5, blur: cornerRadius * 1.4, opacity: 0),
                    identity: NowPlayingBlurScale(scale: 1, blur: 0, opacity: 1)
                )
            )
        }
        .animation(
            reducesMotion ? nil : .spring(duration: 0.38, bounce: 0.18),
            value: isPlaying
        )
    }
}

private struct NowPlayingBlurScale: ViewModifier {
    let scale: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// 圆角三角形（尖朝右）：路径先往里收一个圆角半径，再用同色圆角描边撑回原大小，三个角就是圆的。
/// 播放按钮和上一首/下一首的双三角都用它。
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

/// 两根圆角竖条，各占宽度的 39%（照 SF Symbols 的 pause.fill）。
private struct NowPlayingPauseGlyph: View {
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width * 0.39
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: barWidth)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: barWidth)
            }
        }
    }
}
