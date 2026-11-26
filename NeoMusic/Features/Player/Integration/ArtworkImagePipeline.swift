import FrontAMPlayer
// Source: NeoDizzy Core/UI/ArtworkImagePipeline.swift; see Resources/PlayerSourceNotices.txt.
import Foundation
import Nuke
import UIKit

@MainActor enum ArtworkImagePipeline {
    static func cached(_ request: PlayerArtworkRequest, usesTargetBounds: Bool = false) -> UIImage? {
        if request.url.isFileURL {
            return LocalArtworkImages.cached(request.url, size: localSize(for: request, usesTargetBounds: usesTargetBounds))
        }
        return ImagePipeline.shared.cache[remoteRequest(request)]?.image
    }

    static func displayFallback(_ request: PlayerArtworkRequest, usesTargetBounds: Bool = false) -> UIImage? {
        guard request.url.isFileURL, !request.fits else { return nil }
        let pixels = max(request.pixelWidth, request.pixelHeight)
        return LocalArtworkImages.cached(request.url, pixels: usesTargetBounds ? pixels : LocalArtworkImages.pixelSize(CGFloat(pixels)))
    }

    static func load(_ request: PlayerArtworkRequest, usesTargetBounds: Bool = false) async throws -> UIImage {
        if request.url.isFileURL {
            if let image = await LocalArtworkImages.load(request.url, size: localSize(for: request, usesTargetBounds: usesTargetBounds)) {
                return image
            }
            try Task.checkCancellation()
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: request.url])
        }
        return try await ImagePipeline.shared.image(for: remoteRequest(request))
    }

    static func prefetch(_ requests: [PlayerArtworkRequest], usesTargetBounds: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    _ = try? await load(request, usesTargetBounds: usesTargetBounds)
                }
            }
        }
    }
    nonisolated static func configureMemoryCache() {
        ImageCache.shared.costLimit = min(Int(ProcessInfo.processInfo.physicalMemory / 16), 384 * 1_024 * 1_024)
    }

    private static func localSize(for request: PlayerArtworkRequest, usesTargetBounds: Bool) -> ImageSourceThumbnail.Size {
        // The mini-player uses its original target bounds. Full-screen fill already uses bucketed longest edges.
        if request.fits || usesTargetBounds {
            return .target(width: request.pixelWidth, height: request.pixelHeight, fits: request.fits)
        }
        return .maximumDimension(LocalArtworkImages.pixelSize(CGFloat(max(request.pixelWidth, request.pixelHeight))))
    }

    private static func remoteRequest(_ value: PlayerArtworkRequest) -> ImageRequest {
        var request = ImageRequest(url: value.url)
        request.thumbnail = .init(size: CGSize(width: value.pixelWidth, height: value.pixelHeight),
                                  unit: .pixels, contentMode: value.fits ? .aspectFit : .aspectFill)
        return request
    }
}
