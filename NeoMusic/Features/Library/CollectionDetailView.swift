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
    let artwork: Artwork
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.libraryNavigationChrome) private var navigationChrome
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    @State private var query = ""
    @State private var isConfirmingAlbumDeletion = false

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
    private var albumColorScheme: ColorScheme? { detail.kind == .album ? detail.albumBackdrop?.colorScheme : nil }
    private var pageBackground: Color {
        if detail.kind == .album, let albumBackdrop = detail.albumBackdrop { return albumBackdrop.color }
        return usesFavoritesBackground ? Artwork.favoritesBackground : Color(.systemBackground)
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
        .onChange(of: albumColorScheme, initial: true) { _, scheme in navigationChrome?.setColorScheme(scheme) }
        .libraryTitleDisplayMode(.inline)
        .librarySearchable(text: $query, prompt: "搜索", enabled: detail.kind != .album)
        .toolbar { detailToolbar }
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
                CollectionActions(detail: detail, albumBackground: detail.albumBackdrop?.color)
                    .padding(.top, 13.5 + 4.0 / 3).padding(.bottom, 23 + 2.0 / 3)
            }.frame(maxWidth: .infinity)),
            footer: AnyView(Text(summary).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)),
            pageColor: UIColor(pageBackground), scheme: albumColorScheme ?? colorScheme)
            // Let the actual scrolling content continue beneath the system bars.
            // UIKit's adjustedContentInset keeps the resting header and final row clear.
            .ignoresSafeArea(.container, edges: .vertical)
    }

    private var legacyList: some View {
        List {
            Section {
                VStack(spacing: 0) {
                    header
                    CollectionActions(detail: detail, albumBackground: detail.kind == .album ? detail.albumBackdrop?.color : nil)
                        .padding(.top, 13.5 + 4.0 / 3)
                        .padding(.bottom, 23 + 2.0 / 3)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(detail.songs.isEmpty ? .hidden : .visible, edges: .bottom)
                .listRowSeparatorTint(pageSeparatorTint)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 20 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] - 20 }
                trackList
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowSeparatorTint(pageSeparatorTint)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
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
                .frame(width: 266, height: 266)
                .padding(.top, 13)
                .padding(.bottom, 23)
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
            if let subtitle = detail.subtitle {
                Text(subtitle).font(.title3)
                    .padding(.top, 4)
            }
            if let caption = detail.caption {
                // 实测 Apple Music：年份约 11pt 粗体。
                Text(caption)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5 - 2.0 / 3)
            }
        }
        .lineLimit(2)
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

    private var trackList: some View {
        ForEach(Array(detail.songs.enumerated()), id: \.element.id) { index, song in
            PlaylistTrackRow(song: song) { songActions.play(detail.songs, index, detail.title) }
                .songContextMenu(song)
                .modifier(FavoritesSwipeActions(enabled: detail.route == .playlist("favorites"), song: song))
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .background(SwipedSongBackground(color: UIColor(pageBackground),
                                             colorScheme: albumColorScheme ?? colorScheme).allowsHitTesting(false))
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparatorTint(pageSeparatorTint)
            .alignmentGuide(.listRowSeparatorLeading) { _ in
                index == detail.songs.count - 1 ? 0 : (detail.kind == .album ? 31 : 60)
            }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        }
    }

    private var summary: String {
        let minutes = detail.songs.reduce(0) { $0 + $1.duration } / 60
        return "\(detail.songs.count)首歌，\(minutes)分钟"
    }
}

/// 滚动距离只留在星标上。播放列表其余行不因每个像素重算。
private struct FavoritesHeaderStar: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var scrollDistance: CGFloat = 0

    var body: some View {
        // 按 Apple Music 录屏实测：星标宽 237pt，顶端比封面区域高 33pt；
        // 上滑时只随内容移动约 76%，滚过约 110pt 后逐渐虚化、变淡。
        let distance = max(scrollDistance, 0)
        Color.clear.overlay(alignment: .top) {
            Image(systemName: "star.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 241)
                .foregroundStyle(Artwork.favoritesRed)
                .scaleEffect(reducesMotion ? 1 : 1 + max(-scrollDistance, 0) / 266, anchor: .bottom)
                .blur(radius: max(distance - 110, 0) * 0.15)
                .opacity(1 - min(max(distance - 130, 0) / 360, 1))
                .offset(y: -33 + distance * 0.24)
                .accessibilityHidden(true)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, distance in
            scrollDistance = distance
        }
    }
}

