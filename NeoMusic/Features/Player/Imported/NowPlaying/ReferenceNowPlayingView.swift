// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import LNPopupUI
import SwiftUI
import UniformTypeIdentifiers

struct ReferenceNowPlayingView: View {
    fileprivate static let portraitHorizontalPadding: CGFloat = 32
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(ReferencePlayerState.self) private var player
    @Environment(ReferenceLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: NowPlayingPage
    @State private var pageChange: NowPlayingPageChange?
    @State private var showsLyricsControls = true
    @State private var appleMusicControlsActivityGeneration = 0
    @State private var isQueueSongHeaderHidden = false
    @State private var queueHeaderOffset = QueueHeaderOffset()
    @State private var geometryState: NowPlayingGeometry
    @State private var backdropAnchor = NowPlayingBackdropAnchor()
    @State private var backdropImage: UIImage?
    @State private var undimmedBackdropImage: UIImage?
    @State private var artworkPageFrame = CGRect.zero
    @State private var lyricsModel = NowPlayingLyricsModel()
    @State private var controlsHeight = NowPlayingBottomControls.overlayHeight
    @State private var importingLyrics = false
    @State private var importTrackID: String?
    @State private var pagePerformanceInterval: PerformanceDiagnostics.Interval?
    @Namespace private var pageArtworkNamespace
    private let onDismiss: (() -> Void)?
    private let isActive: Bool
    private var visualsActive: Bool { isActive && scenePhase == .active }
    private var animatesPageChanges: Bool { visualsActive && !accessibilityReduceMotion }
    init(initialPage: NowPlayingPage = .artwork, onDismiss: (() -> Void)? = nil,
         geometry: NowPlayingGeometry = NowPlayingGeometry(), isActive: Bool = true) {
        self.onDismiss = onDismiss
        self.isActive = isActive
        _page = State(initialValue: initialPage)
        // Geometry belongs to this presentation's identity; callers may supply
        // its initial owner to observe layout without screen-coordinate feedback.
        _geometryState = State(initialValue: geometry)
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = ReferenceNowPlayingLayout(contentSize: geometry.size)
            ZStack {
                // 背景自己在铺满安全区之后上报位置，背景副本才能和它完全重合。
                NowPlayingArtworkBackdrop(
                    artworkURL: player.currentTrack?.coverURL,
                    trackID: player.currentTrack?.id,
                    onFrameChange: { geometryState.backdropFrame = $0 },
                    onImageChange: { backdropImage = $0 },
                    onUndimmedImageChange: { undimmedBackdropImage = $0 },
                    anchor: backdropAnchor
                )
                // iPhone 只支持竖屏（见 project.yml 的 UISupportedInterfaceOrientations），不保留横屏布局。
                if let song = player.currentTrack {
                    portraitContent(for: song, layout: layout)
                } else {
                    ContentUnavailableView("当前没有播放歌曲", systemImage: "music.note").foregroundStyle(.white)
                }
            }
            .environment(\.nowPlayingLayout, layout)
            .environment(\.nowPlayingControlsOverflow, textSize.isAccessibilitySize
                         ? max(0, controlsHeight - NowPlayingBottomControls.overlayHeight) : 0)
            .environment(\.nowPlayingBackdropAnchor, backdropAnchor)
            .environment(\.nowPlayingBackdropImage, backdropImage)
            .environment(\.nowPlayingUndimmedBackdropImage, undimmedBackdropImage)
        }
        .coordinateSpace(.named(NowPlayingContentCoordinateSpace.name))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.playerVisualsActive, visualsActive)
        .environment(\.playerArtistEDREnabled, PlayerEDRResources.shared.isReady)
        .task(id: visualsActive) {
            if visualsActive { await PlayerEDRResources.shared.prepare() }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { geometryState.contentSize = $0 }
        .task(id: "\(player.currentTrack?.id ?? "")/\(library.contentRevision)/\(lyricsModel.revision)") {
            guard let track = player.currentTrack else { return }
            await lyricsModel.load(track: track, library: library, player: player)
        }
        .transaction {
            if !animatesPageChanges { $0.animation = nil; $0.disablesAnimations = true }
        }
        .onChange(of: accessibilityReduceMotion) { _, reduced in
            if reduced { finishPageChange() }
        }
        .onChange(of: visualsActive) { _, active in
            if !active { finishPageChange() }
        }
        .onChange(of: page) { _, _ in showsLyricsControls = true }
        .onChange(of: player.currentTrack == nil) { _, empty in if empty { closePlayer() } }
        .onDisappear { finishPageChange() }
        .fileImporter(isPresented: $importingLyrics, allowedContentTypes: [.data, .plainText]) { result in
            guard let id = importTrackID, case .success(let url) = result else { return }
            Task { await lyricsModel.importFile(url, trackID: id, reader: library.reader) }
        }
    }

