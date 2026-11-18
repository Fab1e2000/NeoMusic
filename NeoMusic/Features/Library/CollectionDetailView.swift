import SwiftUI
import UIKit

/// 专辑或播放列表详情页的展示数据。
struct CollectionDetail {
    enum Kind { case album, playlist }

    let kind: Kind
    let title: String
    /// 专辑艺人；播放列表没有时省略。
    var subtitle: String?
    /// 专辑的发行年份或播放列表的更新时间。
    var caption: String?
    @ArtworkResource var artwork: Artwork
    /// 页面底色，取自封面主色。
    let tint: Color
    /// Prepared from the displayed artwork before the library publishes this album.
    var albumBackdrop: AlbumArtworkBackdrop? = nil
    var isFavorite = false
    var isPinned = false
    let songs: [LibrarySongItem]
    /// 菜单操作作用的对象。
    var route: LibraryRoute?
}

/// 专辑与播放列表详情：封面取色铺底，封面、标题、操作按钮与曲目列表。布局对照 Apple Music。
struct CollectionDetailView: View {
    let detail: CollectionDetail
    var hasMoreSongs: Bool = false
    var totalSongCount: Int? = nil
    var onReachedEnd: (() -> Void)? = nil
    var onPrepareCompleteCollection: (() async -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.libraryNavigationChrome) private var navigationChrome
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var query = ""
    @State private var isConfirmingAlbumDeletion = false
    @State private var favoritesScrollDistance = PlaylistScrollDistance()
    @State private var searchProjection = AsyncListProjection<SearchProjectionInput, [LibrarySongItem]>()

    private struct SearchProjectionInput: Equatable {
        let songs: [LibrarySongItem]
        let query: String

