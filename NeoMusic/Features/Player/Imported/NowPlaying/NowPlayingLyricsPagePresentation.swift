// Player presentation for the MeloX-derived components (GPL-3.0).
import SwiftUI

/// SwiftUI owns interpolation, retargeting and completion for the resident pages.
struct NowPlayingPagePresentation: ViewModifier {
    @Environment(\.nowPlayingLayout) private var layout
    let isVisible: Bool
    let presentationScale: CGFloat
    let hiddenOffset: CGFloat
    let spatialAnimation: Animation?
    let opacityAnimation: Animation?
    // Lyrics keep their full viewport when the playback controls are hidden.
    var clipsAboveControls = true

    func body(content: Content) -> some View {
        content
            .animation(spatialAnimation) {
                $0.scaleEffect(isVisible ? 1 : presentationScale)
                    .offset(y: isVisible ? 0 : hiddenOffset * layout.verticalScale)
            }
            .animation(opacityAnimation) { $0.opacity(isVisible ? 1 : 0) }
            .mask(alignment: .top) {
                Rectangle()
                    .frame(height: clipsAboveControls ? max(0, layout.pageY(557)) : nil)
            }
    }
}

/// Source identity keeps outgoing visuals active and rejects older completions.
struct NowPlayingPageChange {
    let id = UUID()
    let source: NowPlayingPage
    let destination: NowPlayingPage
    let entersFromHiddenQueue: Bool
    let startsFromRest: Bool
}
