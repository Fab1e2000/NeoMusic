// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

struct NowPlayingArtworkTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    let isEnabled: Bool
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.matchedGeometryEffect(
                id: id,
                in: namespace,
                properties: .frame,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

extension View {
    func nowPlayingArtworkTransition<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        isEnabled: Bool,
        isSource: Bool = true
    ) -> some View {
        modifier(
            NowPlayingArtworkTransitionModifier(
                id: id,
                namespace: namespace,
                isEnabled: isEnabled,
                isSource: isSource
            )
        )
    }
}

struct NowPlayingSongHeader: View {
    static let referenceHeight: CGFloat = 72
    static let topInset: CGFloat = -2.75
    static let bottomSpacing: CGFloat = 4.75
    static let height = referenceHeight

    let song: PlayerTrack
    let artworkNamespace: Namespace.ID
    let usesReferenceLayout: Bool
    let usesArtworkTransition: Bool
    let showsArtwork: Bool
    var onImportLyrics: (() -> Void)? = nil

    init(
        song: PlayerTrack,
        artworkNamespace: Namespace.ID,
        usesReferenceLayout: Bool,
        usesArtworkTransition: Bool = true,
        showsArtwork: Bool = true,
        onImportLyrics: (() -> Void)? = nil
    ) {
        self.onImportLyrics = onImportLyrics
        self.song = song
        self.artworkNamespace = artworkNamespace
        self.usesReferenceLayout = usesReferenceLayout
        self.usesArtworkTransition = usesArtworkTransition
        self.showsArtwork = showsArtwork
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: artworkSize, height: artworkSize)

            NowPlayingTrackSwipe(song: song, rowSpacing: 2, viewportInsets: .header) { track, marqueeActive in
                NowPlayingMarqueeText(text: track.title, isActive: marqueeActive)
                    .font(
                        usesReferenceLayout
                            ? .headline
                            : .headline
                    )
                    .nowPlayingPrimary()
                    .lineLimit(1)
                    .offset(y: usesReferenceLayout ? 5 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } artist: { track, interactive in
                NowPlayingArtistButton(track: track, interactive: interactive, lineHeight: usesReferenceLayout ? 18 : 26, fontSize: 15)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NowPlayingSongActions(
                track: song, onImportLyrics: onImportLyrics
            )
            .offset(x: usesReferenceLayout ? 6 : 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if showsArtwork {
            NowPlayingPortraitArtwork(song: song, isArtworkPage: false)
            .nowPlayingArtworkTransition(
                id: song.id,
                in: artworkNamespace,
                isEnabled: usesArtworkTransition,
                isSource: false
            )
        } else {
            Color.clear
        }
    }

    private var artworkSize: CGFloat {
        usesReferenceLayout ? Self.referenceHeight : 68
    }

    private var artistText: String {
        guard usesReferenceLayout else { return song.artists }
        return song.artists
    }
}
