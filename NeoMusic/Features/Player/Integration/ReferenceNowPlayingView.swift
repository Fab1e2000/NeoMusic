import SwiftUI
import FrontAMPlayer
import FrontAMPopup

@MainActor private final class ArtworkPrepareRelay {
    var action = ArtworkLoadAction()
}

struct PlayerNowPlayingHostView: View {
    @Environment(PlayerState.self) private var player
    @Environment(PlayerActions.self) private var actions
    @Environment(PlayerLyricsController.self) private var library
    @Environment(\.artworkLoadAction) private var loadArtwork
    var initialPage: NowPlayingPage = .artwork
    var onDismiss: (() -> Void)? = nil
    var isActive = true
    @State private var prepareRelay = ArtworkPrepareRelay()
    @State private var cachedServices: PlayerServices?

    private var resolvedServices: PlayerServices {
        prepareRelay.action = loadArtwork
        if let cachedServices,
           cachedServices.actions === actions,
           cachedServices.lyrics === library.source {
            return cachedServices
        }
        return NeoMusicPlayerServices.make(
            actions: actions,
            library: library,
            prepareArtwork: { [prepareRelay] id in prepareRelay.action(id) },
            prepareQueueArtwork: { [prepareRelay] id, foreground in
                if let handler = prepareRelay.action.queueHandler { return handler(id, foreground) }
                if foreground { prepareRelay.action(id) }
                return nil
            }
        )
    }

    var body: some View {
        let services = resolvedServices
        FullScreenPlayerView(player: player,
            services: services,
            initialPage: initialPage, isActive: isActive, onDismiss: onDismiss,
            artworkTransition: FrontAMPopupArtworkTransition())
            .onAppear {
                if cachedServices !== services { cachedServices = services }
            }
            .onChange(of: ObjectIdentifier(actions)) { _, _ in
                cachedServices = resolvedServices
            }
            .onChange(of: ObjectIdentifier(library)) { _, _ in
                cachedServices = resolvedServices
            }
    }
}

typealias ReferenceNowPlayingView = PlayerNowPlayingHostView
