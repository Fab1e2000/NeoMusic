// Adapted from MeloX AppleMusicLyricsView (GPL-3.0), commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a. Uses its default typography,
// focus geometry, distance blur, viewport mask and press interaction.
// The data adapter accepts local line timestamps; no network lyric provider.
import SwiftUI

struct AppleMusicLocalLyricsView: View {
    let lyrics: ReferenceLyrics
    let playerFrame: CGRect
    @AppStorage(LyricsFocus.storageKey) private var focusPosition = 0.5
    let activeID: Int?
    let bottomOverlayHeight: CGFloat
    let isActive: Bool
    @Binding var isInterfaceHidden: Bool
    let onSeek: (Double) -> Void
    /// Must match playerFrame; a movable presentation should use its own space.
    var playerCoordinateSpace: CoordinateSpace = .global
    /// macOS 侧边歌词面板使用较小的固定字号和随系统外观变化的文字颜色；iOS 播放页保持默认值。
    var fixedFontSize: CGFloat? = nil
    var foreground: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric private var scaledFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.primaryFontSize
    @State private var browsing = false
    @State private var interacting = false
    @State private var resumeGeneration = 0
    @State private var rowGeometry = LyricsRowGeometry()
    /// 上一次对齐到的行；与新行相邻时才用弹簧动画，跳转（拖进度条、点歌词）直接到位。
    @State private var lastFocusedID: Int?
    @State private var visibility = LyricsScrollInterfaceVisibilityTracker()
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private var fontSize: CGFloat { fixedFontSize ?? scaledFontSize }

