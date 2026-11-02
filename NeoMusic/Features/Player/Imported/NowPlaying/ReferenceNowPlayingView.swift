// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import LNPopupUI
import SwiftUI
import UniformTypeIdentifiers

struct ReferenceNowPlayingView: View {
    private static let portraitHorizontalPadding: CGFloat = 32
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
    @Environment(ReferencePlayerState.self) private var player
    @Environment(ReferenceLibrary.self) private var library
    @State private var pageTransition: NowPlayingTransitionCoordinator
    @State private var showsLyricsControls = true
    @State private var appleMusicControlsActivityGeneration = 0
    @State private var isQueueSongHeaderHidden = false
    @State private var queueSongHeaderOffset: CGFloat = 0
    @State private var geometryState: NowPlayingGeometry
    @State private var backdropAnchor = NowPlayingBackdropAnchor()
    @State private var backdropImage: UIImage?
    @State private var undimmedBackdropImage: UIImage?
    @State private var artworkPageFrame = CGRect.zero
    @State private var preparedLyricsSongID: ReferenceTrack.ID?
    @State private var lyricsModel = NowPlayingLyricsModel()
    @State private var importingLyrics = false
    @State private var importTrackID: String?
    @Namespace private var pageArtworkNamespace
    private var page: NowPlayingPage { pageTransition.page }
    private let onDismiss: (() -> Void)?
    init(initialPage: NowPlayingPage = .artwork, onDismiss: (() -> Void)? = nil,
         geometry: NowPlayingGeometry = NowPlayingGeometry()) {
        self.onDismiss = onDismiss
        _pageTransition = State(initialValue: NowPlayingTransitionCoordinator(initialPage: initialPage))
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
            .environment(\.nowPlayingBackdropAnchor, backdropAnchor)
            .environment(\.nowPlayingBackdropImage, backdropImage)
            .environment(\.nowPlayingUndimmedBackdropImage, undimmedBackdropImage)
        }
        .coordinateSpace(.named(NowPlayingContentCoordinateSpace.name))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { geometryState.contentSize = $0 }
        .task(id: "\(player.currentTrack?.id ?? "")/\(library.contentRevision)/\(lyricsModel.revision)") {
            guard let track = player.currentTrack else { return }
            preparedLyricsSongID = nil
            await lyricsModel.load(track: track, library: library, player: player)
        }
        .task(id: transitionSettlementTaskID) { await settlePageTransition() }
        .task(id: lyricsEntranceTaskID) { await presentLyricsEntrance() }
        .onChange(of: page) { _, _ in showsLyricsControls = true }
        .onChange(of: lyricsAvailability, initial: true) { _, availability in
            if availability != .available, page == .lyrics {
                pageSelection.wrappedValue = .artwork
            }
        }
        .onChange(of: player.currentTrack == nil) { _, empty in if empty { closePlayer() } }
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
            dismissalHandle(layout: layout)

