// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

enum NowPlayingPortraitCoordinateSpace {
    static let name = "nowPlayingPortraitPageContent"
}

struct NowPlayingPortraitArtwork: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(ReferencePlayerState.self) private var player

    let song: ReferenceTrack
    let isArtworkPage: Bool

    @State private var bounceScale: CGFloat = 1

    var body: some View {
        ArtworkImage(
            url: song.coverURL,
            cornerRadius: 12
        )
        .scaleEffect(bounceScale)
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: shadowRadius,
            y: shadowOffset
        )
        .animation(
            accessibilityReduceMotion
                ? nil
                : .easeInOut(duration: 0.3),
            value: player.isPlaying
        )
        .accessibilityElement()
        .accessibilityLabel("\(song.title)的封面")
        .task(id: shouldBounce) {
            await animateBounce()
        }
    }

    private var shouldBounce: Bool {
        isArtworkPage && player.isPlaying
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

    private func animateBounce() async {
        bounceScale = 1
        guard shouldBounce, !accessibilityReduceMotion else {
            return
        }

        await Task.yield()
        withAnimation(.easeOut(duration: 0.17)) {
            bounceScale = 1.055
        }

        do {
            try await Task.sleep(for: .milliseconds(170))
        } catch {
            return
        }

        withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
            bounceScale = 1
        }
    }
}
