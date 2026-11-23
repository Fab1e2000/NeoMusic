import SwiftUI
import LNPopupUI
import Nuke
import FullScreenPlayer

@MainActor enum NeoMusicPlayerServices {
    static func make(actions: PlayerActions, library: PlayerLyricsController,
                     prepareArtwork: @escaping (String) -> Void = { _ in },
                     prepareQueueArtwork: ((String, Bool) -> Task<Void, Never>?)? = nil) -> PlayerServices {
        PlayerServices(actions: actions, lyrics: library.source,
                       artwork: artwork(prepare: prepareArtwork, prepareQueue: prepareQueueArtwork), diagnostics: diagnostics)
    }

    static func artwork(prepare: @escaping (String) -> Void = { _ in },
                        prepareQueue: ((String, Bool) -> Task<Void, Never>?)? = nil) -> PlayerArtworkProvider {
        PlayerArtworkProvider(cached: { request in
            if request.url.isFileURL, !request.fits {
                let pixels = LocalArtworkImages.pixelSize(CGFloat(max(request.pixelWidth, request.pixelHeight)))
                if let cached = LocalArtworkImages.cachedThumbnail(request.url, pixels: pixels) { return cached }
            }
            return ImagePipeline.shared.cache[imageRequest(request)]?.image
        }, displayFallback: { request in
            guard request.url.isFileURL, !request.fits else { return nil }
            let pixels = LocalArtworkImages.pixelSize(CGFloat(max(request.pixelWidth, request.pixelHeight)))
            return LocalArtworkImages.cached(request.url, pixels: pixels)
        }, load: { request in
            if request.url.isFileURL, !request.fits {
                let pixels = LocalArtworkImages.pixelSize(CGFloat(max(request.pixelWidth, request.pixelHeight)))
                if let loaded = await LocalArtworkImages.loadThumbnail(request.url, pixels: pixels) {
                    return loaded
                }
            }
            return try await ImagePipeline.shared.image(for: imageRequest(request))
        }, prefetch: { requests in
            await withTaskGroup(of: Void.self) { group in
                var remoteRequests: [ImageRequest] = []
                for request in requests {
                    if request.url.isFileURL, !request.fits {
                        let pixels = LocalArtworkImages.pixelSize(CGFloat(max(request.pixelWidth, request.pixelHeight)))
                        group.addTask { _ = await LocalArtworkImages.loadThumbnail(request.url, pixels: pixels) }
                    } else {
                        remoteRequests.append(imageRequest(request))
                    }
                }
                if !remoteRequests.isEmpty {
                    group.addTask { await ArtworkImagePipeline.prefetch(remoteRequests) }
                }
            }
        }, prepare: prepare, prepareQueue: prepareQueue)
    }

    private static func imageRequest(_ value: PlayerArtworkRequest) -> ImageRequest {
        var request = ImageRequest(url: value.url)
        request.thumbnail = .init(size: CGSize(width: value.pixelWidth, height: value.pixelHeight),
                                  unit: .pixels, contentMode: value.fits ? .aspectFit : .aspectFill)
        return request
    }

    static let diagnostics = PlayerDiagnostics(begin: { name, animation in
        let interval = animation ? PerformanceDiagnostics.beginAnimation(name) : PerformanceDiagnostics.begin(name)
        return { PerformanceDiagnostics.end(name, interval) }
    }, event: { PerformanceDiagnostics.event($0) }, queueScroll: PerformanceDiagnostics.queueScroll)
}

struct NeoMusicArtworkTransition: ViewModifier {
    func body(content: Content) -> some View { content.popupTransitionTarget() }
}
