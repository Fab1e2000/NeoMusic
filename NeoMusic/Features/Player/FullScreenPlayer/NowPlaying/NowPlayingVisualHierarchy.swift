import SwiftUI
import UIKit

/// Apple Music 全屏播放器亮度层级（标准白主角 + `.plusLighter` 配角透明叠加）。
enum NowPlayingVisualHierarchy {
    static var primaryColor: Color { .white }

    static var primaryUIColor: UIColor { .white }

    // 以下配角透明系数按 `.blendMode(.plusLighter)` 逐 pixel 测量 Apple Music 截图反推。
    static let grabberOpacity: Double = 0.28
    static let subtitleOpacity: Double = 0.48
    static let audioQualityTextOpacity: Double = 0.40
    static let audioQualityBackgroundOpacity: Double = 0.08
    static let timeLabelOpacity: Double = 0.28
    static let timeLabelActiveOpacity: Double = 0.85
    static let trackUnfilledOpacity: Double = 0.18
    static let progressFilledOpacity: Double = 0.48
    static let progressFilledActiveOpacity: Double = 0.88
    static let volumeFilledOpacity: Double = 0.55
    static let volumeFilledActiveOpacity: Double = 0.90
    static let volumeIconOpacity: Double = 0.48
    static let volumeIconActiveOpacity: Double = 0.90
    static let bottomButtonUnselectedOpacity: Double = 0.48
    static let bottomButtonSelectedFillOpacity: Double = 0.50
    static let repeatBadgeOpacity: Double = 0.14
    static let airPlayOpacity: Double = 0.55
    static let lyricBrowsingOpacity: Double = 0.48
    static let lyricInactiveBlurredOpacity: Double = 0.34
    static let queueReorderTintAlpha: CGFloat = 0.45
}

extension View {
    func nowPlayingPrimary() -> some View {
        foregroundStyle(NowPlayingVisualHierarchy.primaryColor)
    }

    func nowPlayingPlusLighter(_ opacity: Double) -> some View {
        self
            .foregroundStyle(.white.opacity(opacity))
            .blendMode(.plusLighter)
    }
}
