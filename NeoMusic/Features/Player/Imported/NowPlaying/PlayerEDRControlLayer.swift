import SwiftUI

/// Draws a non-interactive EDR layer over the original control's hit target.
struct PlayerEDRControlLayer: View {
    let shape: PlayerEDRMask
    var role: PlayerEDRRole = .controls
    @Environment(\.playerArtistEDREnabled) private var enabled
    @Environment(\.playerEDRLevels) private var levels
    @Environment(\.nowPlayingBackdropImage) private var backdrop
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmed
    @Environment(\.nowPlayingBackdropAnchor) private var anchor

    var body: some View {
        if enabled, let image = undimmed ?? backdrop, let anchor {
            PlayerEDRMaskView(shape: shape, image: image, anchor: anchor, brightness: levels.value(for: role))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct PlayerEDRControlAvailable: ViewModifier {
    @Environment(\.playerArtistEDREnabled) private var enabled
    @Environment(\.nowPlayingBackdropImage) private var backdrop
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmed
    @Environment(\.nowPlayingBackdropAnchor) private var anchor
    let shape: PlayerEDRMask
    var role: PlayerEDRRole = .controls
    var isEnabled = true

    func body(content: Content) -> some View {
        let active = isEnabled && enabled && (undimmed ?? backdrop) != nil && anchor != nil
        content
            .opacity(active ? 0.02 : 1)
            .overlay { if active { PlayerEDRControlLayer(shape: shape, role: role) } }
    }
}

private struct PlayerEDRMaskView: UIViewRepresentable {
    @Environment(\.playerVisualsActive) private var visualsActive
    let shape: PlayerEDRMask
    let image: UIImage
    let anchor: NowPlayingBackdropAnchor
    let brightness: Double
    func makeUIView(context: Context) -> PlayerEDRGlyphView { PlayerEDRGlyphView() }
    func updateUIView(_ view: PlayerEDRGlyphView, context: Context) {
        view.setRenderingActive(visualsActive)
        view.update(shape: shape, image: image, anchor: anchor, brightness: brightness)
    }
    static func dismantleUIView(_ view: PlayerEDRGlyphView, coordinator: ()) { view.stop() }
}
