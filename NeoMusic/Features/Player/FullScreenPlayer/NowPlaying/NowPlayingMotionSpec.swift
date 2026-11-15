// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

public enum NowPlayingPage: String, Hashable, Sendable {
    case artwork
    case lyrics
    case queue
}

struct NowPlayingAnimationSpec: Equatable, Sendable {
    enum Curve: Equatable, Sendable {
        case smooth
        case easeInOut
        case spring(bounce: Double)
        case cubicBezier(
            x1: Double,
            y1: Double,
            x2: Double,
            y2: Double
        )
        case interpolatingSpring(
            mass: Double,
            stiffness: Double,
            damping: Double,
            initialVelocity: Double
        )
    }

    let curve: Curve
    /// Duration for timed curves; physical springs use their own parameters.
    let duration: TimeInterval
    let delay: TimeInterval

    init(
        _ curve: Curve,
        duration: TimeInterval,
        delay: TimeInterval = 0
    ) {
        self.curve = curve
        self.duration = duration
        self.delay = delay
    }

    var animation: Animation {
        let baseAnimation: Animation = switch curve {
        case .smooth:
            .smooth(duration: duration)
        case .easeInOut:
            .easeInOut(duration: duration)
        case let .spring(bounce):
            .spring(duration: duration, bounce: bounce)
        case let .cubicBezier(x1, y1, x2, y2):
            .timingCurve(
                x1,
                y1,
                x2,
                y2,
                duration: duration
            )
        case let .interpolatingSpring(
            mass,
            stiffness,
            damping,
            initialVelocity
        ):
            .interpolatingSpring(
                Spring(mass: mass, stiffness: stiffness, damping: damping, allowOverDamping: true),
                initialVelocity: initialVelocity
            )
        }
        return delay > 0
            ? baseAnimation.delay(delay)
            : baseAnimation
    }

}

enum NowPlayingInterfaceLayer: Hashable, Sendable {
    case progress
    case transport
    case volume
    case pageSelector
}

struct NowPlayingMotionSpec: Equatable, Sendable {
    private static let pageSpringSettlementDuration = Spring(
        mass: 1,
        stiffness: 350,
        damping: 40,
        allowOverDamping: true
    ).settlingDuration(
        target: 1,
        initialVelocity: 0,
        epsilon: 0.001
    )

    struct PageMotion: Equatable, Sendable {
        let selection: NowPlayingAnimationSpec
        let artworkCollapse: NowPlayingAnimationSpec
        let directAlternate: NowPlayingAnimationSpec
        let outgoing: NowPlayingAnimationSpec
        let incoming: NowPlayingAnimationSpec
        let delayedResidentEntrance: NowPlayingAnimationSpec
        let lyricsSpatialPresentation: NowPlayingAnimationSpec
        let lyricsOpacityPresentation: NowPlayingAnimationSpec
        let lyricsSpatialDismissal: NowPlayingAnimationSpec
        let lyricsOpacityDismissal: NowPlayingAnimationSpec
        let queueSpatialPresentation: NowPlayingAnimationSpec
        let queueOpacityPresentation: NowPlayingAnimationSpec
        let queueSpatialDismissal: NowPlayingAnimationSpec
        let queueOpacityDismissal: NowPlayingAnimationSpec
        let artworkResize: NowPlayingAnimationSpec

        let directAlternateContentScale: CGFloat
        let lyricsPresentationScale: CGFloat
        let queuePresentationScale: CGFloat
        let lyricsTravel: CGFloat
        let queueTravel: CGFloat
        let artworkDetailsTravel: CGFloat
        let songHeaderTravel: CGFloat
        let lyricsPresentationDelay: TimeInterval

    }

    struct InterfaceMotion: Equatable, Sendable {
        struct LayerMotion: Equatable, Sendable {
            let hiddenOffset: CGFloat
            let showDelay: TimeInterval
            let hideDelay: TimeInterval
        }

        let coreShow: NowPlayingAnimationSpec
        let coreHide: NowPlayingAnimationSpec
        let controlShowOpacity: NowPlayingAnimationSpec
        let controlHideOpacity: NowPlayingAnimationSpec
        let utilityShow: NowPlayingAnimationSpec
        let utilityHide: NowPlayingAnimationSpec
        let controlDuration: TimeInterval
        let utilityHiddenOffset: CGFloat
        let utilityHiddenScale: CGFloat
        let progress: LayerMotion
        let transport: LayerMotion
        let volume: LayerMotion
        let pageSelector: LayerMotion

        func layerMotion(
            for layer: NowPlayingInterfaceLayer
        ) -> LayerMotion {
            switch layer {
            case .progress:
                progress
            case .transport:
                transport
            case .volume:
                volume
            case .pageSelector:
                pageSelector
            }
        }

