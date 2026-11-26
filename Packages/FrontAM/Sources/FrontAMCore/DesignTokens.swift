import SwiftUI

public enum DesignTokens {
    public enum Colors {
        public static let favoritesRed = Color(red: 251 / 255, green: 35 / 255, blue: 60 / 255)
        public static let favoritesBackground = Color(red: 233 / 255, green: 237 / 255, blue: 238 / 255)
        public static let homeFavoritesBackdrop = Color(white: 0.575)
        public static let homeFavoritesTile = Color(white: 0.92)
    }

    public enum Spacing {
        public static let pageMargin: CGFloat = 20
        public static let rowDividerInset: CGFloat = 60
        public static let heroCardInset: CGFloat = 16
    }

    public enum Radius {
        public static let songRowCover: CGFloat = 6
        public static let card: CGFloat = 8
        public static let detailCover: CGFloat = 10
        public static let heroCard: CGFloat = 16
        public static let homeFavoritesTile: CGFloat = 7
    }

    public enum Artwork {
        public static let rowCoverSize: CGFloat = 48
        public static let hairlineStrokeOpacity: Double = 0.06
    }

    public enum Typography {
        public static let sectionHeadingSize: CGFloat = 20
    }
}
