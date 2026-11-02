import SwiftUI

/// Moves with the popup content. A dismissal changes its screen position, not
/// the relative positions used by artwork, backdrop copies and lyric focus.
nonisolated enum NowPlayingContentCoordinateSpace {
    static let name = "NowPlayingContent"
}

@Observable
final class NowPlayingGeometry {
    var contentSize: CGSize = .zero
    var backdropFrame: CGRect = .zero

    var contentFrame: CGRect { CGRect(origin: .zero, size: contentSize) }
}

/// User-adjusted portrait layout, exported 2026-10-24 at 20:45.
/// Reference: 402 × 874 pt, with a 62 pt top and 34 pt bottom safe area.
/// Convert screen coordinates into the actual safe content area, rather than
/// applying screenshot offsets on top of the device's safe-area insets.
struct ReferenceNowPlayingLayout {
    var contentSize = CGSize(width: 402, height: 778)
    var horizontalScale: CGFloat { contentSize.width / 402 }
    var verticalScale: CGFloat { contentSize.height / 778 }

    func width(_ value: CGFloat) -> CGFloat { value * horizontalScale }
    func contentY(_ screenY: CGFloat) -> CGFloat { (screenY - 62) * verticalScale }
    func pageY(_ screenY: CGFloat) -> CGFloat { contentY(screenY) - 22 }
    func controlsY(_ screenY: CGFloat) -> CGFloat {
        contentY(screenY) - (contentSize.height - 3 - NowPlayingBottomControls.overlayHeight)
    }
    // Page and control containers already have 32 pt horizontal padding.
    func x(_ screenX: CGFloat) -> CGFloat { width(screenX) - 32 }
}

private struct NowPlayingLayoutKey: EnvironmentKey {
    static let defaultValue = ReferenceNowPlayingLayout()
}

extension EnvironmentValues {
    var nowPlayingLayout: ReferenceNowPlayingLayout {
        get { self[NowPlayingLayoutKey.self] }
        set { self[NowPlayingLayoutKey.self] = newValue }
    }
}
