import FrontAMCore
import FrontAMNavigation
import SwiftUI
import UIKit

extension View {
    public func detailLoadingMask(awaitingDetail: Bool, pageColor: Color) -> some View {
        modifier(DetailLoadingMask(awaitingDetail: awaitingDetail, pageColor: pageColor))
    }
}

private struct DetailLoadingMask: ViewModifier {
    let awaitingDetail: Bool
    let pageColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!awaitingDetail)
            .accessibilityHidden(awaitingDetail)
            .overlay {
                // Keep the scroll view and any cover zoom target laid out beneath the color.
                pageColor.ignoresSafeArea()
                    .opacity(awaitingDetail ? 1 : 0)
                    .transaction(value: awaitingDetail) {
                        // Detail publication may disable animations for the content underneath.
                        $0.disablesAnimations = false
                        $0.animation = reduceMotion || awaitingDetail ? nil : .easeInOut
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

public struct CollectionDetail {
    public enum Kind { case album, playlist }

    public let kind: Kind
    public let title: String
    public var subtitle: String?
    public var caption: String?
    @ArtworkResource public var artwork: Artwork
    public let tint: Color
    public var albumBackdrop: AlbumArtworkBackdrop? = nil
    public var isFavorite = false
    public var isPinned = false
    public let songs: [LibrarySongItem]
    public var route: LibraryRoute?

    public var isOfflineArtistAlbum: Bool {
        if case .libraryArtistAlbum = route { return true }
        return false
    }

    public init(kind: Kind,
                title: String,
                subtitle: String? = nil,
                caption: String? = nil,
                artwork: Artwork,
                tint: Color,
                albumBackdrop: AlbumArtworkBackdrop? = nil,
                isFavorite: Bool = false,
                isPinned: Bool = false,
                songs: [LibrarySongItem],
                route: LibraryRoute? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.caption = caption
        self.artwork = artwork
        self.tint = tint
        self.albumBackdrop = albumBackdrop
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.songs = songs
        self.route = route
    }
}

public struct CollectionDetailView: View {
    public let detail: CollectionDetail?
    public var awaitingDetail = false
    public var loadError: String? = nil
    public var retry: (() -> Void)? = nil
    public var hasMoreSongs: Bool = false
    public var totalSongCount: Int? = nil
    public var onReachedEnd: (() -> Void)? = nil
    public var onPrepareCompleteCollection: (() async -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.artworkLoadAction) private var artworkLoader
    @Environment(\.libraryNavigationChrome) private var navigationChrome
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    @State private var preparedPreview: (LibraryNavigationPreview, AlbumArtworkBackdrop)?

    private var matchingPreview: LibraryNavigationPreview? {
        guard let navigationPreview, navigationPreview.route == detail?.route else { return nil }
        return navigationPreview
    }

    private var pendingPreview: LibraryNavigationPreview? {
        guard detail?.kind == .album, detail?.albumBackdrop == nil, let preview = matchingPreview,
              preview.albumBackdrop == nil, preview.backdropFile != nil else { return nil }
        return preview
    }

    private var albumBackdrop: AlbumArtworkBackdrop? {
        guard detail?.kind == .album else { return nil }
        if let color = detail?.albumBackdrop ?? matchingPreview?.albumBackdrop { return color }
        guard let preparedPreview, preparedPreview.0 == pendingPreview else { return nil }
        return preparedPreview.1
    }

    private func pageBackground(for backdrop: AlbumArtworkBackdrop?) -> Color {
        if let backdrop { return backdrop.color }
        if case .favorites? = detail?.artwork, colorScheme == .light { return Artwork.favoritesBackground }
        return Color(.systemBackground)
    }

    public var body: some View {
        let backdrop = albumBackdrop
        let pageColor = pageBackground(for: backdrop)
        ZStack {
            if let detail {
                CollectionDetailContent(detail: detail, awaitingDetail: awaitingDetail, pageBackground: pageColor,
                    albumBackdrop: backdrop, matchingPreview: matchingPreview, hasMoreSongs: hasMoreSongs,
                    totalSongCount: totalSongCount, onReachedEnd: onReachedEnd,
                    onPrepareCompleteCollection: onPrepareCompleteCollection)
            } else if let loadError {
                ContentUnavailableView {
                    Label(pageText("暂时无法读取"), systemImage: "exclamationmark.circle")
                } description: {
                    Text(loadError)
                } actions: {
                    if let retry { Button(pageText("重试"), action: retry) }
                }
            } else {
                Color.clear.ignoresSafeArea(.container, edges: .vertical)
            }
        }
        .background(pageColor)
        .detailLoadingMask(awaitingDetail: awaitingDetail, pageColor: pageColor)
        .environment(\.colorScheme, backdrop?.colorScheme ?? colorScheme)
        .toolbarColorScheme(backdrop?.colorScheme, for: .navigationBar)
        .task(id: pendingPreview) {
            guard let preview = pendingPreview, let file = preview.backdropFile,
                  let color = await artworkLoader.provider.loadBackdrop(for: file), !Task.isCancelled else { return }
            preparedPreview = (preview, color)
        }
        .onChange(of: backdrop, initial: true) { _, backdrop in
            if detail?.kind == .album { navigationChrome?.setBackdrop(color: backdrop?.uiColor, colorScheme: backdrop?.colorScheme) }
            else { navigationChrome?.setColorScheme(nil) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if detail != nil, let loadError {
                HStack {
                    Text(loadError).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if let retry { Button(pageText("重试"), action: retry) }
                }.padding().background(.regularMaterial)
            }
        }
    }

    public init(detail: CollectionDetail? = nil,
                awaitingDetail: Bool = false,
                loadError: String? = nil,
                retry: (() -> Void)? = nil,
                hasMoreSongs: Bool = false,
                totalSongCount: Int? = nil,
                onReachedEnd: (() -> Void)? = nil,
                onPrepareCompleteCollection: (() async -> Void)? = nil) {
        self.detail = detail
        self.awaitingDetail = awaitingDetail
        self.loadError = loadError
        self.retry = retry
        self.hasMoreSongs = hasMoreSongs
        self.totalSongCount = totalSongCount
        self.onReachedEnd = onReachedEnd
        self.onPrepareCompleteCollection = onPrepareCompleteCollection
    }
}

private struct CollectionDetailContent: View {
    let detail: CollectionDetail
    let awaitingDetail: Bool
    let pageBackground: Color
    let albumBackdrop: AlbumArtworkBackdrop?
    let matchingPreview: LibraryNavigationPreview?
    let hasMoreSongs: Bool
    let totalSongCount: Int?
    let onReachedEnd: (() -> Void)?
    let onPrepareCompleteCollection: (() async -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var query = ""
    @State private var isConfirmingAlbumDeletion = false
    @State private var favoritesScrollDistance = PlaylistScrollDistance()
    @State private var searchProjection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()

    private var displayedSongs: [LibrarySongItem] {
        let input = TrackFilterProjectionInput(tracks: detail.songs, query: query)
        return searchProjection.currentValue(for: input, fastPath: TrackFilterProjection.fastPath, placeholder: { _ in .empty }).tracks
    }

    private var isFavorites: Bool {
        if case .favorites = detail.artwork { return true }
        return false
    }

    private var displayedArtwork: Artwork {
        if case .missing = detail.artwork, let matchingPreview { return matchingPreview.artwork }
        return detail.artwork
    }

    private var palette: CollectionPagePalette {
        CollectionPagePalette(
            background: UIColor(pageBackground),
            isDark: colorScheme == .dark
        )
    }

    private var resolvedSecondaryColor: Color {
        palette.secondaryColor
    }

    var body: some View {
        Group {
            if detail.kind == .album { nativeAlbumList } else { legacyList }
        }
        .environment(\.collectionPagePalette, palette)
        .libraryTitleDisplayMode(.inline)
        .modifier(FavoritesTitleHidden(isHidden: isFavorites))
        .librarySearchable(text: $query, prompt: pageText("搜索"), enabled: detail.kind != .album)
        .toolbar { if !awaitingDetail && !detail.isOfflineArtistAlbum { detailToolbar } }
        .libraryRootAccountButton()
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu(pageText("更多"), systemImage: "ellipsis") {
                if let route = detail.route {
                    let item = LibraryShelfItem(id: detail.title, title: detail.title, artwork: detail.artwork, route: route,
                        isFavorite: detail.isFavorite, isPinned: detail.isPinned)
                    LibraryMenuContents(sections: toolbarActions.toolbarSections(for: item, route: route), firstSectionIsRow: detail.kind == .album)
                }
            }
            .menuOrder(.fixed)
            .alert("", isPresented: $isConfirmingAlbumDeletion) {
                Button(pageText("从资料库删除"), role: .destructive) {
                    guard let route = detail.route else { return }
                    closeDetail()
                    withAnimation(reducesMotion ? nil : .default) { collectionActions.delete(route) }
                }
                Button(pageText("取消"), role: .cancel) {}
            } message: {
                Text(detail.route?.deletionMessage ?? "")
            }
        }
    }

    private var nativeAlbumList: some View {
        NativePlaylistTrackList(songs: detail.songs, title: detail.title,
            header: AnyView(VStack(spacing: 0) {
                header
                CollectionActions(detail: detail, albumBackground: albumBackdrop?.color)
                    .padding(.top, 13.5 + 4.0 / 3).padding(.bottom, 23 + 2.0 / 3)
            }.frame(maxWidth: .infinity)),
            banner: nil, footer: AnyView(Text(summary).font(.subheadline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)),
            showsAddMusicRow: false, pageColor: UIColor(pageBackground), scheme: colorScheme,
            rowStyle: .trackNumber, headerSeparatorInset: 20,
            onPlaySong: { _, index in songActions.play(detail.songs, index, detail.title) })
            .ignoresSafeArea(.container, edges: .vertical)
    }

    private struct CompleteCollectionSearchRequest: Equatable {
        let active: Bool
        let hasMore: Bool
    }

    private var legacyList: some View {
        let shownSongs = displayedSongs
        let footerText = (query.isEmpty && hasMoreSongs)
            ? pageText("\(totalSongCount ?? shownSongs.count)首歌")
            : summary(for: shownSongs)
        return NativePlaylistTrackList(
            songs: shownSongs,
            title: detail.title,
            header: AnyView(VStack(spacing: 0) {
                header
                CollectionActions(detail: detail, albumBackground: detail.kind == .album ? detail.albumBackdrop?.color : nil)
                    .padding(.top, 13.5 + 4.0 / 3)
                    .padding(.bottom, 23 + 2.0 / 3)
            }.frame(maxWidth: .infinity)),
            banner: nil,
            footer: AnyView(Text(footerText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)),
            showsAddMusicRow: false,
            pageColor: UIColor(pageBackground),
            scheme: colorScheme,
            rowCornerRadius: 6,
            headerSeparatorInset: 20,
            lastSongSeparatorLeading: 20,
            swipeMode: .standard(animateFavoriteRemoval: detail.route == .playlist("favorites")),
            scrollDistance: isFavorites ? favoritesScrollDistance : nil,
            onPlaySong: { _, index in songActions.play(shownSongs, index, detail.title) },
            onReachedEnd: (query.isEmpty && hasMoreSongs) ? onReachedEnd : nil
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .task(id: CompleteCollectionSearchRequest(active: !query.isEmpty, hasMore: hasMoreSongs)) {
            if !query.isEmpty && hasMoreSongs { await onPrepareCompleteCollection?() }
        }
        .task(id: TrackFilterProjectionInput(tracks: detail.songs, query: query)) {
            await TrackFilterProjection.update(searchProjection, for: TrackFilterProjectionInput(tracks: detail.songs, query: query))
        }
    }

    private func closeDetail() {
        if let close = closeLibraryDetail.handler { close() } else { dismiss() }
    }

    private var toolbarActions: CollectionMenuActions {
        var actions = collectionActions
        if detail.kind == .album {
            actions.requestDelete = { _ in isConfirmingAlbumDeletion = true }
        }
        return actions
    }

    private var header: some View {
        VStack(spacing: 0) {
            headerArtwork
                .frame(width: textSize.isAccessibilitySize && !isFavorites ? 180 : 266,
                       height: textSize.isAccessibilitySize && !isFavorites ? 180 : 266)
                .padding(.top, 13)
                .padding(.bottom, 23)
            if !isFavorites {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(detail.title).font(.title2.weight(.bold))
                    if detail.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.footnote)
                            .baselineOffset(2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(pageText("已喜爱"))
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if let subtitle = detail.subtitle {
                Text(subtitle).font(.title3)
                    .padding(.top, 4)
            }
            if let caption = detail.caption {
                Text(caption)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(resolvedSecondaryColor)
                    .padding(.top, 5 - 2.0 / 3)
            }
        }
        .lineLimit(textSize.isAccessibilitySize ? nil : 2)
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var headerArtwork: some View {
        if case .favorites = detail.artwork {
            FavoritesHeaderStar()
        } else {
            ArtworkView(artwork: displayedArtwork,
                        contentID: matchingPreview?.contentID ?? detail.route.map { String(describing: $0) },
                        previewArtwork: matchingPreview?.artwork,
                        cornerRadius: DesignTokens.Radius.detailCover, isZoomAlignmentTarget: detail.kind == .album)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        }
    }

    private var summary: String { summary(for: detail.songs) }

    private func summary(for songs: [LibrarySongItem]) -> String {
        let minutes = songs.reduce(0) { $0 + $1.duration } / 60
        return pageText("\(songs.count)首歌，\(minutes)分钟")
    }
}

private struct FavoritesTitleHidden: ViewModifier {
    let isHidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isHidden { content.libraryNavigationTitle("") } else { content }
    }
}

private struct FavoritesHeaderStar: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.playlistScrollDistance) private var playlistScrollDistance
    @State private var scrollDistance: CGFloat = 0

    var body: some View {
        let currentDistance = playlistScrollDistance?.distance ?? scrollDistance
        let distance = min(max(currentDistance, 0), 490)
        let opacity = 1 - min(max(distance - 130, 0) / 360, 1)
        let blurRadius = reducesMotion ? 0 : min(max(distance - 110, 0) * 0.15, 57)
        Color.clear.overlay(alignment: .top) {
            if opacity > 0.001 {
                Image(systemName: "star.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 241)
                    .foregroundStyle(Artwork.favoritesRed)
                    .scaleEffect(reducesMotion ? 1 : 1 + max(-currentDistance, 0) / 266, anchor: .bottom)
                    .blur(radius: blurRadius)
                    .opacity(opacity)
                    .offset(y: -33 + (reducesMotion ? 0 : distance * 0.24))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pageText("喜爱歌曲"))
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, distance in
            if playlistScrollDistance == nil { scrollDistance = min(distance, 500) }
        }
    }
}

private struct CollectionActions: View {
    let detail: CollectionDetail
    let albumBackground: Color?
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.collectionPagePalette) private var palette
    @State private var actionFeedback = 0

    private var canPlay: Bool { detail.route != nil && !detail.songs.isEmpty }

    var body: some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 14))
            : AnyLayout(HStackLayout(spacing: 14))
        VStack(spacing: 0) {
            layout {
                circleButton(pageText("随机播放"), systemImage: "shuffle") {
                    guard canPlay, let route = detail.route else { return }
                    actionFeedback &+= 1
                    actions.play(route, true)
                }
                .disabled(!canPlay)
                Button {
                    guard canPlay, let route = detail.route else { return }
                    actionFeedback &+= 1
                    actions.play(route, false)
                } label: {
                    HStack(spacing: 5.5) {
                        Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                        Text(pageText("播放"))
                    }
                    .font(.headline)
                    .foregroundStyle(palette?.playForeground ?? albumBackground ?? Color(.systemBackground))
                    .padding(.vertical, textSize.isAccessibilitySize ? 10 : 0)
                    .padding(.horizontal, textSize.isAccessibilitySize ? 20 : 0)
                    .frame(width: textSize.isAccessibilitySize ? nil : 160)
                    .frame(minHeight: 48)
                    .background(Color.primary, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                switch detail.kind {
                case .album:
                    if detail.isOfflineArtistAlbum {
                        EmptyView()
                    } else if case .album(let id) = detail.route, actions.usesManagedCollectionActions(id), !detail.isFavorite {
                        albumCollectionButton
                    } else {
                        if let route = detail.route { CollectionDownloadButton(route: route, songs: detail.songs) }
                    }
                case .playlist:
                    if let route = detail.route { CollectionDownloadButton(route: route, songs: detail.songs) }
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: actionFeedback)
            if let route = detail.route { CollectionDownloadSummary(route: route) }
        }
    }

    private var albumCollectionButton: some View {
        Button {
            guard !detail.isFavorite, let route = detail.route else { return }
            actions.toggleFavorite(route)
        } label: {
            Image(systemName: detail.isFavorite ? "arrow.down" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(CollectionCircleButtonStyle())
        .accessibilityLabel(pageText("收藏专辑"))
        .accessibilityIdentifier("album-collection-action")
    }

    private func circleButton(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(CollectionCircleButtonStyle())
    }
}

public struct DrawnCheckmark: View {
    public let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var progress: CGFloat = 1

    public var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .frame(width: 48, height: 48)
            .onAppear {
                guard animates, !reducesMotion else { progress = 1; return }
                progress = 0
                withAnimation(.timingCurve(0.25, 0.6, 0.35, 1, duration: 0.5)) { progress = 1 }
            }
            .accessibilityHidden(true)
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: center.x - 6.8, y: center.y + 1.3))
        path.addLine(to: CGPoint(x: center.x - 1.7, y: center.y + 7.7))
        path.addLine(to: CGPoint(x: center.x + 8, y: center.y - 6.3))
        return path
    }
}

public struct DownloadProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    public let progress: Double

    public var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reducesMotion ? nil : .linear(duration: 0.1), value: progress)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.primary)
                .frame(width: 10, height: 10)
        }
        .frame(width: 27, height: 27)
    }
}