    var body: some View {
        GeometryReader { viewport in
            let height = viewport.size.height
            let referenceHeight = max(height - min(max(bottomOverlayHeight, 0), max(height - 1, 0)), 1)
            let lineHeight = LyricsFontMetrics.boldLineHeight(size: fontSize)
            let focusedHeight = rowGeometry.height(for: activeID) ?? lineHeight
            let visibleHeight = isInterfaceHidden ? height : referenceHeight
            let preferredY = playerFrame.minY + playerFrame.height * min(max(focusPosition.isFinite ? focusPosition : 0.5, 0.05), 0.8)
                - viewport.frame(in: playerCoordinateSpace).minY
            let focusTop = min(max(preferredY - focusedHeight / 2, visibleHeight * 0.08),
                               max(visibleHeight * 0.08, visibleHeight * 0.84 - focusedHeight))
            let anchor = min(max(focusTop / max(height - focusedHeight, 1), 0), 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: motion.lineSpacing) {
                        ForEach(lyrics.lines) { line in
                            lyricRow(line, focusTop: focusTop, stride: lineHeight + motion.lineSpacing)
                                .id(line.id)
                        }
                    }
                    .padding(.top, max(focusTop, motion.firstLineStartOffset))
                    .padding(.bottom, max(height * (1 - anchor), 40))
                }
                .coordinateSpace(name: "localLyricsViewport")
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .mask(viewportMask(referenceRatio: referenceHeight / max(height, 1)))
                .onScrollPhaseChange { _, phase in
                    interacting = phase == .interacting || phase == .decelerating || phase == .tracking
                    if phase == .interacting {
                        browsing = true
                        resumeGeneration += 1
                        visibility.begin(isInterfaceVisible: !isInterfaceHidden)
                    } else if phase == .idle {
                        visibility.end()
                        resumeGeneration += 1
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                    guard interacting else { return }
                    if let visible = visibility.update(offsetDelta: new - old, hideThreshold: 120) {
                        isInterfaceHidden = !visible
                    }
                }
                .task(id: resumeGeneration) {
                    guard browsing, !interacting else { return }
                    do {
                        try await Task.sleep(for: .seconds(3))
                        try Task.checkCancellation()
                        browsing = false
                    } catch { }
                }
                .onChange(of: isActive) { _, active in
                    if active { browsing = false } else { resumeGeneration += 1 }
                }
                .onChange(of: activeID, initial: true) { _, id in
                    rowGeometry.focus(on: id)
                }
                // 当前行、聚焦位置、页面是否显示或是否在手动浏览变化时，重新对齐；新请求会取消旧的。
                .task(id: FocusRequest(id: activeID, focusTop: focusTop, isActive: isActive, browsing: browsing)) {
                    await focus(proxy, anchor: anchor, focusTop: focusTop, viewportHeight: height)
                }
            }
        }
    }

    private func lyricRow(_ line: ReferenceLyricLine, focusTop: CGFloat, stride: CGFloat) -> some View {
        let focused = line.id == activeID
        let disablesBlur = focused || browsing || contrast == .increased || reducesMotion
        let opacity = focused || browsing ? 1 : contrast == .increased
            ? motion.increasedContrastDeselectedTextOpacity : motion.deselectedTextOpacity
        return LyricPressInteraction(isSelected: false, allowsLongPress: false, onTap: {
            onSeek(line.time)
            browsing = false
            resumeGeneration += 1
            isInterfaceHidden = false
        }, onLongPress: {}) { pressProgress in
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: fontSize, weight: .bold))
                .multilineTextAlignment(.leading)
                .foregroundStyle(foreground.opacity(opacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(foreground.opacity(pressProgress * 0.12), in: .rect(cornerRadius: 12))
        }
        .scaleEffect(focused ? 1 : motion.deselectedScale, anchor: .topLeading)
        .onGeometryChange(for: LyricsRowGeometry.Measurement.self) { geometry in
            LyricsRowGeometry.Measurement(
                height: geometry.size.height,
                top: geometry.frame(in: .named("localLyricsViewport")).minY
            )
        } action: {
            rowGeometry.record($0, for: line.id)
        }
        .onDisappear { rowGeometry.discardPosition(for: line.id) }
        .visualEffect { content, geometry in
            let distance = abs(geometry.frame(in: .named("localLyricsViewport")).midY - focusTop)
            let relativeDistance = max(distance / max(stride, 1), 0)
            let blur = motion.nonFocusedBlurRadius + (motion.maximumNonFocusedBlurRadius - motion.nonFocusedBlurRadius)
                * min(max(relativeDistance - 1, 0), 1)
            return content.blur(radius: disablesBlur ? 0 : blur)
        }
        .animation(reducesMotion ? nil : .timingCurve(
            motion.focusBlurTransitionControlPoint1X, motion.focusBlurTransitionControlPoint1Y,
            motion.focusBlurTransitionControlPoint2X, motion.focusBlurTransitionControlPoint2Y,
            duration: motion.focusBlurTransitionDuration), value: focused)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    private func viewportMask(referenceRatio: CGFloat) -> some View {
        let bottomClear = isInterfaceHidden ? 1 : referenceRatio
        let bottomFade = isInterfaceHidden ? 0.08 : 0.16 * referenceRatio
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08 * referenceRatio),
            .init(color: .black, location: max(0.08 * referenceRatio, bottomClear - bottomFade)),
            .init(color: .clear, location: bottomClear),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .animation(reducesMotion ? nil : .smooth(duration: 0.35), value: isInterfaceHidden)
    }

    /// 移植 MeloX 的 ensureFocusAlignment：LazyVStack 里还没排版的行只有估算高度，
    /// 跳到较远的行时 scrollTo 会按估算位置停下，歌词就错位了。所以滚动后核对这一行的实际位置，
    /// 不在聚焦位置就不带动画再滚一次，直到对齐。
    private func focus(_ proxy: ScrollViewProxy, anchor: CGFloat, focusTop: CGFloat, viewportHeight: CGFloat) async {
        guard isActive, !browsing, let id = activeID else { return }
        // 相邻的行、或者已经在屏幕上的行（点了一句歌词）用弹簧滚过去；其余直接跳到位。
        let isAdjacent = lastFocusedID.map { abs($0 - id) <= 1 } ?? false
        let isOnScreen = lastFocusedID != nil && rowGeometry.top(for: id).map { abs($0 - focusTop) < viewportHeight } == true
        lastFocusedID = id
        let spring = motion.lineChangeSpring
        let animated = (isAdjacent || isOnScreen) && !reducesMotion
        withAnimation(animated ? .interpolatingSpring(
            mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping) : nil) {
            proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: anchor))
        }
        // 动画中的位置还在变化，等弹簧基本停下再核对。
        do { try await Task.sleep(for: .milliseconds(animated ? 700 : 32)) } catch { return }
        for _ in 0..<8 {
            if let top = rowGeometry.top(for: id), abs(top - focusTop) <= 2 { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: anchor)) }
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
        }
    }
}

private struct FocusRequest: Hashable {
    let id: Int?
    let focusTop: CGFloat
    let isActive: Bool
    let browsing: Bool
}
