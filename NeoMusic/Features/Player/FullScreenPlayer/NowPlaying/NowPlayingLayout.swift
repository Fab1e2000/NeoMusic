import SwiftUI

nonisolated enum NowPlayingContentCoordinateSpace {
    static let name = "NowPlayingContent"
}

@Observable
final class NowPlayingGeometry {
    var backdropFrame: CGRect = .zero
}

struct ReferenceNowPlayingLayout {
    var contentSize = CGSize(width: 402, height: 778)
    var horizontalScale: CGFloat { contentSize.width / 402 }
    var verticalScale: CGFloat { contentSize.height / 778 }
    var artworkSide: CGFloat { min(width(338), max(170, contentY(490) - contentY(112) - 22)) }

    func width(_ value: CGFloat) -> CGFloat { value * horizontalScale }
    func contentY(_ screenY: CGFloat) -> CGFloat { (screenY - 62) * verticalScale }
    func pageY(_ screenY: CGFloat) -> CGFloat { contentY(screenY) - 22 }
    func controlsY(_ screenY: CGFloat) -> CGFloat {
        contentY(screenY) - (contentSize.height - 3 - NowPlayingBottomControls.overlayHeight)
    }
    func x(_ screenX: CGFloat) -> CGFloat { width(screenX) - 32 }
}

enum NowPlayingDismissalHandleLayout {
    static let height: CGFloat = 22
    static let capsuleHeight: CGFloat = 3.8

    static func capsuleTop(in layout: ReferenceNowPlayingLayout) -> CGFloat { layout.contentY(69) }
}

private struct NowPlayingLayoutKey: EnvironmentKey {
    static let defaultValue = ReferenceNowPlayingLayout()
}

extension EnvironmentValues {
    @Entry var playerVisualsActive = true
    @Entry public var playerVolumeHUDRefreshID = 0
    @Entry public var playerArtworkTransitionTargetVisible = true
    @Entry var nowPlayingControlsOverflow: CGFloat = 0

    var nowPlayingLayout: ReferenceNowPlayingLayout {
        get { self[NowPlayingLayoutKey.self] }
        set { self[NowPlayingLayoutKey.self] = newValue }
    }
}
