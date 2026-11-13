import SwiftUI

struct NowPlayingPlayPauseIcon: View {
    let isPlaying: Bool
    let reducesMotion: Bool

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .resizable()
            .scaledToFit()
            .contentTransition(reducesMotion ? .identity : .symbolEffect(.replace))
            .animation(reducesMotion ? nil : .smooth(duration: 0.25), value: isPlaying)
    }
}
