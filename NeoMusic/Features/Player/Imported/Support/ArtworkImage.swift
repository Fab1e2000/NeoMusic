// Source: NeoDizzy Core/UI/ArtworkImage.swift; see Resources/PlayerSourceNotices.txt.
// 移植自 MeloX（GPLv3）Shared/Media/ArtworkImage.swift：占位改用 DizzyPalette。

import Nuke
import NukeUI
import SwiftUI

/// 封面图。按显示尺寸解码缩略图，滚出屏幕时降低加载优先级。
struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var aspectRatio: CGFloat = 1
    var decodeSize: CGSize? = nil
    var contentMode: ContentMode = .fill

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            LazyImage(
                request: imageRequest(for: proxy.size),
                transaction: Transaction(animation: imageLoadAnimation)
            ) { state in
                content(image: state.image, hasError: state.error != nil)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onDisappear(.lowerPriority)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private func imageRequest(for size: CGSize) -> ImageRequest? {
        ArtworkImagePipeline.request(
            for: url, size: size, displayScale: displayScale, decodeSize: decodeSize,
            contentMode: contentMode == .fit ? .aspectFit : .aspectFill
        )
    }

    private var imageLoadAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    @ViewBuilder
    private func content(image: Image?, hasError: Bool) -> some View {
        if let image {
            image
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .transition(.opacity)
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
