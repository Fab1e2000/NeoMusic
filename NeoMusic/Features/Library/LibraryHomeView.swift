import SwiftUI
import UIKit

struct LibraryShelfItem: Identifiable, Equatable {
    let id: String
    let title: String
    var subtitle: String?
    @ArtworkResource var artwork: Artwork
    var route: LibraryRoute?
    var isFavorite = false
    var isPinned = false
    var addedOrder = 0
    var songID: String? = nil
    var year: Int?
    var sourceOwnerID: String?
    var albumBackdrop: AlbumArtworkBackdrop? = nil
}

enum LibraryRoute: Hashable {
    case category(LibraryCategory)
    case downloadedCategory(LibraryCategory)
    case album(String)
    case artist(String)
    case artistSection(String, ArtistSection)
    case playlist(String)
    case playlistFolder(String)
    case searchCategory(String)
}

struct LibraryHomeView: View {
    let pinned: [LibraryShelfItem]
    let recentlyAdded: [LibraryShelfItem]
    let playlistLibrary: PlaylistLibrary
    var isContentReady = true
    var isPinnedReady = true
    var reorderPinned: ([LibraryRoute]) -> Bool = { _ in false }
    var playSong: (String) -> Void = { _ in }
    var songForMenu: (String) -> LibrarySongItem? = { _ in nil }
    @State private var isCreatingPlaylist = false
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingPinned = false
    @State private var tapActions: [String: PinnedTapAction] = [:]
    @Namespace private var playlistCreationTransition

    private var visiblePinned: [LibraryShelfItem] {
        isContentReady && isPinnedReady ? pinned : []
    }

    var body: some View {
        List {
            if !visiblePinned.isEmpty {
                PinnedCollectionView(items: visiblePinned, isEditing: isEditingPinned, tapActions: $tapActions,
                            reorder: reorderPinned) { item in
                    guard let route = item.route else { return }
                    withAnimation { actions.togglePin(route) }
                }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 22, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            Section {
                LibraryCategoryRows()
                    .disabled(!isContentReady)
                    .animation(reduceMotion ? nil : .default, value: isContentReady)
            }
            .listSectionSeparator(.hidden, edges: .top)
            Section {
                RecentlyAddedGrid(items: recentlyAdded, animatesItemChanges: isContentReady && isPinnedReady,
                                  playSong: playSong, songForMenu: songForMenu)
                    .padding(.top, 17)
                    .padding(.bottom, 16)
                    .frame(maxHeight: textSize.isAccessibilitySize ? nil : .infinity, alignment: .top)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: isContentReady && isPinnedReady)
        .navigationDiagnostics("library")
        .libraryHomeNavigation()
        .toolbar {
            if isEditingPinned {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", systemImage: "checkmark", role: .confirm) {
                        isEditingPinned = false
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建播放列表", systemImage: "text.badge.plus") { isCreatingPlaylist = true }
                        .disabled(!isContentReady)
                }
                .matchedTransitionSource(id: "newPlaylist", in: playlistCreationTransition)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis") {
                        Button("编辑置顶", systemImage: "pin") { isEditingPinned = true }
                            .disabled(pinned.isEmpty)
                    }
                }
                AccountToolbar()
            }
        }
        .onChange(of: pinned.isEmpty) { _, isEmpty in if isEmpty { isEditingPinned = false } }
        .sheet(isPresented: $isCreatingPlaylist) {
            NewPlaylistView(library: playlistLibrary)
                .navigationTransition(.zoom(sourceID: "newPlaylist", in: playlistCreationTransition))
        }
    }
}

enum LibraryCategory: CaseIterable, Hashable {
    case playlists, artists, albums, songs, downloaded

    var title: LocalizedStringKey {
        switch self {
        case .playlists: "播放列表"
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .downloaded: "已下载"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .downloaded: "arrow.down.circle"
        }
    }
}

private struct LibraryCategoryRows: View {
    @ScaledMetric(relativeTo: .title2) private var iconWidth = 24.0
    @ScaledMetric(relativeTo: .body) private var iconSpacing = 17.0

    var body: some View {
        let separatorInset = iconWidth + iconSpacing
        ForEach(LibraryCategory.allCases, id: \.self) { category in
            LibraryRouteLink(value: LibraryRoute.category(category)) {
                HStack(spacing: iconSpacing) {
                    Image(systemName: category.systemImage)
                        .foregroundStyle(.primary)
                        .font(.title2)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                    Text(category.title).font(.body)
                }
                .frame(minHeight: 44)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading] + separatorInset
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        }
    }
}

