import SwiftUI

/// 放不下时滚动的单行文字（和系统音乐的歌名一样）：先停一会儿，再匀速向左滚一整圈，
/// 后面接着第二份文字，首尾相连，滚完回到起点再停。放得下时就是普通的 Text。
/// 字体、颜色跟随外部环境；`isActive` 为 false（比如相邻曲目的预览）或减弱动态效果时不滚，截断显示。
public struct NowPlayingMarqueeText: View {
    let text: String
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    /// 首尾两份文字之间的空隙。
    private static let gap: CGFloat = 40
    /// 滚动速度（pt/秒）。
    private static let speed: CGFloat = 30
    /// 每一圈开始前停留的时间。
    private static let pause: TimeInterval = 2.5
    /// 两侧渐隐的宽度。
    private static let fadeWidth: CGFloat = 12

    private var scrolls: Bool {
        isActive && visualsActive && scenePhase == .active && !accessibilityReduceMotion
            && containerWidth > 0 && textWidth > containerWidth + 0.5
    }

    public init(text: String, isActive: Bool = true) { self.text = text; self.isActive = isActive }

    public var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                guard containerWidth != width else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { containerWidth = width }
            }
            .background(alignment: .leading) {
                // 量文字完整宽度用，不显示。
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        guard textWidth != width else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { textWidth = width }
                    }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    scrollingText
                        .transition(.identity)
                }
            }
            // 宽度测量后插入的滚动文字与外层共用切页几何动画。
            .geometryGroup()
            .accessibilityLabel(text)
    }

    private var scrollingText: some View {
        let distance = textWidth + Self.gap
        let scrollDuration = TimeInterval(distance / Self.speed)
        let width = containerWidth
        let fadeWidth = Self.fadeWidth
        return HStack(spacing: Self.gap) {
            Text(text).lineLimit(1).fixedSize()
            Text(text).lineLimit(1).fixedSize()
        }
        .keyframeAnimator(initialValue: CGFloat.zero) { content, progress in
            content
                .offset(x: -progress * distance)
                .frame(width: width, alignment: .leading)
                .clipped()
                .mask {
                    // 停着时只有右侧渐隐（文字被截在右边）；滚动时左侧也渐隐。
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: fadeWidth)
                            .opacity(progress > 0 ? 1 : 0)
                            .overlay { Color.black.opacity(progress > 0 ? 0 : 1) }
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: fadeWidth)
                    }
                }
        } keyframes: { _ in
            MoveKeyframe(CGFloat.zero)
            LinearKeyframe(CGFloat.zero, duration: Self.pause)
            LinearKeyframe(CGFloat(1), duration: scrollDuration)
        }
        .id(text)
        .accessibilityHidden(true)
    }
}