        func calculate() -> [LibrarySongItem] {
            guard !query.isEmpty else { return songs }
            return songs.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
                    || $0.album.localizedStandardContains(query)
            }
        }
    }

    private struct SearchEntry: Sendable {
        let index: Int
        let title: String
        let artist: String
        let album: String
    }

    private static func searchFastPath(_ input: SearchProjectionInput) -> [LibrarySongItem]? {
        (input.query.isEmpty || input.songs.count <= 120) ? input.calculate() : nil
    }

    private var displayedSongs: [LibrarySongItem] {
        guard detail.kind != .album else { return detail.songs }
        let input = SearchProjectionInput(songs: detail.songs, query: query)
        return searchProjection.currentValue(for: input, fastPath: Self.searchFastPath, placeholder: { _ in [] })
    }

    private var isFavorites: Bool {
        if case .favorites = detail.artwork { return true }
        return false
    }

    private var usesFavoritesBackground: Bool { isFavorites && colorScheme == .light }
    private var matchingPreview: LibraryNavigationPreview? {
        guard let navigationPreview, navigationPreview.route == detail.route else { return nil }
        return navigationPreview
    }
    private var displayedArtwork: Artwork {
        if case .missing = detail.artwork, let matchingPreview { return matchingPreview.artwork }
        return detail.artwork
    }
    private var albumBackdrop: AlbumArtworkBackdrop? {
        detail.kind == .album ? detail.albumBackdrop ?? matchingPreview?.albumBackdrop : nil
    }
    private var albumColorScheme: ColorScheme? { albumBackdrop?.colorScheme }
    private var pageBackground: Color {
        if let albumBackdrop { return albumBackdrop.color }
        return usesFavoritesBackground ? Artwork.favoritesBackground : Color(.systemBackground)
    }

    private var resolvedSecondaryColor: Color {
        Color.secondaryContentColor(on: pageBackground, colorScheme: albumColorScheme ?? colorScheme)
    }

    /// Translucent system separators blend with the artwork-derived page color.
    /// Use the same appearance as text and controls, rather than the device setting alone.
    private var pageSeparatorTint: Color {
        ((albumColorScheme ?? colorScheme) == .dark ? Color.white : Color.black).opacity(0.18)
    }

    var body: some View {
        Group {
            if detail.kind == .album { nativeAlbumList } else { legacyList }
        }
        .background(pageBackground)
        .environment(\.colorScheme, albumColorScheme ?? colorScheme)
        .toolbarColorScheme(albumColorScheme, for: .navigationBar)
        .onChange(of: albumBackdrop, initial: true) { _, backdrop in
            if detail.kind == .album { navigationChrome?.setAlbumBackdrop(backdrop) }
            else { navigationChrome?.setColorScheme(nil) }
        }
        .libraryTitleDisplayMode(.inline)
        .modifier(FavoritesTitleHidden(isHidden: isFavorites))
        .librarySearchable(text: $query, prompt: "搜索", enabled: detail.kind != .album)
        .toolbar { detailToolbar }
        .libraryRootAccountButton()
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("更多", systemImage: "ellipsis") {
                if let route = detail.route {
                    let item = LibraryShelfItem(id: detail.title, title: detail.title, artwork: detail.artwork, route: route,
                        isFavorite: detail.isFavorite, isPinned: detail.isPinned)
                    LibraryMenuContents(sections: toolbarActions.toolbarSections(for: item, route: route), firstSectionIsRow: detail.kind == .album)
                }
            }
            .menuOrder(.fixed)
            .alert("", isPresented: $isConfirmingAlbumDeletion) {
                Button("从资料库删除", role: .destructive) {
                    guard let route = detail.route else { return }
                    closeDetail()
                    withAnimation { collectionActions.delete(route) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(detail.route?.deletionMessage ?? "")
            }
        }
    }

    private var nativeAlbumList: some View {
        NativeAlbumSongList(songs: detail.songs, title: detail.title,
            header: AnyView(VStack(spacing: 0) {
                header
                CollectionActions(detail: detail, albumBackground: albumBackdrop?.color)
                    .padding(.top, 13.5 + 4.0 / 3).padding(.bottom, 23 + 2.0 / 3)
            }.frame(maxWidth: .infinity)),
            footer: AnyView(Text(summary).font(.subheadline).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)),
            pageColor: UIColor(pageBackground), scheme: albumColorScheme ?? colorScheme)
            // Let the actual scrolling content continue beneath the system bars.
            // UIKit's adjustedContentInset keeps the resting header and final row clear.
            .ignoresSafeArea(.container, edges: .vertical)
    }

    private struct CompleteCollectionSearchRequest: Equatable {
        let active: Bool
        let hasMore: Bool
    }

    private var legacyList: some View {
        let shownSongs = displayedSongs
        let footerText = (query.isEmpty && hasMoreSongs)
            ? "\(totalSongCount ?? shownSongs.count)首歌"
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
            scheme: albumColorScheme ?? colorScheme,
            rowCornerRadius: 6,
            headerSeparatorInset: 20,
            lastSongSeparatorLeading: 20,
            usePageBlendSecondaryColors: false,
            swipeMode: .standard(animateFavoriteRemoval: detail.route == .playlist("favorites")),
            scrollDistance: isFavorites ? favoritesScrollDistance : nil,
            onPlaySong: { _, index in songActions.play(shownSongs, index, detail.title) },
            onReachedEnd: (query.isEmpty && hasMoreSongs) ? onReachedEnd : nil
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .task(id: CompleteCollectionSearchRequest(active: !query.isEmpty, hasMore: hasMoreSongs)) {
            if !query.isEmpty && hasMoreSongs { await onPrepareCompleteCollection?() }
        }
        .task(id: SearchProjectionInput(songs: detail.songs, query: query)) {
            let input = SearchProjectionInput(songs: detail.songs, query: query)
            guard Self.searchFastPath(input) == nil else { return }
            let entries = input.songs.enumerated().map { index, song in
                SearchEntry(index: index, title: song.title, artist: song.artist, album: song.album)
            }
            let currentQuery = input.query
            await searchProjection.computeIfNeeded(
                for: input,
                fastPath: Self.searchFastPath,
                background: {
                    entries.filter {
                        $0.title.localizedStandardContains(currentQuery)
                            || $0.artist.localizedStandardContains(currentQuery)
                            || $0.album.localizedStandardContains(currentQuery)
                    }.map(\.index)
                },
                finish: { indices in indices.map { input.songs[$0] } }
            )
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
                            .accessibilityLabel("已喜爱")
                    }
                }
                .multilineTextAlignment(.center)
            }
            if let subtitle = detail.subtitle {
                Text(subtitle).font(.title3)
                    .padding(.top, 4)
            }
            if let caption = detail.caption {
                // 实测 Apple Music：年份约 11pt 粗体。
                Text(caption)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(detail.kind == .album ? .primary : .secondary)
                    .padding(.top, 5 - 2.0 / 3)
            }
        }
        .lineLimit(textSize.isAccessibilitySize ? nil : 2)
        .padding(.horizontal, 20)
    }

    /// “喜爱歌曲”的星标直接画在底色上，不显示封面边框与阴影。
    @ViewBuilder private var headerArtwork: some View {
        if case .favorites = detail.artwork {
            FavoritesHeaderStar()
        } else {
            ArtworkView(artwork: displayedArtwork,
                        contentID: matchingPreview?.contentID ?? detail.route.map { String(describing: $0) },
                        previewArtwork: matchingPreview?.artwork,
                        cornerRadius: 10, isZoomAlignmentTarget: detail.kind == .album)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        }
    }

    private var summary: String { summary(for: detail.songs) }

    private func summary(for songs: [LibrarySongItem]) -> String {
        let minutes = songs.reduce(0) { $0 + $1.duration } / 60
        return "\(songs.count)首歌，\(minutes)分钟"
    }
}

