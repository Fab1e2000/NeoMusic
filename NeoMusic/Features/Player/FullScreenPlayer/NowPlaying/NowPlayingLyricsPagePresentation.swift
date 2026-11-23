// Player presentation for the MeloX-derived components (GPL-3.0).
import SwiftUI

struct NowPlayingPagePresentation: ViewModifier {
    @Environment(\.nowPlayingLayout) private var layout
    let isVisible: Bool
    let page: NowPlayingPage
    var selectedPage: NowPlayingPage? = nil
    var change: NowPlayingPageChange? = nil
    var animates = true
    var clipsAboveControls = true

    func body(content: Content) -> some View {
        let selection = selectedPage ?? (isVisible ? page : .artwork)
        let direct = change.map {
            NowPlayingPageTransition.isDirectLyricsQueueTransition(from: $0.source, to: $0.destination)
        } ?? false
        let hiddenScale: CGFloat = selection == .artwork && change == nil ? 0.95 : 0.9
        let spatialAnimation: Animation? = if !animates {
            nil
        } else if direct {
            isVisible
                ? .interpolatingSpring(mass: 1, stiffness: 447, damping: 42.13).delay(0.069)
                : .timingCurve(0.35, 0, 0.18, 1, duration: 0.31)
        } else {
            selection == .artwork
                ? NowPlayingPageTransition.animation
                : NowPlayingPageTransition.motion.artworkCollapse.animation
        }
        let opacityAnimation: Animation? = if !animates {
            nil
        } else if isVisible {
            direct ? .easeInOut(duration: 0.205).delay(0.055)
                : (page == .queue ? .easeInOut(duration: 0.301).delay(0.105)
                                  : .easeInOut(duration: 0.246).delay(0.167))
        } else {
            direct ? .easeInOut(duration: 0.18)
                : (page == .queue ? .easeInOut(duration: 0.17)
                                  : .easeOut(duration: 0.22))
        }
        GeometryReader { proxy in
            let topExtension = page == .queue ? NowPlayingSongHeader.lift : 0
            let anchor = UnitPoint(x: 0.5, y: (layout.pageY(319.3) + topExtension) / proxy.size.height)
            Color.clear
                .frame(width: proxy.size.width,
                       height: clipsAboveControls ? min(proxy.size.height, max(0, layout.pageY(557) + topExtension)) : proxy.size.height)
                .overlay(alignment: .top) {
                    content
                        .scaleEffect(isVisible ? 1 : hiddenScale, anchor: anchor)
                        .offset(y: selection == .artwork ? 470 * layout.verticalScale : 0)
                        .animation(spatialAnimation, value: selection)
                        .opacity(isVisible ? 1 : 0)
                        .animation(opacityAnimation, value: isVisible)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .clipped()
        }
        .transaction { $0.animation = nil }
    }
}

struct NowPlayingPageChange {
    let id = UUID()
    let source: NowPlayingPage
    let destination: NowPlayingPage
    // No visible queue artwork to match: render the other page's cover at its own endpoint.
    let stationaryArtworkPage: NowPlayingPage?
    let startsFromRest: Bool

    static let stationaryFade = Animation.easeInOut(duration: 0.18)
}
