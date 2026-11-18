// Ported from youshen2/MeloX (GPL-3.0), commit 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import Foundation

/// Typography values resolved for MeloX's SwiftUI/CoreText lyric renderer.
///
/// The Music 26.6 UIKit specification stores a 48-point source font, but its
/// surrounding text-container geometry is not equivalent to assigning 48
/// points directly to `SynchronizedLyricText`. The rendered baseline therefore
/// stays close to `.largeTitle` instead of exposing that source value verbatim.
nonisolated struct AppleMusicLyricsTypographyProfile: Equatable, Sendable {
    let primaryFontSize: Double
    /// Translation size measured from the Music lyrics recording: the Chinese
    /// line's advance matches a 20 pt system font, while the original stays
    /// on the bold primary size above.
    let translationFontSize: Double
    /// White translation over the player background, relative to the line's focus opacity.
    let translationOpacity: Double
    /// Space between the original line box and the translation line box.
    let translationTopSpacing: Double

    static let iOS26_6 = Self(
        primaryFontSize: 34,
        translationFontSize: 20,
        translationOpacity: 0.55,
        translationTopSpacing: 6
    )
}
