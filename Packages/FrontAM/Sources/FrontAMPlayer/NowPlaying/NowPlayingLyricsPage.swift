// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

enum NowPlayingLyricsPresentation: Equatable {
    case portrait
    case landscape
}

struct NowPlayingLyricsContent {
    let lyrics: PlayerLyrics?
    let error: String?

    init(availability: NowPlayingLyricsModel.Availability, lyrics: PlayerLyrics?, error: String?) {
        self.lyrics = availability == .available ? lyrics : nil
        self.error = availability == .loading ? nil : error
    }
}

struct NowPlayingLyricsPage: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow
    @ScaledMetric(relativeTo: .title) private var plainLyricsFontSize = AppleMusicLyricsTypographyProfile.iOS26_6.primaryFontSize
    @ScaledMetric(relativeTo: .title) private var plainLyricsLineSpacing = 14

    let song: PlayerTrack
    let lyrics: PlayerLyrics?
    let errorMessage: String?
    let isActive: Bool
    let isPageVisible: Bool
    let presentation: NowPlayingLyricsPresentation
    let isInterfaceHidden: Bool
    @Environment(PlayerState.self) private var player
    @Environment(NowPlayingProgressInteraction.self) private var progressInteraction: NowPlayingProgressInteraction?
    @State private var lastActiveLineID: Int?
    @State private var isScrubbingProgress = false
    @State private var loadingFeedback = NowPlayingLyricsLoadingFeedback()
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsSongHeader: Bool
    let showsTranslation: Bool
    let bottomOverlayExtension: CGFloat
    let onInterfaceInteraction: (() -> Void)?
    let onInterfaceVisibilityChange: ((Bool) -> Void)?
    let onUserInteractionChange: ((Bool) -> Void)?

    init(
        song: PlayerTrack,
        lyrics: PlayerLyrics?,
        errorMessage: String?,
        isActive: Bool = true,
        isPageVisible: Bool? = nil,
        presentation: NowPlayingLyricsPresentation = .portrait,
        isInterfaceHidden: Bool = false,
        artworkNamespace: Namespace.ID,
        usesArtworkTransition: Bool = true,
        showsSongHeader: Bool = true,
        showsTranslation: Bool = false,
        bottomOverlayExtension: CGFloat = 0,
        onInterfaceInteraction: (() -> Void)? = nil,
        onInterfaceVisibilityChange: ((Bool) -> Void)? = nil,
        onUserInteractionChange: ((Bool) -> Void)? = nil
    ) {
        self.song = song
        self.lyrics = lyrics
        self.errorMessage = errorMessage
        self.isActive = isActive
        self.isPageVisible = isPageVisible ?? isActive
        self.presentation = presentation
        self.isInterfaceHidden = isInterfaceHidden
        self.artworkNamespace = artworkNamespace
        self.usesArtworkTransition = usesArtworkTransition
        self.showsSongHeader = showsSongHeader
        self.showsTranslation = showsTranslation
        self.bottomOverlayExtension = bottomOverlayExtension
        self.onInterfaceInteraction = onInterfaceInteraction
        self.onInterfaceVisibilityChange = onInterfaceVisibilityChange
        self.onUserInteractionChange = onUserInteractionChange
    }

    var body: some View {
        lyricsStyleContent
            .transition(.opacity)
            .overlay(alignment: .top) {
                if presentation == .portrait, showsSongHeader {
                    songHeader
                        .frame(height: NowPlayingSongHeader.referenceHeight)
                        .padding(.top, NowPlayingSongHeader.topInset)
                }
            }
        .animation(
            accessibilityReduceMotion ? nil : .smooth(duration: 0.3),
            value: presentation
        )
        .background {
            LyricLineObserver(
                lyrics: lyrics,
                isActive: isActive,
                fallback: lastActiveLineID,
                lineID: $lastActiveLineID,
                isScrubbing: $isScrubbingProgress
            )
        }
    }

    private var songHeader: some View {
        NowPlayingSongHeader(
            song: song,
            artworkNamespace: artworkNamespace,
            usesReferenceLayout: usesReferencePortraitLayout,
            usesArtworkTransition: usesArtworkTransition
        )
    }

    private var contentReady: Bool { lyrics != nil || errorMessage != nil || showsLoadingFeedback }

    @ViewBuilder
    private var lyricsStyleContent: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("歌词读取失败", systemImage: "exclamationmark.bubble", description: Text(errorMessage))
                    .padding(.top, sharedSongHeaderInset)
                    .contentShape(Rectangle())
                    .onTapGesture { onInterfaceInteraction?() }
            } else if let lyrics {
                if lyrics.isTimed {
                    AppleMusicLocalLyricsView(
                        lyrics: lyrics, activeID: lastActiveLineID,
                        bottomOverlayHeight: appleMusicBottomOverlayHeight,
                        isActive: isActive,
                        isPageVisible: isPageVisible,
                        isInterfaceHidden: Binding(get: { isInterfaceHidden }, set: { onInterfaceVisibilityChange?(!$0) }),
                        onSeek: { player.seek(to: $0) },
                        topOverlayHeight: sharedSongHeaderInset - lyricsContentSpacing,
                        showsTranslation: showsTranslation,
                        isPlaying: player.isPlaying,
                        isScrubbing: isScrubbingProgress,
                        timelineAnchor: player.timelineAnchor,
                        progressInteraction: progressInteraction,
                        onInterfaceInteraction: onInterfaceInteraction,
                        onUserInteractionChange: onUserInteractionChange
                    )
                } else {
                    plainLyricsContent(lyrics.plainText)
                }
            } else {
                Group {
                    if showsLoadingFeedback {
                        ProgressView("正在载入歌词")
                            .font(.body)
                            .tint(.white)
                            .foregroundStyle(.white)
                            .padding(.top, 24)
                            .accessibilityIdentifier("player.lyrics.loading")
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, sharedSongHeaderInset)
            }
        }
        .opacity(contentReady ? 1 : 0)
        .allowsHitTesting(contentReady)
        .accessibilityHidden(!contentReady)
        .transaction(value: contentReady) { $0.animation = nil; $0.disablesAnimations = true }
        .task(id: NowPlayingLyricsLoadingRequest(trackID: song.id, isLoading: lyrics == nil && errorMessage == nil,
                                                isActive: isActive)) {
            guard isActive, lyrics == nil, errorMessage == nil else {
                loadingFeedback.reset()
                return
            }
            await loadingFeedback.waitToShow(for: song.id)
        }
    }

    private var showsLoadingFeedback: Bool {
        isActive && loadingFeedback.visibleTrackID == song.id
    }

    @ViewBuilder
    private func plainLyricsContent(_ plainText: String) -> some View {
        let filteredText = LyricsCreditFilter.filterPlainText(plainText)
        let displayText = filteredText.isEmpty ? plainText : filteredText
        let topOverlay = max(0, sharedSongHeaderInset - lyricsContentSpacing)
        let bottomInset = isInterfaceHidden ? CGFloat(24) : appleMusicBottomOverlayHeight
        ScrollView {
            Text(displayText)
                .font(.system(size: plainLyricsFontSize, weight: .bold))
                .lineSpacing(plainLyricsLineSpacing)
                .nowPlayingPrimary()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.top, sharedSongHeaderInset, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .animation(
            NowPlayingInterfaceTransition.interfaceAnimation(
                isVisible: !isInterfaceHidden,
                reducesMotion: accessibilityReduceMotion
            ),
            value: isInterfaceHidden
        )
        .mask {
            GeometryReader { proxy in
                let height = max(proxy.size.height, 1)
                let fade = LyricsViewportFade(
                    height: height,
                    referenceHeight: max(height - appleMusicBottomOverlayHeight, 1),
                    shownReferenceHeight: max(height - appleMusicBottomOverlayHeight, 1),
                    topOverlayHeight: topOverlay,
                    isInterfaceHidden: isInterfaceHidden
                )
                let topStart = min(max(fade.topStart / height, 0), 1)
                let topEnd = min(max(fade.topEnd / height, topStart), 1)
                let bottomStart = min(max(fade.bottomStart / height, topEnd), 1)
                let bottomEnd = min(max(fade.bottomEnd / height, bottomStart), 1)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: topStart),
                        .init(color: .black, location: topEnd),
                        .init(color: .black, location: bottomStart),
                        .init(color: .clear, location: bottomEnd),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            if isInterfaceHidden {
                onInterfaceInteraction?()
            }
        }
    }

    private var appleMusicBottomOverlayHeight: CGFloat {
        switch presentation {
        case .portrait:
            max(0, layout.contentSize.height - 3 - layout.contentY(557))
                + bottomOverlayExtension + controlsOverflow
        case .landscape:
            50
        }
    }

    private var usesReferencePortraitLayout: Bool {
        presentation == .portrait
    }

    private var lyricsContentSpacing: CGFloat {
        guard presentation == .portrait else { return 0 }
        return usesReferencePortraitLayout ? 16 : 18
    }

    private var sharedSongHeaderInset: CGFloat {
        guard presentation == .portrait else {
            return 0
        }
        return NowPlayingSongHeader.topInset
            + NowPlayingSongHeader.referenceHeight
            + lyricsContentSpacing
    }

}

