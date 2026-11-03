import SwiftUI

/// 资料库里的一个播放列表。
struct LibraryPlaylistItem: Identifiable {
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

    /// 菜单与预览卡片共用的展示数据。
    var shelfItem: LibraryShelfItem {
        LibraryShelfItem(id: id, title: title, artwork: artwork, route: .playlist(id), isFavorite: isFavorite,
                         isPinned: isPinned, addedOrder: addedOrder)
    }
}

/// 播放列表文件夹；文件夹里可以再放文件夹。
struct PlaylistFolder: Identifiable, Codable {
    let id: String
    var name: String
    var parentID: String?
    var addedOrder = 0
}

/// 资料库中的播放列表与文件夹；持久化只保存条目身份，不触碰音乐文件。
@MainActor @Observable
final class PlaylistLibrary {
    private(set) var playlists: [LibraryPlaylistItem]
    private(set) var folders: [PlaylistFolder]
    /// 播放列表所在文件夹；不在表中即在最外层。
    private var placement: [String: String] = [:]
    private var nextOrder = 1000
    private var contents: [String: [LibrarySongItem]] = [:]
    /// 最近一次移入文件夹，页面据此显示“已移至”提示。
    private(set) var recentMove: RecentMove?
    /// 等待确认删除的播放列表，由宿主弹出确认框。
    var pendingDeletion: LibraryPlaylistItem?
    /// 等待移到文件夹的播放列表，由宿主弹出文件夹选择页。
    var pendingMove: LibraryPlaylistItem?
    /// 等待编辑的播放列表，由宿主弹出编辑页（例如从长按菜单进入）。
    var pendingEdit: LibraryPlaylistItem?
    /// 等待选择目标播放列表的歌曲，由宿主弹出“添加到播放列表”。
    var pendingAddition: PendingAddition?

    struct PendingAddition: Identifiable {
        let songs: [LibrarySongItem]
        let id = UUID()
    }

    struct RecentMove: Equatable {
        let folderID: String
        let id = UUID()
    }

    init(playlists: [LibraryPlaylistItem], folders: [PlaylistFolder] = []) {
        self.playlists = playlists
        self.folders = folders
    }

    private var persistenceURL: URL?
    private var loadingPersistence = false
    private(set) var persistenceError: String?
    /// Metadata edits reuse the exact stored PNG instead of rasterizing every cover again.
    @ObservationIgnored private var savedArtwork: [String: (image: Image, data: Data)] = [:]

    private struct SavedPlaylist: Codable {
        let id: String
        let title: String
        let description: String
        let showsOnProfile: Bool
        let isFavorite: Bool
        let isPinned: Bool
        let isSystem: Bool
        let addedOrder: Int
        let lastPlayedOrder: Int
        let updatedOrder: Int
        let artworkData: Data?
        let songs: [String]
    }
    private struct Snapshot: Codable {
        let playlists: [SavedPlaylist]
        let folders: [PlaylistFolder]
        let placement: [String: String]
        let nextOrder: Int
    }

