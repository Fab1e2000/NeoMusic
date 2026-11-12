// Source: NeoDizzy Core/UI/ArtworkImagePipeline.swift; see Resources/PlayerSourceNotices.txt.
import Foundation
import Nuke

/// Shared image resource policy; providers still own their image URLs and authentication.
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
        // Retain enough decoded covers for several screens without allowing Nuke's
        // default cache to grow to 768 MB on a phone. Eviction never removes source data.
        ImageCache.shared.costLimit = min(Int(ProcessInfo.processInfo.physicalMemory / 32), 192 * 1_024 * 1_024)
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
        // Pixel buckets keep nearby layout sizes cache-compatible without decoding a
        // 44 pt row at 384 px on a 3x display. An explicit decode size stays exact.
        func bucket(_ value: CGFloat) -> CGFloat { (value / 64).rounded(.up) * 64 }
        let thumbnailSize = decodeSize == nil
            ? CGSize(width: bucket(pixels.width), height: bucket(pixels.height))
            : pixels
        var request = ImageRequest(url: url)
        request.thumbnail = .init(size: thumbnailSize, unit: .pixels, contentMode: contentMode)
        return request
    }
}
