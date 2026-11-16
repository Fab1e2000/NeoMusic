// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

enum NowPlayingPageTransition {
    static let motion = NowPlayingMotionSpec.appleMusic26.page

    static var animation: Animation { motion.selection.animation }

    static func selectionAnimation(from source: NowPlayingPage, to destination: NowPlayingPage) -> Animation {
        if isDirectLyricsQueueTransition(from: source, to: destination) {
            return motion.directAlternate.animation
        }
        return source == .artwork ? motion.artworkCollapse.animation : animation
    }

    static func isDirectLyricsQueueTransition(from source: NowPlayingPage, to destination: NowPlayingPage) -> Bool {
        source == .lyrics && destination == .queue || source == .queue && destination == .lyrics
    }
}
