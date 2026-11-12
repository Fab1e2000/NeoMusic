// Source: NeoDizzy Core/UI/ArtworkImage.swift; see Resources/PlayerSourceNotices.txt.
// 移植自 MeloX（GPLv3）Shared/Media/ArtworkImage.swift：占位改用 DizzyPalette。

import Nuke
import NukeUI
import SwiftUI

/// 封面图。按显示尺寸解码缩略图，滚出屏幕时降低加载优先级。
struct ArtworkImage: View {
    let url: URL?
    var contentID: String? = nil
    var artworkLoadID: String? = nil
    var cornerRadius: CGFloat = 10
    var aspectRatio: CGFloat = 1
    var decodeSize: CGSize? = nil
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var displayedImage: Image?
    @State private var displayedContentID: String?

    var body: some View {
        GeometryReader { proxy in
            LazyImage(
                request: imageRequest(for: proxy.size),
                transaction: Transaction(animation: nil)
            ) { state in
                content(image: state.image ?? retainedImage, hasError: state.error != nil)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onCompletion { result in
                guard let contentID, case .success(let response) = result else { return }
                displayedImage = Image(uiImage: response.image)
                displayedContentID = contentID
            }
            .onDisappear(.lowerPriority)
            .id(contentID)
            .onChange(of: hasArtworkSource) {
                if !hasArtworkSource { displayedImage = nil; displayedContentID = nil }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private var retainedImage: Image? {
        guard hasArtworkSource, let contentID, displayedContentID == contentID else { return nil }
        return displayedImage
    }

    private var hasArtworkSource: Bool { url != nil || artworkLoadID != nil }

    private func imageRequest(for size: CGSize) -> ImageRequest? {
        ArtworkImagePipeline.request(
            for: url, size: size, displayScale: displayScale, decodeSize: decodeSize,
            contentMode: contentMode == .fit ? .aspectFit : .aspectFill
        )
    }

    @ViewBuilder
    private func content(image: Image?, hasError: Bool) -> some View {
        if let image {
            image
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else if hasError || url == nil {
            ZStack {
                DizzyPalette.artworkPlaceholder
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(DizzyPalette.artworkPlaceholderSymbol)
            }
        } else {
            DizzyPalette.artworkPlaceholder
        }
    }
}
