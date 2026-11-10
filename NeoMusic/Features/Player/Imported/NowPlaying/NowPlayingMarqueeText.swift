import SwiftUI

/// 放不下时滚动的单行文字（和系统音乐的歌名一样）：先停一会儿，再匀速向左滚一整圈，
/// 后面接着第二份文字，首尾相连，滚完回到起点再停。放得下时就是普通的 Text。
/// 字体、颜色跟随外部环境；`isActive` 为 false（比如相邻曲目的预览）或减弱动态效果时不滚，截断显示。
struct NowPlayingMarqueeText: View {
    let text: String
    var isActive = true
    var edrFontSize: CGFloat? = nil
    var edrFontSizeIsScaled = false

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.playerVisualsActive) private var visualsActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// 这一轮滚动的起点；换歌时重新计时，从头开始。
    @State private var startDate = Date.now

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

    @ViewBuilder private var titleText: some View {
        if let edrFontSize {
            PlayerWhiteEDRText(text: text, fontSize: edrFontSize, fontSizeIsScaled: edrFontSizeIsScaled)
        }
        else { Text(text) }
    }

    var body: some View {
        titleText
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .background(alignment: .leading) {
                // 量文字完整宽度用，不显示。
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    scrollingText
                }
            }
            .onChange(of: text) { startDate = .now }
            .onChange(of: scrolls) { _, active in if active { startDate = .now } }
            .accessibilityLabel(text)
    }

    private var scrollingText: some View {
        let distance = textWidth + Self.gap
        let scrollDuration = TimeInterval(distance / Self.speed)
        let cycle = Self.pause + scrollDuration
        return TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let phase = elapsed.truncatingRemainder(dividingBy: cycle)
            let progress = max(0, phase - Self.pause) / scrollDuration
            let offset = -CGFloat(progress) * distance
            let isMoving = phase > Self.pause
            HStack(spacing: Self.gap) {
                titleText.lineLimit(1).fixedSize()
                titleText.lineLimit(1).fixedSize()
            }
            .offset(x: offset)
            .frame(width: containerWidth, alignment: .leading)
            .clipped()
            .mask {
                // 停着时只有右侧渐隐（文字被截在右边）；滚动时左侧也渐隐。
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fadeWidth)
                        .opacity(isMoving ? 1 : 0)
                        .overlay { Color.black.opacity(isMoving ? 0 : 1) }
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fadeWidth)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
