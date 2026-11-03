import SwiftUI

/// 资料库首页展示用的一项专辑或播放列表。
struct LibraryShelfItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let artwork: Artwork
    var route: LibraryRoute?
    var isFavorite = false
    var isPinned = false
    /// 排序用：数值越大越晚加入资料库；专辑的发行年份。
    var addedOrder = 0
    var year: Int?
}

/// 资料库内的页面跳转。
enum LibraryRoute: Hashable {
    case category(LibraryCategory)
    case downloadedCategory(LibraryCategory)
    case album(String)
    case artist(String)
    case playlist(String)
    case playlistFolder(String)
}

/// 资料库首页：置顶、分类入口与最近添加。布局对照 Apple Music。
struct LibraryHomeView: View {
    let pinned: [LibraryShelfItem]
    let recentlyAdded: [LibraryShelfItem]
    let playlistLibrary: PlaylistLibrary
    var isContentReady = true
    var reorderPinned: ([LibraryRoute]) -> Bool = { _ in false }
    @State private var isCreatingPlaylist = false
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryNavigationChrome) private var chrome
    @State private var isEditingPinned = false
    /// 各置顶项的“轻点操作”，只保存在本次运行中。
    @State private var tapActions: [String: PinnedTapAction] = [:]
    @Namespace private var playlistCreationTransition

    private var visiblePinned: [LibraryShelfItem] {
        isContentReady && chrome?.hasAppeared != false ? pinned : []
    }

    var body: some View {
        List {
            if !visiblePinned.isEmpty {
                PinnedCollectionView(items: visiblePinned, isEditing: isEditingPinned, tapActions: $tapActions,
                            reorder: reorderPinned) { item in
                    guard let route = item.route else { return }
                    withAnimation { actions.togglePin(route) }
                }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 22, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            Section {
                LibraryCategoryRows()
                    .disabled(!isContentReady)
            }
            .listSectionSeparator(.hidden, edges: .top)
            Section {
                RecentlyAddedGrid(items: recentlyAdded)
                    .padding(.top, 17)
                    .padding(.bottom, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // First fill stays below its heading while List moves the row
                    // for the pinned insertion. Later collection edits still animate.
                    .transaction(value: isContentReady) { $0.animation = nil }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        // The List owns row heights as well as the grids. Animate here so losing
        // a pinned row (or the final pin) also moves the categories below it.
        .libraryCollectionAnimation(value: [visiblePinned.map(\.id), recentlyAdded.map(\.id)])
        .navigationDiagnostics("library")
        .libraryHomeNavigation()
        .toolbar {
            if isEditingPinned {
                // 编辑置顶时只保留完成按钮，对照 Apple Music。
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
                // ToolbarItem 的转场源包含系统共享玻璃背景。
                .matchedTransitionSource(id: "newPlaylist", in: playlistCreationTransition)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis") {
                        // The cells own their wobble; keep toolbar replacement out of an animation transaction.
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

/// 分类入口；分隔线从文字起点开始。
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

/// 最近添加：两列网格。
private struct RecentlyAddedGrid: View {
    let items: [LibraryShelfItem]
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("最近添加")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    CollectionCardLink(item: item) { AlbumCard(item: item) }
                }
            }
        }
    }
}

/// 已下载效果稿：示例数据与真实下载状态无关。
struct DownloadedMockView: View {
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
            // 还没有下载过专辑时不显示“最近下载”。
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
        .libraryCollectionAnimation(value: albums.map(\.id))
        .libraryNavigationTitle("已下载")
        .libraryTitleDisplayMode(.inline)
    }
}
