import SwiftUI

struct LibraryPlaylistItem: Identifiable, Equatable {
    let id: String
    var title: String
    @ArtworkResource var artwork: Artwork
    var description = ""
    var showsOnProfile = true
    var isFavorite = false
    var isPinned = false
    var isSystem = false
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
    var isSubscribed = false
    var isReadOnly: Bool { sourceOwnerID != nil || isReadOnlyContent || isDownloadedSnapshot }
    var offersCollection: Bool { id.hasPrefix("home:playlist:") && sourceOwnerID != nil && !isSubscribed }

    var shelfItem: LibraryShelfItem {
        LibraryShelfItem(id: id, title: title, subtitle: subtitle, artwork: artwork, route: .playlist(id), isFavorite: isFavorite,
                         isPinned: isPinned, addedOrder: addedOrder, sourceOwnerID: sourceOwnerID)
    }
}

enum PlaylistSort: Hashable, Sendable {
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

enum PlaylistEntry: Identifiable, Equatable {
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

    var typeRank: Int {
        switch self {
        case .playlist(let playlist) where playlist.isSystem: 0
        case .folder: 1
        case .playlist: 2
        }
    }
}

struct PlaylistsListView: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    let library: PlaylistLibrary
    var folderID: String?
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = PlaylistSort.type
    @State private var layout = LibraryLayout.list
    @State private var projection = AsyncListProjection<ProjectionInput, [PlaylistEntry]>()
    @State private var isNamingFolder = false
    @State private var isCreatingPlaylist = false
    @Namespace private var playlistCreationTransition
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.libraryToastCenter) private var toastCenter
    @Environment(\.libraryNavigationChrome) private var chrome
    @State private var folderName = ""
    @State private var renamingFolder: PlaylistFolder?
    @State private var deletingFolder: PlaylistFolder?
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
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

        var playlistEntries: [PlaylistSortEntry] {
            playlists.enumerated().map { index, item in
                PlaylistSortEntry(
                    index: index, id: item.id, title: item.title, isFavorite: item.isFavorite, isSystem: item.isSystem,
                    addedOrder: item.addedOrder, lastPlayedOrder: item.lastPlayedOrder, updatedOrder: item.updatedOrder,
                    addedAt: item.addedAt, lastPlayedAt: item.lastPlayedAt, updatedAt: item.updatedAt,
                    folderID: placement[item.id]
                )
            }
        }

        var folderEntries: [FolderSortEntry] {
            folders.enumerated().map { index, folder in
                FolderSortEntry(index: index, id: folder.id, name: folder.name,
                                parentID: folder.parentID, addedOrder: folder.addedOrder)
            }
        }

        func finish(_ projected: [ProjectedEntry]) -> [PlaylistEntry] {
            projected.map { entry in
                switch entry {
                case .folder(let folderIndex, let playlistIndices):
                    .folder(folders[folderIndex], playlists: playlistIndices.map { playlists[$0] })
                case .playlist(let playlistIndex):
                    .playlist(playlists[playlistIndex])
                }
            }
        }

        func calculate() -> [PlaylistEntry] {
            finish(PlaylistsListView.computeProjectedEntries(playlists: playlistEntries, folders: folderEntries,
                                                             folderID: folderID, query: query, filter: filter, sort: sort))
        }
    }

    private struct PlaylistSortEntry: Sendable {
        let index: Int
        let id: String
        let title: String
        let isFavorite: Bool
        let isSystem: Bool
        let addedOrder: Int
        let lastPlayedOrder: Int
        let updatedOrder: Int
        let addedAt: Date?
        let lastPlayedAt: Date?
        let updatedAt: Date?
        let folderID: String?

        var typeRank: Int { isSystem ? 0 : 2 }

        func date(for sort: PlaylistSort) -> Date? {
            switch sort {
            case .addedDate: addedAt
            case .lastPlayed: lastPlayedAt
            case .updated: updatedAt
            default: nil
            }
        }

        func order(for sort: PlaylistSort) -> Int {
            switch sort {
            case .lastPlayed: lastPlayedOrder
            case .updated: updatedOrder
            default: addedOrder
            }
        }
    }

    private struct FolderSortEntry: Sendable {
        let index: Int
        let id: String
        let name: String
        let parentID: String?
        let addedOrder: Int
    }

    private enum ProjectedEntry: Sendable {
        case folder(index: Int, playlistIndices: [Int])
        case playlist(index: Int)
    }

    private struct EntrySortWrapper: Sendable {
        let entry: ProjectedEntry
        let title: String
        let typeRank: Int
        let date: Date?
        let order: Int
    }

    private static func fastPath(_ input: ProjectionInput) -> [PlaylistEntry]? {
        (input.playlists.count + input.folders.count) <= 80 ? input.calculate() : nil
    }

    nonisolated private static func computeProjectedEntries(playlists: [PlaylistSortEntry],
                                                            folders: [FolderSortEntry],
                                                            folderID: String?,
                                                            query: String,
                                                            filter: LibraryFilter,
                                                            sort: PlaylistSort) -> [ProjectedEntry] {
        var wrapped: [EntrySortWrapper] = []
        if filter != .favorites {
            var playlistsByFolder: [String: [Int]] = [:]
            for item in playlists {
                if Task.isCancelled { return [] }
                if let folder = item.folderID {
                    playlistsByFolder[folder, default: []].append(item.index)
                }
            }
            for folder in folders where folder.parentID == folderID {
                if Task.isCancelled { return [] }
                wrapped.append(EntrySortWrapper(
                    entry: .folder(index: folder.index, playlistIndices: playlistsByFolder[folder.id, default: []]),
                    title: folder.name,
                    typeRank: 1,
                    date: nil,
                    order: folder.addedOrder
                ))
            }
        }
        for item in playlists where item.folderID == folderID {
            if Task.isCancelled { return [] }
            if filter == .favorites, !item.isFavorite { continue }
            wrapped.append(EntrySortWrapper(
                entry: .playlist(index: item.index),
                title: item.title,
                typeRank: item.typeRank,
                date: item.date(for: sort),
                order: item.order(for: sort)
            ))
        }
        let matching = query.isEmpty ? wrapped : wrapped.filter { $0.title.localizedStandardContains(query) }
        if Task.isCancelled { return [] }
        let ordered: [EntrySortWrapper]
        switch sort {
        case .name:
            ordered = matching.sorted(byName: \.title)
        case .type:
            ordered = matching.sorted { ($0.typeRank, $0.order) < ($1.typeRank, $1.order) }
        case .addedDate, .lastPlayed, .updated:
            ordered = matching.enumerated().sorted { lhs, rhs in
                let left = lhs.element.date, right = rhs.element.date
                if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
                if left != nil { return lhs.offset < rhs.offset }
                return lhs.element.order > rhs.element.order
            }.map(\.element)
        }
        return ordered.map(\.entry)
    }

    private var currentInput: ProjectionInput {
        ProjectionInput(playlists: library.playlists, folders: library.folders, placement: library.placement,
                        folderID: folderID, query: query, filter: filter, sort: sort)
    }

    var body: some View {
        let input = currentInput
        let entries = projection.currentValue(for: input, fastPath: Self.fastPath, placeholder: { _ in [] })
        let resolved = projection.isResolved(for: input, fastPath: Self.fastPath)
        content(entries)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let status = library.onlineStatus {
                    HStack(spacing: 10) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !library.isRefreshingOnline, library.retryOnline != nil {
                            Button("重试") { Task { await library.retryOnline?() } }.font(.caption)
                        }
                    }.padding(.horizontal, DesignTokens.Spacing.pageMargin).padding(.vertical, 8)
                        .background(Color(.systemBackground))
                }
            }
            .overlay {
                if resolved {
                    if entries.isEmpty, folderID != nil, query.isEmpty, filter == .all {
                        VStack(spacing: 11) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 50))
                            Text("添加到此文件夹的播放列表将在这里显示。")
                                .font(.body)
                        }
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
                    } else if entries.isEmpty {
                        LibraryListEmptyState(noun: "播放列表", symbol: "music.note.list", query: $query, filter: $filter)
                    }
                }
            }
            .onChange(of: library.recentMove, initial: true) { _, _ in presentMoveToast() }
            .onChange(of: chrome?.isActive ?? true) { _, _ in presentMoveToast() }
            .libraryNavigationTitle(title)
            .libraryTitleDisplayMode(.large)
            .libraryRootAccountButton()
            .modifier(PlaylistSearch(query: $query, isEnabled: !entries.isEmpty || !query.isEmpty || !resolved))
            .task(id: input) {
                let playlistEntries = input.playlistEntries
                let folderEntries = input.folderEntries
                let targetFolderID = input.folderID
                let currentQuery = input.query
                let currentFilter = input.filter
                let currentSort = input.sort
                await projection.computeIfNeeded(
                    for: input,
                    fastPath: Self.fastPath,
                    background: {
                        Self.computeProjectedEntries(playlists: playlistEntries, folders: folderEntries,
                                                     folderID: targetFolderID, query: currentQuery,
                                                     filter: currentFilter, sort: currentSort)
                    },
                    finish: input.finish
                )
            }
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
                    withAnimation(reducesMotion ? nil : .default) { _ = library.createFolder(named: name, in: folderID) }
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
            .alert("", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                   presenting: deletingFolder) { folder in
                Button("删除文件夹和播放列表", role: .destructive) {
                    if folder.id == folderID {
                        if let close = closeLibraryDetail.handler { close() } else { dismiss() }
                    }
                    withAnimation(reducesMotion ? nil : .default) { library.deleteFolder(folder.id) }
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
                    if let folder = renamingFolder, !name.isEmpty { withAnimation(reducesMotion ? nil : .default) { library.renameFolder(folder.id, to: name) } }
                }
            }
    }

    private func presentMoveToast() {
        guard chrome?.isActive ?? true, let move = library.recentMove,
              let folder = library.consumeRecentMove(move) else { return }
        let toast = LibraryToast.movedToFolder(folderName: folder.name, folderID: folder.id)
        if let toastCenter { toastCenter.show(toast) } else { collectionActions.notify(toast) }
    }

    func folderSections(_ folder: PlaylistFolder) -> LibraryMenuSections {
        let targets = library.folders.filter { !library.isDescendant($0.id, of: folder.id) }
        let move: LibraryMenuItem
        if targets.isEmpty && folder.parentID == nil {
            move = LibraryMenuItem(title: "移到文件夹", systemImage: "folder", isDisabled: true)
        } else {
            let options: [(id: String?, name: String, image: String)] = [(nil, "播放列表", "music.note.list")]
                + targets.map { ($0.id, $0.name, "folder") }
            move = LibraryMenuItem(title: "移到文件夹", systemImage: "folder", children: options.map { option in
                LibraryMenuItem(identity: option.id.map { "folder:" + $0 } ?? "playlist-root",
                                title: option.name, systemImage: option.image, isSelected: option.id == folder.parentID) {
                    withAnimation(reducesMotion ? nil : .default) { library.move(folderID: folder.id, to: option.id) }
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
            GenericCollectionList(
                items: entries,
                menu: { entry in
                    if let folder = entry.folder { return folderSections(folder).nativeMenu(firstSectionIsRow: false) }
                    return collectionActions.sections(for: entry.shelfItem, route: entry.route).nativeMenu(firstSectionIsRow: true)
                },
                open: { entry, source in
                    openLibraryRoute(entry.shelfItem, sourceProvider: source)
                },
                moveItem: { id, folderID in
                    guard library.playlists.contains(where: { $0.id == id }),
                          library.folders.contains(where: { $0.id == folderID }) else { return }
                    withAnimation(reducesMotion ? nil : .default) { library.move(playlistID: id, to: folderID) }
                },
                shelfItem: { $0.shelfItem },
                route: { $0.route },
                wrapsAccessibilityText: true
            )
            .ignoresSafeArea(.container, edges: .vertical)
        case .grid:
            ScrollView {
                LibraryCollectionGrid(rowSpacing: 21) {
                    ForEach(entries) { entry in
                        CollectionCardLink(item: entry.shelfItem, menuSections: entry.folder.map { folder in { _ in folderSections(folder) } }) {
                            AlbumCard(item: entry.shelfItem)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.pageMargin)
                .padding(.bottom, 24)
            }
        }
    }
}

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

extension View {
    func playlistDeletionConfirmation(_ library: PlaylistLibrary, enabled: Bool = true) -> some View {
        modifier(PlaylistDeletionConfirmation(library: library, enabled: enabled))
    }
}

private struct PlaylistDeletionConfirmation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
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
                LibraryHaptics.mediumImpact()
                withAnimation(reducesMotion ? nil : .default) { library.deletePlaylist(playlist.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("确定要删除此播放列表吗？这会将播放列表从资料库删除。")
        }
    }
}

struct PlaylistListRow: View {
    let item: LibraryShelfItem
    var usesCellArtwork = false
    var wrapsAccessibilityText = false
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if usesCellArtwork {
                    LibraryArtworkSurface(content: ArtworkView(artwork: item.artwork, cornerRadius: DesignTokens.Radius.songRowCover),
                                          cornerRadius: DesignTokens.Radius.songRowCover, hostedBackgroundColor: nil)
                } else {
                    ArtworkView(artwork: item.artwork, cornerRadius: DesignTokens.Radius.songRowCover)
                }
            }
                .frame(width: 64, height: 64)
                .overlay(alignment: .leading) { FavoriteMark(isFavorite: item.isFavorite, color: .yellow) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(wrapsAccessibilityText && textSize.isAccessibilitySize ? nil : 1)
        }
        .frame(minHeight: 80)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 76 }
    }
}
