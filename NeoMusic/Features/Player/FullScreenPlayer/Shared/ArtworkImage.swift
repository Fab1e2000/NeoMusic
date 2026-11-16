// Source: NeoDizzy / MeloX (GPL-3.0). Image I/O is supplied by the host.
import SwiftUI

struct ArtworkImage: View {
    let url: URL?
    var contentID: String? = nil
    var artworkLoadID: String? = nil
    var cornerRadius: CGFloat = 10
    var aspectRatio: CGFloat = 1
    var decodeSize: CGSize? = nil
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    @Environment(PlayerServices.self) private var services: PlayerServices?
    @State private var displayedImage: UIImage?
    @State private var displayedContentID: String?
    @State private var failed = false

    private struct LoadID: Equatable {
        let content: String?
        let artwork: String?
        let request: PlayerArtworkRequest?
    }

    var body: some View {
        Group {
            if let fixedSize = decodeSize {
                let request = imageRequest(for: fixedSize)
                let cached = request.flatMap { services?.artwork.cached($0) }
                Color.clear
                    .overlay {
                        content(image: cached ?? retainedImage)
                    }
                    .task(id: LoadID(content: contentID, artwork: artworkLoadID, request: request)) {
                        await loadArtwork(request: request)
                    }
            } else {
                GeometryReader { proxy in
                    let request = imageRequest(for: proxy.size)
                    let cached = request.flatMap { services?.artwork.cached($0) }
                    content(image: cached ?? retainedImage)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .task(id: LoadID(content: contentID, artwork: artworkLoadID, request: request)) {
                            await loadArtwork(request: request)
                        }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private func loadArtwork(request: PlayerArtworkRequest?) async {
        failed = false
        guard let request, let provider = services?.artwork else {
            if url == nil && artworkLoadID == nil { displayedImage = nil; displayedContentID = nil }
            return
        }
        do {
            let image: UIImage
            if let cached = provider.cached(request) { image = cached }
            else { image = try await provider.load(request) }
            try Task.checkCancellation()
            displayedImage = image
            displayedContentID = contentID
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failed = true } }
    }

    private var retainedImage: UIImage? {
        guard url != nil || artworkLoadID != nil,
              let contentID, displayedContentID == contentID else { return nil }
        return displayedImage
    }

    private func imageRequest(for size: CGSize) -> PlayerArtworkRequest? {
        let target = decodeSize ?? size
        guard let url, target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0, displayScale.isFinite, displayScale > 0 else { return nil }
        let pixels = CGSize(width: target.width * displayScale, height: target.height * displayScale)
        guard pixels.width.isFinite, pixels.height.isFinite else { return nil }
        func dimension(_ value: CGFloat) -> Int { Int(decodeSize == nil ? (value / 64).rounded(.up) * 64 : value) }
        return PlayerArtworkRequest(url: url, pixelWidth: dimension(pixels.width),
                                    pixelHeight: dimension(pixels.height), fits: contentMode == .fit)
    }

    @ViewBuilder private func content(image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else if failed || url == nil {
            ZStack {
                DizzyPalette.artworkPlaceholder
                Image(systemName: "music.note").font(.title2).foregroundStyle(DizzyPalette.artworkPlaceholderSymbol)
            }
        } else { DizzyPalette.artworkPlaceholder }
    }
}
