import SwiftUI

/// 资料库里的一个播放列表。
struct LibraryPlaylistItem: Identifiable, Equatable {
    let id: String
    var title: String
    var artwork: Artwork
    var description = ""
    var showsOnProfile = true
    var isFavorite = false
    var isPinned = false
    /// “喜爱歌曲”等系统播放列表；按类型排序时排在最前。
    var isSystem = false
    /// 排序用：数值越大越晚。
    var addedOrder = 0
    var lastPlayedOrder = 0
    var updatedOrder = 0

    var addedAt: Date? = nil
    var lastPlayedAt: Date? = nil
    var updatedAt: Date? = nil
    var sourceOwnerID: String? = nil
    var subtitle: String? = nil
    var isReadOnlyContent = false
    var isDownloadedSnapshot = false
    /// 已在网易云收藏。播放列表页面据此提供取消收藏。
    var isSubscribed = false
    var isReadOnly: Bool { sourceOwnerID != nil || isReadOnlyContent || isDownloadedSnapshot }
    /// 尚未收藏的网易云歌单页显示收藏，收藏后改为下载。
    var offersCollection: Bool { id.hasPrefix("home:playlist:") && sourceOwnerID != nil && !isSubscribed }

    /// 菜单与预览卡片共用的展示数据。
    var shelfItem: LibraryShelfItem {
        LibraryShelfItem(id: id, title: title, subtitle: subtitle, artwork: artwork, route: .playlist(id), isFavorite: isFavorite,
                         isPinned: isPinned, addedOrder: addedOrder, sourceOwnerID: sourceOwnerID)
    }
}

/// 播放列表页的排序方式，对照 Apple Music。按类型时依次为系统播放列表、文件夹、其他播放列表。
enum PlaylistSort: Hashable {
    case name, addedDate, lastPlayed, updated, type

    static let options = [
        LibrarySortOption(sort: PlaylistSort.name, title: "名称"),
        LibrarySortOption(sort: PlaylistSort.addedDate, title: "添加日期"),
        LibrarySortOption(sort: PlaylistSort.lastPlayed, title: "上次播放日期"),
        LibrarySortOption(sort: PlaylistSort.updated, title: "更新日期"),
        LibrarySortOption(sort: PlaylistSort.type, title: "播放列表类型"),
    ]
}

extension Array where Element == PlaylistEntry {
    func sorted(by sort: PlaylistSort) -> [PlaylistEntry] {
        switch sort {
        case .name:
            sorted(byName: \.title)
        case .type:
            sorted { ($0.typeRank, $0.order(for: sort)) < ($1.typeRank, $1.order(for: sort)) }
        case .addedDate, .lastPlayed, .updated:
            enumerated().sorted { lhs, rhs in
                let left = lhs.element.date(for: sort), right = rhs.element.date(for: sort)
                if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
                if left != nil { return lhs.offset < rhs.offset }
                return lhs.element.order(for: sort) > rhs.element.order(for: sort)
            }.map(\.element)
        }
    }
}

/// 播放列表页的一项：文件夹或播放列表。
enum PlaylistEntry: Identifiable {
    case folder(PlaylistFolder, playlists: [LibraryPlaylistItem])
    case playlist(LibraryPlaylistItem)

    var id: String {
        switch self {
        case .folder(let folder, _): "folder:" + folder.id
        case .playlist(let playlist): playlist.id
        }
    }

    var title: String {
        switch self {
        case .folder(let folder, _): folder.name
        case .playlist(let playlist): playlist.title
        }
    }

    var shelfItem: LibraryShelfItem {
        switch self {
        case .folder(let folder, let playlists):
            LibraryShelfItem(id: id, title: folder.name, subtitle: "\(playlists.count)个播放列表",
                             artwork: .folder(Array(playlists.prefix(4).map(\.artwork))),
                             route: .playlistFolder(folder.id))
        case .playlist(let playlist):
            playlist.shelfItem
        }
    }

