// Direct source port from MeloX (GPL-3.0), b8bc60f.
// Data/settings adapters retain NeoDizzy playback and lyric sources.
import SwiftUI

enum NowPlayingLyricsPresentation: Equatable {
    case portrait
    case landscape
}

/// A track mismatch is reported as loading before its replacement task starts.
struct NowPlayingLyricsContent {
    let lyrics: PlayerLyrics?
    let error: String?

    init(availability: NowPlayingLyricsModel.Availability, lyrics: PlayerLyrics?, error: String?) {
        self.lyrics = availability == .loading ? nil : lyrics
        self.error = availability == .loading ? nil : error
    }
}

struct NowPlayingLyricsPage: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow
    @ScaledMetric(relativeTo: .title) private var plainLyricsFontSize = 36
    @ScaledMetric(relativeTo: .title) private var plainLyricsLineSpacing = 14

    let song: PlayerTrack
    let lyrics: PlayerLyrics?
    let errorMessage: String?
    let isActive: Bool
    let presentation: NowPlayingLyricsPresentation
    let isInterfaceHidden: Bool
    @Environment(PlayerState.self) private var player
    @State private var lastActiveLineID: Int?
    @State private var loadingFeedback = NowPlayingLyricsLoadingFeedback()
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsSongHeader: Bool
    let showsTranslation: Bool
    let onInterfaceInteraction: (() -> Void)?
    let onInterfaceVisibilityChange: ((Bool) -> Void)?
    let onUserInteractionChange: ((Bool) -> Void)?

    init(
        song: PlayerTrack,
        lyrics: PlayerLyrics?,
        errorMessage: String?,
        isActive: Bool = true,
        presentation: NowPlayingLyricsPresentation = .portrait,
        isInterfaceHidden: Bool = false,
        artworkNamespace: Namespace.ID,
        usesArtworkTransition: Bool = true,
        showsSongHeader: Bool = true,
        showsTranslation: Bool = false,
        onInterfaceInteraction: (() -> Void)? = nil,
        onInterfaceVisibilityChange: ((Bool) -> Void)? = nil,
        onUserInteractionChange: ((Bool) -> Void)? = nil
    ) {
        self.song = song
        self.lyrics = lyrics
        self.errorMessage = errorMessage
        self.isActive = isActive
        self.presentation = presentation
        self.isInterfaceHidden = isInterfaceHidden
        self.artworkNamespace = artworkNamespace
        self.usesArtworkTransition = usesArtworkTransition
        self.showsSongHeader = showsSongHeader
        self.showsTranslation = showsTranslation
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

    private var contentReady: Bool { lyrics != nil || errorMessage != nil || showsLoadingFeedback }

    @ViewBuilder
    private var lyricsStyleContent: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("歌词读取失败", systemImage: "exclamationmark.bubble", description: Text(errorMessage))
                    .padding(.top, sharedSongHeaderInset)
            } else if let lyrics {
                if lyrics.isEmpty {
                    ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                        .padding(.top, sharedSongHeaderInset)
                } else if lyrics.isTimed {
                    AppleMusicLocalLyricsView(
                        lyrics: lyrics, activeID: lastActiveLineID,
                        bottomOverlayHeight: appleMusicBottomOverlayHeight, isActive: isActive,
                        isInterfaceHidden: Binding(get: { isInterfaceHidden }, set: { onInterfaceVisibilityChange?(!$0) }),
                        onSeek: { player.seek(to: $0) },
                        topOverlayHeight: sharedSongHeaderInset - lyricsContentSpacing,
                        showsTranslation: showsTranslation,
                        onUserInteractionChange: onUserInteractionChange
                    )
                } else {
                    ScrollView {
                        Text(lyrics.plainText)
                            .font(.system(size: plainLyricsFontSize, weight: .bold))
                            .lineSpacing(plainLyricsLineSpacing)
                            .nowPlayingPrimary()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.top, sharedSongHeaderInset)
                    .padding(.bottom, isInterfaceHidden ? 0 : appleMusicBottomOverlayHeight)
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

    private var appleMusicBottomOverlayHeight: CGFloat {
        switch presentation {
        case .portrait:
            max(0, layout.contentSize.height - 3 - layout.contentY(557)) + controlsOverflow
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

/// Delay belongs to the visible load task; replacing or hiding that task cancels publication.
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

/// Reads playback progress without invalidating the lyric rows until the active line changes.
private struct LyricLineObserver: View {
    let lyrics: PlayerLyrics?
    let isActive: Bool
    let fallback: Int?
    @Binding var lineID: Int?
    @Environment(PlayerState.self) private var player

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
