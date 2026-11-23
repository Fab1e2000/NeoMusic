// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

struct NowPlayingQueuePage: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow

    let header: NowPlayingQueueSongHeader
    let onImportLyrics: (() -> Void)?
    let onScroll: (CGFloat) -> Void
    var onViewportHeightChange: (CGFloat) -> Void = { _ in }

    static let songHeaderHeight = NowPlayingSongHeader.topInset + NowPlayingSongHeader.referenceHeight
        + NowPlayingSongHeader.bottomSpacing

    var body: some View {
        NowPlayingQueueList(
            entries: player.upcomingQueueEntries,
            version: player.upcomingQueueVersion,
            history: player.playbackHistory,
            trackTransitionKey: player.currentTrackTransitionKey,
            subtitle: player.automaticContinuationDescription,
            songHeader: header,
            onImportLyrics: onImportLyrics,
            headerHeight: Self.songHeaderHeight,
            horizontalInset: 32,
            onPlay: { player.playFromQueue(at: $0) },
            onMove: { player.moveUpcomingQueueItems(fromOffsets: $0, toOffset: $1) },
            onScroll: onScroll
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onViewportHeightChange($0) }
        .padding(.bottom, Self.bottomContentInset(layout: layout, controlsOverflow: controlsOverflow))
    }

    static func bottomContentInset(layout: ReferenceNowPlayingLayout, controlsOverflow: CGFloat) -> CGFloat {
        max(0, layout.contentSize.height - 3 - layout.contentY(554)) + controlsOverflow
    }
}

struct NowPlayingQueueSongHeader: Equatable {
    let song: PlayerTrack
    let artworkNamespace: Namespace.ID
    var isVisible = true
    var artworkDecodeSize: CGSize? = nil
}

struct NowPlayingQueueTopFade: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.35), location: 0.3),
                .init(color: .black.opacity(0.8), location: 0.65),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
    }
}

struct NowPlayingQueueModeControls: View {
    @Environment(PlayerState.self) private var player

    var body: some View {
        HStack(spacing: 13) {
            modeButton(
                systemImage: "shuffle",
                isSelected: player.isShuffled,
                isEnabled: true,
                accessibilityLabel:
                    player.isShuffled
                        ? "关闭随机播放"
                        : "随机播放",
                action: toggleShuffle
            )

            modeButton(
                systemImage: player.repeatMode.systemImage,
                isSelected: player.repeatMode != .off,
                isEnabled: true,
                accessibilityLabel:
                    player.repeatMode.accessibilityTitle,
                action: cycleRepeatMode
            )

            modeButton(
                systemImage: "infinity",
                isSelected: player.isAutomaticContinuationEnabled && player.canAutomaticallyContinue,
                isEnabled: player.canAutomaticallyContinue,
                accessibilityLabel: player.isAutomaticContinuationEnabled ? "关闭心动模式" : "心动模式",
                action: player.toggleAutomaticContinuation
            )

            modeButton(
                systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal",
                isSelected: player.isCrossfadeEnabled,
                isEnabled: true,
                accessibilityLabel: "三秒交叉淡化",
                action: player.toggleCrossfade
            )

        }
    }

    private func modeButton(
        systemImage: String,
        isSelected: Bool,
        isEnabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isSelected {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.white.opacity(NowPlayingVisualHierarchy.bottomButtonSelectedFillOpacity))
                        modeIcon(systemImage: systemImage)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .blendMode(.plusLighter)
                } else {
                    modeIcon(systemImage: systemImage)
                        .nowPlayingPlusLighter(0.75)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(.white.opacity(0.12))
                                .blendMode(.plusLighter)
                        }
                }
            }
            .contentTransition(.symbolEffect(.replace.downUp.wholeSymbol))
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .opacity(isEnabled ? 1 : 0.25)
            .frame(height: 44)
            .contentShape(.rect(cornerRadius: 22))
        }
        .padding(.vertical, -3)
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggleShuffle() {
        withAnimation(.smooth(duration: 0.34)) {
            player.toggleShuffle()
        }
    }

    @ViewBuilder
    private func modeIcon(systemImage: String) -> some View {
        if systemImage == "circle.lefthalf.filled.righthalf.striped.horizontal" {
            HStack(spacing: -7) {
                Circle().stroke(lineWidth: 2.5)
                Circle().fill()
            }.frame(width: 22, height: 13)
        } else {
            Image(systemName: systemImage)
        }
    }

    private func cycleRepeatMode() {
        withAnimation(.smooth(duration: 0.34)) {
            player.cycleRepeatMode()
        }
    }

}

struct NowPlayingQueueRow: View {
    private let readSong: @MainActor () -> PlayerTrack
    var showsMenu = true
    let onPlay: () -> Void

    init(song: PlayerTrack, showsMenu: Bool = true, onPlay: @escaping () -> Void) {
        self.readSong = { song }
        self.showsMenu = showsMenu
        self.onPlay = onPlay
    }

    init(song: @escaping @MainActor () -> PlayerTrack, showsMenu: Bool = true, onPlay: @escaping () -> Void) {
        self.readSong = song
        self.showsMenu = showsMenu
        self.onPlay = onPlay
    }

    var body: some View {
        let song = readSong()
        if showsMenu {
            SongMenuHost(track: song, play: onPlay) { configuration in
                row(for: song).contextMenu { ReferenceSongMenuContents(configuration: configuration) }
            }
        } else {
            row(for: song)
        }
    }

    private func row(for song: PlayerTrack) -> some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ArtworkImage(
                    url: song.coverURL,
                    contentID: song.id,
                    artworkLoadID: song.artworkLoadID,
                    cornerRadius: 6, decodeSize: CGSize(width: 48, height: 48)
                )
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .nowPlayingPrimary()
                        .lineLimit(1)

                    NowPlayingVibrantLabel(text: song.artists, fontSize: 13)
                }

                Spacer(minLength: 4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
