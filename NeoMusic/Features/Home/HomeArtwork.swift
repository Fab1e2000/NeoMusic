import SwiftUI

enum HomeArtworkSource: Sendable {
    case image(String)
    case favorites
}

struct HomeArtwork: View {
    let artwork: HomeArtworkSource

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch artwork {
            case .image(let name):
                Image(name).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            case .favorites:
                Color(white: 0.575)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(white: 0.92))
                            .overlay {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 116, weight: .regular))
                                    .foregroundStyle(DesignTokens.Colors.favoritesRed)
                            }
                            .frame(width: size.width - 32, height: size.width - 32)
                            .padding(.top, 16)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