private struct RecentlyAddedGrid: View {
    let items: [LibraryShelfItem]
    let animatesItemChanges: Bool
    var playSong: (String) -> Void = { _ in }
    var songForMenu: (String) -> LibrarySongItem? = { _ in nil }
    @Environment(\.dynamicTypeSize) private var textSize
    private var visibleItems: [LibraryShelfItem] { Array(items.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("最近添加")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if textSize.isAccessibilitySize {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(visibleItems) { item in
                        RecentlyAddedCard(item: item, playSong: playSong, songForMenu: songForMenu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                RecentlyAddedCollection(items: visibleItems, animatesItemChanges: animatesItemChanges,
                                        playSong: playSong, songForMenu: songForMenu)
            }
        }
    }
}

private struct RecentlyAddedCard: View {
    let item: LibraryShelfItem
    let playSong: (String) -> Void
    let songForMenu: (String) -> LibrarySongItem?

    var body: some View {
        Group {
            if let songID = item.songID {
                RecentSongCard(item: item, songID: songID, play: { playSong(songID) }, songForMenu: songForMenu)
            } else {
                CollectionCardLink(item: item) { AlbumCard(item: item) }
                    .environment(\.nativeArtworkSurfaceEnabled, true)
            }
        }
        .environment(\.nativeArtworkSurfaceEnabled, false)
    }
}

private struct RecentlyAddedCollection: UIViewRepresentable {
    let items: [LibraryShelfItem]
    let animatesItemChanges: Bool
    let playSong: (String) -> Void
    let songForMenu: (String) -> LibrarySongItem?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Metrics.spacing
        layout.minimumLineSpacing = Metrics.rowSpacing
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.allowsSelection = false
        view.clipsToBounds = false
        view.contentInsetAdjustmentBehavior = .never
        view.delegate = context.coordinator
        context.coordinator.attach(to: view, initial: self, environment: context.environment)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let animated = animatesItemChanges && !context.environment.accessibilityReduceMotion
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(animated)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
        context.animate {
            context.coordinator.update(with: self, environment: context.environment, animated: animated)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: Metrics.height(for: items, width: width, traits: uiView.traitCollection))
    }

    private enum Metrics {
        static let columns = 2
        static let spacing: CGFloat = 12
        static let rowSpacing: CGFloat = 20
        static let titleSpacing: CGFloat = 7

        static func itemWidth(_ width: CGFloat) -> CGFloat {
            max(0, (width - spacing) / CGFloat(columns))
        }

        static func itemHeight(hasSubtitle: Bool, width: CGFloat, traits: UITraitCollection) -> CGFloat {
            let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
            let lines: CGFloat = hasSubtitle ? 2 : 1
            let text = ceil(font.lineHeight) * lines + (hasSubtitle ? 1 : 0)
            return itemWidth(width) + titleSpacing + text
        }

        static func height(for items: [LibraryShelfItem], width: CGFloat, traits: UITraitCollection) -> CGFloat {
            guard !items.isEmpty else { return 0 }
            var total: CGFloat = 0
            var rows = 0
            var index = 0
            while index < items.count {
                let left = items[index].subtitle != nil
                let right = index + 1 < items.count && items[index + 1].subtitle != nil
                total += max(itemHeight(hasSubtitle: left, width: width, traits: traits),
                             itemHeight(hasSubtitle: right, width: width, traits: traits))
                rows += 1
                index += columns
            }
            if rows > 1 { total += CGFloat(rows - 1) * rowSpacing }
            return total
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var latest: RecentlyAddedCollection?
        private var environment = EnvironmentValues()
        private var itemsByID: [String: LibraryShelfItem] = [:]
        private var hasApplied = false
        private var configuredColorScheme: ColorScheme?
        private var configuredDynamicTypeSize: DynamicTypeSize?
        private var configuredLocale: Locale?

        func attach(to view: UICollectionView, initial: RecentlyAddedCollection, environment: EnvironmentValues) {
            collectionView = view
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            update(with: initial, environment: environment, animated: false)
        }

        func update(with view: RecentlyAddedCollection, environment: EnvironmentValues, animated: Bool) {
            latest = view
            self.environment = environment
            guard let source = dataSource else { return }
            let identifiers = view.items.map(\.id)
            guard Set(identifiers).count == identifiers.count else { return }
            let previous = itemsByID
            let updated = Dictionary(uniqueKeysWithValues: zip(identifiers, view.items))
            let previousIdentifiers = source.snapshot().itemIdentifiers
            let appearanceChanged = configuredColorScheme != environment.colorScheme
                || configuredDynamicTypeSize != environment.dynamicTypeSize
                || configuredLocale != environment.locale
            let existing = Set(previousIdentifiers)
            let changed = identifiers.filter { existing.contains($0) && (previous[$0] != updated[$0] || appearanceChanged) }
            guard !hasApplied || previousIdentifiers != identifiers || !changed.isEmpty else { return }
            let needsLayout = previousIdentifiers.count != identifiers.count
                || configuredDynamicTypeSize != environment.dynamicTypeSize
            itemsByID = updated
            configuredColorScheme = environment.colorScheme
            configuredDynamicTypeSize = environment.dynamicTypeSize
            configuredLocale = environment.locale
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(identifiers)
            snapshot.reconfigureItems(changed)
            let shouldAnimate = hasApplied && !previousIdentifiers.isEmpty && previousIdentifiers != identifiers && animated
            source.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
                if needsLayout { self?.collectionView?.collectionViewLayout.invalidateLayout() }
            }
            hasApplied = true
        }

        private func configure(_ cell: UICollectionViewCell, id: String) {
            guard let item = itemsByID[id], let latest else { return }
            let environment = environment
            let playSong = latest.playSong
            let songForMenu = latest.songForMenu
            cell.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration {
                RecentlyAddedCard(item: item, playSong: playSong, songForMenu: songForMenu)
                .libraryHostedAppearance(environment)
                .environment(\.openLibraryRoute, environment.openLibraryRoute)
                .environment(\.collectionMenuActions, environment.collectionMenuActions)
                .environment(\.songMenuActions, environment.songMenuActions)
                .environment(\.libraryZoomNamespace, environment.libraryZoomNamespace)
            }
            .margins(.all, 0)
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = Metrics.itemWidth(collectionView.bounds.width)
            let hasSubtitle = dataSource?.itemIdentifier(for: indexPath).flatMap { itemsByID[$0]?.subtitle != nil } ?? true
            return CGSize(width: width, height: Metrics.itemHeight(hasSubtitle: hasSubtitle, width: collectionView.bounds.width, traits: collectionView.traitCollection))
        }
    }
}

private struct RecentSongCard: View {
    let item: LibraryShelfItem
    let songID: String
    var play: () -> Void
    var songForMenu: (String) -> LibrarySongItem?
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var open

