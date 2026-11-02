import SwiftUI

/// 上一首/下一首的双三角图标。每次 `trigger` 变化，箭头往前“推进”一格：
/// 整排三角形平移一个三角形的宽度，最前面的一个缩小淡出，后面补进来一个从小放大淡入。
/// 尺寸由外部的 frame 决定。
struct NowPlayingSkipIcon: View {
    enum Direction {
        case forward
        case backward
    }

    let direction: Direction
    let trigger: Int
    let reducesMotion: Bool
    /// 圆角半径，图标越小设得越小。
    var cornerRadius: CGFloat = 2.5

    /// 推进了几格。只增不减：推进一格前后的画面一样，停在任何整数上都对，连续点击也能接着推。
    @State private var progress: CGFloat = 0

    var body: some View {
        NowPlayingSkipTriangles(progress: progress, cornerRadius: cornerRadius)
            .scaleEffect(x: direction == .forward ? 1 : -1)
            .onChange(of: trigger) {
                guard !reducesMotion else { return }
                withAnimation(.smooth(duration: 0.42)) {
                    progress += 1
                }
            }
    }
}

/// 按进度的小数部分摆三个三角形。`progress` 是可动画的，动画中每一帧都会用插值后的值重画。
nonisolated private struct NowPlayingSkipTriangles: View, Animatable {
    var progress: CGFloat
    let cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            // 两个三角形各占一半宽度，前一个的尖正好碰到后一个的底边。
            let width = proxy.size.width / 2
            let height = proxy.size.height
            let phase = progress - progress.rounded(.down)
            ZStack(alignment: .leading) {
                // -1：后面补进来的；0：后面那个；1：最前面那个，推进时移出。
                ForEach(-1...1, id: \.self) { index in
                    let position = CGFloat(index) + phase
                    NowPlayingPlayGlyph(cornerRadius: cornerRadius, verticalInset: 0.08)
                        .frame(width: width, height: height)
                        .scaleEffect(Self.visibility(at: position))
                        .opacity(Self.visibility(at: position))
                        .offset(x: position * width)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .leading)
            // `progress` already contains the system's interpolated presentation
            // value. Do not animate the child offsets again when phase wraps and
            // fixed triangle identities exchange their visual slots.
            .transaction { $0.animation = nil }
        }
    }

    /// 位置 0、1 是静止时的两个三角形；越过这两个位置就缩小、变透明。
    private static func visibility(at position: CGFloat) -> CGFloat {
        if position < 0 { return max(0, 1 + position) }
        if position > 1 { return max(0, 2 - position) }
        return 1
    }
}
