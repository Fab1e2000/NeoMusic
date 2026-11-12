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
    @ScaledMetric private var scaledFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.primaryFontSize
    @State private var browsing = false
    @State private var interacting = false
    @State private var resumeGeneration = 0
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var visibleIDs = Set<Int>()
    @State private var rowGeometry: LyricsRowGeometry
    /// 上一次对齐到的行；与新行相邻时才用弹簧动画，跳转（拖进度条、点歌词）直接到位。
    @State private var lastFocusedID: Int?
    @State private var visibility = LyricsScrollInterfaceVisibilityTracker()
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private var fontSize: CGFloat { fixedFontSize ?? scaledFontSize }

    init(lyrics: ReferenceLyrics, playerFrame: CGRect, activeID: Int?, bottomOverlayHeight: CGFloat,
         isActive: Bool, isInterfaceHidden: Binding<Bool>, onSeek: @escaping (Double) -> Void,
         playerCoordinateSpace: CoordinateSpace = .global, fixedFontSize: CGFloat? = nil,
         foreground: Color = .white, rowGeometry: LyricsRowGeometry = LyricsRowGeometry()) {
        self.lyrics = lyrics
        self.playerFrame = playerFrame
        self.activeID = activeID
        self.bottomOverlayHeight = bottomOverlayHeight
        self.isActive = isActive
        _isInterfaceHidden = isInterfaceHidden
        self.onSeek = onSeek
        self.playerCoordinateSpace = playerCoordinateSpace
        self.fixedFontSize = fixedFontSize
        self.foreground = foreground
        _rowGeometry = State(initialValue: rowGeometry)
    }

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: motion.lineSpacing) {
                    ForEach(lyrics.lines) { line in
                        lyricRow(line, focusTop: focusTop, stride: lineHeight + motion.lineSpacing)
                            .id(line.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.top, max(focusTop, motion.firstLineStartOffset))
                .padding(.bottom, max(height * (1 - anchor), 40))
            }
            .scrollPosition($position, anchor: UnitPoint(x: 0.5, y: anchor))
            .coordinateSpace(name: "localLyricsViewport")
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .mask(viewportMask(referenceRatio: referenceHeight / max(height, 1)))
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visibleIDs = Set($0) }
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
            .task(id: LyricsBrowseResumeRequest(generation: resumeGeneration, isActive: isActive,
                                                browsing: browsing, interacting: interacting)) {
                guard isActive, browsing, !interacting else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    try Task.checkCancellation()
                    browsing = false
                } catch { }
            }
            .onChange(of: isActive) { _, active in
                if active { browsing = false }
                else {
                    interacting = false
                    visibility.end()
                }
            }
            .onChange(of: activeID, initial: true) { _, id in
                rowGeometry.focus(on: id)
            }
            .onChange(of: FocusRequest(id: activeID, anchor: anchor, isActive: isActive,
                                      browsing: browsing), initial: true) { _, request in
                focus(request)
            }
        }
    }

    private func lyricRow(_ line: ReferenceLyricLine, focusTop: CGFloat, stride: CGFloat) -> some View {
        LocalLyricsRow(line: line, fontSize: fontSize, foreground: foreground,
                       focused: line.id == activeID, browsing: browsing, focusTop: focusTop,
                       stride: stride, coordinateSpaceName: "localLyricsViewport") {
            onSeek(line.time)
            browsing = false
            resumeGeneration += 1
            isInterfaceHidden = false
        }
        .onGeometryChange(for: LyricsRowGeometry.Measurement.self) { geometry in
            LyricsRowGeometry.Measurement(height: geometry.size.height,
                                          top: geometry.frame(in: .named("localLyricsViewport")).minY)
        } action: {
            rowGeometry.record($0, for: line.id)
        }
        .onDisappear { rowGeometry.discardPosition(for: line.id) }
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

    /// Native identity-based scrolling retains the target as lazy rows acquire their real heights.
    private func focus(_ request: FocusRequest) {
        guard request.isActive, !request.browsing, let id = request.id else { return }
        let adjacent = lastFocusedID.map { abs($0 - id) <= 1 } ?? false
        let animated = lastFocusedID != nil && (adjacent || visibleIDs.contains(id)) && !reducesMotion
        lastFocusedID = id
        let spring = motion.lineChangeSpring
        withAnimation(animated ? .interpolatingSpring(
            mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping) : nil) {
            position.scrollTo(id: id, anchor: UnitPoint(x: 0.5, y: request.anchor))
        }
    }
}

private struct FocusRequest: Equatable {
    let id: Int?
    let anchor: CGFloat
    let isActive: Bool
    let browsing: Bool
}

private struct LyricsBrowseResumeRequest: Equatable {
    let generation: Int
    let isActive: Bool
    let browsing: Bool
    let interacting: Bool
}

/// Shared lyric appearance and native button feedback; scrolling belongs to each container.
struct LocalLyricsRow: View {
    let line: ReferenceLyricLine
    let fontSize: CGFloat
    let foreground: Color
    let focused: Bool
    let browsing: Bool
    let focusTop: CGFloat
    let stride: CGFloat
    let coordinateSpaceName: String
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6

    var body: some View {
        let disablesBlur = focused || browsing || contrast == .increased || reducesMotion
        let opacity = focused || browsing ? 1 : contrast == .increased
            ? motion.increasedContrastDeselectedTextOpacity : motion.deselectedTextOpacity
        LyricPressInteraction(isSelected: false, allowsLongPress: false, onTap: onTap, onLongPress: {}) { pressProgress in
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: fontSize, weight: .bold))
                .multilineTextAlignment(.leading)
                .foregroundStyle(foreground.opacity(opacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(foreground.opacity(pressProgress * 0.12), in: .rect(cornerRadius: 12))
        }
        .scaleEffect(focused ? 1 : motion.deselectedScale, anchor: .topLeading)
        .visualEffect { content, geometry in
            let distance = abs(geometry.frame(in: .named(coordinateSpaceName)).midY - focusTop)
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
}