    var body: some View {
        let song = songForMenu(songID)
        let lines = song.map { [$0.title, $0.artist, $0.album] } ?? [item.title] + (item.subtitle.map { [$0] } ?? [])
        AlbumCard(item: item)
            .padding(8)
            .contentShape(.rect)
            .nativeContextMenu(
                identity: item.id,
                menu: {
                    guard let song = songForMenu(songID) else { return UIMenu() }
                    return actions.rowMenuSections(for: song) { open($0) }.nativeMenu(firstSectionIsRow: true)
                },
                preview: { AnyView(MenuPreviewCard(artwork: song?.artwork ?? item.artwork, lines: lines)) },
                previewSize: { MenuPreviewCard.size(for: lines, compatibleWith: $0) },
                commit: { _ in play() },
                tap: play
            )
            .padding(-8)
    }
}

struct DownloadedLibraryView: View {
    let albums: [LibraryShelfItem]
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        List {
            Section {
                ForEach([LibraryCategory.playlists, .artists, .albums, .songs], id: \.self) { category in
                    LibraryRouteLink(value: LibraryRoute.downloadedCategory(category)) {
                        HStack(spacing: 17) {
                            Image(systemName: category.systemImage).foregroundStyle(.primary).font(.title2).frame(width: 24)
                            Text(category.title).font(.body)
                        }
                        .frame(minHeight: 44)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 41 }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            }
            .listSectionSeparator(.hidden, edges: .top)
            if !albums.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 13) {
                    Text("最近下载").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(albums) { item in CollectionCardLink(item: item) { AlbumCard(item: item) } }
                    }
                }
                .padding(.top, 17).padding(.bottom, 16)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .libraryNavigationTitle("已下载")
        .libraryTitleDisplayMode(.inline)
    }
}

typealias DownloadedMockView = DownloadedLibraryView