/// 喜爱歌曲用星标表示这一页，导航栏和内容里都不再放标题。
private struct FavoritesTitleHidden: ViewModifier {
    let isHidden: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isHidden { content.libraryNavigationTitle("") } else { content }
    }
}

/// 滚动距离只留在星标上。播放列表其余行不因每个像素重算。
private struct FavoritesHeaderStar: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.playlistScrollDistance) private var playlistScrollDistance
    @State private var scrollDistance: CGFloat = 0

    var body: some View {
        // 按 Apple Music 录屏实测：星标宽 237pt，顶端比封面区域高 33pt；
        // 上滑时只随内容移动约 76%，滚过约 110pt 后逐渐虚化、变淡。
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
        .accessibilityLabel("喜爱歌曲")
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, distance in
            if playlistScrollDistance == nil { scrollDistance = min(distance, 500) }
        }
    }
}

/// 详情页标题下的随机播放、播放与右侧附加操作。
/// 专辑右侧为下载按钮：↓、下载进度（中间为停止）、完成后为 ✓，与 Apple Music 一致。
private struct CollectionActions: View {
    let detail: CollectionDetail
    let albumBackground: Color?
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var actionFeedback = 0

    private var canPlay: Bool { detail.route != nil && !detail.songs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 14) {
            circleButton("随机播放", systemImage: "shuffle") {
                guard canPlay, let route = detail.route else { return }
                actions.play(route, true)
            }
            .disabled(!canPlay)
            Button {
                guard canPlay, let route = detail.route else { return }
                actions.play(route, false)
            } label: {
                // 实测 Apple Music：三角约 14×15pt，与文字间距约 7pt。
                HStack(spacing: 5.5) {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                    Text("播放")
                }
                .font(.headline)
                .foregroundStyle(albumBackground ?? Color(.systemBackground))
                .padding(.vertical, textSize.isAccessibilitySize ? 10 : 0)
                .frame(width: 160)
                .frame(minHeight: 48)
                .background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            switch detail.kind {
            case .album:
                if case .album(let id) = detail.route, id.hasPrefix("catalog:"), !detail.isFavorite {
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
            actionFeedback &+= 1
            actions.toggleFavorite(route)
        } label: {
            Image(systemName: detail.isFavorite ? "arrow.down" : "plus")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收藏专辑")
        .accessibilityIdentifier("album-collection-action")
    }

    private func circleButton(_ title: LocalizedStringKey, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(Color.primary.opacity(0.08), in: .circle)
            .buttonStyle(.plain)
    }
}

/// 下载完成的勾号。实测 Apple Music（相对按钮中心，pt）：起点 (-6.8, 1.3)、拐点 (-1.7, 7.7)、终点 (8, -6.3)，线宽约 2.2pt。
/// 逐帧计量：起笔点停留约 2 帧，随后快速画出并长时间减速，约 0.5 秒画完，四分之一时间时已画一半。
struct DrawnCheckmark: View {
    let animates: Bool
    @State private var progress: CGFloat = 1

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .frame(width: 48, height: 48)
            .onAppear {
                guard animates else { return }
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

/// 下载按钮中的整体进度：灰色轨道、白色进度弧，中间是停止方块。实测 Apple Music：圆环直径约 28pt。
struct DownloadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.primary)
                .frame(width: 10, height: 10)
        }
        .frame(width: 27, height: 27)
    }
}

extension Color {
    /// 底色较暗时，页面文字与控件改用浅色。
    var prefersLightContent: Bool {
        let resolved = resolve(in: EnvironmentValues())
        let luminance = 0.299 * resolved.red + 0.587 * resolved.green + 0.114 * resolved.blue
        return luminance < 0.55
    }
}


/// Configure the actual list cell so UIKit continues to own swipe state and geometry.
/// A SwiftUI listRowBackground replaces that background, so it is deliberately absent.
struct SwipedSongBackground: UIViewRepresentable {
    let color: UIColor
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> BackgroundProbe {
        let view = BackgroundProbe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BackgroundProbe, context: Context) {
        view.pageColor = color
        view.isDark = colorScheme == .dark
        view.attach()
    }

