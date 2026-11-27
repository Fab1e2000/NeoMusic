// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

enum NowPlayingInterfaceTransition {
    typealias ControlLayer = NowPlayingInterfaceLayer

    private static let motion = NowPlayingMotionSpec.appleMusic26.interface

    static func interfaceAnimation(
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Animation? {
        guard !reducesMotion else { return nil }
        return isVisible
            ? motion.coreShow.animation
            : motion.coreHide.animation
    }

    static func hiddenOffset(
        for layer: ControlLayer
    ) -> CGFloat {
        motion.layerMotion(for: layer).hiddenOffset
    }

    static func controlAnimation(
        for layer: ControlLayer,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Animation? {
        guard !reducesMotion else { return nil }

        return motion.controlAnimation(
            for: layer,
            isVisible: isVisible
        ).animation
    }

    static func controlOpacityAnimation(
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Animation? {
        guard !reducesMotion else { return nil }

        return motion.controlOpacityAnimation(isVisible: isVisible).animation
    }
}
