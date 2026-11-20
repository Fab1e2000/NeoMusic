import SwiftUI

/// 跨模块共享的轻量级视觉常量，仅收口已在多个页面消费的基础数值，避免魔法数字漂移。
enum DesignTokens {
    enum Colors {
        /// Apple Music “喜爱歌曲”星标的实测红色。
        static let favoritesRed = Color(red: 251 / 255, green: 35 / 255, blue: 60 / 255)
        static let favoritesBackground = Color(red: 233 / 255, green: 237 / 255, blue: 238 / 255)
    }

    enum Spacing {
        static let pageMargin: CGFloat = 20
        static let rowDividerInset: CGFloat = 60
    }

    enum Radius {
        static let songRowCover: CGFloat = 6
        static let card: CGFloat = 8
        static let detailCover: CGFloat = 10
        static let heroCard: CGFloat = 16
    }

    enum Artwork {
        static let rowCoverSize: CGFloat = 48
        static let hairlineStrokeOpacity: Double = 0.06
    }

    enum Typography {
        static let sectionHeadingSize: CGFloat = 20
    }
}