    static func dismantleUIView(_ view: BackgroundProbe, coordinator: ()) {
        view.detach()
    }

    final class BackgroundProbe: UIView {
        var pageColor: UIColor = .systemBackground
        var isDark = false
        private weak var cell: UICollectionViewCell?
        private var previousHandler: UICollectionViewCell.ConfigurationUpdateHandler?
        private var previousBackground: UIBackgroundConfiguration?
        private var previousAutomaticUpdates = true

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach() } else { detach() }
        }

        func attach() {
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
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let hasRGB = base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            // Blend 6% toward white on dark pages, toward black on light pages.
            let lift: CGFloat = isDark ? 0.06 : 0
            let swiped = hasRGB ? UIColor(red: red * 0.94 + lift, green: green * 0.94 + lift,
                                         blue: blue * 0.94 + lift, alpha: alpha) : base
            var background = cell.defaultBackgroundConfiguration().updated(for: state)
            if state.isSwiped { background.backgroundColor = swiped }
            else if !state.isHighlighted && !state.isSelected { background.backgroundColor = base }
            background.cornerRadius = state.isSwiped ? 26 : 0
            cell.backgroundConfiguration = background
        }

        func detach() {
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

/// UIKit owns touch highlighting, selection, context menus, swipe actions
/// and the adjoining separators, including the first and last song boundaries.
private struct NativeAlbumSongList: UIViewControllerRepresentable {
    let songs: [LibrarySongItem]
    let title: String
    let header: AnyView
    let footer: AnyView
    let pageColor: UIColor
    let scheme: ColorScheme

    func makeUIViewController(context: Context) -> AlbumSongsController { AlbumSongsController() }
    func updateUIViewController(_ controller: AlbumSongsController, context: Context) {
        controller.update(self, environment: context.environment)
    }
}

private final class AlbumSongsController: UICollectionViewController {
    private enum Item: Hashable {
        case header, song(String), footer
    }
    private var model: NativeAlbumSongList?
    private var environment = EnvironmentValues()
    private var songsByID: [String: LibrarySongItem] = [:]
    private var source: UICollectionViewDiffableDataSource<Int, Item>!
    // The album header shares its hosting environment with its controls.
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        // Deliver short taps promptly; only confirmed selection receives a visible fill.
        // UIKit still cancels content touches when a scroll or swipe takes over.
        collectionView.delaysContentTouches = false
        collectionView.register(AlbumSelectionCell.self, forCellWithReuseIdentifier: "song")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "header")
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "footer")
        addChild(headerHost)
        headerHost.safeAreaRegions = []
        headerHost.sizingOptions = .intrinsicContentSize
        headerHost.view.backgroundColor = .clear
        headerHost.view.translatesAutoresizingMaskIntoConstraints = false
        headerHost.didMove(toParent: self)
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.separatorConfiguration.color = UIColor { traits in
            (traits.userInterfaceStyle == .dark ? UIColor.white : .black).withAlphaComponent(0.18)
        }
        configuration.itemSeparatorHandler = { [weak self] path, separator in
            guard let self, let item = source?.itemIdentifier(for: path) else { return separator }
            var result = separator
            switch item {
            case .header:
                result.topSeparatorVisibility = .hidden
                result.bottomSeparatorVisibility = model?.songs.isEmpty == false ? .automatic : .hidden
                result.bottomSeparatorInsets = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
            case .song(let id):
                result.bottomSeparatorVisibility = .automatic
                result.bottomSeparatorInsets = .init(top: 0, leading: model?.songs.last?.id == id ? 20 : 51,
                                                     bottom: 0, trailing: 20)
            case .footer:
                result.bottomSeparatorVisibility = .hidden
            }
            return result
        }
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.leadingActions(at: path) }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingActions(at: path) }
        collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: configuration), animated: false)
        source = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { [weak self] collection, path, item in
            guard let self else { return nil }
            switch item {
            case .song(let id):
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "song", for: path) as! AlbumSelectionCell
                configure(cell, id: id)
                return cell
            case .header:
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "header", for: path) as! UICollectionViewListCell
                cell.backgroundConfiguration = .clear()
                if headerHost.view.superview !== cell.contentView {
                    cell.contentView.addSubview(headerHost.view)
                    NSLayoutConstraint.activate([
                        headerHost.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                        headerHost.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                        headerHost.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                        headerHost.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
                    ])
                }
                return cell
            case .footer:
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "footer", for: path) as! UICollectionViewListCell
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = UIHostingConfiguration {
                    hosted(model?.footer)
                }.margins(.all, 0)
                return cell
            }
        }
    }

    private func hosted<V: View>(_ content: V) -> some View {
        content
            .environment(\.songMenuActions, environment.songMenuActions)
            .environment(\.collectionMenuActions, environment.collectionMenuActions)
            .environment(\.libraryDownloads, environment.libraryDownloads)
            .environment(\.songRowPlayback, environment.songRowPlayback)
            .environment(\.colorScheme, model?.scheme ?? environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.artworkLoadAction, environment.artworkLoadAction)
            .environment(\.nativeArtworkSurfaceEnabled, true)
    }

    private var previousTitle: String?
    private var previousSummaryText: String?

    func update(_ model: NativeAlbumSongList, environment: EnvironmentValues) {
        loadViewIfNeeded()
        let previous = songsByID
        let previousScheme = self.model?.scheme
        let backgroundChanged = self.model?.pageColor != model.pageColor
        let environmentChanged = self.environment.scenePhase != environment.scenePhase
            || self.environment.dynamicTypeSize != environment.dynamicTypeSize
            || self.environment.songRowPlayback !== environment.songRowPlayback
            || self.environment.libraryDownloads !== environment.libraryDownloads
            || self.environment.songPlaybackIndicatorsActive != environment.songPlaybackIndicatorsActive
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion
        let schemeChanged = previousScheme != model.scheme
        let globalAppearanceChanged = schemeChanged || backgroundChanged || environmentChanged
        let previousLastID = self.model?.songs.last?.id

        self.model = model
        self.environment = environment
        songsByID = Dictionary(model.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if overrideUserInterfaceStyle != (model.scheme == .dark ? .dark : .light) {
            overrideUserInterfaceStyle = model.scheme == .dark ? .dark : .light
        }
        if collectionView.backgroundColor != model.pageColor {
            collectionView.backgroundColor = model.pageColor
        }
        headerHost.rootView = AnyView(hosted(model.header))

        let oldIDs = source.snapshot().itemIdentifiers
        let newIDs: [Item] = [.header] + model.songs.map { .song($0.id) } + [.footer]
        let isNewAppearance = oldIDs.isEmpty
        let lastID = model.songs.last?.id

        var reconfigured: [Item] = []
        if !isNewAppearance {
            if globalAppearanceChanged || previousTitle != model.title || oldIDs.count != newIDs.count {
                reconfigured.append(.header)
                reconfigured.append(.footer)
            }
            for song in model.songs {
                guard let old = previous[song.id] else { continue }
                let separatorChanged = (song.id == previousLastID) != (song.id == lastID)
                let metadataChanged = old.title != song.title
                    || old.artist != song.artist
                    || old.trackNumber != song.trackNumber
                    || old.isFavorite != song.isFavorite
                    || old.unavailabilityReason != song.unavailabilityReason
                if metadataChanged || globalAppearanceChanged || separatorChanged {
                    reconfigured.append(.song(song.id))
                }
            }
        }
        previousTitle = model.title
        guard oldIDs != newIDs || !reconfigured.isEmpty else { return }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs)
        if !reconfigured.isEmpty { snapshot.reconfigureItems(reconfigured) }
        let shouldAnimate = !isNewAppearance
            && oldIDs != newIDs
            && !collectionView.isDragging
            && !collectionView.isDecelerating
            && !environment.accessibilityReduceMotion
        source.apply(snapshot, animatingDifferences: shouldAnimate)
    }

    // The native accessory uses the same ±0.5 blend result against the opaque page.
    private var albumSecondaryColor: UIColor {
        CollectionTrackUI.solidSecondaryColor(
            on: model?.pageColor ?? .systemBackground,
            isDark: model?.scheme == .dark,
            traitCollection: traitCollection
        )
    }

    private func configure(_ cell: AlbumSelectionCell, id: String) {
        guard let song = songsByID[id] else { return }
        let secondary = albumSecondaryColor
        cell.more.tintColor = secondary
        cell.contentConfiguration = UIHostingConfiguration {
            hosted(NativeAlbumRowContent(song: song, secondary: Color(secondary)))
        }.margins(.all, 0).margins(.leading, 20).margins(.trailing, 2)
        cell.more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menu(for: id).children ?? [])
        }])
        cell.accessibilityLabel = CollectionTrackUI.songAccessibilityLabel(for: song)
        cell.accessibilityTraits.insert(.button)
        cell.setNeedsUpdateConfiguration()
    }

    private func song(at path: IndexPath) -> LibrarySongItem? {
        guard case .song(let id) = source.itemIdentifier(for: path) else { return nil }
        return songsByID[id]
    }
    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        song(at: indexPath) != nil
    }
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        song(at: indexPath) != nil
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let song = song(at: indexPath), let model,
              let index = model.songs.firstIndex(where: { $0.id == song.id }) else { return }
        environment.songMenuActions.play(model.songs, index, model.title)
        // Show native selection feedback only after UIKit has recognized a tap.
        collectionView.deselectItem(at: indexPath, animated: true)
    }

    private func menu(for id: String) -> UIMenu {
        guard let song = songsByID[id] else { return UIMenu(children: []) }
        let downloads = environment.libraryDownloads
        let open = environment.openLibraryRoute
        let sections = environment.songMenuActions.albumTrackSections(for: song,
            isDownloaded: downloads?.state(of: id) == .downloaded,
            download: { downloads?.download([song]) }, removeDownload: { downloads?.requestRemoval([song]) },
            notify: environment.collectionMenuActions.notify, open: { open($0) })
        return sections.nativeMenu(firstSectionIsRow: (sections.first?.count ?? 0) > 1)
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let song = song(at: path) else { return nil }
        return CollectionTrackUI.contextMenuConfiguration(for: song, traits: collectionView.traitCollection) { [weak self] in
            self?.menu(for: song.id) ?? UIMenu(children: [])
        }
    }

    private func leadingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = song(at: indexPath) else { return nil }
        return CollectionTrackUI.leadingSwipeConfiguration(
            for: song,
            songActions: environment.songMenuActions,
            notify: environment.collectionMenuActions.notify
        )
    }

    private func trailingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = song(at: indexPath) else { return nil }
        return CollectionTrackUI.trailingSwipeConfiguration(
            for: song,
            mode: .standard(animateFavoriteRemoval: false),
            downloads: environment.libraryDownloads,
            songActions: environment.songMenuActions,
            notify: environment.collectionMenuActions.notify
        )
    }

}

private struct NativeAlbumRowContent: View {
    let song: LibrarySongItem
    let secondary: Color
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        HStack(spacing: 9) {
            AlbumSongPosition(song: song, foreground: secondary)
            Text(song.title).font(.callout).foregroundStyle(.primary)
                .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            SongDownloadStatus(song: song, secondaryStyle: AnyShapeStyle(secondary))
        }
        .frame(minHeight: 52 + 1.0 / 3)
    }
}

final class AlbumSelectionCell: UICollectionViewListCell {
    let more = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false
        more.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        more.tintColor = .label
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "更多"
        accessories = [.customView(configuration: .init(customView: more, placement: .trailing(),
            reservedLayoutWidth: .custom(44), maintainsFixedSize: true))]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        // Match the approved D prototype: UIKit owns highlighting and swipe geometry.
        // A translucent fill preserves the overlap instead of preblending the page color.
        backgroundConfiguration = CollectionTrackUI.translucentCellBackground(for: self, state: state, traitCollection: traitCollection)
    }
}
