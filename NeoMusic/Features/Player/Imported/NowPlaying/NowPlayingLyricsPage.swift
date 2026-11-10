// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import SwiftUI

enum NowPlayingLyricsPresentation: Equatable {
    case portrait
    case landscape
}

/// A track mismatch is reported as loading before its replacement task starts.
struct NowPlayingLyricsContent {
    let lyrics: ReferenceLyrics?
    let error: String?

    init(availability: NowPlayingLyricsModel.Availability, lyrics: ReferenceLyrics?, error: String?) {
        self.lyrics = availability == .loading ? nil : lyrics
        self.error = availability == .loading ? nil : error
    }
}

struct NowPlayingLyricsPage: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow
    @ScaledMetric(relativeTo: .title) private var plainLyricsFontSize = 36
    @ScaledMetric(relativeTo: .title) private var plainLyricsLineSpacing = 14

    let song: ReferenceTrack
    let lyrics: ReferenceLyrics?
    let errorMessage: String?
    let isActive: Bool
    let presentation: NowPlayingLyricsPresentation
    let isInterfaceHidden: Bool
    let playerFrame: CGRect
    @Environment(ReferencePlayerState.self) private var player
    @State private var lastActiveLineID: Int?
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsSongHeader: Bool
    let onInterfaceInteraction: (() -> Void)?
    let onInterfaceVisibilityChange: ((Bool) -> Void)?
    let onInitialFocusPrepared: (() -> Void)?

    init(
        song: ReferenceTrack,
        lyrics: ReferenceLyrics?,
        errorMessage: String?,
        isActive: Bool = true,
        presentation: NowPlayingLyricsPresentation = .portrait,
        isInterfaceHidden: Bool = false,
        artworkNamespace: Namespace.ID,
        usesArtworkTransition: Bool = true,
        showsSongHeader: Bool = true,
        playerFrame: CGRect,
        onInterfaceInteraction: (() -> Void)? = nil,
        onInterfaceVisibilityChange: ((Bool) -> Void)? = nil,
        onInitialFocusPrepared: (() -> Void)? = nil
    ) {
        self.playerFrame = playerFrame
        self.song = song
        self.lyrics = lyrics
        self.errorMessage = errorMessage
        self.isActive = isActive
        self.presentation = presentation
        self.isInterfaceHidden = isInterfaceHidden
        self.artworkNamespace = artworkNamespace
        self.usesArtworkTransition = usesArtworkTransition
        self.showsSongHeader = showsSongHeader
        self.onInterfaceInteraction = onInterfaceInteraction
        self.onInterfaceVisibilityChange = onInterfaceVisibilityChange
        self.onInitialFocusPrepared = onInitialFocusPrepared
    }

    var body: some View {
        VStack(spacing: lyricsContentSpacing) {
            if presentation == .portrait, showsSongHeader {
                songHeader
            }

            lyricsStyleContent
                .transition(.opacity)
        }
        .padding(.top, sharedSongHeaderInset)
        .padding(.bottom, portraitContentBottomInset)
        .animation(
            accessibilityReduceMotion ? nil : .smooth(duration: 0.3),
            value: presentation
        )
        .background {
            // Progress ticks five times a second. Publish a new line only when the focused row changes.
            LyricLineObserver(lyrics: lyrics, isActive: isActive, fallback: lastActiveLineID, lineID: $lastActiveLineID)
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

    @ViewBuilder
    private var lyricsStyleContent: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("歌词读取失败", systemImage: "exclamationmark.bubble", description: Text(errorMessage))
            } else if let lyrics {
                if lyrics.isEmpty {
                    ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                } else if lyrics.isTimed {
                    AppleMusicLocalLyricsView(
                        lyrics: lyrics, playerFrame: playerFrame, activeID: lastActiveLineID,
                        bottomOverlayHeight: appleMusicBottomOverlayHeight, isActive: isActive,
                        isInterfaceHidden: Binding(get: { isInterfaceHidden }, set: { onInterfaceVisibilityChange?(!$0) }),
                        onSeek: { player.seek(to: $0) },
                        playerCoordinateSpace: .named(NowPlayingContentCoordinateSpace.name)
                    )
                } else {
                    ScrollView {
                        Text(lyrics.plainText).font(.system(size: plainLyricsFontSize, weight: .bold)).lineSpacing(plainLyricsLineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .padding(.bottom, appleMusicBottomOverlayHeight)
                }
            } else { ContentSkeleton(layout: .lyrics).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        .pageContentReveal(isReady: lyrics != nil || errorMessage != nil)
        .task(id: lyrics != nil || errorMessage != nil) {
            guard lyrics != nil || errorMessage != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            onInitialFocusPrepared?()
        }
    }

    private var appleMusicBottomOverlayHeight: CGFloat {
        switch presentation {
        case .portrait:
            NowPlayingBottomControls.overlayHeight + controlsOverflow
        case .landscape:
            50
        }
    }

    private var portraitContentBottomInset: CGFloat {
        guard presentation == .portrait else { return 0 }
        return 12
    }

    private var usesReferencePortraitLayout: Bool {
        presentation == .portrait
    }

    private var lyricsContentSpacing: CGFloat {
        guard presentation == .portrait else { return 0 }
        return usesReferencePortraitLayout ? 16 : 18
    }

    private var sharedSongHeaderInset: CGFloat {
        guard presentation == .portrait, !showsSongHeader else {
            return 0
        }
        return NowPlayingSongHeader.topInset
            + NowPlayingSongHeader.referenceHeight
            + lyricsContentSpacing
    }

}

/// Reads playback progress without invalidating the lyric rows until the active line changes.
private struct LyricLineObserver: View {
    let lyrics: ReferenceLyrics?
    let isActive: Bool
    let fallback: Int?
    @Binding var lineID: Int?
    @Environment(ReferencePlayerState.self) private var player

    private var line: Int? {
        guard isActive, let lyrics else { return fallback }
        return lyrics.activeLine(at: player.progress)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: line, initial: true) { _, value in
                if lineID != value { lineID = value }
            }
    }
}
