import SwiftUI
import UIKit

extension View {
    func detailLoadingMask(awaitingDetail: Bool, pageColor: Color) -> some View {
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

struct CollectionDetail {
    enum Kind { case album, playlist }

    let kind: Kind
    let title: String
    var subtitle: String?
    var caption: String?
    @ArtworkResource var artwork: Artwork
    let tint: Color
    var albumBackdrop: AlbumArtworkBackdrop? = nil
    var isFavorite = false
    var isPinned = false
    let songs: [LibrarySongItem]
    var route: LibraryRoute?

    var isOfflineArtistAlbum: Bool {
        if case .libraryArtistAlbum = route { return true }
        return false
    }
}

struct CollectionDetailView: View {
    let detail: CollectionDetail?
    var awaitingDetail = false
    var loadError: String? = nil
    var retry: (() -> Void)? = nil
    var hasMoreSongs: Bool = false
    var totalSongCount: Int? = nil
    var onReachedEnd: (() -> Void)? = nil
    var onPrepareCompleteCollection: (() async -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
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

    var body: some View {
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
                    Label("暂时无法读取", systemImage: "exclamationmark.circle")
                } description: {
                    Text(loadError)
                } actions: {
                    if let retry { Button("重试", action: retry) }
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
                  let color = await LocalArtworkImages.loadBackdrop(for: file), !Task.isCancelled else { return }
            preparedPreview = (preview, color)
        }
        .onChange(of: backdrop, initial: true) { _, backdrop in
            if detail?.kind == .album { navigationChrome?.setAlbumBackdrop(backdrop) }
            else { navigationChrome?.setColorScheme(nil) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if detail != nil, let loadError {
                HStack {
                    Text(loadError).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if let retry { Button("重试", action: retry) }
                }.padding().background(.regularMaterial)
            }
        }
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
        .librarySearchable(text: $query, prompt: "搜索", enabled: detail.kind != .album)
        .toolbar { if !awaitingDetail && !detail.isOfflineArtistAlbum { detailToolbar } }
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
            pageColor: UIColor(pageBackground), scheme: colorScheme)
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
        .accessibilityLabel("喜爱歌曲")
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
                HStack(spacing: 5.5) {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                    Text("播放")
                }
                .font(.headline)
                .foregroundStyle(palette?.playForeground ?? albumBackground ?? Color(.systemBackground))
                .padding(.vertical, textSize.isAccessibilitySize ? 10 : 0)
                .frame(width: 160)
                .frame(minHeight: 48)
                .background(Color.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            switch detail.kind {
            case .album:
                if detail.isOfflineArtistAlbum {
                    EmptyView()
                } else if case .album(let id) = detail.route, id.hasPrefix("catalog:"), !detail.isFavorite {
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
        .accessibilityLabel("收藏专辑")
        .accessibilityIdentifier("album-collection-action")
    }

    private func circleButton(_ title: LocalizedStringKey, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(CollectionCircleButtonStyle())
    }
}

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
            let swiped = CollectionPagePalette(background: base, isDark: isDark).swiped
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
    private var listConfiguration: UICollectionLayoutListConfiguration?
    private var currentPalette: CollectionPagePalette {
        CollectionPagePalette(
            background: model?.pageColor ?? .systemBackground,
            isDark: model?.scheme == .dark
        )
    }
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
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
        configuration.separatorConfiguration.color = currentPalette.separator
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
        self.listConfiguration = configuration
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
            .environment(\.songPlaybackIndicatorsActive, environment.songPlaybackIndicatorsActive)
            .environment(\.colorScheme, model?.scheme ?? environment.colorScheme)
            .environment(\.collectionPagePalette, environment.collectionPagePalette)
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
        let playbackVisualsChanged = self.environment.scenePhase != environment.scenePhase
            || self.environment.songPlaybackIndicatorsActive != environment.songPlaybackIndicatorsActive
        let environmentChanged = self.environment.dynamicTypeSize != environment.dynamicTypeSize
            || self.environment.songRowPlayback !== environment.songRowPlayback
            || self.environment.libraryDownloads !== environment.libraryDownloads
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
        if (backgroundChanged || schemeChanged), var configuration = listConfiguration {
            configuration.separatorConfiguration.color = currentPalette.separator
            listConfiguration = configuration
            collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: configuration), animated: false)
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
            let activeSongID = environment.songRowPlayback?.hasCurrent == true ? environment.songRowPlayback?.current.id : nil
            for song in model.songs {
                guard let old = previous[song.id] else { continue }
                let separatorChanged = (song.id == previousLastID) != (song.id == lastID)
                let metadataChanged = old.title != song.title
                    || old.artist != song.artist
                    || old.trackNumber != song.trackNumber
                    || old.isFavorite != song.isFavorite
                    || old.unavailabilityReason != song.unavailabilityReason
                let playbackRowAffected = playbackVisualsChanged && song.id == activeSongID
                if metadataChanged || globalAppearanceChanged || separatorChanged || playbackRowAffected {
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
        cell.palette = currentPalette
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
    var palette: CollectionPagePalette? {
        didSet { if oldValue != palette { setNeedsUpdateConfiguration() } }
    }
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
        backgroundConfiguration = CollectionTrackUI.translucentCellBackground(for: self, state: state, traitCollection: traitCollection, palette: palette)
    }
}