    /// Cache-first startup may restore only when every saved reference can be resolved.
    @discardableResult
    func configurePersistence(url: URL, songs: [LibrarySongItem], requireCompleteLibrary: Bool = false) -> Bool {
        guard persistenceURL == nil else { return true }
        loadingPersistence = true
        defer { loadingPersistence = false }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
                let lookup = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                if requireCompleteLibrary,
                   !saved.playlists.allSatisfy({ $0.songs.allSatisfy { lookup[$0] != nil } }) {
                    return false
                }
                var restoredArtwork: [String: (image: Image, data: Data)] = [:]
                playlists = saved.playlists.map { item in
                    let artwork: Artwork
                    if let data = item.artworkData, let uiImage = UIImage(data: data) {
                        let image = Image(uiImage: uiImage)
                        restoredArtwork[item.id] = (image, data)
                        artwork = .image(image)
                    } else { artwork = item.isSystem ? .favorites : .playlist }
                    return LibraryPlaylistItem(id: item.id, title: item.title, artwork: artwork,
                        description: item.description, showsOnProfile: item.showsOnProfile,
                        isFavorite: item.isFavorite, isPinned: item.isPinned, isSystem: item.isSystem,
                        addedOrder: item.addedOrder, lastPlayedOrder: item.lastPlayedOrder, updatedOrder: item.updatedOrder)
                }
                folders = saved.folders
                placement = saved.placement
                nextOrder = saved.nextOrder
                contents = Dictionary(saved.playlists.map { ($0.id, $0.songs.compactMap { lookup[$0] }) }, uniquingKeysWith: { first, _ in first })
                savedArtwork = restoredArtwork
            }
            persistenceURL = url
            persistenceError = nil
            return true
        } catch {
            // Leave an unreadable store untouched; do not overwrite it with an empty library.
            persistenceError = "无法读取播放列表：\(error.localizedDescription)"
            return false
        }
    }

    func reconcileSongs(_ songs: [LibrarySongItem]) {
        let lookup = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in contents.keys { contents[id] = contents[id]?.compactMap { lookup[$0.id] } }
        persist()
    }

    private func persist() {
        guard !loadingPersistence, let url = persistenceURL else { return }
        do {
            var nextArtwork: [String: (image: Image, data: Data)] = [:]
            let items = playlists.map { item -> SavedPlaylist in
                let data: Data?
                if case .image(let image) = item.artwork {
                    if let cached = savedArtwork[item.id], cached.image == image {
                        data = cached.data
                    } else {
                        let renderer = ImageRenderer(content: image.resizable().scaledToFill().frame(width: 512, height: 512).clipped())
                        data = renderer.uiImage?.pngData()
                    }
                    if let data { nextArtwork[item.id] = (image, data) }
                } else { data = nil }
                return SavedPlaylist(id: item.id, title: item.title, description: item.description,
                    showsOnProfile: item.showsOnProfile, isFavorite: item.isFavorite, isPinned: item.isPinned,
                    isSystem: item.isSystem, addedOrder: item.addedOrder, lastPlayedOrder: item.lastPlayedOrder,
                    updatedOrder: item.updatedOrder, artworkData: data, songs: contents[item.id, default: []].map(\.id))
            }
            let data = try JSONEncoder().encode(Snapshot(playlists: items, folders: folders, placement: placement, nextOrder: nextOrder))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            savedArtwork = nextArtwork
            persistenceError = nil
        } catch { persistenceError = "无法保存播放列表：\(error.localizedDescription)" }
    }

    func playlist(_ id: String) -> LibraryPlaylistItem? { playlists.first { $0.id == id } }
    func songs(in id: String) -> [LibrarySongItem] { contents[id] ?? [] }

    /// 单次选择确认后才提交，保留选择顺序；已有歌曲不重复加入。
    /// 按顺序加到播放列表末尾，已在列表中的歌曲跳过；返回实际加入的数量。
    @discardableResult
    func addSongs(_ songs: [LibrarySongItem], to id: String) -> Int {
        defer { persist() }
        guard canDelete(id) else { return 0 }
        var current = contents[id] ?? []
        var known = Set(current.map(\.id))
        for song in songs where known.insert(song.id).inserted { current.append(song) }
        let added = current.count - contents[id, default: []].count
        guard added > 0 else { return 0 }
        contents[id] = current
        markUpdated(id)
        return added
    }

    /// 没有自定封面的播放列表用第一首歌的封面，与 Apple Music 一致。
    func displayArtwork(of playlist: LibraryPlaylistItem) -> Artwork {
        if case .playlist = playlist.artwork, let first = contents[playlist.id]?.first { return first.artwork }
        return playlist.artwork
    }

    /// 歌曲从资料库删除时，也从所有播放列表移除。
    func removeSongEverywhere(_ songID: String) {
        defer { persist() }
        for id in contents.keys where contents[id]?.contains(where: { $0.id == songID }) == true {
            contents[id]?.removeAll { $0.id == songID }
            markUpdated(id)
        }
    }

    func removeSong(_ songID: String, from id: String) {
        defer { persist() }
        guard canDelete(id), contents[id]?.contains(where: { $0.id == songID }) == true else { return }
        contents[id]?.removeAll { $0.id == songID }
        markUpdated(id)
    }

    func renamePlaylist(_ id: String, to name: String) {
        defer { persist() }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, canDelete(id), let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = title
        markUpdated(id)
    }

    func savePlaylist(_ id: String, title: String, description: String, showsOnProfile: Bool,
                      artwork: Artwork, songs: [LibrarySongItem]) {
        defer { persist() }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canDelete(id), let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = name
        playlists[index].description = description
        playlists[index].showsOnProfile = showsOnProfile
        playlists[index].artwork = artwork
        var seen = Set<String>()
        contents[id] = songs.filter { seen.insert($0.id).inserted }
        markUpdated(id)
    }

    func reorderSongs(in id: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        defer { persist() }
        guard canDelete(id), var songs = contents[id],
              offsets.allSatisfy({ songs.indices.contains($0) }),
              (0...songs.count).contains(destination) else { return }
        songs.move(fromOffsets: offsets, toOffset: destination)
        contents[id] = songs
        markUpdated(id)
    }

    func toggleFavorite(_ id: String) {
        defer { persist() }
        guard let index = playlists.firstIndex(where: { $0.id == id }), !playlists[index].isSystem else { return }
        playlists[index].isFavorite.toggle()
    }

    func togglePin(_ id: String) {
        defer { persist() }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isPinned.toggle()
    }

    private func markUpdated(_ id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        nextOrder += 1
        playlists[index].updatedOrder = nextOrder
    }

    func folder(_ id: String) -> PlaylistFolder? { folders.first { $0.id == id } }
    func folders(in parentID: String?) -> [PlaylistFolder] { folders.filter { $0.parentID == parentID } }
    func playlists(in folderID: String?) -> [LibraryPlaylistItem] { playlists.filter { placement[$0.id] == folderID } }
    func folderID(of playlistID: String) -> String? { placement[playlistID] }

    /// 文件夹中直接包含的播放列表数量。
    func playlistCount(in folderID: String) -> Int { playlists(in: folderID).count }

    /// 创建播放列表并保存。
    @discardableResult
    func createPlaylist(named name: String, artwork: Artwork, in folderID: String?) -> LibraryPlaylistItem? {
        defer { persist() }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        nextOrder += 1
        let playlist = LibraryPlaylistItem(id: UUID().uuidString, title: title, artwork: artwork,
                                          addedOrder: nextOrder, updatedOrder: nextOrder)
        playlists.append(playlist)
        placement[playlist.id] = folderID
        return playlist
    }

    @discardableResult
    func createFolder(named name: String, in parentID: String?) -> PlaylistFolder {
        defer { persist() }
        nextOrder += 1
        let folder = PlaylistFolder(id: UUID().uuidString, name: name, parentID: parentID, addedOrder: nextOrder)
        folders.append(folder)
        return folder
    }

    /// 把播放列表移到某个文件夹；`nil` 为最外层。
    func move(playlistID: String, to folderID: String?) {
        defer { persist() }
        guard placement[playlistID] != folderID else { return }
        placement[playlistID] = folderID
        recentMove = folderID.map { RecentMove(folderID: $0) }
    }

    func clearRecentMove(_ move: RecentMove) {
        if recentMove == move { recentMove = nil }
    }

    /// 用户自己的播放列表可以删除；“喜爱歌曲”等系统播放列表不能删除。
    func canDelete(_ playlistID: String) -> Bool {
        playlists.contains { $0.id == playlistID && !$0.isSystem }
    }

    /// 从资料库删除播放列表，只删记录，不碰音乐文件。
    func deletePlaylist(_ id: String) {
        defer { persist() }
        guard canDelete(id) else { return }
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }

    /// 删除文件夹及其中的子文件夹与播放列表，对照 Apple Music。只删资料库记录，不碰音乐文件；
    /// “喜爱歌曲”等系统播放列表不能删除，移回最外层。
    func deleteFolder(_ id: String) {
        defer { persist() }
        let removed = Set(folders.map(\.id).filter { isDescendant($0, of: id) })
        let contained = Set(placement.filter { removed.contains($0.value) }.map(\.key))
        playlists.removeAll { contained.contains($0.id) && !$0.isSystem }
        for playlistID in contained {
            placement[playlistID] = nil
            if !playlists.contains(where: { $0.id == playlistID }) { contents[playlistID] = nil }
        }
        folders.removeAll { removed.contains($0.id) }
    }

    func renameFolder(_ id: String, to name: String) {
        defer { persist() }
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    /// 把文件夹移到另一个文件夹；`nil` 为最外层。不能移进自己或自己的子文件夹。
    func move(folderID: String, to parentID: String?) {
        defer { persist() }
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              !(parentID.map { isDescendant($0, of: folderID) } ?? false) else { return }
        folders[index].parentID = parentID
    }

    /// `id` 是否为 `ancestorID` 本身或其子孙文件夹。
    func isDescendant(_ id: String, of ancestorID: String) -> Bool {
        var current: String? = id
        while let value = current {
            if value == ancestorID { return true }
            current = folder(value)?.parentID
        }
        return false
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
            sorted { $0.order(for: sort) > $1.order(for: sort) }
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
    @State private var isNamingFolder = false
    @State private var isCreatingPlaylist = false
    @Namespace private var playlistCreationTransition
    @State private var folderName = ""
    @State private var renamingFolder: PlaylistFolder?
    @State private var deletingFolder: PlaylistFolder?
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @State private var renameText = ""

    private var title: String { folderID.flatMap { library.folder($0)?.name } ?? "播放列表" }

    private var entries: [PlaylistEntry] {
        let playlists = library.playlists(in: folderID)
        if filter == .favorites {
            return sorted(playlists.filter(\.isFavorite).map(PlaylistEntry.playlist))
        }
        let folders = library.folders(in: folderID).map { PlaylistEntry.folder($0, playlists: library.playlists(in: $0.id)) }
        return sorted(folders + playlists.map(PlaylistEntry.playlist))
    }

    private func sorted(_ entries: [PlaylistEntry]) -> [PlaylistEntry] { entries.sorted(by: sort) }

    var body: some View {
        let entries = entries
        content(entries)
            .overlay {
                if entries.isEmpty, folderID != nil {
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
                }
            }
            .libraryCollectionAnimation(value: entries.map(\.id))
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
            .modifier(PlaylistSearch(query: $query, isEnabled: !entries.isEmpty))
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
                    library.createFolder(named: name, in: folderID)
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
                    library.deleteFolder(folder.id)
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("确定要删除此文件夹吗？这会将文件夹中的所有播放列表从资料库删除。")
            }
            .alert("重新命名", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("文件夹名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("存储") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let folder = renamingFolder, !name.isEmpty { library.renameFolder(folder.id, to: name) }
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
                    library.move(folderID: folder.id, to: option.id)
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        PlaylistSwiftUIRow(entry: entry,
                            menuSections: entry.folder.map { folder in { _ in folderSections(folder) } },
                            isLast: index == entries.count - 1,
                            movePlaylist: { id, folderID in
                                guard library.playlists.contains(where: { $0.id == id }),
                                      library.folders.contains(where: { $0.id == folderID }) else { return }
                                withAnimation { library.move(playlistID: id, to: folderID) }
                            })
                    }
                }
            }
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                    GridItem(.flexible(), spacing: 12, alignment: .top)],
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