private struct NowPlayingLyricsLoadingRequest: Equatable {
    let trackID: String
    let isLoading: Bool
    let isActive: Bool
}

@MainActor @Observable final class NowPlayingLyricsLoadingFeedback {
    private(set) var visibleTrackID: String?

    func reset() { visibleTrackID = nil }

    func waitToShow(for trackID: String,
                    wait: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) async {
        reset()
        do {
            try await wait()
            try Task.checkCancellation()
            visibleTrackID = trackID
        } catch { }
    }
}

private struct LyricLineObserver: View {
    let lyrics: PlayerLyrics?
    let isActive: Bool
    let fallback: Int?
    @Binding var lineID: Int?
    @Binding var isScrubbing: Bool
    @Environment(PlayerState.self) private var player
    @Environment(NowPlayingProgressInteraction.self) private var progressInteraction: NowPlayingProgressInteraction?

    private var scrubbing: Bool {
        guard isActive else { return false }
        return progressInteraction?.isPressed == true
    }

    private func resolvedLine(anchor: PlayerTimelineAnchor) -> Int? {
        guard isActive, let lyrics else { return fallback }
        let liveProgress = anchor.elapsed()
        if let interaction = progressInteraction {
            if let scrubbingTime = interaction.scrubbingProgress {
                return lyrics.activeLine(at: scrubbingTime)
            }
            if interaction.isAwaitingCommittedSeek {
                return lyrics.activeLine(at: interaction.displayProgress(live: liveProgress))
            }
        }
        let headstart = anchor.rate > 0 ? AppleMusicLyricsMotionProfile.iOS26_6.animationHeadstart : 0
        return lyrics.activeLine(at: liveProgress + headstart)
    }

    var body: some View {
        let anchor = player.timelineAnchor
        let animatesLive = isActive && lyrics != nil && anchor.rate > 0 && !scrubbing

        Group {
            if animatesLive {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { _ in
                    let activeLine = resolvedLine(anchor: anchor)
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onChange(of: activeLine, initial: true) { _, value in
                            if lineID != value { lineID = value }
                        }
                }
            } else {
                let activeLine = resolvedLine(anchor: anchor)
                Color.clear
                    .frame(width: 0, height: 0)
                    .onChange(of: activeLine, initial: true) { _, value in
                        if lineID != value { lineID = value }
                    }
            }
        }
        .accessibilityHidden(true)
        .onChange(of: scrubbing, initial: true) { _, value in
            if isScrubbing != value { isScrubbing = value }
        }
    }
}
