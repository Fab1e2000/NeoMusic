// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingContent<ArtworkTransition: ViewModifier>: View {
    let artworkTransition: ArtworkTransition
    @Environment(PlayerServices.self) private var services: PlayerServices?
    private var portraitHorizontalPadding: CGFloat { 32 }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(PlayerState.self) private var player
    @Environment(PlayerLyricsSource.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: NowPlayingPage
    @State private var pageChange: NowPlayingPageChange?
    @State private var showsLyricsControls = true
    @State private var appleMusicControlsActivityGeneration = 0
    @State private var lyricsControlTouchCount = 0
    @State private var isQueueSongHeaderHidden = false
    @State private var queueHeaderOffset = QueueHeaderOffset()
    @State private var geometryState: NowPlayingGeometry
    @State private var artworkPageFrame = CGRect.zero
    @State private var lyricsModel = NowPlayingLyricsModel()
    @State private var progressInteraction = NowPlayingProgressInteraction()
    @State private var controlsHeight = NowPlayingBottomControls.overlayHeight
    @State private var importingLyrics = false
    @State private var importTrackID: String?
    @State private var pagePerformanceInterval: (() -> Void)?
    @Namespace private var pageArtworkNamespace
    private let onDismiss: (() -> Void)?
    private let isActive: Bool
    private var visualsActive: Bool { isActive && scenePhase == .active }
    private var animatesPageChanges: Bool { visualsActive && !accessibilityReduceMotion }
    init(artworkTransition: ArtworkTransition, initialPage: NowPlayingPage = .artwork, onDismiss: (() -> Void)? = nil,
         geometry: NowPlayingGeometry = NowPlayingGeometry(), isActive: Bool = true) {
        self.artworkTransition = artworkTransition
        self.onDismiss = onDismiss
        self.isActive = isActive
        _page = State(initialValue: initialPage)
        // Geometry belongs to this presentation's identity; callers may supply
        // its initial owner to observe layout without screen-coordinate feedback.
        _geometryState = State(initialValue: geometry)
    }
    private var artworkPreparationIDs: [String] {
        guard visualsActive else { return [] }
        return [player.currentTrack?.artworkLoadID, player.previousInOrder?.track.artworkLoadID,
                player.nextInOrder?.track.artworkLoadID].compactMap { $0 }
    }

    private var lyricsLoadKey: String {
        "\(player.currentTrack?.id ?? "")/\(library.contentRevision)/\(lyricsModel.revision)"
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = ReferenceNowPlayingLayout(contentSize: geometry.size)
            ZStack {
                // 背景自己在铺满安全区之后上报位置，背景副本才能和它完全重合。
                PlaybackLinkedBackdrop(
                    artworkURL: player.currentTrack?.coverURL,
                    trackID: player.currentTrack?.id,
                    onFrameChange: { geometryState.backdropFrame = $0 }
                )
                // iPhone 只支持竖屏（见 project.yml 的 UISupportedInterfaceOrientations），不保留横屏布局。
                if let song = player.currentTrack {
                    portraitContent(for: song, layout: layout,
                                    lyricsBottomExtension: geometry.safeAreaInsets.bottom + 3)
                } else {
                    ContentUnavailableView("当前没有播放歌曲", systemImage: "music.note").foregroundStyle(.white)
                }
            }
            .compositingGroup()
            .environment(\.nowPlayingLayout, layout)
            .environment(\.nowPlayingControlsOverflow, textSize.isAccessibilitySize
                         ? max(0, controlsHeight - NowPlayingBottomControls.overlayHeight) : 0)
        }
        .coordinateSpace(.named(NowPlayingContentCoordinateSpace.name))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.playerVisualsActive, visualsActive)
        .background {
            LyricsControlsAutoHideObserver(
                onLyricsPage: page == .lyrics,
                controlsVisible: showsLyricsControls,
                active: visualsActive,
                voiceOver: accessibilityVoiceOverEnabled,
                touching: lyricsControlTouchCount > 0,
                transitioning: pageChange != nil,
                generation: appleMusicControlsActivityGeneration,
                onAutoHide: { setAppleMusicLyricsControlsVisible(false) }
            )
        }
        .environment(progressInteraction)
        .task(id: artworkPreparationIDs) {
            for identity in Set(artworkPreparationIDs) { services?.artwork.prepare(identity) }
        }
        .task(id: lyricsLoadKey) {
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
        .onChange(of: page) { _, _ in
            showsLyricsControls = true
            lyricsControlTouchCount = 0
        }
        .onChange(of: player.currentTrackTransitionKey) { _, _ in
            showsLyricsControls = true
            lyricsControlTouchCount = 0
            progressInteraction.resetForTrackChange()
        }
        .onChange(of: lyricsAvailability, initial: true) { _, availability in
            if page == .lyrics, availability == .empty { selectPage(.artwork) }
        }
        .onChange(of: accessibilityVoiceOverEnabled) { _, enabled in
            if enabled, page == .lyrics { showsLyricsControls = true }
        }
        .onChange(of: player.currentTrack == nil) { _, empty in if empty { closePlayer() } }
        .onDisappear { finishPageChange() }
        .fileImporter(isPresented: $importingLyrics, allowedContentTypes: [.data, .plainText]) { result in
            guard let id = importTrackID, case .success(let url) = result else { return }
            Task { await lyricsModel.importFile(url, trackID: id, reader: library) }
        }
    }

    private func closePlayer() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func portraitContent(for song: PlayerTrack, layout: ReferenceNowPlayingLayout,
                                 lyricsBottomExtension: CGFloat) -> some View {
        VStack(spacing: 0) {
            dismissalHandle(layout: layout)

            pageContent(for: song, lyricsBottomExtension: lyricsBottomExtension)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    portraitPlayerControlsLayer(for: song)
                }
        }
        .padding(.horizontal, portraitHorizontalPadding)
        .safeAreaPadding(.bottom, 3)
    }

    private func portraitPlayerControlsLayer(
        for song: PlayerTrack
    ) -> some View {
        ZStack(alignment: .bottom) {
            portraitPlayerControls(for: song)
                .modifier(LyricsControlSurfaceHitShield(isActive: page == .lyrics))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .background {
                    LyricsControlsIdleTouchMonitor(
                        isActive: page == .lyrics,
                        onBegan: lyricsControlTouchBegan,
                        onEnded: lyricsControlTouchEnded
                    )
                }
                .allowsHitTesting(!hidesLyricsControls)
                .accessibilityHidden(hidesLyricsControls)


        }
    }

    private func portraitPlayerControls(for song: PlayerTrack) -> some View {
        NowPlayingBottomControls(
            song: song,
            page: page,
            onPageTap: { selectPage(page == $0 ? .artwork : $0) },
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

    private func selectPage(_ destination: NowPlayingPage) {
        guard destination != page,
              destination != .lyrics || lyricsAvailability == .available else { return }
        finishPageMeasurement()
        pagePerformanceInterval = services?.diagnostics?.begin("PlayerPageSwitch", animation: true)
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
            showsLyricsControls = true
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

    private var titleSpatialAnimation: Animation? {
        guard animatesPageChanges else { return nil }
        return pageChange?.source == .artwork
            ? NowPlayingPageTransition.motion.titleCollapse.animation
            : NowPlayingPageTransition.animation
    }

    private var hidesLyricsControls: Bool {
        page == .lyrics && !showsLyricsControls
    }

    private var usesAutoHidingAppleMusicInterface: Bool {
        page == .lyrics
    }

    private var hasLyricsTranslations: Bool { lyricsContent.lyrics?.hasTranslation == true }
    private var hasLyricsRomanizations: Bool { false }

    private var usesExpandedAppleMusicLyricsLayout: Bool {
        page == .lyrics
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
        .overlay(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.rect)
                .onTapGesture {
                    closePlayer()
                }
        }
        .zIndex(1)
        .accessibilityElement()
        .accessibilityLabel("收起播放器")
        .accessibilityHint("返回上一页")
        .accessibilityIdentifier("player.dismiss")
        .accessibilityAction {
            closePlayer()
        }
    }

    private func pageContent(for song: PlayerTrack, lyricsBottomExtension: CGFloat) -> some View {
        ZStack(alignment: .top) {
            transientArtworkPageContent(for: song)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .padding(.horizontal, portraitHorizontalPadding)
                .clipped()
                .padding(.horizontal, -portraitHorizontalPadding)

            residentQueuePage(for: song)

            residentAppleMusicLyricsPage(for: song, bottomExtension: lyricsBottomExtension)

            QueueLinkedSongHeader(
                song: song,
                page: page,
                offset: queueHeaderOffset,
                artworkNamespace: pageArtworkNamespace,
                onImportLyrics: library.canImport ? {
                    importTrackID = song.id
                    importingLyrics = true
                } : nil
            )
            .padding(.top, NowPlayingSongHeader.topInset)
            .offset(y: page == .artwork && !accessibilityReduceMotion ? NowPlayingPageTransition.motion.songHeaderTravel : 0)
            .animation(titleSpatialAnimation, value: page == .artwork)
            .opacity(page == .artwork ? 0 : 1)
            .animation(animatesPageChanges
                       ? (page == .artwork ? .easeInOut(duration: 0.12)
                                          : .easeInOut(duration: 0.125).delay(0.234)) : nil,
                       value: page == .artwork)
            .allowsHitTesting(page != .artwork)
            .accessibilityHidden(page == .artwork)

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
                reducesMotion: accessibilityReduceMotion,
                artworkTransition: artworkTransition
            )
        }
        .coordinateSpace(
            name: NowPlayingPortraitCoordinateSpace.name
        )
    }

    @ViewBuilder
    private func transientArtworkPageContent(
        for song: PlayerTrack
    ) -> some View {
        let isVisible = page == .artwork
        let yOffset: CGFloat = if isVisible || accessibilityReduceMotion {
            0
        } else if pageChange?.entersFromHiddenQueue == true {
            -NowPlayingPageTransition.motion.artworkDetailsTravel
        } else {
            NowPlayingPageTransition.motion.artworkDetailsTravel
        }
        NowPlayingArtworkPage(
            song: song,
            artworkNamespace: pageArtworkNamespace,
            usesArtworkTransition: false,
            showsArtwork: false
        )
        .offset(y: yOffset)
        .animation(titleSpatialAnimation, value: isVisible)
        .opacity(isVisible ? 1 : 0)
        .animation(animatesPageChanges
                   ? (isVisible ? .easeInOut(duration: 0.125).delay(0.15)
                                : .easeInOut(duration: 0.12).delay(0.04)) : nil,
                   value: isVisible)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .environment(\.playerVisualsActive, visualsActive && isVisible)
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
        for song: PlayerTrack
    ) -> some View {
        let isVisible = page == .queue

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
        // 列表及切页遮罩均使用整屏宽度，保留边缘的原生滚动条。
        .padding(.horizontal, portraitHorizontalPadding)
        .clipped()
        .modifier(NowPlayingPagePresentation(
            isVisible: isVisible, page: .queue, selectedPage: page, change: pageChange,
            animates: animatesPageChanges
        ))
        .padding(.horizontal, -portraitHorizontalPadding)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .environment(\.playerVisualsActive, visualsActive && (isVisible || pageChange?.source == .queue))
    }

    private func portraitLyricsPage(for song: PlayerTrack, bottomExtension: CGFloat) -> some View {
        NowPlayingLyricsPage(
            song: song, lyrics: lyricsContent.lyrics, errorMessage: lyricsContent.error,
            isActive: visualsActive && page == .lyrics,
            isPageVisible: isActive && page == .lyrics,
            isInterfaceHidden: hidesLyricsControls,
            artworkNamespace: pageArtworkNamespace, showsSongHeader: false,
            showsTranslation: true,
            bottomOverlayExtension: bottomExtension,
            onInterfaceInteraction: handleLyricsInterfaceInteraction,
            onInterfaceVisibilityChange: setAppleMusicLyricsControlsVisible,
            onUserInteractionChange: { active in
                if active { lyricsControlTouchBegan() } else { lyricsControlTouchEnded() }
            }
        )
        .accessibilityAction(named: lyricsInterfaceAccessibilityActionName) {
            handleLyricsInterfaceInteraction()
        }
    }

    private func residentAppleMusicLyricsPage(for song: PlayerTrack, bottomExtension: CGFloat) -> some View {
        let isVisible = page == .lyrics
        return portraitLyricsPage(for: song, bottomExtension: bottomExtension)
            .id(song.id)
            .padding(.horizontal, portraitHorizontalPadding)
            .modifier(NowPlayingPagePresentation(
                isVisible: isVisible, page: .lyrics, selectedPage: page, change: pageChange,
                animates: animatesPageChanges,
                clipsAboveControls: !isVisible || (!hidesLyricsControls && pageChange != nil)
            ))
            .padding(.horizontal, -portraitHorizontalPadding)
            .padding(.bottom, -bottomExtension)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }

    private func finishPageMeasurement() {
        guard let interval = pagePerformanceInterval else { return }
        interval()
        pagePerformanceInterval = nil
    }

    private var lyricsInterfaceAccessibilityActionName: String { "显示播放控件" }

    private func handleLyricsInterfaceInteraction() {
        registerAppleMusicControlsActivity()
    }

    private func lyricsControlTouchBegan() {
        guard page == .lyrics else { return }
        lyricsControlTouchCount += 1
        appleMusicControlsActivityGeneration &+= 1
    }

    private func lyricsControlTouchEnded() {
        lyricsControlTouchCount = max(0, lyricsControlTouchCount - 1)
        if page == .lyrics {
            appleMusicControlsActivityGeneration &+= 1
        }
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

enum LyricsControlsIdle {
    static let duration: Duration = .seconds(4)

    static func shouldScheduleHide(onLyricsPage: Bool, controlsVisible: Bool, voiceOver: Bool,
                                    playerActive: Bool, touching: Bool, transitioning: Bool,
                                    isPlaying: Bool = true) -> Bool {
        onLyricsPage && controlsVisible && playerActive && isPlaying && !voiceOver && !touching && !transitioning
    }
}

private struct LyricsControlsIdleKey: Equatable {
    let onLyricsPage: Bool
    let controlsVisible: Bool
    let active: Bool
    let isPlaying: Bool
    let voiceOver: Bool
    let touching: Bool
    let transitioning: Bool
    let generation: Int
}

/// Observes `player.isPlaying` and scrubbing state outside `NowPlayingContent.body`
/// so toggling playback disables auto-hide without re-evaluating the whole player tree.
private struct LyricsControlsAutoHideObserver: View {
    @Environment(PlayerState.self) private var player
    @Environment(NowPlayingProgressInteraction.self) private var progressInteraction: NowPlayingProgressInteraction?
    let onLyricsPage: Bool
    let controlsVisible: Bool
    let active: Bool
    let voiceOver: Bool
    let touching: Bool
    let transitioning: Bool
    let generation: Int
    let onAutoHide: () -> Void

    private var isScrubbing: Bool {
        progressInteraction?.isPressed == true || progressInteraction?.scrubbingProgress != nil
    }

    private var idleKey: LyricsControlsIdleKey {
        LyricsControlsIdleKey(
            onLyricsPage: onLyricsPage,
            controlsVisible: controlsVisible,
            active: active,
            isPlaying: player.isPlaying,
            voiceOver: voiceOver,
            touching: touching || isScrubbing,
            transitioning: transitioning,
            generation: generation
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: idleKey) {
                guard LyricsControlsIdle.shouldScheduleHide(
                    onLyricsPage: onLyricsPage,
                    controlsVisible: controlsVisible,
                    voiceOver: voiceOver,
                    playerActive: active,
                    touching: touching || isScrubbing,
                    transitioning: transitioning,
                    isPlaying: player.isPlaying
                ) else { return }
                do { try await Task.sleep(for: LyricsControlsIdle.duration) } catch { return }
                guard !Task.isCancelled else { return }
                onAutoHide()
            }
    }
}

/// Observes touches on the player without taking them from buttons, sliders, or lyric rows.
private struct LyricsControlsIdleTouchMonitor: UIViewRepresentable {
    var isActive: Bool
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> IdleTouchAnchor {
        let view = IdleTouchAnchor()
        view.isUserInteractionEnabled = false
        view.isMonitoringEnabled = isActive
        view.onBegan = onBegan
        view.onEnded = onEnded
        return view
    }

    func updateUIView(_ uiView: IdleTouchAnchor, context: Context) {
        uiView.isMonitoringEnabled = isActive
        uiView.onBegan = onBegan
        uiView.onEnded = onEnded
    }

    final class IdleTouchAnchor: UIView, UIGestureRecognizerDelegate {
        var isMonitoringEnabled = false {
            didSet { recognizer?.isEnabled = isMonitoringEnabled }
        }
        var onBegan: (() -> Void)?
        var onEnded: (() -> Void)?
        private var recognizer: IdleTouchRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
                recognizer = nil
                return
            }
            attachIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard recognizer == nil, window != nil else { return }
            var host: UIView = self
            while let parent = host.superview, parent !== window {
                if parent.bounds.height > host.bounds.height + 80 { break }
                host = parent
            }
            guard host !== self else { return }
            let recognizer = IdleTouchRecognizer()
            recognizer.isEnabled = isMonitoringEnabled
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.onBegan = { [weak self] in self?.onBegan?() }
            recognizer.onEnded = { [weak self] in self?.onEnded?() }
            host.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class IdleTouchRecognizer: UIGestureRecognizer {
        var onBegan: (() -> Void)?
        var onEnded: (() -> Void)?

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            onBegan?()
            state = .began
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            onEnded?()
            state = .ended
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            onEnded?()
            state = .cancelled
        }
    }
}

/// Keeps taps that miss a button on the lyrics control surface, instead of the lyric row behind it.
struct LyricsControlSurfaceHitShield: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                Color.clear
                    .contentShape(.rect)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Queue scroll writes here. Only the header and floating artwork read it, so the rest of the player stays put.
@MainActor @Observable
private final class QueueHeaderOffset {
    var points: CGFloat = 0
}

private struct QueueLinkedSongHeader: View {
    let song: PlayerTrack
    let page: NowPlayingPage
    let offset: QueueHeaderOffset
    let artworkNamespace: Namespace.ID
    let onImportLyrics: (() -> Void)?

    var body: some View {
        NowPlayingSongHeader(
            song: song,
            artworkNamespace: artworkNamespace,
            usesReferenceLayout: true,
            usesArtworkTransition: false,
            showsArtwork: false,
            onImportLyrics: onImportLyrics
        )
        .modifier(QueueSongHeaderScrollPresentation(page: page, offset: offset))
    }
}

/// Keep scroll observation outside the title, artist menu and track-swipe content.
private struct QueueSongHeaderScrollPresentation: ViewModifier {
    let page: NowPlayingPage
    let offset: QueueHeaderOffset

    func body(content: Content) -> some View {
        let translation = page == .queue ? offset.points : 0
        content
            .offset(y: translation)
            .opacity(NowPlayingSongHeader.scrollFadeOpacity(scrolled: -translation))
    }
}

/// Keep `player.isPlaying` observation inside the backdrop so toggling playback
/// does not invalidate `NowPlayingContent` (including resident lyrics/queue pages).
private struct PlaybackLinkedBackdrop: View {
    @Environment(PlayerState.self) private var player
    let artworkURL: URL?
    let trackID: String?
    let onFrameChange: (CGRect) -> Void

    var body: some View {
        NowPlayingArtworkBackdrop(
            artworkURL: artworkURL,
            trackID: trackID,
            isPlaying: player.isPlaying,
            onFrameChange: onFrameChange
        )
    }
}

private struct QueueLinkedArtwork<ArtworkTransition: ViewModifier>: View {
    @Environment(PlayerState.self) private var player
    let song: PlayerTrack
    let page: NowPlayingPage
    let offset: QueueHeaderOffset
    let artworkPageFrame: CGRect
    let reducesMotion: Bool

    let artworkTransition: ArtworkTransition
    private var expanded: Bool { player.isPlaying }
    private var playbackScale: CGFloat {
        page == .artwork && !expanded ? NowPlayingArtworkPage.pausedArtworkScale : 1
    }
    private var frame: CGRect {
        if page == .artwork {
            return artworkPageFrame
        }
        return CGRect(
            x: 0,
            y: NowPlayingSongHeader.topInset,
            width: NowPlayingSongHeader.referenceHeight,
            height: NowPlayingSongHeader.referenceHeight
        )
    }

    var body: some View {
        GeometryReader { _ in
            if frame.width > 0 {
                NowPlayingPortraitArtwork(
                    song: song,
                    isArtworkPage: page == .artwork,
                    decodeSize: artworkPageFrame.width > 0 ? artworkPageFrame.size : nil
                )
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(playbackScale)
                    .animation(reducesMotion ? nil : .interpolatingSpring(
                        mass: 1, stiffness: expanded ? 180 : 153, damping: expanded ? 16.4 : 22.8
                    ), value: expanded)
                    .modifier(artworkTransition)
                    .modifier(QueueArtworkScrollPosition(page: page, offset: offset, frame: frame))
                    .allowsHitTesting(false)
            }
        }
        .modifier(QueueArtworkScrollMask(page: page, offset: offset))
        .padding(.horizontal, -CGFloat(32))
    }
}

private struct QueueArtworkScrollPosition: ViewModifier {
    let page: NowPlayingPage
    let offset: QueueHeaderOffset
    let frame: CGRect

    func body(content: Content) -> some View {
        content.position(
            x: frame.midX + CGFloat(32),
            y: frame.midY + (page == .queue ? offset.points : 0)
        )
    }
}

private struct QueueArtworkScrollMask: ViewModifier {
    let page: NowPlayingPage
    let offset: QueueHeaderOffset

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                // The queue cover follows the list behind its top edge.
                // Keep the artwork page's shadow uncut beneath the handle.
                VStack(spacing: 0) {
                    NowPlayingQueueTopFade(height: page == .queue ? min(24, max(0, -offset.points)) : 0)
                    Rectangle()
                }
                .padding(.top, page == .queue ? NowPlayingSongHeader.topInset : 0)
                .padding(page == .queue ? 0 : -max(geometry.size.width, geometry.size.height))
            }
        }
    }
}