/// “喜爱歌曲”沿用系统侧滑样式；其他详情页不受影响。
private struct FavoritesSwipeActions: ViewModifier {
    let enabled: Bool
    let song: LibrarySongItem
    @Environment(\.songMenuActions) private var actions

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .leading) {
                    Button("插播", systemImage: "text.line.first.and.arrowtriangle.forward") { actions.playNext(song) }
                        .labelStyle(.iconOnly)
                        .tint(.indigo)
                }
                .swipeActions(edge: .trailing) {
                    Button("从喜欢歌曲移除", systemImage: "trash") {
                        CenteredActionSheet.confirmRemoveFromLiked {
                            withAnimation { actions.removeFromFavorites(song) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .tint(.red)
                }
        } else {
            content
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
    @State private var actionFeedback = 0

    private var canPlay: Bool { detail.route != nil && !detail.songs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 14) {
            circleButton("随机播放", systemImage: "shuffle") {
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
                // 实测 Apple Music：三角约 14×15pt，与文字间距约 7pt。
                HStack(spacing: 5.5) {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                    Text("播放")
                }
                .font(.headline)
                .foregroundStyle(albumBackground ?? Color(.systemBackground))
                .frame(width: 160, height: 48)
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

/// 播放列表曲目行：播放与菜单平级，侧滑背景及形状由 List 管理。
private struct PlaylistTrackRow: View {
    let song: LibrarySongItem
    let play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    PlaylistSongArtwork(song: song, cornerRadius: 6)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .leading) { FavoriteMark(isFavorite: song.isFavorite) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.callout).foregroundStyle(song.unavailabilityReason == nil ? .primary : .secondary)
                        Text(song.unavailabilityReason ?? song.artist)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.automatic)
            SongDownloadStatus(song: song, showsImported: false)
            TrackMoreButton(song: song)
        }
        .frame(minHeight: 56)
    }
}

struct TrackMoreButton: View {
    let song: LibrarySongItem
    var color = Color.primary

    var body: some View {
        Menu { SongMenuContents(song: song) } label: {
            Label("更多", systemImage: "ellipsis")
        }
        .menuOrder(.fixed)
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .foregroundStyle(color)
        .frame(width: 42, height: 44)
        .padding(.trailing, -7)
        .buttonStyle(.borderless)
        .tint(.secondary)
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
private struct SwipedSongBackground: UIViewRepresentable {
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
            let traits = UITraitCollection(traitsFrom: [cell.traitCollection,
                UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)])
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
                result.bottomSeparatorVisibility = model?.songs.isEmpty == false ? .visible : .hidden
                result.bottomSeparatorInsets = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
            case .song(let id):
                result.bottomSeparatorVisibility = .visible
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

    func update(_ model: NativeAlbumSongList, environment: EnvironmentValues) {
        loadViewIfNeeded()
        let previous = songsByID
        let previousScheme = self.model?.scheme
        let environmentChanged = self.environment.scenePhase != environment.scenePhase || self.environment.dynamicTypeSize != environment.dynamicTypeSize
        self.model = model
        self.environment = environment
        songsByID = Dictionary(model.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        overrideUserInterfaceStyle = model.scheme == .dark ? .dark : .light
        collectionView.backgroundColor = model.pageColor
        headerHost.rootView = AnyView(hosted(model.header))
        let oldIDs = source.snapshot().itemIdentifiers
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([.header] + model.songs.map { .song($0.id) } + [.footer])
        let changed = model.songs.filter { song in
            guard let old = previous[song.id] else { return false }
            return old.title != song.title || old.trackNumber != song.trackNumber || old.isFavorite != song.isFavorite || previousScheme != model.scheme || environmentChanged
        }.map { Item.song($0.id) }
        snapshot.reconfigureItems(changed + (oldIDs.isEmpty ? [] : [.header, .footer]))
        source.apply(snapshot, animatingDifferences: !oldIDs.isEmpty)
    }

    private func configure(_ cell: AlbumSelectionCell, id: String) {
        guard let song = songsByID[id] else { return }
        cell.contentConfiguration = UIHostingConfiguration {
            hosted(NativeAlbumRowContent(song: song))
                .allowsHitTesting(false)
        }.margins(.all, 0).margins(.leading, 20).margins(.trailing, 9)
        cell.more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menu(for: id).children ?? [])
        }])
        cell.accessibilityLabel = song.title
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
        let downloaded = downloads?.state(of: id) == .downloaded
        var sections = environment.songMenuActions.albumTrackSections(for: song, isDownloaded: downloaded,
            download: { downloads?.download([song]) }, removeDownload: { downloads?.requestRemoval([song]) },
            notify: environment.collectionMenuActions.notify)
        if !song.artistReferences.isEmpty {
            let open = environment.openLibraryRoute
            sections.append(song.artistReferences.map { artist in
                LibraryMenuItem(title: artist.name, systemImage: "music.microphone") { open(.artist(artist.id)) }
            })
        }
        return sections.nativeMenu(firstSectionIsRow: !downloaded)
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let song = song(at: path) else { return nil }
        return UIContextMenuConfiguration(identifier: song.id as NSString) {
            let lines = [song.title, song.artist, song.album]
            let size = MenuPreviewCard.size(for: lines)
            let host = UIHostingController(rootView: MenuPreviewCard(artwork: song.artwork, lines: lines).frame(width: size.width, height: size.height))
            host.safeAreaRegions = []; host.preferredContentSize = size; host.view.backgroundColor = .clear
            return host
        } actionProvider: { [weak self] _ in self?.menu(for: song.id) }
    }

    private func leadingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = song(at: indexPath) else { return nil }
        let actions = environment.songMenuActions
        let notify = environment.collectionMenuActions.notify
        let later = UIContextualAction(style: .normal, title: nil) { _, _, done in
            actions.playLater(song); notify(.addedToQueue); done(true)
        }
        later.image = UIImage(systemName: "text.line.last.and.arrowtriangle.forward"); later.backgroundColor = .systemOrange
        later.image?.accessibilityLabel = "添加到队列"
        let next = UIContextualAction(style: .normal, title: nil) { _, _, done in
            actions.playNext(song); notify(.playingNext); done(true)
        }
        next.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward"); next.backgroundColor = .systemIndigo
        next.image?.accessibilityLabel = "插播"
        return UISwipeActionsConfiguration(actions: [later, next])
    }
    private func trailingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = song(at: indexPath), song.isOnline else { return nil }
        let chosen = OnlineSongTrailingSwipe.actions(isFavorite: song.isFavorite,
                                                     downloadState: environment.libraryDownloads?.state(of: song.id),
                                                     canDownload: environment.libraryDownloads?.isDownloadable(song) == true)
        let items = chosen.map { swipeAction($0, song: song) }
        guard !items.isEmpty else { return nil }
        let configuration = UISwipeActionsConfiguration(actions: items)
        configuration.performsFirstActionWithFullSwipe = chosen.first != .removeFromLiked
        return configuration
    }

    private func swipeAction(_ action: OnlineSongTrailingSwipe, song: LibrarySongItem) -> UIContextualAction {
        switch action {
        case .like:
            let like = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
                done(true)
                LibraryHaptics.impact()
                self?.environment.songMenuActions.toggleFavorite(song)
            }
            like.image = UIImage(systemName: "heart.fill"); like.backgroundColor = .systemPink
            like.image?.accessibilityLabel = "喜欢"
            return like
        case .download, .stopDownload:
            let active = action == .stopDownload
            let download = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
                if active { self?.environment.libraryDownloads?.stop([song]) }
                else { self?.environment.libraryDownloads?.download([song]) }
                done(true)
            }
            download.image = UIImage(systemName: active ? "stop.fill" : "arrow.down"); download.backgroundColor = .systemBlue
            download.image?.accessibilityLabel = active ? "停止下载" : "下载"
            return download
        case .removeFromLiked:
            let remove = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
                done(true)
                self?.confirmRemoveFromLiked(song)
            }
            remove.image = UIImage(systemName: "trash"); remove.backgroundColor = .systemRed
            remove.image?.accessibilityLabel = "从喜欢歌曲移除"
            return remove
        }
    }

    private func confirmRemoveFromLiked(_ song: LibrarySongItem) {
        CenteredActionSheet.confirmRemoveFromLiked { [weak self] in
            self?.environment.songMenuActions.removeFromFavorites(song)
        }
    }

}