        func controlAnimation(
            for layer: NowPlayingInterfaceLayer,
            isVisible: Bool
        ) -> NowPlayingAnimationSpec {
            let layerMotion = layerMotion(for: layer)
            return NowPlayingAnimationSpec(
                .smooth,
                duration: controlDuration,
                delay:
                    isVisible
                        ? layerMotion.showDelay
                        : layerMotion.hideDelay
            )
        }

        func controlOpacityAnimation(
            isVisible: Bool
        ) -> NowPlayingAnimationSpec {
            isVisible ? controlShowOpacity : controlHideOpacity
        }
    }

    let page: PageMotion
    let interface: InterfaceMotion

    static let appleMusic26 = NowPlayingMotionSpec(
        page: PageMotion(
            selection: NowPlayingAnimationSpec(
                .interpolatingSpring(mass: 1, stiffness: 475, damping: 45, initialVelocity: 0),
                duration: 0.60
            ),
            // Fit to the supplied recording's cover bounds; SwiftUI owns retargeting.
            artworkCollapse: NowPlayingAnimationSpec(
                .interpolatingSpring(mass: 1, stiffness: 800, damping: 72, initialVelocity: 0),
                duration: 0.60
            ),
            directAlternate: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.44
            ),
            outgoing: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.24
            ),
            incoming: NowPlayingAnimationSpec(
                .easeInOut,
                duration: 0.24,
                delay: 0.15
            ),
            delayedResidentEntrance: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.34,
                delay: 0.11
            ),
            // Lyrics and queue share the same resident-page motion.
            lyricsSpatialPresentation: NowPlayingAnimationSpec(
                .interpolatingSpring(
                    mass: 1,
                    stiffness: 475,
                    damping: 45,
                    initialVelocity: 0
                ),
                duration: pageSpringSettlementDuration
            ),
            lyricsOpacityPresentation: NowPlayingAnimationSpec(
                .cubicBezier(
                    x1: 0.42,
                    y1: 0,
                    x2: 0.58,
                    y2: 1
                ),
                duration: 0.30,
                delay: 0.10
            ),
            lyricsSpatialDismissal: NowPlayingAnimationSpec(
                .interpolatingSpring(
                    mass: 1,
                    stiffness: 475,
                    damping: 45,
                    initialVelocity: 0
                ),
                duration: pageSpringSettlementDuration
            ),
            lyricsOpacityDismissal: NowPlayingAnimationSpec(
                .cubicBezier(
                    x1: 0.42,
                    y1: 0,
                    x2: 0.58,
                    y2: 1
                ),
                duration: 0.30
            ),
            // The recording's queue moves below the cover while fading, keeping
            // the playback controls fixed outside the animated content.
            queueSpatialPresentation: NowPlayingAnimationSpec(
                .interpolatingSpring(
                    mass: 1,
                    stiffness: 475,
                    damping: 45,
                    initialVelocity: 0
                ),
                duration: pageSpringSettlementDuration
            ),
            queueOpacityPresentation: NowPlayingAnimationSpec(
                .cubicBezier(
                    x1: 0.42,
                    y1: 0,
                    x2: 0.58,
                    y2: 1
                ),
                duration: 0.30,
                delay: 0.10
            ),
            queueSpatialDismissal: NowPlayingAnimationSpec(
                .interpolatingSpring(
                    mass: 1,
                    stiffness: 475,
                    damping: 45,
                    initialVelocity: 0
                ),
                duration: pageSpringSettlementDuration
            ),
            queueOpacityDismissal: NowPlayingAnimationSpec(
                .cubicBezier(
                    x1: 0.42,
                    y1: 0,
                    x2: 0.58,
                    y2: 1
                ),
                duration: 0.30
            ),
            artworkResize: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.48
            ),
            directAlternateContentScale: 0.92,
            lyricsPresentationScale: 0.90,
            queuePresentationScale: 0.90,
            lyricsTravel: 470,
            queueTravel: 470,
            artworkDetailsTravel: -300,
            songHeaderTravel: 40,
            lyricsPresentationDelay: 0
        ),
        interface: InterfaceMotion(
            coreShow: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.36
            ),
            coreHide: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.36
            ),
            controlShowOpacity: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.36
            ),
            controlHideOpacity: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.18
            ),
            utilityShow: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.24,
                delay: 0.12
            ),
            utilityHide: NowPlayingAnimationSpec(
                .smooth,
                duration: 0.18
            ),
            controlDuration: 0.36,
            utilityHiddenOffset: 64,
            utilityHiddenScale: 0.82,
            progress: InterfaceMotion.LayerMotion(
                hiddenOffset: 245,
                showDelay: 0,
                hideDelay: 0
            ),
            transport: InterfaceMotion.LayerMotion(
                hiddenOffset: 220,
                showDelay: 0,
                hideDelay: 0
            ),
            volume: InterfaceMotion.LayerMotion(
                hiddenOffset: 198,
                showDelay: 0,
                hideDelay: 0
            ),
            pageSelector: InterfaceMotion.LayerMotion(
                hiddenOffset: 98,
                showDelay: 0,
                hideDelay: 0
            )
        )
    )
}
