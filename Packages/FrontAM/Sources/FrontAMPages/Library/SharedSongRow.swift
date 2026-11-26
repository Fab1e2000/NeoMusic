import FrontAMCore
import SwiftUI
import UIKit

extension Color {
    public static func secondaryContentColor(on background: Color, colorScheme: ColorScheme) -> Color {
        CollectionPagePalette(background: UIColor(background), isDark: colorScheme == .dark).secondaryColor
    }
}

public struct SongRowAppearance {
    public var titleFont: Font = .callout
    public var subtitleFont: Font = .footnote
    public var subtitleColor: Color = .secondary
    public var titleSubtitleSpacing: CGFloat = 2
    public var titleLineLimit: Int? = 1
    public var subtitleLineLimit: Int? = 1
    public var moreColor: Color = .primary
    public var moreFont: Font = .body.weight(.semibold)
    public var moreTrailingPadding: CGFloat = -7
    public var favoriteMarkColor: Color = .secondary
    public var favoriteMarkOffset: CGFloat = -14.5
    public var downloadStatusStyle: AnyShapeStyle? = nil
    public var minHeight: CGFloat = 56
    public var usesPlainButtonStyle = false
}

public struct TrackMoreButton: View {
    public let song: LibrarySongItem
    public var color: Color = .primary
    public var font: Font = .body.weight(.semibold)
    public var accessibilityLabel: String = "更多"
    public var trailingPadding: CGFloat = -7
    public var onRemoveFromPlaylist: (() -> Void)? = nil