    private func closePlayer() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func portraitContent(for song: ReferenceTrack, layout: ReferenceNowPlayingLayout) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 22).accessibilityHidden(true)

            pageContent(for: song)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    portraitPlayerControlsLayer(for: song)
                }
        }
        .overlay(alignment: .top) { dismissalHandle(layout: layout) }
        .padding(.horizontal, Self.portraitHorizontalPadding)
        .safeAreaPadding(.bottom, 3)
    }

    private func portraitPlayerControlsLayer(
        for song: ReferenceTrack
    ) -> some View {
        ZStack(alignment: .bottom) {
            portraitPlayerControls(for: song)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .allowsHitTesting(!hidesLyricsControls)
                .accessibilityHidden(hidesLyricsControls)


        }
    }

    private func portraitPlayerControls(for song: ReferenceTrack) -> some View {
        NowPlayingBottomControls(
            song: song,
            page: pageSelection,
            hasLyrics: lyricsAvailability == .available,
            showsLyricsUtilities:
                usesExpandedAppleMusicLyricsLayout,
            hasLyricsTranslations: hasLyricsTranslations,
            hasLyricsRomanizations: hasLyricsRomanizations,
            isInterfaceHidden: hidesLyricsControls
        )
    }

    private var lyricsAvailability: NowPlayingLyricsModel.Availability {
        lyricsModel.availability(for: player.currentTrack?.id)
    }

    private var lyricsContent: NowPlayingLyricsContent {
        NowPlayingLyricsContent(availability: lyricsAvailability,
                                lyrics: lyricsModel.lyrics, error: lyricsModel.error)
    }

    private var pageSelection: Binding<NowPlayingPage> {
        Binding(get: { page }, set: selectPage)
    }

    private func selectPage(_ destination: NowPlayingPage) {
        guard destination != page,
              destination != .lyrics || lyricsAvailability == .available else { return }
        finishPageMeasurement()
        pagePerformanceInterval = PerformanceDiagnostics.beginAnimation("PlayerPageSwitch")
        let request = NowPlayingPageChange(
            source: page, destination: destination,
            entersFromHiddenQueue: page == .queue && isQueueSongHeaderHidden,
            startsFromRest: pageChange == nil
        )
        let animation = animatesPageChanges
            ? NowPlayingPageTransition.selectionAnimation(from: page, to: destination) : nil
        withAnimation(animation, completionCriteria: .removed) {
            pageChange = request
            page = destination
        } completion: {
            guard pageChange?.id == request.id else { return }
            finishPageChange()
        }
    }

    private func finishPageChange() {
        if pageChange != nil {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { pageChange = nil }
        }
        finishPageMeasurement()
    }

    private func pageAnimation(_ spec: NowPlayingAnimationSpec, includesDelay: Bool = true,
                               extraDelay: TimeInterval = 0) -> Animation? {
        guard animatesPageChanges else { return nil }
        return NowPlayingAnimationSpec(spec.curve, duration: spec.duration,
                                       delay: (includesDelay ? spec.delay : 0) + extraDelay).animation
    }

    private var hidesLyricsControls: Bool {
        page == .lyrics && !showsLyricsControls
    }

    private var usesAutoHidingAppleMusicInterface: Bool {
        page == .lyrics
    }

    private var hasLyricsTranslations: Bool { false }
    private var hasLyricsRomanizations: Bool { false }

    private var usesExpandedAppleMusicLyricsLayout: Bool {
        page == .lyrics
    }

    private func dismissalHandle(layout: ReferenceNowPlayingLayout) -> some View {
        Button(action: closePlayer) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.58))
                    .frame(width: layout.width(60), height: 3.8)
                    .padding(.top, layout.contentY(69))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收起播放器")
        .accessibilityHint("返回上一页")
        .accessibilityIdentifier("player.dismiss")
    }

    private func pageContent(for song: ReferenceTrack) -> some View {
        ZStack(alignment: .top) {
            transientArtworkPageContent(for: song)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .clipped()

            residentQueuePage(for: song)

            residentAppleMusicLyricsPage(for: song)

            if page != .artwork {
                QueueLinkedSongHeader(
                    song: song,
                    page: page,
                    offset: queueHeaderOffset,
                    artworkNamespace: pageArtworkNamespace,
                    onImportLyrics: {
                        importTrackID = song.id
                        importingLyrics = true
                    }
                )
                .padding(.top, NowPlayingSongHeader.topInset)
                .transition(
                    NowPlayingPageTransition.songHeader(
                        reducesMotion: accessibilityReduceMotion
                    )
                )
            }

        }
        .background {
            NowPlayingArtworkFrameMeasurement(onFrameChange: recordArtworkPageFrame)
        }
        .overlay {
            QueueLinkedArtwork(
                song: song,
                page: page,
                offset: queueHeaderOffset,
                artworkPageFrame: artworkPageFrame,
                reducesMotion: accessibilityReduceMotion
            )
        }
        .coordinateSpace(
            name: NowPlayingPortraitCoordinateSpace.name
        )
    }

    @ViewBuilder
    private func transientArtworkPageContent(
        for song: ReferenceTrack
    ) -> some View {
        if page == .artwork {
            NowPlayingArtworkPage(
                song: song,
                artworkNamespace: pageArtworkNamespace,
                usesArtworkTransition: false,
                showsArtwork: false
            )
            .transition(
                pageContentTransition(for: .artwork)
            )
        }
    }

    private func recordArtworkPageFrame(_ frame: CGRect) {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return
        }
        let tolerance: CGFloat = 0.5
        guard abs(artworkPageFrame.minX - frame.minX) > tolerance
                || abs(artworkPageFrame.minY - frame.minY) > tolerance
                || abs(artworkPageFrame.width - frame.width) > tolerance
                || abs(artworkPageFrame.height - frame.height) > tolerance else {
            return
        }
        artworkPageFrame = frame
    }

    private func residentQueuePage(
        for song: ReferenceTrack
    ) -> some View {
        let isVisible = page == .queue
        let motion = NowPlayingPageTransition.motion

        return NowPlayingQueuePage(
            song: song,
            presentation: .portrait,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsSongHeader: false,
            onSongHeaderHiddenChange: {
                isQueueSongHeaderHidden = $0
            },
            onSongHeaderOffsetChange: { offset in
                if queueHeaderOffset.points != offset { queueHeaderOffset.points = offset }
            }
        )
        // 列表通栏，超出外层水平内边距；先放宽再裁剪，再收回，裁剪范围才是整屏宽度。
        .padding(.horizontal, Self.portraitHorizontalPadding)
        .clipped()
        .padding(.horizontal, -Self.portraitHorizontalPadding)
        .modifier(NowPlayingPagePresentation(
            isVisible: isVisible, presentationScale: motion.queuePresentationScale,
            hiddenOffset: motion.queueTravel,
            spatialAnimation: pageAnimation(isVisible ? motion.queueSpatialPresentation : motion.queueSpatialDismissal),
            opacityAnimation: pageAnimation(isVisible ? motion.queueOpacityPresentation : motion.queueOpacityDismissal,
                                            includesDelay: pageChange?.startsFromRest == true)
        ))
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .environment(\.playerVisualsActive, visualsActive && (isVisible || pageChange?.source == .queue))
    }

    private func portraitLyricsPage(for song: ReferenceTrack) -> some View {
        NowPlayingLyricsPage(
            song: song, lyrics: lyricsContent.lyrics, errorMessage: lyricsContent.error,
            isActive: visualsActive && page == .lyrics, isInterfaceHidden: hidesLyricsControls,
            artworkNamespace: pageArtworkNamespace, showsSongHeader: false,
            playerFrame: geometryState.contentFrame,
            onInterfaceVisibilityChange: setAppleMusicLyricsControlsVisible
        )
        .accessibilityAction(named: lyricsInterfaceAccessibilityActionName) {
            handleLyricsInterfaceInteraction()
        }
    }

    private func residentAppleMusicLyricsPage(for song: ReferenceTrack) -> some View {
        let isVisible = page == .lyrics
        let motion = NowPlayingPageTransition.motion
        let entranceDelay = isVisible && pageChange?.startsFromRest == true ? motion.lyricsPresentationDelay : 0
        return portraitLyricsPage(for: song)
            .id(song.id)
            .modifier(NowPlayingPagePresentation(
                isVisible: isVisible, presentationScale: motion.lyricsPresentationScale,
                hiddenOffset: motion.lyricsTravel,
                spatialAnimation: pageAnimation(isVisible ? motion.lyricsSpatialPresentation : motion.lyricsSpatialDismissal,
                                                extraDelay: entranceDelay),
                opacityAnimation: pageAnimation(isVisible ? motion.lyricsOpacityPresentation : motion.lyricsOpacityDismissal,
                                                extraDelay: entranceDelay)
            ))
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .environment(\.playerVisualsActive, visualsActive && (isVisible || pageChange?.source == .lyrics))
    }

    private func pageContentTransition(for destination: NowPlayingPage) -> AnyTransition {
        NowPlayingPageTransition.content(for: destination,
                                         entersFromHiddenQueue: pageChange?.entersFromHiddenQueue == true,
                                         reducesMotion: accessibilityReduceMotion)
    }

    private func finishPageMeasurement() {
        guard let interval = pagePerformanceInterval else { return }
        PerformanceDiagnostics.end("PlayerPageSwitch", interval)
        pagePerformanceInterval = nil
    }

    private var lyricsInterfaceAccessibilityActionName: String { "显示播放控件" }

    private func handleLyricsInterfaceInteraction() {
        registerAppleMusicControlsActivity()
    }

    private func registerAppleMusicControlsActivity() {
        guard usesAutoHidingAppleMusicInterface else { return }

        appleMusicControlsActivityGeneration &+= 1
        guard !showsLyricsControls else { return }

        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: true,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            showsLyricsControls = true
        }
    }

    private func setAppleMusicLyricsControlsVisible(_ isVisible: Bool) {
        guard usesAutoHidingAppleMusicInterface else { return }
        if isVisible {
            registerAppleMusicControlsActivity()
            return
        }

        guard showsLyricsControls,
              !accessibilityVoiceOverEnabled else {
            return
        }
        cancelAppleMusicControlsAutoHide()
        withAnimation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: false,
                reducesMotion: accessibilityReduceMotion
            )
        ) {
            showsLyricsControls = false
        }
    }



    private func cancelAppleMusicControlsAutoHide() {
        appleMusicControlsActivityGeneration &+= 1
    }

}

