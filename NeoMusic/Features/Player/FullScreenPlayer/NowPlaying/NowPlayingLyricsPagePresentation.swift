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
    // Keep page transitions clipped above the bottom controls without cutting settled interface fades.
    var clipsAboveControls = true

    func body(content: Content) -> some View {
        let presented = content
            .animation(spatialAnimation) {
                $0.scaleEffect(isVisible ? 1 : presentationScale)
                    .offset(y: isVisible ? 0 : hiddenOffset * layout.verticalScale)
            }
            .animation(opacityAnimation) { $0.opacity(isVisible ? 1 : 0) }
        // Rectangular scissor clip instead of .mask avoids a full-screen offscreen alpha pass every frame.
        GeometryReader { proxy in
            Color.clear
                .frame(
                    width: proxy.size.width,
                    height: clipsAboveControls ? min(proxy.size.height, max(0, layout.pageY(557))) : proxy.size.height
                )
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
                .overlay(alignment: .top) {
                    presented
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .clipped()
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