    var route: LibraryRoute {
        switch self {
        case .folder(let folder, _): .playlistFolder(folder.id)
        case .playlist(let playlist): .playlist(playlist.id)
        }
    }

    func date(for sort: PlaylistSort) -> Date? {
        guard case .playlist(let item) = self else { return nil }
        switch sort {
        case .addedDate: return item.addedAt
        case .lastPlayed: return item.lastPlayedAt
        case .updated: return item.updatedAt
        default: return nil
        }
    }

    /// 同类之间的排序依据：文件夹只有名称与添加顺序。
    func order(for sort: PlaylistSort) -> Int {
        switch self {
        case .folder(let folder, _): folder.addedOrder
        case .playlist(let playlist):
            switch sort {
            case .lastPlayed: playlist.lastPlayedOrder
            case .updated: playlist.updatedOrder
            default: playlist.addedOrder
            }
        }
    }

    /// 按类型排序的分组：系统播放列表、文件夹、其他播放列表。
    var typeRank: Int {
        switch self {
        case .playlist(let playlist) where playlist.isSystem: 0
        case .folder: 1
        case .playlist: 2
        }
    }
}

/// 播放列表总览，或某个文件夹的内容。列表与网格两种显示方式，对照 Apple Music。
struct PlaylistsListView: View {
    let library: PlaylistLibrary
    var folderID: String?
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = PlaylistSort.type
    @State private var layout = LibraryLayout.list
    @State private var projection = LibraryListProjection<ProjectionInput, [PlaylistEntry]>()
    @State private var isNamingFolder = false
    @State private var isCreatingPlaylist = false
    @Namespace private var playlistCreationTransition
    @Environment(\.collectionMenuActions) private var collectionActions
    @State private var folderName = ""
    @State private var renamingFolder: PlaylistFolder?
    @State private var deletingFolder: PlaylistFolder?
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var renameText = ""

    private var title: String { folderID.flatMap { library.folder($0)?.name } ?? "播放列表" }

    private struct ProjectionInput: Equatable {
        let playlists: [LibraryPlaylistItem]
        let folders: [PlaylistFolder]
        let placement: [String: String]
        let folderID: String?
        let query: String
        let filter: LibraryFilter
        let sort: PlaylistSort
    }

    private var entries: [PlaylistEntry] {
        let input = ProjectionInput(playlists: library.playlists, folders: library.folders, placement: library.placement,
                                    folderID: folderID, query: query, filter: filter, sort: sort)
        return projection.value(for: input) {
            let playlists = input.playlists.filter { input.placement[$0.id] == input.folderID }
            let entries: [PlaylistEntry]
            if input.filter == .favorites {
                entries = playlists.filter(\.isFavorite).map(PlaylistEntry.playlist)
            } else {
                let folders = input.folders.filter { $0.parentID == input.folderID }.map { folder in
                    PlaylistEntry.folder(folder, playlists: input.playlists.filter { input.placement[$0.id] == folder.id })
                }
                entries = folders + playlists.map(PlaylistEntry.playlist)
            }
            let matching = input.query.isEmpty ? entries : entries.filter { $0.title.localizedStandardContains(input.query) }
            return matching.sorted(by: input.sort)
        }
    }