/// Queue scroll writes here. Only the header and floating artwork read it, so the rest of the player stays put.
@MainActor @Observable
private final class QueueHeaderOffset {
    var points: CGFloat = 0
}

private struct QueueLinkedSongHeader: View {
    let song: ReferenceTrack
    let page: NowPlayingPage
    let offset: QueueHeaderOffset
    let artworkNamespace: Namespace.ID
    let onImportLyrics: () -> Void

    private var translation: CGFloat { page == .queue ? offset.points : 0 }

    var body: some View {
        NowPlayingSongHeader(
            song: song,
            artworkNamespace: artworkNamespace,
            usesReferenceLayout: true,
            usesArtworkTransition: false,
            showsArtwork: false,
            onImportLyrics: onImportLyrics
        )
        .offset(y: translation)
        .opacity(NowPlayingSongHeader.scrollFadeOpacity(scrolled: -translation))
    }
}

private struct QueueLinkedArtwork: View {
    @Environment(ReferencePlayerState.self) private var player
    let song: ReferenceTrack
    let page: NowPlayingPage
    let offset: QueueHeaderOffset
    let artworkPageFrame: CGRect
    let reducesMotion: Bool

    private var headerOffset: CGFloat { page == .queue ? offset.points : 0 }
    private var fadeHeight: CGFloat { page == .queue ? min(24, max(0, -offset.points)) : 0 }
    private var expanded: Bool { player.isPlaying }
    private var frame: CGRect {
        if page == .artwork { return displayedFrame }
        return CGRect(
            x: 0,
            y: NowPlayingSongHeader.topInset + headerOffset,
            width: NowPlayingSongHeader.referenceHeight,
            height: NowPlayingSongHeader.referenceHeight
        )
    }
    private var displayedFrame: CGRect {
        guard !expanded else { return artworkPageFrame }
        let horizontalInset = artworkPageFrame.width * (1 - NowPlayingArtworkPage.pausedArtworkScale) / 2
        let verticalInset = artworkPageFrame.height * (1 - NowPlayingArtworkPage.pausedArtworkScale) / 2
        return artworkPageFrame.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    var body: some View {
        GeometryReader { _ in
            if frame.width > 0 {
                NowPlayingPortraitArtwork(song: song, isArtworkPage: page == .artwork)
                    .frame(width: frame.width, height: frame.height)
                    .popupTransitionTarget()
                    .position(
                        x: frame.midX + ReferenceNowPlayingView.portraitHorizontalPadding,
                        y: frame.midY
                    )
                    .animation(
                        reducesMotion ? nil : NowPlayingPageTransition.motion.artworkResize.animation,
                        value: expanded
                    )
                    .allowsHitTesting(false)
            }
        }
        .mask {
            GeometryReader { geometry in
                // The queue cover follows the list behind its top edge.
                // Keep the artwork page's shadow uncut beneath the handle.
                VStack(spacing: 0) {
                    NowPlayingQueueTopFade(height: fadeHeight)
                    Rectangle()
                }
                .padding(page == .queue ? 0 : -max(geometry.size.width, geometry.size.height))
            }
        }
        .padding(.horizontal, -ReferenceNowPlayingView.portraitHorizontalPadding)
    }
}
