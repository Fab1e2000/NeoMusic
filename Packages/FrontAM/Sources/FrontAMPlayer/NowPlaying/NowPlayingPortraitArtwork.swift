// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

enum NowPlayingPortraitCoordinateSpace {
    static let name = "nowPlayingPortraitPageContent"
}

struct NowPlayingPortraitArtwork: View {
    @Environment(PlayerState.self) private var player

    let song: PlayerTrack
    let isArtworkPage: Bool
    var decodeSize: CGSize? = nil
    var clipsToQueueEdges = false

    private var image: ArtworkImage {
        ArtworkImage(
            url: song.coverURL,
            contentID: song.id,
            artworkLoadID: song.artworkLoadID,
            cornerRadius: 12,
            decodeSize: decodeSize
        )
    }

    var body: some View {
        Group {
            if clipsToQueueEdges {
                NowPlayingQueueArtworkSurface(artwork: image)
            } else {
                image
            }
        }
        .geometryGroup()
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: shadowRadius,
            y: shadowOffset
        )
        .accessibilityElement()
        .accessibilityLabel("\(song.title)的封面")
    }

    private var shadowOpacity: Double {
        guard isArtworkPage else { return 0 }
        return player.isPlaying ? 0.34 : 0.18
    }

    private var shadowRadius: CGFloat {
        guard isArtworkPage else { return 0 }
        return player.isPlaying ? 26 : 14
    }

    private var shadowOffset: CGFloat {
        guard isArtworkPage else { return 0 }
        return player.isPlaying ? 15 : 8
    }

}
