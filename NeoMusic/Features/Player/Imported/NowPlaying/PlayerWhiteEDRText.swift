import SwiftUI

/// Retains the SwiftUI text layout while rendering a neutral EDR glyph layer.
struct PlayerWhiteEDRText: View {
    let text: String
    let fontSize: CGFloat
    var fontWeight: UIFont.Weight = .semibold
    @Environment(\.playerArtistEDREnabled) private var enabled
    @Environment(\.nowPlayingBackdropImage) private var image
    @Environment(\.nowPlayingBackdropAnchor) private var anchor

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(enabled && image != nil && anchor != nil ? Color.clear : Color.white)
            .overlay {
                if enabled, let image, let anchor {
                    PlayerEDRArtistLabel(text: text, fontSize: fontSize, image: image, anchor: anchor,
                                         brightness: 0.70, isWhite: true, fontWeight: fontWeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
