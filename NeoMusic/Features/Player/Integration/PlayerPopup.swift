import FrontAMPopup
import SwiftUI

struct PlayerPopup: ViewModifier {
    @Binding var isPresented: Bool
    let isSuppressed: Bool
    let onClose: () -> Void
    var barColorScheme: ColorScheme? = nil
    var toasts: LibraryToastCenter? = nil
    @Environment(\.artworkLoadAction) private var loadArtwork

    func body(content: Content) -> some View {
        content
            .environment(\.songPlaybackIndicatorsActive, !isPresented)
            .modifier(FrontAMPlayerPopup(
                isPresented: $isPresented,
                isSuppressed: isSuppressed,
                artwork: NeoMusicPlayerServices.artwork(usesTargetBounds: true, prepare: { loadArtwork($0) }),
                barColorScheme: barColorScheme,
                onClose: onClose,
                onContentActivityChange: { active, track in
                    AppLogger.ui.notice("popup.content active=\(active) titleEmpty=\(track.title.isEmpty) cover=\(track.coverURL != nil)")
                }
            ) {
                ArtworkView(artwork: .missing, cornerRadius: 3)
                    .environment(\.nativeArtworkSurfaceEnabled, false)
            } expandedContent: { active, dismiss in
                PlayerNowPlayingHostView(onDismiss: dismiss, isActive: active)
                    .modifier(OptionalPlayerToastModifier(toasts: active ? toasts : nil))
            })
    }
}

private struct OptionalPlayerToastModifier: ViewModifier {
    let toasts: LibraryToastCenter?
    func body(content: Content) -> some View {
        content.overlay {
            if let toasts {
                Color.clear.libraryToasts(toasts)
            }
        }
    }
}
