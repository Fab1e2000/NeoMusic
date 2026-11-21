// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

struct NowPlayingArtworkPage: View {
    static let pausedArtworkScale: CGFloat = 247.0 / 338.0

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(PlayerServices.self) private var services: PlayerServices?
    @Environment(PlayerState.self) private var player
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow
    @Environment(\.playerVisualsActive) private var visualsActive
    @ScaledMetric(relativeTo: .title3) private var informationFontSize: CGFloat = 20

    let song: PlayerTrack
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsArtwork: Bool
    let onArtworkFrameChange: (CGRect) -> Void

    @State private var artworkBounceScale: CGFloat = 1
    @State private var bounceGeneration = 0
    @State private var handledBounceGeneration = 0

    init(
        song: PlayerTrack,
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

    private var shouldBounce: Bool {
        showsArtwork && visualsActive && player.isPlaying && !accessibilityReduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            let textScale = informationFontSize / 20
            let extraInformationHeight = 53 * (textScale - 1)
            let artworkSize = Self.artworkSide(layout: layout, textScale: textScale, controlsOverflow: controlsOverflow)
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
                            contentID: song.id,
                            artworkLoadID: song.artworkLoadID,
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
                .task(id: ArtworkBounceRequest(generation: bounceGeneration, isActive: shouldBounce)) {
                    guard bounceGeneration > handledBounceGeneration else { artworkBounceScale = 1; return }
                    handledBounceGeneration = bounceGeneration
                    await animateArtworkBounce()
                }
                .position(x: proxy.size.width / 2, y: layout.pageY(95) + artworkSize / 2)

                let actionsLeft = layout.x(329.875) - 46.125
                let titleWidth = layout.width(227)
                let artistWidth = layout.width(215)
                let slotLeft = layout.x(145.5) - titleWidth / 2
                let slotWidth = max(actionsLeft - slotLeft, titleWidth)
                let titleCenterY = layout.pageY(488.833) - 39.5 * (textScale - 1) - controlsOverflow
                let artistCenterY = layout.pageY(512.5) - 13 * (textScale - 1) - controlsOverflow
                let slotTop = titleCenterY - (27 * textScale) / 2 - 6
                let slotBottom = artistCenterY + max((26 * textScale) / 2 + 6, 22)
                let slotHeight = max(slotBottom - slotTop, 1)
                let slotCenterY = (slotTop + slotBottom) / 2
                let swipeInsets = TrackSwipeViewportInsets(
                    leadingBleed: layout.width(24),
                    trailingBleed: 0,
                    leadingFade: layout.width(24),
                    trailingFade: min(layout.width(21), max(slotWidth - titleWidth, 12)),
                    fadesOnlyWhenSliding: false
                )

                NowPlayingTrackSwipe(
                    song: song,
                    pageDistance: max(layout.width(278), slotWidth + 24),
                    rowSpacing: nil,
                    viewportInsets: swipeInsets,
                    viewportWidth: slotWidth
                ) { track, marqueeActive in
                    NowPlayingMarqueeText(text: track.title, isActive: marqueeActive)
                        .font(.system(size: informationFontSize, weight: .semibold))
                        .nowPlayingPrimary()
                        .lineLimit(1)
                        .frame(width: titleWidth, height: 27 * textScale, alignment: .leading)
                        .position(x: titleWidth / 2, y: titleCenterY - slotTop)
                } artist: { track, interactive in
                    NowPlayingArtistButton(track: track, interactive: interactive, lineHeight: 26 * textScale,
                                           fontSize: informationFontSize, fontSizeIsScaled: true)
                        .font(.system(size: informationFontSize))
                        .lineLimit(1)
                        .frame(width: artistWidth, height: 26 * textScale, alignment: .leading)
                        .position(x: artistWidth / 2, y: artistCenterY - slotTop)
                }
                .frame(width: slotWidth, height: slotHeight)
                .position(x: slotLeft + slotWidth / 2, y: slotCenterY)

                NowPlayingSongActions(track: song)
                    .fixedSize()
                    .frame(width: 92.25, height: 44, alignment: .trailing)
                    .contentShape(.rect)
                    .position(x: layout.x(329.875), y: layout.pageY(501) - extraInformationHeight / 2 - controlsOverflow)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: ArtworkPrefetchKey(urls: visualsActive ? player.adjacentArtworkURLs : [], size: displayedArtworkSize, scale: displayScale)) {
                guard visualsActive else { return }
                guard let provider = services?.artwork else { return }
                let pixels = Int((displayedArtworkSize * displayScale / 64).rounded(.up) * 64)
                guard pixels > 0 else { return }
                let requests = player.adjacentArtworkURLs.map {
                    PlayerArtworkRequest(url: $0, pixelWidth: pixels, pixelHeight: pixels)
                }
                await provider.prefetch(requests)
            }
        }
    }

    static func artworkSide(layout: ReferenceNowPlayingLayout, textScale: CGFloat, controlsOverflow: CGFloat = 0) -> CGFloat {
        max(0, layout.artworkSide - max(0, 53 * (textScale - 1)) - controlsOverflow)
    }

    private func animateArtworkBounce() async {
        artworkBounceScale = 1
        guard shouldBounce else { return }

        await Task.yield()
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(.easeOut(duration: 0.17), completionCriteria: .removed) {
                artworkBounceScale = 1.055
            } completion: {
                continuation.resume()
            }
        }
        guard !Task.isCancelled else { return }

        withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
            artworkBounceScale = 1
        }
    }
}

struct NowPlayingArtworkFrameMeasurement: View {
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow
    @ScaledMetric(relativeTo: .title3) private var informationFontSize: CGFloat = 20
    let onFrameChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let artworkSize = NowPlayingArtworkPage.artworkSide(layout: layout, textScale: informationFontSize / 20,
                                                              controlsOverflow: controlsOverflow)
            Color.clear
                .frame(width: artworkSize, height: artworkSize)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(NowPlayingPortraitCoordinateSpace.name))
                } action: { onFrameChange($0) }
                .position(x: proxy.size.width / 2, y: layout.pageY(95) + artworkSize / 2)
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
