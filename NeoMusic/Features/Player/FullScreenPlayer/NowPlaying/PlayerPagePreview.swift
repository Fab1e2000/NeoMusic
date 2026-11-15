#if DEBUG
// Preview composition derived from ReferenceNowPlayingView (MeloX, GPL-3.0).
// The production components and their reference geometry are shared unchanged.
import SwiftUI

public struct PlayerPagePreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReducesTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    private let fixtures: PlayerPreviewInputs
    public init(player: PlayerState, services: PlayerServices) {
        fixtures = PlayerPreviewInputs(player: player, services: services)
    }
    @State private var usesSimulation = false
    @State private var initialPage = NowPlayingPage.artwork
    @State private var presentationID = UUID()
    @State private var simulatesLyricsLoading = false
    @State private var showsLyricsLoadingFeedback = true

    public var body: some View {
        player(fixtures)
            .environment(fixtures.player).environment(fixtures.library).environment(fixtures.actions)
            .environment(fixtures.services)
            .safeAreaInset(edge: .top, spacing: 0) { comparisonControls }
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func player(_ fixtures: PlayerPreviewInputs) -> some View {
        Group {
            if usesSimulation {
                NativePlayerMotionContent(initialPage: initialPage,
                                          simulatesLyricsLoading: simulatesLyricsLoading,
                                          showsLyricsLoadingFeedback: showsLyricsLoadingFeedback,
                                          onDismiss: { dismiss() })
            } else {
                NowPlayingContent(artworkTransition: EmptyModifier(), initialPage: initialPage, onDismiss: { dismiss() })
            }
        }
        .id(presentationID)
    }

    private var comparisonControls: some View {
        HStack {
            Picker("预览内容", selection: $usesSimulation) {
                Text("正式").tag(false)
                Text("模拟").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 138)
            .accessibilityIdentifier("player.motion.comparison")

            Spacer()

            Menu {
                Picker("起始页面", selection: $initialPage) {
                    Text("封面").tag(NowPlayingPage.artwork)
                    Text("歌词").tag(NowPlayingPage.lyrics)
                    Text("队列").tag(NowPlayingPage.queue)
                }
                Text(systemReducesMotion ? "减少动态效果：系统已开启" : "减少动态效果：系统已关闭")
                Text(systemReducesTransparency ? "减少透明度：系统已开启" : "减少透明度：系统已关闭")
                Text(systemContrast == .increased ? "提高对比度：系统已开启" : "提高对比度：系统已关闭")
                Button("重置到起始页面", systemImage: "arrow.counterclockwise") {
                    presentationID = UUID()
                }
                Section("载入对照（模拟）") {
                    Toggle("模拟歌词载入中", isOn: $simulatesLyricsLoading)
                        .disabled(!usesSimulation)
                    Toggle("显示载入反馈", isOn: $showsLyricsLoadingFeedback)
                        .disabled(!usesSimulation || !simulatesLyricsLoading)
                }
                Section {
                    Text("三首本地示例，拖动进度可查看同步歌词。载入超过三秒显示反馈，关闭反馈可对照原空白状态。")
                }
            } label: {
                Label("预览", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("player.motion.options")
            .accessibilityValue("减少动态效果：\(systemReducesMotion ? "开" : "关")；减少透明度：\(systemReducesTransparency ? "开" : "关")；提高对比度：\(systemContrast == .increased ? "开" : "关")")
        }
        .dynamicTypeSize(.large)
        .padding(.horizontal, 12)
        .onChange(of: initialPage) { _, _ in presentationID = UUID() }
    }
}

private struct NativePlayerMotionContent: View {
    private static let horizontalPadding: CGFloat = 32
    private let motion = NowPlayingMotionSpec.appleMusic26.page
    private let onDismiss: () -> Void
    private let simulatesLyricsLoading: Bool
    private let showsLyricsLoadingFeedback: Bool
    @Environment(PlayerState.self) private var player
    @Environment(PlayerLyricsSource.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: NowPlayingPage
    @State private var change: NowPlayingPageChange?
    @State private var geometry = NowPlayingGeometry()
    @State private var artworkFrame = CGRect.zero
    @State private var lyricsModel = NowPlayingLyricsModel()
    @State private var controlsHeight = NowPlayingBottomControls.overlayHeight
    @State private var showsLyricsControls = true
    @State private var queueHeaderHidden = false
    @State private var queueOffset = NativePlayerPreviewQueueOffset()
    @Namespace private var artworkNamespace

    init(initialPage: NowPlayingPage, simulatesLyricsLoading: Bool,
         showsLyricsLoadingFeedback: Bool, onDismiss: @escaping () -> Void) {
        _page = State(initialValue: initialPage)
        self.simulatesLyricsLoading = simulatesLyricsLoading
        self.showsLyricsLoadingFeedback = showsLyricsLoadingFeedback
        self.onDismiss = onDismiss
    }

    private var visualsActive: Bool { scenePhase == .active }
    private var animates: Bool { visualsActive && !reducesMotion }
    private var hidesControls: Bool { page == .lyrics && !showsLyricsControls }
    private var availability: NowPlayingLyricsModel.Availability {
        lyricsModel.availability(for: player.currentTrack?.id)
    }
    private var lyrics: NowPlayingLyricsContent {
        NowPlayingLyricsContent(availability: availability, lyrics: lyricsModel.lyrics, error: lyricsModel.error)
    }
    private var pageSelection: Binding<NowPlayingPage> {
        Binding(get: { page }, set: select)
    }

    var body: some View {
        GeometryReader { container in
            let layout = ReferenceNowPlayingLayout(contentSize: container.size)
            ZStack {
                NowPlayingArtworkBackdrop(
                    artworkURL: player.currentTrack?.coverURL,
                    trackID: player.currentTrack?.id,
                    isPlaying: player.isPlaying,
                    onFrameChange: { geometry.backdropFrame = $0 }
                )
                if let song = player.currentTrack {
                    VStack(spacing: 0) {
                        dismissalHandle(layout: layout)
                        pages(song)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottom) { controls(song) }
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .safeAreaPadding(.bottom, 3)
                }
            }
            .environment(\.nowPlayingLayout, layout)
            .environment(\.nowPlayingControlsOverflow, textSize.isAccessibilitySize
                         ? max(0, controlsHeight - NowPlayingBottomControls.overlayHeight) : 0)
        }
        .coordinateSpace(.named(NowPlayingContentCoordinateSpace.name))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.playerVisualsActive, visualsActive)
        .transaction {
            if !animates { $0.animation = nil; $0.disablesAnimations = true }
        }
        .task(id: visualsActive) {
            if visualsActive { await NowPlayingFluidBackdropResources.shared.prepare() }
        }
        .task(id: "\(player.currentTrack?.id ?? "")/\(library.contentRevision)/\(lyricsModel.revision)") {
            guard let track = player.currentTrack else { return }
            await lyricsModel.load(track: track, library: library, player: player)
        }
        .onChange(of: simulatesLyricsLoading, initial: true) { _, loading in
            if loading {
                select(.lyrics)
                setLyricsControlsVisible(true)
            }
        }
        .onChange(of: reducesMotion) { _, reduced in
            if reduced { clearCompletedChange() }
        }
        .onChange(of: visualsActive) { _, active in
            if !active { clearCompletedChange() }
        }
        .onDisappear { clearCompletedChange() }
    }

    private func dismissalHandle(layout: ReferenceNowPlayingLayout) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(.white.opacity(NowPlayingVisualHierarchy.grabberOpacity))
                .blendMode(.plusLighter)
                .frame(width: layout.width(60), height: 3.8)
                .padding(.top, layout.contentY(69))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22, alignment: .top)
        .contentShape(.rect)
        .onTapGesture { onDismiss() }
        .accessibilityElement()
        .accessibilityLabel("收起播放器")
        .accessibilityHint("返回上一页")
        .accessibilityAction { onDismiss() }
    }

    private func controls(_ song: PlayerTrack) -> some View {
        NowPlayingBottomControls(
            song: song, page: pageSelection, hasLyrics: simulatesLyricsLoading || availability == .available,
            showsLyricsUtilities: page == .lyrics, hasLyricsTranslations: false,
            hasLyricsRomanizations: false, isInterfaceHidden: hidesControls
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        .allowsHitTesting(!hidesControls)
        .accessibilityHidden(hidesControls)
    }

    private func pages(_ song: PlayerTrack) -> some View {
        ZStack(alignment: .top) {
            Group {
                if page == .artwork {
                    NowPlayingArtworkPage(song: song, artworkNamespace: artworkNamespace,
                                          usesArtworkTransition: false, showsArtwork: false)
                        .transition(artworkTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            queuePage(song)
            lyricsPage(song)

            if page != .artwork {
                NativePlayerPreviewSongHeader(song: song, page: page, offset: queueOffset,
                                              artworkNamespace: artworkNamespace)
                    .padding(.top, NowPlayingSongHeader.topInset)
                    .transition(NowPlayingPageTransition.songHeader(reducesMotion: reducesMotion))
            }
        }
        .background {
            NowPlayingArtworkFrameMeasurement { frame in
                if artworkFrame != frame { artworkFrame = frame }
            }
        }
        .overlay {
            NativePlayerPreviewArtwork(song: song, page: page, offset: queueOffset,
                                       artworkFrame: artworkFrame, reducesMotion: reducesMotion)
        }
        .coordinateSpace(name: NowPlayingPortraitCoordinateSpace.name)
    }

    private var artworkTransition: AnyTransition {
        NowPlayingPageTransition.content(for: .artwork,
                                         entersFromHiddenQueue: change?.entersFromHiddenQueue == true,
                                         reducesMotion: reducesMotion)
    }

    private func queuePage(_ song: PlayerTrack) -> some View {
        let isVisible = page == .queue
        return NowPlayingQueuePage(
            song: song, presentation: .portrait, artworkNamespace: artworkNamespace,
            usesArtworkTransition: false, showsSongHeader: false,
            onSongHeaderHiddenChange: { queueHeaderHidden = $0 },
            onSongHeaderOffsetChange: { if queueOffset.points != $0 { queueOffset.points = $0 } }
        )
        .padding(.horizontal, Self.horizontalPadding)
        .clipped()
        .modifier(NowPlayingPagePresentation(
            isVisible: isVisible, presentationScale: motion.queuePresentationScale,
            hiddenOffset: motion.queueTravel,
            spatialAnimation: animation(isVisible ? motion.queueSpatialPresentation : motion.queueSpatialDismissal),
            opacityAnimation: animation(isVisible ? motion.queueOpacityPresentation : motion.queueOpacityDismissal,
                                        includesDelay: change?.startsFromRest == true)
        ))
        .padding(.horizontal, -Self.horizontalPadding)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .environment(\.playerVisualsActive, visualsActive && (isVisible || change?.source == .queue))
    }

    private func lyricsPage(_ song: PlayerTrack) -> some View {
        let isVisible = page == .lyrics
        let entranceDelay = isVisible && change?.startsFromRest == true ? motion.lyricsPresentationDelay : 0
        return NowPlayingLyricsPage(
            song: song, lyrics: simulatesLyricsLoading ? nil : lyrics.lyrics,
            errorMessage: simulatesLyricsLoading ? nil : lyrics.error,
            isActive: visualsActive && isVisible, isInterfaceHidden: hidesControls,
            artworkNamespace: artworkNamespace, showsSongHeader: false,
            onInterfaceVisibilityChange: setLyricsControlsVisible
        )
        .id(song.id)
        .opacity(simulatesLyricsLoading && !showsLyricsLoadingFeedback ? 0 : 1)
        .accessibilityHidden(simulatesLyricsLoading && !showsLyricsLoadingFeedback)
        .modifier(NowPlayingPagePresentation(
            isVisible: isVisible, presentationScale: motion.lyricsPresentationScale,
            hiddenOffset: motion.lyricsTravel,
            spatialAnimation: animation(isVisible ? motion.lyricsSpatialPresentation : motion.lyricsSpatialDismissal,
                                        extraDelay: entranceDelay),
            opacityAnimation: animation(isVisible ? motion.lyricsOpacityPresentation : motion.lyricsOpacityDismissal,
                                        includesDelay: change?.startsFromRest == true,
                                        extraDelay: entranceDelay),
            clipsAboveControls: !isVisible || (!hidesControls && change != nil)
        ))
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .accessibilityAction(named: "显示播放控件") { setLyricsControlsVisible(true) }
        .environment(\.playerVisualsActive, visualsActive && (isVisible || change?.source == .lyrics))
    }

    private func animation(_ spec: NowPlayingAnimationSpec, includesDelay: Bool = true,
                           extraDelay: TimeInterval = 0) -> Animation? {
        guard animates else { return nil }
        return NowPlayingAnimationSpec(spec.curve, duration: spec.duration,
                                       delay: (includesDelay ? spec.delay : 0) + extraDelay).animation
    }

    private func select(_ destination: NowPlayingPage) {
        guard destination != page,
              destination != .lyrics || simulatesLyricsLoading || availability == .available else { return }
        let request = NowPlayingPageChange(
            source: page, destination: destination,
            entersFromHiddenQueue: page == .queue && queueHeaderHidden,
            startsFromRest: change == nil
        )
        let selection = animates
            ? NowPlayingPageTransition.selectionAnimation(from: page, to: destination) : nil
        withAnimation(selection, completionCriteria: .removed) {
            change = request
            page = destination
            showsLyricsControls = true
        } completion: {
            guard change?.id == request.id else { return }
            clearCompletedChange()
        }
    }

    private func clearCompletedChange() {
        guard change != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { change = nil }
    }

    private func setLyricsControlsVisible(_ visible: Bool) {
        guard page == .lyrics, visible || !voiceOverEnabled else { return }
        withAnimation(NowPlayingInterfaceTransition.interfaceAnimation(isVisible: visible,
                                                                       reducesMotion: reducesMotion)) {
            showsLyricsControls = visible
        }
    }
}

@MainActor @Observable private final class NativePlayerPreviewQueueOffset {
    var points: CGFloat = 0
}

private struct NativePlayerPreviewSongHeader: View {
    let song: PlayerTrack
    let page: NowPlayingPage
    let offset: NativePlayerPreviewQueueOffset
    let artworkNamespace: Namespace.ID
    private var translation: CGFloat { page == .queue ? offset.points : 0 }

    var body: some View {
        NowPlayingSongHeader(song: song, artworkNamespace: artworkNamespace, usesReferenceLayout: true,
                             usesArtworkTransition: false, showsArtwork: false)
            .offset(y: translation)
            .opacity(NowPlayingSongHeader.scrollFadeOpacity(scrolled: -translation))
    }
}

private struct NativePlayerPreviewArtwork: View {
    @Environment(PlayerState.self) private var player
    let song: PlayerTrack
    let page: NowPlayingPage
    let offset: NativePlayerPreviewQueueOffset
    let artworkFrame: CGRect
    let reducesMotion: Bool
    private var headerOffset: CGFloat { page == .queue ? offset.points : 0 }
    private var fadeHeight: CGFloat { page == .queue ? min(24, max(0, -offset.points)) : 0 }
    private var frame: CGRect {
        guard page == .artwork else {
            return CGRect(x: 0, y: NowPlayingSongHeader.topInset + headerOffset,
                          width: NowPlayingSongHeader.referenceHeight, height: NowPlayingSongHeader.referenceHeight)
        }
        guard !player.isPlaying else { return artworkFrame }
        return artworkFrame.insetBy(
            dx: artworkFrame.width * (1 - NowPlayingArtworkPage.pausedArtworkScale) / 2,
            dy: artworkFrame.height * (1 - NowPlayingArtworkPage.pausedArtworkScale) / 2
        )
    }

    var body: some View {
        GeometryReader { _ in
            if frame.width > 0 {
                NowPlayingPortraitArtwork(song: song, isArtworkPage: page == .artwork)
                    .frame(width: frame.width, height: frame.height)

                    .position(x: frame.midX + 32, y: frame.midY)
                    .animation(reducesMotion ? nil : NowPlayingPageTransition.motion.artworkResize.animation,
                               value: player.isPlaying)
                    .allowsHitTesting(false)
            }
        }
        .mask {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    NowPlayingQueueTopFade(height: fadeHeight)
                    Rectangle()
                }
                .padding(.top, page == .queue ? NowPlayingSongHeader.topInset : 0)
                .padding(page == .queue ? 0 : -max(geometry.size.width, geometry.size.height))
            }
        }
        .padding(.horizontal, -32)
    }
}

private struct PlayerPreviewInputs {
    let player: PlayerState
    let services: PlayerServices
    var library: PlayerLyricsSource { services.lyrics }
    var actions: PlayerActions { services.actions }
}
#endif
