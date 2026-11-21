// Direct source port from MeloX (GPL-3.0), b8bc60f.
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
    struct PageMotion: Equatable, Sendable {
        let selection: NowPlayingAnimationSpec
        let artworkCollapse: NowPlayingAnimationSpec
        let titleCollapse: NowPlayingAnimationSpec
        let directAlternate: NowPlayingAnimationSpec
        let artworkDetailsTravel: CGFloat
        let songHeaderTravel: CGFloat
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
                .interpolatingSpring(mass: 1, stiffness: 441, damping: 42, initialVelocity: 0),
                duration: 0.60
            ),
            artworkCollapse: NowPlayingAnimationSpec(
                .interpolatingSpring(mass: 1, stiffness: 426, damping: 40.6, initialVelocity: 0),
                duration: 0.60
            ),
            titleCollapse: NowPlayingAnimationSpec(
                .interpolatingSpring(mass: 1, stiffness: 337, damping: 36.5, initialVelocity: 0),
                duration: 0.60
            ),
            directAlternate: NowPlayingAnimationSpec(.easeInOut, duration: 0.31),
            artworkDetailsTravel: -384,
            songHeaderTravel: 384
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
