import SwiftUI
import UIKit

/// 从封面颜色生成动态流体背景；只在换歌时交叉淡入。
struct NowPlayingArtworkBackdrop: View {
    let artworkURL: URL?
    var trackID: String? = nil
    var isPlaying: Bool = true
    var ignoresSafeArea = true
    /// 作为背景副本画在别的视图底下：没有封面时完全透明（露出真背景），不画黑色打底和压暗。
    var isUnderlay = false
    /// 背景实际铺开的范围（含安全区），供外层坐标校准。
    var onFrameChange: ((CGRect) -> Void)? = nil
    var onFluidSourceChange: ((NowPlayingFluidBackdropSource?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PlayerServices.self) private var services: PlayerServices?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playerVisualsActive) private var visualsActive
    private var fluidResources = NowPlayingFluidBackdropResources.shared
    @State private var fluidSource: NowPlayingFluidBackdropSource?
    @State private var renderedTrackID: String?

    init(
        artworkURL: URL?,
        trackID: String? = nil,
        isPlaying: Bool = true,
        ignoresSafeArea: Bool = true,
        isUnderlay: Bool = false,
        onFrameChange: ((CGRect) -> Void)? = nil,
        onFluidSourceChange: ((NowPlayingFluidBackdropSource?) -> Void)? = nil
    ) {
        self.artworkURL = artworkURL
        self.trackID = trackID
        self.isPlaying = isPlaying
        _renderedTrackID = State(initialValue: trackID)
        self.ignoresSafeArea = ignoresSafeArea
        self.isUnderlay = isUnderlay
        self.onFrameChange = onFrameChange
        self.onFluidSourceChange = onFluidSourceChange
        _fluidSource = State(initialValue: artworkURL.flatMap {
            NowPlayingFluidBackdropCache.shared.cached(for: $0)
        })
    }

    private struct BackdropRequestID: Equatable {
        let url: URL?
        let trackID: String?
    }

    private static func request(for url: URL?) -> PlayerArtworkRequest? {
        url.map { PlayerArtworkRequest(url: $0, pixelWidth: 240, pixelHeight: 240) }
    }

    /// 供 Metal 提取主色调与 128x128 颜色块的小尺寸封面解码。
    private static let decodeSize = CGSize(width: 240, height: 240)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if !isUnderlay {
                    Color.black
                }

                if let fluidSource, let pipelines = fluidResources.pipelines {
                    NowPlayingFluidBackdropRepresentable(
                        source: fluidSource,
                        isPlaying: isPlaying,
                        reduceMotion: accessibilityReduceMotion,
                        isActive: visualsActive && scenePhase == .active,
                        pipelines: pipelines
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
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
        .onChange(of: fluidSource?.id, initial: true) { _, _ in onFluidSourceChange?(fluidSource) }
        .task(id: visualsActive && scenePhase == .active) {
            if visualsActive && scenePhase == .active { await fluidResources.prepare() }
        }
        .task(id: BackdropRequestID(url: artworkURL, trackID: trackID)) {
            // Retain the backdrop while loading, but never attribute another song's cover to a missing image.
            guard let artworkURL, let request = Self.request(for: artworkURL) else {
                if trackID == nil || renderedTrackID != trackID {
                    fluidSource = nil
                }
                return
            }
            let fluidCache = NowPlayingFluidBackdropCache.shared
            let cachedFluid = fluidCache.cached(for: artworkURL)

            let nextFluid: NowPlayingFluidBackdropSource?
            if let cachedFluid {
                nextFluid = cachedFluid
            } else if let loaded = try? await services?.artwork.load(request), !Task.isCancelled {
                nextFluid = await fluidCache.prepare(loaded, for: artworkURL)
            } else {
                nextFluid = nil
            }
            guard !Task.isCancelled else { return }
            if nextFluid == nil, trackID != nil, renderedTrackID == trackID { return }
            renderedTrackID = trackID
            fluidSource = nextFluid
        }
    }
}
