import SwiftUI
import LNPopupUI
import Nuke
import FullScreenPlayer

@MainActor enum NeoMusicPlayerServices {
    static func make(actions: PlayerActions, library: PlayerLyricsController,
                     prepareArtwork: @escaping (String) -> Void = { _ in }) -> PlayerServices {
        PlayerServices(actions: actions, lyrics: library.source,
                       artwork: artwork(prepare: prepareArtwork), diagnostics: diagnostics)
    }

    static func artwork(prepare: @escaping (String) -> Void = { _ in }) -> PlayerArtworkProvider {
        PlayerArtworkProvider(cached: { request in
            ImagePipeline.shared.cache[imageRequest(request)]?.image
        }, load: { request in
            try await ImagePipeline.shared.image(for: imageRequest(request))
        }, prefetch: { requests in
            await ArtworkImagePipeline.prefetch(requests.map(imageRequest))
        }, prepare: prepare)
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
    }, event: { PerformanceDiagnostics.event($0) })
}

struct NeoMusicArtworkTransition: ViewModifier {
    func body(content: Content) -> some View { content.popupTransitionTarget() }
}
