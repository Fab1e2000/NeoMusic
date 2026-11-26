// Ported from youshen2/MeloX (GPL-3.0), commit 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import Foundation

nonisolated struct AppleMusicLyricsTypographyProfile: Equatable, Sendable {
    let primaryFontSize: Double
    let translationFontSize: Double
    let translationOpacity: Double
    let translationTopSpacing: Double

    static let iOS26_6 = Self(
        primaryFontSize: 34,
        translationFontSize: 20,
        translationOpacity: 0.55,
        translationTopSpacing: 6
    )
}
