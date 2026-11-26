import SwiftUI

public struct FullScreenPlayerView<ArtworkTransition: ViewModifier>: View {
    private let player: PlayerState
    private let services: PlayerServices
    private let initialPage: NowPlayingPage
    private let isActive: Bool
    private let onDismiss: (() -> Void)?
    private let artworkTransition: ArtworkTransition

    public init(player: PlayerState, services: PlayerServices, initialPage: NowPlayingPage = .artwork,
                isActive: Bool = true, onDismiss: (() -> Void)? = nil, artworkTransition: ArtworkTransition) {
        self.player = player; self.services = services; self.initialPage = initialPage
        self.isActive = isActive; self.onDismiss = onDismiss; self.artworkTransition = artworkTransition
    }

    public var body: some View {
        NowPlayingContent(artworkTransition: artworkTransition, initialPage: initialPage,
                          onDismiss: onDismiss, isActive: isActive)
            .environment(player)
            .environment(services)
            .environment(services.actions)
            .environment(services.lyrics)
    }
}

extension FullScreenPlayerView where ArtworkTransition == EmptyModifier {
    public init(player: PlayerState, services: PlayerServices, initialPage: NowPlayingPage = .artwork,
                isActive: Bool = true, onDismiss: (() -> Void)? = nil) {
        self.init(player: player, services: services, initialPage: initialPage, isActive: isActive,
                  onDismiss: onDismiss, artworkTransition: EmptyModifier())
    }
}
