import FrontAMCore
import SwiftUI

public enum HomeArtworkSource: Sendable {
    case image(String)
    case favorites
}

public struct HomeArtwork: View {
    public let artwork: HomeArtworkSource

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch artwork {
            case .image(let name):
                Image(name).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            case .favorites:
                DesignTokens.Colors.homeFavoritesBackdrop
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.homeFavoritesTile)
                            .fill(DesignTokens.Colors.homeFavoritesTile)
                            .overlay {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 116, weight: .regular))
                                    .foregroundStyle(DesignTokens.Colors.favoritesRed)
                            }
                            .frame(width: size.width - 2 * DesignTokens.Spacing.heroCardInset,
                                   height: size.width - 2 * DesignTokens.Spacing.heroCardInset)
                            .padding(.top, DesignTokens.Spacing.heroCardInset)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    public init(artwork: HomeArtworkSource) {
        self.artwork = artwork
    }
}
