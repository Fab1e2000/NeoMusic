// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI
import UIKit

struct NowPlayingSongActions: View {
    let track: PlayerTrack
    var onImportLyrics: (() -> Void)? = nil
    var body: some View {
        SongMenuHost(track: track, extras: extras) { configuration in
            HStack(spacing: 4.25) {
                FavoriteButton(track: track, playerStyle: true)
                NowPlayingMenuButton(track: track) { configuration.nativeItems }.frame(width: 44, height: 44)
            }
        }
    }
    private var extras: [SongRowAction] {
        guard let onImportLyrics else { return [] }
        return [.init(id: "lyrics", title: "导入本地歌词", systemImage: "square.and.arrow.down", perform: onImportLyrics)]
    }
}

struct NowPlayingMenuButton: UIViewRepresentable {
    var track: PlayerTrack? = nil
    var iconColor: UIColor = NowPlayingVisualHierarchy.primaryUIColor
    @Environment(PlayerActions.self) private var actions
    var items: () -> [UIMenuElement]

    final class Coordinator {
        var items: () -> [UIMenuElement]
        let artists = PlayerArtistMenuController()
        init(items: @escaping () -> [UIMenuElement]) { self.items = items }
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal
        )
        button.tintColor = iconColor
        button.backgroundColor = .clear
        button.layer.cornerRadius = 22
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "更多")
        context.coordinator.artists.bind(track: track, actions: actions)
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak coordinator = context.coordinator] completion in
            guard let coordinator else { completion([]); return }
            completion(coordinator.items())
        }])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.tintColor = iconColor
        context.coordinator.items = items
        if context.coordinator.artists.bind(track: track, actions: actions) {
            button.contextMenuInteraction?.dismissMenu()
        }
    }

    static func dismantleUIView(_ uiView: UIButton, coordinator: Coordinator) {
        coordinator.artists.cancel()
    }
}