/// SwiftUI 滚动列表复用资料库卡片菜单；仅接受本次页面产生的播放列表拖动。
private struct PlaylistSwiftUIRow: View {
    let entry: PlaylistEntry
    var menuSections: ((CollectionMenuActions) -> LibraryMenuSections)?
    let isLast: Bool
    let movePlaylist: (String, String) -> Void
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.displayScale) private var displayScale

    private var drag: NativeMenuDrag? {
        guard case .playlist(let playlist) = entry else { return nil }
        return NativeMenuDrag(identifier: playlist.id) {
            let renderer = ImageRenderer(content: ArtworkView(artwork: playlist.artwork, cornerRadius: 8).frame(width: 64, height: 64))
            renderer.scale = displayScale
            return renderer.uiImage
        }
    }

    private var drop: NativeMenuDrop? {
        guard case .folder(let folder, _) = entry else { return nil }
        return NativeMenuDrop { id in movePlaylist(id, folder.id) }
    }

    var body: some View {
        CollectionCardLink(item: entry.shelfItem, menuSections: menuSections,
                           firstSectionIsRow: entry.folder == nil,
                           tap: { openLibraryRoute(entry.route) }, drag: drag, drop: drop) {
            HStack(spacing: 12) {
                PlaylistListRow(item: entry.shelfItem)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .overlay(alignment: .bottom) {
                if !isLast { Divider().padding(.leading, 96).padding(.trailing, 20) }
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
    /// 删除播放列表前的确认，挂在应用根部，任何入口请求删除都在这里确认。
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
        content.confirmationDialog(
            "确定要删除此播放列表吗？这会将播放列表从资料库删除。",
            isPresented: Binding(get: { isActive && library.pendingDeletion != nil }, set: { if !$0 && isActive { library.pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: library.pendingDeletion
        ) { playlist in
            Button("删除播放列表", role: .destructive) { withAnimation { library.deletePlaylist(playlist.id) } }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 播放列表、文件夹的列表行：大封面、标题与可选副标题（文件夹显示播放列表数量）。
struct PlaylistListRow: View {
    let item: LibraryShelfItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: item.artwork, cornerRadius: 6)
                .frame(width: 64)
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
