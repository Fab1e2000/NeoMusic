import FullScreenPlayer
// Source: NeoDizzy Core/UI/ArtworkImagePipeline.swift; see Resources/PlayerSourceNotices.txt.
import Foundation
import Nuke

enum ArtworkImagePipeline {
    static func thumbnailRequest(for url: URL, pixels: Int) -> ImageRequest {
        var request = ImageRequest(url: url)
        request.thumbnail = .init(size: CGSize(width: pixels, height: pixels), unit: .pixels,
                                  contentMode: .aspectFill)
        return request
    }

    static func prefetch(_ requests: [ImageRequest]) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    _ = try? await ImagePipeline.shared.image(for: request)
                }
            }
        }
    }
    static func configureMemoryCache() {
        ImageCache.shared.costLimit = min(Int(ProcessInfo.processInfo.physicalMemory / 16), 384 * 1_024 * 1_024)
    }

    static func request(for url: URL?, size: CGSize, displayScale: CGFloat,
                        decodeSize: CGSize? = nil,
                        contentMode: ImageProcessingOptions.ContentMode = .aspectFill) -> ImageRequest? {
        let target = decodeSize ?? size
        guard let url, target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0,
              displayScale.isFinite, displayScale > 0 else { return nil }
        let pixels = CGSize(width: target.width * displayScale, height: target.height * displayScale)
        guard pixels.width.isFinite, pixels.height.isFinite else { return nil }
        func bucket(_ value: CGFloat) -> CGFloat { (value / 64).rounded(.up) * 64 }
        let thumbnailSize = decodeSize == nil
            ? CGSize(width: bucket(pixels.width), height: bucket(pixels.height))
            : pixels
        var request = ImageRequest(url: url)
        request.thumbnail = .init(size: thumbnailSize, unit: .pixels, contentMode: contentMode)
        return request
    }
}
