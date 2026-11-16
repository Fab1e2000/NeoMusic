#if DEBUG
import SwiftUI

public struct PlayerPagePreview: View {
    @Environment(\.dismiss) private var dismiss
    private let player: PlayerState
    private let services: PlayerServices

    public init(player: PlayerState, services: PlayerServices) {
        self.player = player
        self.services = services
    }

    public var body: some View {
        NowPlayingContent(artworkTransition: EmptyModifier(), onDismiss: { dismiss() })
            .environment(player)
            .environment(services.lyrics)
            .environment(services.actions)
            .environment(services)
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
    }
}
#endif
