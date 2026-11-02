import SwiftUI

/// 专辑、播放列表或歌曲的封面。
enum Artwork {
    /// Apple Music“喜爱歌曲”星标的实测颜色。
    static let favoritesRed = Color(red: 251 / 255, green: 35 / 255, blue: 60 / 255)
    static let favoritesBackground = Color(red: 233 / 255, green: 237 / 255, blue: 238 / 255)

    case image(Image)
    /// “喜爱歌曲”固定使用浅灰底上的红色星标。
    case favorites
    /// 没有封面的播放列表。
    case playlist
    /// 播放列表文件夹。
    indirect case folder([Artwork])
    /// 没有封面的歌曲或专辑。
    case missing
}

/// 方形封面，按宽度铺满并裁切圆角。
struct ArtworkView: View {
    let artwork: Artwork
    var cornerRadius: CGFloat = 8
    var isZoomAlignmentTarget = false
    @Environment(\.displayScale) private var displayScale

    @Environment(\.nativeArtworkSurfaceEnabled) private var nativeSurface

    var body: some View {
        if nativeSurface {
            LibraryArtworkSurface(content: drawing, cornerRadius: cornerRadius,
                                  isZoomAlignmentTarget: isZoomAlignmentTarget)
                .aspectRatio(1, contentMode: .fit)
        }
        else { drawing }
    }

    private var drawing: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 1 / displayScale)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch artwork {
        case .image(let image):
            image.resizable().scaledToFill()
        case .favorites:
            GeometryReader { proxy in
                Artwork.favoritesBackground
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: proxy.size.width * 0.50))
                            .foregroundStyle(Artwork.favoritesRed)
                    }
            }
        case .playlist:
            placeholder(systemImage: "music.note.list", symbolScale: 0.38)
        case .folder(let artworks) where artworks.isEmpty:
            // 空文件夹显示文件夹符号，与 Apple Music 一致。
            placeholder(systemImage: "folder", symbolScale: 0.44)
        case .folder(let artworks):
            GeometryReader { proxy in
                Color(.tertiarySystemFill)
                    .overlay(alignment: .topLeading) {
                        // 文件夹封面是内容的 2×2 缩略图；空文件夹保留空底。
                        Grid(horizontalSpacing: proxy.size.width * 0.06, verticalSpacing: proxy.size.width * 0.06) {
                            GridRow {
                                folderThumbnail(artworks, at: 0, width: proxy.size.width)
                                folderThumbnail(artworks, at: 1, width: proxy.size.width)
                            }
                            GridRow {
                                folderThumbnail(artworks, at: 2, width: proxy.size.width)
                                folderThumbnail(artworks, at: 3, width: proxy.size.width)
                            }
                        }
                        .padding(proxy.size.width * 0.10)
                    }
            }
        case .missing:
            placeholder(systemImage: "music.note")
        }
    }

    private func placeholder(systemImage: String, symbolScale: CGFloat = 0.3) -> some View {
        GeometryReader { proxy in
            Color(.secondarySystemFill)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: proxy.size.width * symbolScale))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func folderThumbnail(_ artworks: [Artwork], at index: Int, width: CGFloat) -> some View {
        Group {
            if artworks.indices.contains(index) {
                ArtworkView(artwork: artworks[index], cornerRadius: width * 0.025)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: width * 0.36)
    }
}
