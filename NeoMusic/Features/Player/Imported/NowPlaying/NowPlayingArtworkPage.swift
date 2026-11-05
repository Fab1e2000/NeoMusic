// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

struct NowPlayingArtworkPage: View {
    static let pausedArtworkScale: CGFloat = 0.74

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(ReferencePlayerState.self) private var player
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.playerVisualsActive) private var visualsActive

    let song: ReferenceTrack
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsArtwork: Bool
    let onArtworkFrameChange: (CGRect) -> Void

    @State private var artworkBounceScale: CGFloat = 1
    @State private var bounceGeneration = 0
    @State private var handledBounceGeneration = 0

    init(
        song: ReferenceTrack,
        artworkNamespace: Namespace.ID,
        usesArtworkTransition: Bool = true,
        showsArtwork: Bool = true,
        onArtworkFrameChange:
            @escaping (CGRect) -> Void = { _ in }
    ) {
        self.song = song
        self.artworkNamespace = artworkNamespace
        self.usesArtworkTransition = usesArtworkTransition
        self.showsArtwork = showsArtwork
        self.onArtworkFrameChange = onArtworkFrameChange
    }

    private var isArtworkExpanded: Bool {
        player.isPlaying
    }

    var body: some View {
        GeometryReader { proxy in
            let artworkSize = layout.artworkSide
            let displayedArtworkSize =
                artworkSize
                * (
                    isArtworkExpanded
                        ? 1
                        : Self.pausedArtworkScale
                )

            ZStack(alignment: .topLeading) {

                ZStack {
                    if showsArtwork {
                        ArtworkImage(
                            url: song.coverURL,
                            cornerRadius: 12
                        )
                        .frame(
                            width: displayedArtworkSize,
                            height: displayedArtworkSize
                        )
                        .scaleEffect(artworkBounceScale)
                        .nowPlayingArtworkTransition(
                            id: song.id,
                            in: artworkNamespace,
                            isEnabled: usesArtworkTransition,
                            isSource: true
                        )
                        .shadow(
                            color: .black.opacity(
                                player.isPlaying ? 0.34 : 0.18
                            ),
                            radius: player.isPlaying ? 26 : 14,
                            y: player.isPlaying ? 15 : 8
                        )
                    } else {
                        Color.clear
                            .frame(
                                width: artworkSize,
                                height: artworkSize
                            )
                            .onGeometryChange(
                                for: CGRect.self
                            ) { geometry in
                                geometry.frame(
                                    in: .named(
                                        NowPlayingPortraitCoordinateSpace
                                            .name
                                    )
                                )
                            } action: { newFrame in
                                onArtworkFrameChange(newFrame)
                            }
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .animation(
                    accessibilityReduceMotion
                        ? nil
                        : .smooth(duration: 0.48),
                    value: isArtworkExpanded
                )
                .animation(
                    accessibilityReduceMotion
                        ? nil
                        : .easeInOut(duration: 0.3),
                    value: player.isPlaying
                )
                .accessibilityElement()
                .accessibilityLabel("\(song.title)的封面")
                .accessibilityHidden(!showsArtwork)
                .onChange(of: player.isPlaying) { _, playing in
                    if playing && showsArtwork && visualsActive { bounceGeneration += 1 }
                }
                .task(id: ArtworkBounceRequest(generation: bounceGeneration, isActive: visualsActive && player.isPlaying)) {
                    guard bounceGeneration > handledBounceGeneration else { artworkBounceScale = 1; return }
                    handledBounceGeneration = bounceGeneration
                    await animateArtworkBounce(
                        whenPlaying: player.isPlaying
                    )
                }
                .position(x: proxy.size.width / 2, y: layout.pageY(112) + artworkSize / 2)

                // 左右滑动歌名切到上一首/下一首；相邻歌名在歌名这一栏的宽度之外淡入。
                NowPlayingTrackSwipe(song: song, pageDistance: layout.width(227) + 24) { track, interactive in
                    ZStack {
                        // 放不下时滚动显示（相邻曲目的预览不滚）。
                        NowPlayingMarqueeText(text: track.title, isActive: interactive, edrFontSize: 20)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .frame(width: layout.width(227), height: 27, alignment: .leading)
                            .contentShape(.rect)
                            .position(x: layout.x(145.5), y: layout.pageY(503.5))

                        NowPlayingArtistButton(track: track, interactive: interactive)
                            .font(.system(size: 20))
                            .lineLimit(1)
                            .frame(width: layout.width(215), height: 26, alignment: .leading)
                            .position(x: layout.x(139.5), y: layout.pageY(528.5))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                NowPlayingSongActions(track: song)
                    .fixedSize()
                    .frame(width: 92.25, height: 44, alignment: .trailing)
                    .contentShape(.rect)
                    .position(x: layout.x(329.875), y: layout.pageY(517.25))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: ArtworkPrefetchKey(urls: visualsActive ? player.adjacentArtworkURLs : [], size: displayedArtworkSize, scale: displayScale)) {
                guard visualsActive else { return }
                let requests = player.adjacentArtworkURLs.compactMap {
                    ArtworkImagePipeline.request(for: $0, size: CGSize(width: displayedArtworkSize, height: displayedArtworkSize),
                                                 displayScale: displayScale)
                }
                await ArtworkImagePipeline.prefetch(requests)
            }
        }
    }

    private func animateArtworkBounce(
        whenPlaying isPlaying: Bool
    ) async {
        artworkBounceScale = 1
        guard showsArtwork,
              visualsActive,
              isPlaying,
              !accessibilityReduceMotion else {
            return
        }

        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.17)) {
            artworkBounceScale = 1.055
        }

        do {
            try await Task.sleep(for: .milliseconds(170))
        } catch {
            return
        }

        withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
            artworkBounceScale = 1
        }
    }
}

/// Measures the cover without mounting controls, lyrics, image requests or timers.
struct NowPlayingArtworkFrameMeasurement: View {
    @Environment(\.nowPlayingLayout) private var layout
    let onFrameChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(width: layout.artworkSide, height: layout.artworkSide)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(NowPlayingPortraitCoordinateSpace.name))
                } action: { onFrameChange($0) }
                .position(x: proxy.size.width / 2, y: layout.pageY(112) + layout.artworkSide / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ArtworkBounceRequest: Equatable {
    let generation: Int
    let isActive: Bool
}

private struct ArtworkPrefetchKey: Equatable {
    let urls: [URL]
    let size: CGFloat
    let scale: CGFloat
}
