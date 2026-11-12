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
    @Environment(\.playerVisualsActive) private var visualsActive

    let song: ReferenceTrack
    let isArtworkPage: Bool

    @State private var bounceScale: CGFloat = 1
    @State private var bounceGeneration = 0
    @State private var handledBounceGeneration = 0

    var body: some View {
        ArtworkImage(
            url: song.coverURL,
            contentID: song.id,
            artworkLoadID: song.artworkLoadID,
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
        .onChange(of: player.isPlaying) { _, playing in
            if playing && isArtworkPage && visualsActive { bounceGeneration += 1 }
        }
        .task(id: ArtworkBounceRequest(generation: bounceGeneration, isActive: shouldBounce)) {
            guard bounceGeneration > handledBounceGeneration else { bounceScale = 1; return }
            handledBounceGeneration = bounceGeneration
            await animateBounce()
        }
    }

    private var shouldBounce: Bool {
        isArtworkPage && visualsActive && player.isPlaying && !accessibilityReduceMotion
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
        guard shouldBounce else {
            return
        }

        await Task.yield()
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(.easeOut(duration: 0.17), completionCriteria: .removed) {
                bounceScale = 1.055
            } completion: {
                continuation.resume()
            }
        }
        guard !Task.isCancelled else { return }

        withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
            bounceScale = 1
        }
    }
}
