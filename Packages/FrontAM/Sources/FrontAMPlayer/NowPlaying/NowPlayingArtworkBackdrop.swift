import SwiftUI
import UIKit

struct NowPlayingArtworkBackdrop: View {
    let artworkURL: URL?
    var trackID: String? = nil
    var isPlaying: Bool = true
    var ignoresSafeArea = true
    var onFrameChange: ((CGRect) -> Void)? = nil
    var onPaletteChange: ((NowPlayingBackdropPalette?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PlayerServices.self) private var services: PlayerServices?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playerVisualsActive) private var visualsActive
    @State private var palette: NowPlayingBackdropPalette?
    @State private var renderedTrackID: String?
    @State private var hasDisplayedPalette = false

    init(
        artworkURL: URL?,
        trackID: String? = nil,
        isPlaying: Bool = true,
        ignoresSafeArea: Bool = true,
        onFrameChange: ((CGRect) -> Void)? = nil,
        onPaletteChange: ((NowPlayingBackdropPalette?) -> Void)? = nil
    ) {
        self.artworkURL = artworkURL
        self.trackID = trackID
        self.isPlaying = isPlaying
        _renderedTrackID = State(initialValue: trackID)
        self.ignoresSafeArea = ignoresSafeArea
        self.onFrameChange = onFrameChange
        self.onPaletteChange = onPaletteChange
        _palette = State(initialValue: artworkURL.flatMap {
            NowPlayingBackdropCache.shared.cached(for: $0)
        })
    }

    private struct BackdropRequestID: Equatable {
        let url: URL?
        let trackID: String?
    }

    private static func request(for url: URL?) -> PlayerArtworkRequest? {
        url.map { PlayerArtworkRequest(url: $0, pixelWidth: 240, pixelHeight: 240) }
    }

    private var animatesGradient: Bool {
        visualsActive && scenePhase == .active && isPlaying && !accessibilityReduceMotion
    }

    private var crossfadesTracks: Bool {
        visualsActive && scenePhase == .active && !accessibilityReduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let palette {
                    NowPlayingMeshBackdrop(
                        palette: palette,
                        animates: animatesGradient,
                        reduceMotion: accessibilityReduceMotion
                    )
                    .transition(.opacity)
                }
            }
            .animation(crossfadesTracks && hasDisplayedPalette ? .easeInOut(duration: 0.6) : nil,
                       value: palette)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(NowPlayingContentCoordinateSpace.name))
            } action: {
                onFrameChange?($0)
            }
        }
        .ignoresSafeArea(edges: ignoresSafeArea ? .all : [])
        .accessibilityHidden(true)
        .onChange(of: palette, initial: true) { _, newValue in
            if newValue != nil { hasDisplayedPalette = true }
            onPaletteChange?(newValue)
        }
        .task(id: BackdropRequestID(url: artworkURL, trackID: trackID)) {
            guard let artworkURL, let request = Self.request(for: artworkURL) else {
                if trackID == nil || renderedTrackID != trackID {
                    palette = nil
                }
                return
            }
            let cache = NowPlayingBackdropCache.shared

            let nextPalette: NowPlayingBackdropPalette?
            if let cached = cache.cached(for: artworkURL) {
                nextPalette = cached
            } else if let loaded = try? await services?.artwork.load(request), !Task.isCancelled {
                nextPalette = await cache.prepare(loaded, for: artworkURL)
            } else {
                nextPalette = nil
            }
            guard !Task.isCancelled else { return }
            if nextPalette == nil, trackID != nil, renderedTrackID == trackID { return }
            renderedTrackID = trackID
            palette = nextPalette
        }
    }
}

private struct NowPlayingMeshBackdrop: View {
    let palette: NowPlayingBackdropPalette
    let animates: Bool
    let reduceMotion: Bool

    @State private var isDrifting = false

    var body: some View {
        MeshGradient(
            width: NowPlayingBackdropPalette.columns,
            height: NowPlayingBackdropPalette.rows,
            points: points,
            colors: palette.swatches.map(\.color)
        )
        .animation(driftAnimation, value: isDrifting)
        .onAppear { isDrifting = animates }
        .onChange(of: animates) { _, enabled in isDrifting = enabled }
    }

    private var driftAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return animates
            ? .easeInOut(duration: 24).repeatForever(autoreverses: true)
            : .easeInOut(duration: 1.2)
    }

    private var points: [SIMD2<Float>] {
        let drift = isDrifting
        let seed = palette.seed
        func direction(_ bit: UInt64) -> Float { (seed >> bit) & 1 == 0 ? -1 : 1 }

        let topX = drift ? 0.5 + 0.09 * direction(1) : 0.5
        let leftY = drift ? 0.5 + 0.08 * direction(3) : 0.5
        let centerX = drift ? 0.5 + 0.09 * direction(5) : 0.5
        let centerY = drift ? 0.5 + 0.08 * direction(7) : 0.5
        let rightY = drift ? 0.5 + 0.08 * direction(9) : 0.5
        let bottomX = drift ? 0.5 + 0.09 * direction(11) : 0.5

        return [
            SIMD2<Float>(0, 0), SIMD2<Float>(topX, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, leftY), SIMD2<Float>(centerX, centerY), SIMD2<Float>(1, rightY),
            SIMD2<Float>(0, 1), SIMD2<Float>(bottomX, 1), SIMD2<Float>(1, 1),
        ]
    }
}