    var body: some View {
        let entries = entries
        content(entries)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let status = library.onlineStatus {
                    HStack(spacing: 10) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !library.isRefreshingOnline, library.retryOnline != nil {
                            Button("重试") { Task { await library.retryOnline?() } }.font(.caption)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color(.systemBackground))
                }
            }
            .overlay {
                if entries.isEmpty, folderID != nil, query.isEmpty, filter == .all {
                    // 空文件夹：大图标与一行说明，对照 Apple Music。
                    VStack(spacing: 11) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 50))
                        Text("添加到此文件夹的播放列表将在这里显示。")
                            .font(.body)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                } else if entries.isEmpty {
                    LibraryListEmptyState(noun: "播放列表", symbol: "music.note.list", query: $query, filter: $filter)
                }
            }
            .overlay(alignment: .bottom) {
                if let move = library.recentMove, let folder = library.folder(move.folderID) {
                    MovedToFolderToast(folderName: folder.name) { openLibraryRoute(.playlistFolder(folder.id)) }
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .task(id: move.id) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(.smooth(duration: 0.3)) { library.clearRecentMove(move) }
                        }
                }
            }
            .animation(.smooth(duration: 0.3), value: library.recentMove)
            .libraryNavigationTitle(title)
            .libraryTitleDisplayMode(.large)
            .libraryRootAccountButton()
            .modifier(PlaylistSearch(query: $query, isEnabled: !entries.isEmpty || !query.isEmpty))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新建播放列表", systemImage: "text.badge.plus") { isCreatingPlaylist = true }
                        Button("创建新文件夹", systemImage: "folder.badge.plus") {
                            folderName = ""
                            isNamingFolder = true
                        }
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
                .matchedTransitionSource(id: "newPlaylist", in: playlistCreationTransition)
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryFilterMenu(filter: $filter, allTitle: "所有播放列表", allImage: "music.note.list")
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    // 文件夹页的“…”菜单同时放文件夹自身的操作，对照 Apple Music。
                    let folderActions = folderID.flatMap(library.folder).map(folderSections) ?? []
                    LibrarySortMenu(layout: $layout, sort: $sort, options: PlaylistSort.options,
                                    leading: Array(folderActions.dropLast()), trailing: Array(folderActions.suffix(1)))
                }
            }
            .alert("新建文件夹", isPresented: $isNamingFolder) {
                TextField("文件夹名称", text: $folderName)
                    .submitLabel(.done)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    withAnimation { _ = library.createFolder(named: name, in: folderID) }
                }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("请为此文件夹输入名称。")
            }
            .sheet(isPresented: $isCreatingPlaylist) {
                NewPlaylistView(library: library, folderID: folderID)
                    .navigationTransition(.zoom(sourceID: "newPlaylist", in: playlistCreationTransition))
            }
            .playlistDeletionConfirmation(library)
            // Apple Music 用居中的提示框确认，只有说明文字，没有标题。
            .alert("", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                   presenting: deletingFolder) { folder in
                Button("删除文件夹和播放列表", role: .destructive) {
                    // 在文件夹自己的页面里删除时返回上一层。
                    if folder.id == folderID {
                        if let close = closeLibraryDetail.handler { close() } else { dismiss() }
                    }
                    withAnimation { library.deleteFolder(folder.id) }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("确定要删除此文件夹吗？这会删除其中的本地播放列表，网易云播放列表将移回最外层。")
            }
            .alert("重新命名", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("文件夹名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("存储") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let folder = renamingFolder, !name.isEmpty { withAnimation { library.renameFolder(folder.id, to: name) } }
                }
            }
    }

    /// 文件夹的长按菜单，对照 Apple Music：重新命名、移到文件夹；从资料库删除（先确认）。
    private func folderSections(_ folder: PlaylistFolder) -> LibraryMenuSections {
        let targets = library.folders.filter { !library.isDescendant($0.id, of: folder.id) }
        let move: LibraryMenuItem
        if targets.isEmpty && folder.parentID == nil {
            move = LibraryMenuItem(title: "移到文件夹", systemImage: "folder", isDisabled: true)
        } else {
            let options: [(id: String?, name: String, image: String)] = [(nil, "播放列表", "music.note.list")]
                + targets.map { ($0.id, $0.name, "folder") }
            move = LibraryMenuItem(title: "移到文件夹", systemImage: "folder", children: options.map { option in
                LibraryMenuItem(title: option.name, systemImage: option.image, isSelected: option.id == folder.parentID) {
                    withAnimation { library.move(folderID: folder.id, to: option.id) }
                }
            })
        }
        return [[
            LibraryMenuItem(title: "重新命名", systemImage: "pencil") {
                renameText = folder.name
                renamingFolder = folder
            },
            move,
        ], [
            LibraryMenuItem(title: "从资料库删除", systemImage: "trash", isDestructive: true) { deletingFolder = folder },
        ]]
    }

    @ViewBuilder private func content(_ entries: [PlaylistEntry]) -> some View {
        switch layout {
        case .list:
            PlaylistCollectionList(entries: entries, menu: { entry in
                if let folder = entry.folder { return folderSections(folder).nativeMenu(firstSectionIsRow: false) }
                return collectionActions.sections(for: entry.shelfItem, route: entry.route).nativeMenu(firstSectionIsRow: true)
            }, open: { route, source in
                guard let entry = entries.first(where: { $0.route == route }) else { return }
                openLibraryRoute(entry.shelfItem, sourceProvider: source)
            }, movePlaylist: { id, folderID in
                guard library.playlists.contains(where: { $0.id == id }),
                      library.folders.contains(where: { $0.id == folderID }) else { return }
                withAnimation { library.move(playlistID: id, to: folderID) }
            })
            // UIKit hosts the large title in the scrolling content during a push.
            // Let its adjustedContentInset position rows without clipping that title.
            .ignoresSafeArea(.container, edges: .vertical)
        case .grid:
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                         count: textSize.isAccessibilitySize ? 1 : 2),
                          alignment: .leading, spacing: 21) {
                    ForEach(entries) { entry in
                        CollectionCardLink(item: entry.shelfItem, menuSections: entry.folder.map { folder in { _ in folderSections(folder) } }) {
                            AlbumCard(item: entry.shelfItem)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

/// 搜索框默认隐藏，下拉列表时出现；空文件夹没有可滚动的内容，不提供搜索.
private struct PlaylistSearch: ViewModifier {
    @Binding var query: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.librarySearchable(text: $query, prompt: "搜索播放列表", enabled: isEnabled)
    }
}

extension PlaylistEntry {
    var folder: PlaylistFolder? { if case .folder(let folder, _) = self { folder } else { nil } }
}

/// 移入文件夹后浮在底部的提示，点按进入该文件夹，对照 Apple Music。
private struct MovedToFolderToast: View {
    let folderName: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 0) {
                    Text("已移至").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Text(folderName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("已移至\(folderName)")
        .accessibilityHint("打开文件夹")
    }
}

extension View {
    /// 删除播放列表前的确认。用居中提示框，避免确认框从挂载的页面边缘冒出来。
    func playlistDeletionConfirmation(_ library: PlaylistLibrary, enabled: Bool = true) -> some View {
        modifier(PlaylistDeletionConfirmation(library: library, enabled: enabled))
    }
}

private struct PlaylistDeletionConfirmation: ViewModifier {
    @Bindable var library: PlaylistLibrary
    var enabled: Bool
    @Environment(\.libraryNavigationChrome) private var chrome
    private var isActive: Bool { enabled && (chrome?.isActive ?? true) }

    func body(content: Content) -> some View {
        content.alert(
            "",
            isPresented: Binding(get: { isActive && library.pendingDeletion != nil }, set: { if !$0 && isActive { library.pendingDeletion = nil } }),
            presenting: library.pendingDeletion
        ) { playlist in
            Button("删除播放列表", role: .destructive) {
                LibraryHaptics.impact()
                withAnimation { library.deletePlaylist(playlist.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("确定要删除此播放列表吗？这会将播放列表从资料库删除。")
        }
    }
}

/// 播放列表、文件夹的列表行：大封面、标题与可选副标题（文件夹显示播放列表数量）。
struct PlaylistListRow: View {
    let item: LibraryShelfItem
    var usesCellArtwork = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if usesCellArtwork { PlaylistCellArtwork(artwork: item.artwork) }
                else { ArtworkView(artwork: item.artwork, cornerRadius: 6) }
            }
                .frame(width: 64, height: 64)
                .overlay(alignment: .leading) { FavoriteMark(isFavorite: item.isFavorite, color: .yellow) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(minHeight: 80)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 76 }
    }
}
