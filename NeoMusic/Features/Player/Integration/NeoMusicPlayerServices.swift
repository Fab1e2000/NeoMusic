import SwiftUI
import FrontAMPlayer

@MainActor enum NeoMusicPlayerServices {
    static func make(actions: PlayerActions, library: PlayerLyricsController,
                     prepareArtwork: @escaping (String) -> Void = { _ in },
                     prepareQueueArtwork: ((String, Bool) -> Task<Void, Never>?)? = nil) -> PlayerServices {
        PlayerServices(actions: actions, lyrics: library.source,
                       artwork: artwork(prepare: prepareArtwork, prepareQueue: prepareQueueArtwork), diagnostics: diagnostics)
    }

    static func artwork(usesTargetBounds: Bool = false,
                        prepare: @escaping (String) -> Void = { _ in },
                        prepareQueue: ((String, Bool) -> Task<Void, Never>?)? = nil) -> PlayerArtworkProvider {
        PlayerArtworkProvider(cached: { ArtworkImagePipeline.cached($0, usesTargetBounds: usesTargetBounds) },
                              displayFallback: { ArtworkImagePipeline.displayFallback($0, usesTargetBounds: usesTargetBounds) },
                              load: { try await ArtworkImagePipeline.load($0, usesTargetBounds: usesTargetBounds) },
                              prefetch: { await ArtworkImagePipeline.prefetch($0, usesTargetBounds: usesTargetBounds) },
                              prepare: prepare, prepareQueue: prepareQueue)
    }

    static let diagnostics = PlayerDiagnostics(begin: { name, animation in
        let interval = animation ? PerformanceDiagnostics.beginAnimation(name) : PerformanceDiagnostics.begin(name)
        return { PerformanceDiagnostics.end(name, interval) }
    }, event: { PerformanceDiagnostics.event($0) }, queueScroll: PerformanceDiagnostics.queueScroll)
}
