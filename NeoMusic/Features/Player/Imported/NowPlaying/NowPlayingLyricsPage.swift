// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import SwiftUI

enum NowPlayingLyricsPresentation: Equatable {
    case portrait
    case landscape
}

struct NowPlayingLyricsPage: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let song: ReferenceTrack
    let lyrics: ReferenceLyrics?
    let errorMessage: String?
    let isActive: Bool
    let presentation: NowPlayingLyricsPresentation
    let isInterfaceHidden: Bool
    let playerFrame: CGRect
    @Environment(ReferencePlayerState.self) private var player
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
                        lyrics: lyrics, playerFrame: playerFrame, activeID: lyrics.activeLine(at: player.progress),
                        bottomOverlayHeight: appleMusicBottomOverlayHeight, isActive: isActive,
                        isInterfaceHidden: Binding(get: { isInterfaceHidden }, set: { onInterfaceVisibilityChange?(!$0) }),
                        onSeek: { player.seek(to: $0) },
                        playerCoordinateSpace: .named(NowPlayingContentCoordinateSpace.name)
                    )
                } else {
                    ScrollView {
                        Text(lyrics.plainText).font(.system(size: 36, weight: .bold)).lineSpacing(14)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .padding(.bottom, appleMusicBottomOverlayHeight)
                }
            } else { ContentSkeleton(layout: .lyrics).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        .pageContentReveal(isReady: lyrics != nil || errorMessage != nil)
        .task(id: lyrics != nil) {
            guard lyrics != nil || errorMessage != nil else { return }
            await Task.yield()
            onInitialFocusPrepared?()
        }
    }

    private var appleMusicBottomOverlayHeight: CGFloat {
        switch presentation {
        case .portrait:
            NowPlayingBottomControls.overlayHeight
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
