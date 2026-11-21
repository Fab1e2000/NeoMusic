// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

struct NowPlayingQueuePage: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.nowPlayingControlsOverflow) private var controlsOverflow

    let song: PlayerTrack
    let presentation: NowPlayingLyricsPresentation
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let showsSongHeader: Bool
    let onSongHeaderHiddenChange: (Bool) -> Void
    let onSongHeaderOffsetChange: (CGFloat) -> Void

    private static let contentHorizontalInset: CGFloat = 32

    @State private var headerScroll = QueueHeaderScrollState()

    init(
        song: PlayerTrack,
        presentation: NowPlayingLyricsPresentation,
        artworkNamespace: Namespace.ID,
        usesArtworkTransition: Bool = true,
        showsSongHeader: Bool = true,
        onSongHeaderHiddenChange:
            @escaping (Bool) -> Void = { _ in },
        onSongHeaderOffsetChange:
            @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.song = song
        self.presentation = presentation
        self.artworkNamespace = artworkNamespace
        self.usesArtworkTransition = usesArtworkTransition
        self.showsSongHeader = showsSongHeader
        self.onSongHeaderHiddenChange = onSongHeaderHiddenChange
        self.onSongHeaderOffsetChange = onSongHeaderOffsetChange
    }

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingQueueList(
                entries: player.upcomingQueueEntries,
                version: player.upcomingQueueVersion,
                trackTransitionKey: player.currentTrackTransitionKey,
                subtitle: player.automaticContinuationDescription,
                headerHeight: songHeaderHeight,
                horizontalInset: Self.contentHorizontalInset,
                bottomInset: 50,
                onPlay: { player.playFromQueue(at: $0) },
                onMove: moveQueueItems,
                onScroll: updateSongHeaderState
            )
            .overlay(alignment: .top) {
                QueueHeaderControls(scroll: headerScroll, headerHeight: songHeaderHeight)
            }
            .overlay(alignment: .top) {
                if presentation == .portrait && showsSongHeader {
                    QueueSongHeader(scroll: headerScroll, song: song,
                                    artworkNamespace: artworkNamespace,
                                    usesArtworkTransition: usesArtworkTransition,
                                    headerHeight: songHeaderHeight)
                }
            }
            .padding(.bottom, bottomContentInset)
        }
        .onAppear {
            resetSongHeaderState()
        }
        .onChange(of: player.currentTrackTransitionKey) { _, _ in
            resetSongHeaderState()
        }
    }

    private func resetSongHeaderState() {
        if presentation == .portrait {
            headerScroll.offset = 0
            onSongHeaderHiddenChange(false)
            onSongHeaderOffsetChange(0)
        }
    }

    private var songHeaderHeight: CGFloat {
        presentation == .portrait
            ? NowPlayingSongHeader.topInset + NowPlayingSongHeader.referenceHeight
                + NowPlayingSongHeader.bottomSpacing
            : 0
    }

    private var bottomContentInset: CGFloat {
        presentation == .portrait
            ? max(0, layout.contentSize.height - 3 - layout.contentY(557)) + controlsOverflow
            : 12
    }

    private func updateSongHeaderState(for offset: CGFloat) {
        guard presentation == .portrait, headerScroll.offset != offset else { return }
        let wasHidden = songHeaderHeight > 0 && headerScroll.offset >= songHeaderHeight
        headerScroll.offset = offset
        onSongHeaderOffsetChange(-min(offset, max(songHeaderHeight, 0)))
        let isHidden = songHeaderHeight > 0 && offset >= songHeaderHeight
        if wasHidden != isHidden { onSongHeaderHiddenChange(isHidden) }
    }

    private func moveQueueItems(
        from source: IndexSet,
        to destination: Int
    ) {
        player.moveUpcomingQueueItems(fromOffsets: source, toOffset: destination)
    }
}

@MainActor @Observable
private final class QueueHeaderScrollState {
    var offset: CGFloat = 0
}

private struct QueueHeaderControls: View {
    let scroll: QueueHeaderScrollState
    let headerHeight: CGFloat

    var body: some View {
        NowPlayingQueueModeControls()
            .padding(.vertical, 3)
            .frame(height: 44)
            .modifier(QueueControlsScrollPosition(scroll: scroll, headerHeight: headerHeight))
    }
}

private struct QueueControlsScrollPosition: ViewModifier {
    let scroll: QueueHeaderScrollState
    let headerHeight: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: max(headerHeight - scroll.offset, 0))
    }
}

private struct QueueSongHeader: View {
    let scroll: QueueHeaderScrollState
    let song: PlayerTrack
    let artworkNamespace: Namespace.ID
    let usesArtworkTransition: Bool
    let headerHeight: CGFloat

    var body: some View {
        NowPlayingSongHeader(song: song, artworkNamespace: artworkNamespace,
                             usesReferenceLayout: true,
                             usesArtworkTransition: usesArtworkTransition && scroll.offset <= 0.5)
            .frame(height: NowPlayingSongHeader.referenceHeight)
            .padding(.top, NowPlayingSongHeader.topInset)
            .frame(height: headerHeight, alignment: .top)
            .offset(y: -scroll.offset)
            .opacity(NowPlayingSongHeader.scrollFadeOpacity(scrolled: scroll.offset))
    }
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

private struct NowPlayingQueueModeControls: View {
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
                accessibilityLabel: "自动续播推荐音乐",
                action: player.toggleAutomaticContinuation
            )
            .accessibilityValue("当前版本暂未提供自动续播推荐音乐")

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
    let entry: PlayerQueueEntry
    let onPlay: () -> Void

    var body: some View {
        SongMenuHost(track: entry.song, play: onPlay) { configuration in
            HStack(spacing: 0) {
                Button(action: onPlay) {
                    HStack(spacing: 12) {
                        ArtworkImage(
                            url: entry.song.coverURL,
                            contentID: entry.song.id,
                            artworkLoadID: entry.song.artworkLoadID,
                            cornerRadius: 6
                        )
                        .frame(width: 48, height: 48)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.song.title)
                                .font(.body)
                                .nowPlayingPrimary()
                                .lineLimit(1)

                            NowPlayingVibrantLabel(text: entry.song.artists, fontSize: 13)
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

            }
            .contextMenu { ReferenceSongMenuContents(configuration: configuration) }

        }
    }
}