    public var body: some View {
        Menu { SongMenuContents(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist) } label: {
            Label(accessibilityLabel, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(font)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(accessibilityLabel)
        .menuOrder(.fixed)
        .padding(.leading, -12)
        .padding(.trailing, trailingPadding)
        .buttonStyle(.borderless)
        .tint(color)
    }
}

public struct SharedSongRow<Leading: View>: View {
    public let song: LibrarySongItem
    public var subtitle: String? = nil
    public var appearance = SongRowAppearance()
    public var moreAccessibilityLabel: String = "更多"
    public var playButtonAccessibilityIdentifier: String? = nil
    public var onRemoveFromPlaylist: (() -> Void)? = nil
    public let play: () -> Void
    @ViewBuilder public let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var textSize

    public var body: some View {
        let displaySubtitle = song.unavailabilityReason ?? subtitle ?? song.artist
        let titleLimit = textSize.isAccessibilitySize ? nil : appearance.titleLineLimit
        let subtitleLimit = textSize.isAccessibilitySize ? nil : appearance.subtitleLineLimit

        HStack(spacing: 12) {
            playButton {
                HStack(spacing: 12) {
                    leading()
                        .overlay(alignment: .leading) { favoriteMark }
                    VStack(alignment: .leading, spacing: appearance.titleSubtitleSpacing) {
                        Text(song.title)
                            .font(appearance.titleFont)
                            .foregroundStyle(song.unavailabilityReason == nil ? .primary : .secondary)
                            .lineLimit(titleLimit)
                        subtitleView(displaySubtitle)
                            .font(appearance.subtitleFont)
                            .lineLimit(subtitleLimit)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            SongDownloadStatus(
                song: song,
                showsImported: false,
                secondaryStyle: appearance.downloadStatusStyle ?? AnyShapeStyle(Color.primary.opacity(0.26))
            )
            TrackMoreButton(
                song: song,
                color: appearance.moreColor,
                font: appearance.moreFont,
                accessibilityLabel: moreAccessibilityLabel,
                trailingPadding: appearance.moreTrailingPadding,
                onRemoveFromPlaylist: onRemoveFromPlaylist
            )
        }
        .frame(minHeight: appearance.minHeight > 0 ? appearance.minHeight : nil)
    }

    @ViewBuilder private var favoriteMark: some View {
        FavoriteMark(
            isFavorite: song.isFavorite,
            color: appearance.favoriteMarkColor,
            leadingOffset: appearance.favoriteMarkOffset
        )
    }

    @ViewBuilder private func subtitleView(_ text: String) -> some View {
        Text(text).foregroundStyle(appearance.subtitleColor)
    }

    @ViewBuilder private func playButton<Content: View>(@ViewBuilder label: () -> Content) -> some View {
        let button = Group {
            if appearance.usesPlainButtonStyle {
                Button(action: play, label: label).buttonStyle(.plain)
            } else {
                Button(action: play, label: label).buttonStyle(.automatic)
            }
        }
        let label = CollectionTrackUI.songAccessibilityLabel(for: song, subtitle: subtitle)
        if let playButtonAccessibilityIdentifier {
            button.accessibilityLabel(label).accessibilityIdentifier(playButtonAccessibilityIdentifier)
        } else {
            button.accessibilityLabel(label)
        }
    }
}

public enum SongSwipeMode {
    case standard(animateFavoriteRemoval: Bool = false)
    case editablePlaylist(remove: () -> Void)
    case libraryDownloads
}

extension View {
    public func songListRow(
        _ song: LibrarySongItem,
        mode: SongSwipeMode = .standard(),
        swipeBackground: Color? = Color(.systemBackground),
        colorScheme: ColorScheme? = nil
    ) -> some View {
        modifier(SongListRowModifier(
            song: song,
            mode: mode,
            swipeBackground: swipeBackground,
            explicitColorScheme: colorScheme
        ))
    }
}

private struct SongListRowModifier: ViewModifier {
    let song: LibrarySongItem
    let mode: SongSwipeMode
    let swipeBackground: Color?
    let explicitColorScheme: ColorScheme?
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.colorScheme) private var environmentColorScheme

    private var removeFromPlaylistAction: (() -> Void)? {
        if case .editablePlaylist(let remove) = mode { return remove }
        return nil
    }

    func body(content: Content) -> some View {
        let trailingItems = OnlineSongTrailingSwipe.actions(
            isFavorite: song.isFavorite,
            downloadState: downloads?.state(of: song.id),
            canDownload: downloads?.isDownloadable(song) == true
        )

        let base = content
            .songContextMenu(song, onRemoveFromPlaylist: removeFromPlaylistAction)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button("插播", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    songActions.playNext(song)
                    if !songActions.defersQueueNotice { songActions.notify(.playingNext) }
                }
                .labelStyle(.iconOnly)
                .tint(.indigo)
                Button("添加到队列", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    songActions.playLater(song)
                    if !songActions.defersQueueNotice { songActions.notify(.addedToQueue) }
                }
                .labelStyle(.iconOnly)
                .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                trailingSwipeButtons(items: trailingItems)
            }

        if let swipeBackground {
            base.background(
                SwipedSongBackground(
                    color: UIColor(swipeBackground),
                    colorScheme: explicitColorScheme ?? environmentColorScheme
                )
                .allowsHitTesting(false)
            )
        } else {
            base
        }
    }

    @ViewBuilder private func trailingSwipeButtons(items: [OnlineSongTrailingSwipe]) -> some View {
        switch mode {
        case .standard(let animateRemoval):
            OnlineSongTrailingSwipeButtons(song: song, items: items, animateRemoval: animateRemoval)
        case .editablePlaylist(let remove):
            Button("移除", systemImage: "minus.circle.fill") {
                CenteredActionSheet.confirmRemoveFromPlaylist(remove)
            }
            .labelStyle(.iconOnly)
            .tint(.red)
        case .libraryDownloads:
            if downloads?.state(of: song.id)?.isActive == true {
                Button("停止下载", systemImage: "stop.fill") {
                    LibraryHaptics.impact()
                    downloads?.stop([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            } else if downloads?.canRemove(song) == true {
                Button("移除下载", systemImage: "xmark.circle") {
                    downloads?.requestRemoval([song])
                }
                .labelStyle(.iconOnly)
                .tint(.red)
            } else if downloads?.isDownloadable(song) == true {
                Button("下载", systemImage: "arrow.down") {
                    LibraryHaptics.impact()
                    downloads?.download([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            } else {
                OnlineSongTrailingSwipeButtons(
                    song: song,
                    items: song.isFavorite ? [.removeFromLiked] : [.like],
                    animateRemoval: false
                )
            }
        }
    }
}

public struct SwipedSongBackground: UIViewRepresentable {
    public let color: UIColor
    public let colorScheme: ColorScheme

    public func makeUIView(context: Context) -> BackgroundProbe {
        let view = BackgroundProbe()
        view.isUserInteractionEnabled = false
        return view
    }

    public func updateUIView(_ view: BackgroundProbe, context: Context) {
        view.pageColor = color
        view.isDark = colorScheme == .dark
        view.attach()
    }

    public static func dismantleUIView(_ view: BackgroundProbe, coordinator: ()) {
        view.detach()
    }

    public final class BackgroundProbe: UIView {
        public var pageColor: UIColor = .systemBackground
        public var isDark = false
        private weak var cell: UICollectionViewCell?
        private var previousHandler: UICollectionViewCell.ConfigurationUpdateHandler?
        private var previousBackground: UIBackgroundConfiguration?
        private var previousAutomaticUpdates = true

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach() } else { detach() }
        }

        public func attach() {
            var ancestor = superview
            while let view = ancestor, !(view is UICollectionViewCell) { ancestor = view.superview }
            guard let target = ancestor as? UICollectionViewCell else { return }
            if cell !== target {
                detach()
                cell = target
                previousHandler = target.configurationUpdateHandler
                previousBackground = target.backgroundConfiguration
                previousAutomaticUpdates = target.automaticallyUpdatesBackgroundConfiguration
            }
            target.automaticallyUpdatesBackgroundConfiguration = false
            target.configurationUpdateHandler = { [weak self] cell, state in
                guard let self else { return }
                self.previousHandler?(cell, state)
                self.apply(to: cell, state: state)
            }
            apply(to: target, state: target.configurationState)
        }

        private func apply(to cell: UICollectionViewCell, state: UICellConfigurationState) {
            let traits = cell.traitCollection.modifyingTraits {
                $0.userInterfaceStyle = isDark ? .dark : .light
            }
            let base = pageColor.resolvedColor(with: traits)
            let swiped = CollectionPagePalette(background: base, isDark: isDark).swiped
            var background = cell.defaultBackgroundConfiguration().updated(for: state)
            if state.isSwiped { background.backgroundColor = swiped }
            else if !state.isHighlighted && !state.isSelected { background.backgroundColor = base }
            background.cornerRadius = state.isSwiped ? 26 : 0
            cell.backgroundConfiguration = background
        }

        public func detach() {
            guard let cell else { return }
            cell.configurationUpdateHandler = previousHandler
            cell.automaticallyUpdatesBackgroundConfiguration = previousAutomaticUpdates
            cell.backgroundConfiguration = previousBackground
            self.cell = nil
            previousHandler = nil
            previousBackground = nil
        }
    }
}
