#if DEBUG
import SwiftUI
public struct PlayerControlsPreview: View {
    let player: PlayerState
    let song: PlayerTrack
    let actions: PlayerActions
    public init(player: PlayerState, song: PlayerTrack, actions: PlayerActions) {
        self.player = player; self.song = song; self.actions = actions
    }
    public var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            VStack(spacing: 48) {
                NowPlayingProgressControl(song: song)
                    .padding(.horizontal, 32)
                NowPlayingVolumeControl()
            }
        }
        .environment(player)
        .environment(actions)
        .preferredColorScheme(.dark)
    }
}

#endif