            pageContent(for: song)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    portraitPlayerControlsLayer(for: song)
                }
        }
        .padding(.horizontal, Self.portraitHorizontalPadding)
        .safeAreaPadding(.bottom, 3)
    }

    private func portraitPlayerControlsLayer(
        for song: ReferenceTrack
    ) -> some View {
        ZStack(alignment: .bottom) {
            portraitPlayerControls(for: song)
                .allowsHitTesting(!hidesLyricsControls)
                .accessibilityHidden(hidesLyricsControls)


        }
        .frame(height: NowPlayingBottomControls.overlayHeight)
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

    private var pageSelection: Binding<NowPlayingPage> {
        Binding(
            get: { page },
            set: { newPage in
                guard newPage != .lyrics || lyricsAvailability == .available else { return }
                pageTransition.select(
                    newPage,
                    usesAppleMusicLyrics:
                        true,
                    isQueueSongHeaderHidden:
                        isQueueSongHeaderHidden,
                    motion: NowPlayingPageTransition.motion
                )
            }
        )
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
        ZStack(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.58))
                .frame(width: layout.width(60), height: 3.8)
                .padding(.top, layout.contentY(69))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22, alignment: .top)
        .contentShape(.rect)
        .onTapGesture {
            closePlayer()
        }
        .accessibilityElement()
        .accessibilityLabel("收起播放器")
        .accessibilityHint("返回上一页")
        .accessibilityAction {
            closePlayer()
        }
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
                sharedPortraitSongHeader(for: song)
                    .padding(.top, NowPlayingSongHeader.topInset)
                    .offset(y: sharedPortraitSongHeaderOffset)
                    .opacity(
                        NowPlayingSongHeader.scrollFadeOpacity(
                            scrolled: -sharedPortraitSongHeaderOffset
                        )
                    )
                    .transition(
                        NowPlayingPageTransition.songHeader(
                            reducesMotion: accessibilityReduceMotion
                        )
                    )
            }

        }
        .background {
            if keepsStableArtworkFrameMeasurement {
                artworkFrameMeasurement(for: song)
            }
        }
        .overlay {
            GeometryReader { _ in
                if portraitArtworkFrame.width > 0 {
                    NowPlayingPortraitArtwork(
                        song: song,
                        isArtworkPage: page == .artwork
                    )
                    .frame(
                        width: portraitArtworkFrame.width,
                        height: portraitArtworkFrame.height
                    )
                    .popupTransitionTarget()
                    .position(
                        x:
                            portraitArtworkFrame.midX
                            + Self.portraitHorizontalPadding,
                        y: portraitArtworkFrame.midY
                    )
                    .animation(
                        accessibilityReduceMotion
                            ? nil
                            : NowPlayingPageTransition
                                .motion
                                .artworkResize
                                .animation,
                        value: isPortraitArtworkExpanded
                    )
                    .allowsHitTesting(false)
                }
            }
            .mask {
                GeometryReader { geometry in
                    // The queue cover follows the list behind its top edge.
                    // Keep the artwork page's shadow uncut beneath the handle.
                    VStack(spacing: 0) {
                        NowPlayingQueueTopFade(height: queueHeaderFadeHeight)
                        Rectangle()
                    }
                        .padding(page == .queue ? 0 : -max(geometry.size.width, geometry.size.height))
                }
            }
            .padding(
                .horizontal,
                -Self.portraitHorizontalPadding
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
                showsArtwork: false,
                onArtworkFrameChange:
                    recordPresentedArtworkPageFrame
            )
            .transition(
                pageContentTransition(for: .artwork)
            )
        }
    }

    private func artworkFrameMeasurement(
        for song: ReferenceTrack
    ) -> some View {
        NowPlayingArtworkPage(
            song: song,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsArtwork: false,
            onArtworkFrameChange: recordArtworkPageFrame
        )
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var keepsStableArtworkFrameMeasurement: Bool {
        page != .artwork || pageTransition.transition != nil
    }

    private func recordPresentedArtworkPageFrame(
        _ frame: CGRect
    ) {
        // The artwork page enters from below. Its geometry includes that
        // temporary transition offset, so keep using the resident
        // measurement until the page transition has settled.
        guard pageTransition.transition == nil else { return }
        recordArtworkPageFrame(frame)
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
        let visualState = residentQueueVisualState

        return NowPlayingQueuePage(
            song: song,
            presentation: .portrait,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsSongHeader: false,
            onSongHeaderHiddenChange: {
                isQueueSongHeaderHidden = $0
            },
            onSongHeaderOffsetChange: {
                queueSongHeaderOffset = $0
            }
        )
        // 列表通栏，超出外层水平内边距；先放宽再裁剪，再收回，裁剪范围才是整屏宽度。
        .padding(.horizontal, Self.portraitHorizontalPadding)
        .clipped()
        .padding(.horizontal, -Self.portraitHorizontalPadding)
        .nowPlayingQueuePagePresentation(
            visualState: visualState,
            opacityTransition: pageTransition.queueOpacityTransition,
            spatialTransition: pageTransition.queueSpatialTransition,
            opacitySpec:
                pageTransition.queueOpacityTransition.targetProgress >= 1
                    ? NowPlayingPageTransition.motion
                        .queueOpacityPresentation
                    : NowPlayingPageTransition.motion
                        .queueOpacityDismissal,
            presentationScale:
                NowPlayingPageTransition.motion.queuePresentationScale,
            reducesMotion: accessibilityReduceMotion
        )
        .allowsHitTesting(page == .queue)
        .accessibilityHidden(page != .queue)
    }

    private func portraitLyricsPage(
        for song: ReferenceTrack,
        onInitialFocusPrepared: (() -> Void)? = nil
    ) -> some View {
        NowPlayingLyricsPage(
            song: song, lyrics: lyricsModel.lyrics, errorMessage: lyricsModel.error,
            isActive: page == .lyrics, isInterfaceHidden: hidesLyricsControls,
            artworkNamespace: pageArtworkNamespace, showsSongHeader: false,
            playerFrame: geometryState.contentFrame,
            onInterfaceVisibilityChange: setAppleMusicLyricsControlsVisible,
            onInitialFocusPrepared: onInitialFocusPrepared
        )
        .accessibilityAction(named: lyricsInterfaceAccessibilityActionName) {
            handleLyricsInterfaceInteraction()
        }
    }

    private func residentAppleMusicLyricsPage(
        for song: ReferenceTrack
    ) -> some View {
        let visualState = residentLyricsVisualState

        return portraitLyricsPage(
            for: song,
            onInitialFocusPrepared: {
                markLyricsContentPrepared(for: song.id)
            }
        )
        .id(song.id)
        .nowPlayingLyricsPagePresentation(
            visualState: visualState,
            opacityTransition:
                pageTransition.lyricsOpacityTransition,
            spatialTransition:
                pageTransition.lyricsSpatialTransition,
            opacitySpec:
                pageTransition.lyricsOpacityTransition
                    .targetProgress >= 1
                    ? NowPlayingPageTransition.motion
                        .lyricsOpacityPresentation
                    : NowPlayingPageTransition.motion
                        .lyricsOpacityDismissal,
            presentationScale:
                NowPlayingPageTransition.motion
                    .lyricsPresentationScale,
            reducesMotion: accessibilityReduceMotion
        )
        .allowsHitTesting(page == .lyrics)
        .accessibilityHidden(page != .lyrics)
    }

    private var residentLyricsVisualState: NowPlayingPageVisualState {
        NowPlayingPageTransition.motion.residentLyricsState(
            selectedPage: page,
            transition: pageTransition.transition,
            isEntrancePresented:
                pageTransition.isLyricsEntrancePresented
        )
    }

    private var residentQueueVisualState: NowPlayingPageVisualState {
        NowPlayingPageTransition.motion.residentQueueState(
            selectedPage: page,
            transition: pageTransition.transition
        )
    }

    private func sharedPortraitSongHeader(
        for song: ReferenceTrack
    ) -> some View {
        NowPlayingSongHeader(
            song: song,
            artworkNamespace: pageArtworkNamespace,
            usesReferenceLayout: true,
            usesArtworkTransition: false,
            showsArtwork: false,
            onImportLyrics: {
                importTrackID = song.id
                importingLyrics = true
            }
        )
    }

    private var portraitArtworkFrame: CGRect {
        if page == .artwork {
            return displayedArtworkPageFrame
        }

        return CGRect(
            x: 0,
            y: NowPlayingSongHeader.topInset + sharedPortraitSongHeaderOffset,
            width: NowPlayingSongHeader.referenceHeight,
            height: NowPlayingSongHeader.referenceHeight
        )
    }

    private var displayedArtworkPageFrame: CGRect {
        guard !isPortraitArtworkExpanded else {
            return artworkPageFrame
        }
        let horizontalInset =
            artworkPageFrame.width
            * (1 - NowPlayingArtworkPage.pausedArtworkScale)
            / 2
        let verticalInset =
            artworkPageFrame.height
            * (1 - NowPlayingArtworkPage.pausedArtworkScale)
            / 2
        return artworkPageFrame.insetBy(
            dx: horizontalInset,
            dy: verticalInset
        )
    }

    private var isPortraitArtworkExpanded: Bool {
        player.isPlaying
    }

    private var sharedPortraitSongHeaderOffset: CGFloat {
        page == .queue ? queueSongHeaderOffset : 0
    }

    private var queueHeaderFadeHeight: CGFloat {
        page == .queue ? min(24, max(0, -queueSongHeaderOffset)) : 0
    }

    private func pageContentTransition(
        for destination: NowPlayingPage
    ) -> AnyTransition {
        if NowPlayingPageTransition.isDirectLyricsQueueTransition(
            from: pageTransition.sourcePage,
            to: pageTransition.destinationPage
        ) {
            return NowPlayingPageTransition.directAlternateContent(
                reducesMotion: accessibilityReduceMotion
            )
        }

        return NowPlayingPageTransition.content(
            for: destination,
            entersFromHiddenQueue:
                pageTransition.entersFromHiddenQueue,
            reducesMotion: accessibilityReduceMotion
        )
    }

    private var transitionSettlementTaskID:
        NowPlayingTransitionSettlementTaskID {
        NowPlayingTransitionSettlementTaskID(
            requestID: pageTransition.transition?.id,
            isLyricsEntrancePresented:
                pageTransition.isLyricsEntrancePresented
        )
    }

    private var lyricsEntranceTaskID:
        NowPlayingLyricsEntranceTaskID {
        NowPlayingLyricsEntranceTaskID(
            requestID: pageTransition.pendingLyricsEntrance?
                .requestID,
            songID: player.currentTrack?.id,
            preparedSongID: preparedLyricsSongID,
            isContentPrepared: isLyricsContentPrepared
        )
    }

    private func settlePageTransition() async {
        guard let transition = pageTransition.transition,
              pageTransition.isLyricsEntrancePresented else {
            return
        }

        let now = ContinuousClock.now
        let settlementDuration = accessibilityReduceMotion
            ? 0
            : max(
                NowPlayingPageTransition.motion.settlementDuration(
                    for: transition
                ),
                pageTransition.activeMotionRemainingDuration(at: now)
            )
        if settlementDuration > 0 {
            do {
                try await Task.sleep(
                    for: .seconds(settlementDuration)
                )
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              page == transition.destination,
              pageTransition.transition?.id == transition.id else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageTransition.settleTransition(
                requestID: transition.id
            )
        }
    }

    private func presentLyricsEntrance() async {
        guard let pendingEntrance =
            pageTransition.pendingLyricsEntrance else {
            return
        }
        let requestID = pendingEntrance.requestID

        await Task.yield()
        guard !Task.isCancelled,
              pageTransition.pendingLyricsEntrance?.requestID
                == requestID else {
            return
        }

        if accessibilityReduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageTransition.presentLyricsEntrance(
                    requestID: requestID,
                    motion: NowPlayingPageTransition.motion
                )
            }
            return
        }

        guard page == .lyrics,
              pageTransition.usesStagedLyricsEntrance else {
            return
        }

        let presentationDeadline = isLyricsContentPrepared
            ? pendingEntrance.notBefore
            : pendingEntrance.fallbackAt
        let remainingDelay = ContinuousClock.now.duration(
            to: presentationDeadline
        )
        if remainingDelay > .zero {
            do {
                try await Task.sleep(for: remainingDelay)
            } catch {
                return
            }
        }

        guard !Task.isCancelled,
              page == .lyrics,
              pageTransition.pendingLyricsEntrance?.requestID
                == requestID else {
            return
        }

        pageTransition.presentLyricsEntrance(
            requestID: requestID,
            motion: NowPlayingPageTransition.motion
        )
    }

    private var isLyricsContentPrepared: Bool {
        (lyricsModel.lyrics?.isEmpty == true || lyricsModel.error != nil)
            || preparedLyricsSongID == player.currentTrack?.id
    }

    private func markLyricsContentPrepared(for songID: ReferenceTrack.ID) {
        guard player.currentTrack?.id == songID else { return }
        preparedLyricsSongID = songID
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

private struct NowPlayingTransitionSettlementTaskID: Equatable {
    let requestID: UUID?
    let isLyricsEntrancePresented: Bool
}

private struct NowPlayingLyricsEntranceTaskID: Equatable {
    let requestID: UUID?
    let songID: ReferenceTrack.ID?
    let preparedSongID: ReferenceTrack.ID?
    let isContentPrepared: Bool
}
