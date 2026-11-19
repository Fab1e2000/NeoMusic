import SwiftUI
import UIKit

extension Color {
    /// Computes the solid ±128 channel-offset secondary color on top of `background`
    /// for controls (such as SwiftUI `Menu`) whose isolated rendering layer breaks `.blendMode`.
    static func secondaryContentColor(on background: Color, colorScheme: ColorScheme) -> Color {
        CollectionPagePalette(background: UIColor(background), isDark: colorScheme == .dark).secondaryColor
    }
}

struct SongRowAppearance {
    var titleFont: Font = .callout
    var subtitleFont: Font = .footnote
    var subtitleColor: Color = .secondary
    var titleSubtitleSpacing: CGFloat = 2
    var titleLineLimit: Int? = 1
    var subtitleLineLimit: Int? = 1
    var moreColor: Color = .primary
    var moreFont: Font = .body.weight(.semibold)
    var moreTrailingPadding: CGFloat = -7
    var favoriteMarkColor: Color = .secondary
    var favoriteMarkOffset: CGFloat = -14.5
    var downloadStatusStyle: AnyShapeStyle? = nil
    var minHeight: CGFloat = 56
    var usesPlainButtonStyle = false
}

struct TrackMoreButton: View {
    let song: LibrarySongItem
    var color: Color = .primary
    var font: Font = .body.weight(.semibold)
    var accessibilityLabel: String = "更多"
    var trailingPadding: CGFloat = -7
    var onRemoveFromPlaylist: (() -> Void)? = nil

    var body: some View {
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

/// 跨页面共用的歌曲行组件，统一左侧槽位、喜爱星标、下载状态与 44×44pt 更多按钮。
struct SharedSongRow<Leading: View>: View {
    let song: LibrarySongItem
    var subtitle: String? = nil
    var appearance = SongRowAppearance()
    var moreAccessibilityLabel: String = "更多"
    var playButtonAccessibilityIdentifier: String? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    let play: () -> Void
    @ViewBuilder let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
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
        if let playButtonAccessibilityIdentifier {
            button.accessibilityIdentifier(playButtonAccessibilityIdentifier)
        } else {
            button
        }
    }
}

enum SongSwipeMode {
    case standard(animateFavoriteRemoval: Bool = false)
    case editablePlaylist(remove: () -> Void)
    case libraryDownloads
}

extension View {
    /// 统一为列表歌曲行附加长按菜单、右滑（插播 + 添加到队列）、左滑手势及原生侧滑胶囊背景。
    func songListRow(
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
