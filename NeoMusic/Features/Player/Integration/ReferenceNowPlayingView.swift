import SwiftUI
import FullScreenPlayer

/// NeoMusic's composition boundary; all reusable presentation lives in FullScreenPlayer.
struct ReferenceNowPlayingView: View {
    @Environment(PlayerState.self) private var player
    @Environment(PlayerActions.self) private var actions
    @Environment(ReferenceLibrary.self) private var library
    @Environment(\.artworkLoadAction) private var loadArtwork
    var initialPage: NowPlayingPage = .artwork
    var onDismiss: (() -> Void)? = nil
    var isActive = true

    var body: some View {
        FullScreenPlayerView(player: player,
            services: NeoMusicPlayerServices.make(actions: actions, library: library,
                                                  prepareArtwork: { loadArtwork($0) }),
            initialPage: initialPage, isActive: isActive, onDismiss: onDismiss,
            artworkTransition: NeoMusicArtworkTransition())
    }
}
