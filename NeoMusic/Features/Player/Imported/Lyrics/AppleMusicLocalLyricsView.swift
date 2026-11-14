// Adapted from MeloX AppleMusicLyricsView (GPL-3.0), commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a. Uses its default typography,
// distance blur, viewport mask and press interaction. Typography and focus
// geometry follow the supplied Music references.
// The data adapter accepts local line timestamps; no network lyric provider.
import SwiftUI

struct AppleMusicLocalLyricsView: View {
    let lyrics: ReferenceLyrics
    let activeID: Int?
    let bottomOverlayHeight: CGFloat
    let isActive: Bool
    @Binding var isInterfaceHidden: Bool
    let onSeek: (Double) -> Void
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
    @State private var restingFocusTop: CGFloat = 0
    @State private var restingAnchor: CGFloat = 0.5
    @State private var visibility = LyricsScrollInterfaceVisibilityTracker()
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6
    private var fontSize: CGFloat { fixedFontSize ?? scaledFontSize }

    init(lyrics: ReferenceLyrics, activeID: Int?, bottomOverlayHeight: CGFloat,
         isActive: Bool, isInterfaceHidden: Binding<Bool>, onSeek: @escaping (Double) -> Void,
         fixedFontSize: CGFloat? = nil,
         foreground: Color = .white, rowGeometry: LyricsRowGeometry = LyricsRowGeometry()) {
        self.lyrics = lyrics
        self.activeID = activeID
        self.bottomOverlayHeight = bottomOverlayHeight
        self.isActive = isActive
        _isInterfaceHidden = isInterfaceHidden
        self.onSeek = onSeek
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
            // The reference places the leading line near the upper quarter of the
            // visible lyrics, with wrapped lines continuing below that position.
            let preferredTop = visibleHeight * 0.233 - lineHeight / 2
            let focusTop = min(max(preferredTop, visibleHeight * 0.08),
                               max(visibleHeight * 0.08, visibleHeight * 0.84 - focusedHeight))
            let anchor = min(max(focusTop / max(height - focusedHeight, 1), 0), 1)
            // Keep the last active focus while the outgoing page shrinks.
            let appliedFocusTop = isActive ? focusTop : restingFocusTop
            let scrollAnchor = isActive ? anchor : restingAnchor
            let viewportFade = LyricsViewportFade(
                height: height,
                referenceHeight: referenceHeight,
                isInterfaceHidden: isInterfaceHidden
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: motion.lineSpacing) {
                    ForEach(lyrics.lines) { line in
                        lyricRow(
                            line,
                            focusTop: appliedFocusTop,
                            stride: lineHeight + motion.lineSpacing,
                            viewportFade: viewportFade
                        )
                            .id(line.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.top, max(appliedFocusTop, motion.firstLineStartOffset))
                .padding(.bottom, max(height * (1 - scrollAnchor), 40))
            }
            .scrollPosition($position, anchor: UnitPoint(x: 0.5, y: scrollAnchor))
            .coordinateSpace(name: "localLyricsViewport")
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
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
            .onChange(of: focusTop, initial: true) { _, newValue in
                if isActive { restingFocusTop = newValue }
            }
            .onChange(of: anchor, initial: true) { _, newValue in
                if isActive { restingAnchor = newValue }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    restingFocusTop = focusTop
                    restingAnchor = anchor
                    browsing = false
                } else {
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

    private func lyricRow(
        _ line: ReferenceLyricLine,
        focusTop: CGFloat,
        stride: CGFloat,
        viewportFade: LyricsViewportFade
    ) -> some View {
        LocalLyricsRow(
            line: line,
            fontSize: fontSize,
            foreground: foreground,
            focused: line.id == activeID,
            browsing: browsing,
            focusTop: focusTop,
            stride: stride,
            coordinateSpaceName: "localLyricsViewport",
            viewportFade: viewportFade,
            isInterfaceHidden: isInterfaceHidden
        ) {
            guard isActive else { return }
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

nonisolated struct LyricsViewportFade: Equatable, Sendable {
    var topEnd: CGFloat = 0
    var bottomStart: CGFloat = .greatestFiniteMagnitude
    var bottomEnd: CGFloat = .greatestFiniteMagnitude

    init(
        topEnd: CGFloat = 0,
        bottomStart: CGFloat = .greatestFiniteMagnitude,
        bottomEnd: CGFloat = .greatestFiniteMagnitude
    ) {
        self.topEnd = topEnd
        self.bottomStart = bottomStart
        self.bottomEnd = bottomEnd
    }

    init(height: CGFloat, referenceHeight: CGFloat, isInterfaceHidden: Bool) {
        let ratio = referenceHeight / max(height, 1)
        let bottomClear = isInterfaceHidden ? 1 : ratio
        let bottomFade = isInterfaceHidden ? 0.08 : 0.16 * ratio
        let topLocation = 0.08 * ratio
        self.init(
            topEnd: topLocation * height,
            bottomStart: max(topLocation, bottomClear - bottomFade) * height,
            bottomEnd: bottomClear * height
        )
    }
}

nonisolated private struct LyricsEdgeVisualModifier: ViewModifier, Animatable {
    var fade: LyricsViewportFade
    let isInterfaceHidden: Bool
    let reducesMotion: Bool
    let coordinateSpaceName: String
    let disablesBlur: Bool
    let focusTop: CGFloat
    let stride: CGFloat
    let motion: AppleMusicLyricsMotionProfile
    let blendPlusLighter: Bool

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(fade.topEnd, .init(fade.bottomStart, fade.bottomEnd)) }
        set {
            fade.topEnd = newValue.first
            fade.bottomStart = newValue.second.first
            fade.bottomEnd = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let currentFade = fade
        content
            .visualEffect { inner, geometry in
                let frame = geometry.frame(in: .named(coordinateSpaceName))
                let scaleY = frame.height / max(geometry.size.height, 1)
                let blur: CGFloat
                if disablesBlur {
                    blur = 0
                } else {
                    let distance = abs(frame.midY - focusTop)
                    let relativeDistance = max(distance / max(stride, 1), 0)
                    blur = motion.nonFocusedBlurRadius
                        + (motion.maximumNonFocusedBlurRadius - motion.nonFocusedBlurRadius)
                        * min(max(relativeDistance - 1, 0), 1)
                }
                let needsFade = frame.minY < currentFade.topEnd || frame.maxY > currentFade.bottomStart
                return inner
                    .colorEffect(
                        ShaderLibrary.lyricsViewportFade(
                            .float4(
                                Float(frame.minY),
                                Float(scaleY),
                                Float(currentFade.topEnd),
                                Float(currentFade.bottomStart)
                            ),
                            .float(Float(currentFade.bottomEnd))
                        ),
                        isEnabled: needsFade
                    )
                    .blur(radius: blur)
            }
            .blendMode(blendPlusLighter ? .plusLighter : .normal)
            .animation(reducesMotion ? nil : .smooth(duration: 0.35), value: isInterfaceHidden)
    }
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
    var viewportFade: LyricsViewportFade = LyricsViewportFade()
    var isInterfaceHidden = false
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let motion = AppleMusicLyricsMotionProfile.iOS26_6

    var body: some View {
        let disablesBlur = focused || browsing || contrast == .increased || reducesMotion
        let usesPlayerHierarchy = foreground == .white
        let secondaryOpacity: Double = browsing
            ? NowPlayingVisualHierarchy.lyricBrowsingOpacity
            : (contrast == .increased ? motion.increasedContrastDeselectedTextOpacity : NowPlayingVisualHierarchy.lyricInactiveBlurredOpacity)
        LyricPressInteraction(isSelected: false, allowsLongPress: false, onTap: onTap, onLongPress: {}) { pressProgress in
            Group {
                if usesPlayerHierarchy && focused {
                    lyricText.nowPlayingPrimary()
                } else {
                    lyricText.foregroundStyle(
                        usesPlayerHierarchy
                            ? Color.white.opacity(secondaryOpacity)
                            : foreground.opacity(focused || browsing ? 1 : secondaryOpacity)
                    )
                }
            }
            .modifier(LyricsEdgeVisualModifier(
                fade: viewportFade,
                isInterfaceHidden: isInterfaceHidden,
                reducesMotion: reducesMotion,
                coordinateSpaceName: coordinateSpaceName,
                disablesBlur: disablesBlur,
                focusTop: focusTop,
                stride: stride,
                motion: motion,
                blendPlusLighter: usesPlayerHierarchy && !focused
            ))
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(foreground.opacity(pressProgress * 0.12))
                    .modifier(LyricsEdgeVisualModifier(
                        fade: viewportFade,
                        isInterfaceHidden: isInterfaceHidden,
                        reducesMotion: reducesMotion,
                        coordinateSpaceName: coordinateSpaceName,
                        disablesBlur: true,
                        focusTop: focusTop,
                        stride: stride,
                        motion: motion,
                        blendPlusLighter: usesPlayerHierarchy
                    ))
            }
        }
        .scaleEffect(focused ? 1 : motion.deselectedScale, anchor: .topLeading)
        .animation(reducesMotion ? nil : .timingCurve(
            motion.focusBlurTransitionControlPoint1X, motion.focusBlurTransitionControlPoint1Y,
            motion.focusBlurTransitionControlPoint2X, motion.focusBlurTransitionControlPoint2Y,
            duration: motion.focusBlurTransitionDuration), value: focused)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    private var lyricText: some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: fontSize, weight: .bold))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