private struct NativeAlbumRowContent: View {
    let song: LibrarySongItem
    @Environment(\.libraryDownloads) private var downloads
    var body: some View {
        HStack(spacing: 9) {
            AlbumSongPosition(song: song)
            Text(song.title).font(.callout).foregroundStyle(.primary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            SongDownloadStatus(song: song)
        }
        .frame(minHeight: 52 + 1.0 / 3)
    }
}

private final class AlbumSelectionCell: UICollectionViewListCell {
    let more = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false
        more.frame = CGRect(x: 0, y: 0, width: 30, height: 44)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        more.tintColor = .secondaryLabel
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "更多"
        accessories = [.customView(configuration: .init(customView: more, placement: .trailing(),
            reservedLayoutWidth: .custom(30), maintainsFixedSize: true))]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        // Match the approved D prototype: UIKit owns highlighting and swipe geometry.
        // A translucent fill preserves the overlap instead of preblending the page color.
        var background = defaultBackgroundConfiguration().updated(for: state)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let overlay: UIColor = isDark ? .white : .black
        if state.isSwiped {
            background.backgroundColor = overlay.withAlphaComponent(0.06)
        } else if state.isSelected {
            background.backgroundColor = overlay.withAlphaComponent(isDark ? 0.10 : 0.06)
        } else {
            background.backgroundColor = .clear
        }
        background.cornerRadius = state.isSwiped ? 26 : 0
        backgroundConfiguration = background
    }
}
