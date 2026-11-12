// Player presentation for the MeloX-derived components (GPL-3.0).
import SwiftUI

/// SwiftUI owns interpolation, retargeting and completion for the resident pages.
struct NowPlayingPagePresentation: ViewModifier {
    let isVisible: Bool
    let presentationScale: CGFloat
    let hiddenOffset: CGFloat
    let spatialAnimation: Animation?
    let opacityAnimation: Animation?

    func body(content: Content) -> some View {
        content
            .animation(spatialAnimation) {
                $0.scaleEffect(isVisible ? 1 : presentationScale)
                    .offset(y: isVisible ? 0 : hiddenOffset)
            }
            .animation(opacityAnimation) { $0.opacity(isVisible ? 1 : 0) }
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
