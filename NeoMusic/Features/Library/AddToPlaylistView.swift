import SwiftUI

extension View {
    /// 歌曲等待添加时弹出“添加到播放列表”，挂在应用根部，任何入口请求添加都在这里选择。
    func addToPlaylistSheet(_ library: PlaylistLibrary, toasts: LibraryToastCenter) -> some View {
        modifier(AddToPlaylistSheet(library: library, toasts: toasts))
    }
}

private struct AddToPlaylistSheet: ViewModifier {
    @Bindable var library: PlaylistLibrary
    let toasts: LibraryToastCenter
    /// 加入后的提示等 sheet 完全收起再显示：收起过程中出现的提示不会显示出来，Apple Music 也是收起后才出现。
    @State private var pendingToast: LibraryToast?

    func body(content: Content) -> some View {
        content.sheet(item: $library.pendingAddition, onDismiss: {
            if let toast = pendingToast { toasts.show(toast) }
            pendingToast = nil
        }) { addition in
            AddToPlaylistView(library: library, songs: addition.songs) { pendingToast = $0 }
                .presentationDetents([.large])
        }
    }
}

/// 选择要加入的播放列表，对照 Apple Music：最近播放、所有播放列表，文件夹可以进入；
/// 右上角排序，底部新建与多选。系统播放列表（如“喜爱歌曲”）不能手动添加，不列出。
struct AddToPlaylistView: View {
    let library: PlaylistLibrary
    let songs: [LibrarySongItem]
    /// 加入完成，交给宿主在 sheet 收起后提示。
    let added: (LibraryToast) -> Void
    @State private var sort = PlaylistSort.type
    /// 多选时已选的播放列表；为空集合表示正在多选但还没选，`nil` 表示不在多选。
    @State private var selection: Set<String>?

    var body: some View {
        NavigationStack {
            AddToPlaylistList(library: library, songs: songs, added: added, folderID: nil,
                              sort: $sort, selection: $selection)
                .navigationDestination(for: String.self) { folderID in
                    AddToPlaylistList(library: library, songs: songs, added: added, folderID: folderID,
                                      sort: $sort, selection: $selection)
                }
        }
    }
}

private struct AddToPlaylistList: View {
    let library: PlaylistLibrary
    let songs: [LibrarySongItem]
    let added: (LibraryToast) -> Void
    let folderID: String?
    @Binding var sort: PlaylistSort
    @Binding var selection: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isCreatingPlaylist = false
    @State private var isNamingFolder = false
    @State private var folderName = ""

    private var recent: [LibraryPlaylistItem] {
        Array(library.playlists.filter { !$0.isSystem && !$0.isReadOnly }.sorted { $0.lastPlayedOrder > $1.lastPlayedOrder }.prefix(3))
    }

    private var entries: [PlaylistEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            // 查找时不分层级，列出名称匹配的全部播放列表。
            return library.playlists.filter { !$0.isSystem && !$0.isReadOnly && $0.title.localizedStandardContains(trimmed) }
                .map(PlaylistEntry.playlist).sorted(by: sort)
        }
        let folders = library.folders(in: folderID).map { PlaylistEntry.folder($0, playlists: library.playlists(in: $0.id).filter { !$0.isReadOnly && !$0.isSystem }) }
        let playlists = library.playlists(in: folderID).filter { !$0.isSystem && !$0.isReadOnly }.map(PlaylistEntry.playlist)
        return (folders + playlists).sorted(by: sort)
    }

    private var title: String {
        guard let selection else { return folderID.flatMap { library.folder($0)?.name } ?? "添加到播放列表" }
        return selection.isEmpty ? "添加到…" : "添加到\(selection.count)个播放列表"
    }

    var body: some View {
        // 分组标题作为普通行，避免列表默认标题的灰色与吸顶背景。
        List {
            if folderID == nil, query.isEmpty, !recent.isEmpty {
                header("最近播放")
                ForEach(recent) { row(.playlist($0)) }
            }
            // 查找时只列结果，不显示分组标题。
            if query.isEmpty { header("所有播放列表") }
            ForEach(entries) { row($0) }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: folderID == nil ? "在播放列表中查找" : "在文件夹中查找")
        .searchDictationBehavior(.inline(activation: .onLook))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let selection {
                    // 多选时右上角改为确认，选中至少一个才可用。
                    Button("添加", systemImage: "checkmark", role: .confirm) { addToSelection(selection) }
                        .disabled(selection.isEmpty)
                } else {
                    Menu {
                        Picker("排序方式", selection: $sort) {
                            ForEach(PlaylistSort.options) { Text($0.title).tag($0.sort) }
                        }
                    } label: {
                        Label("排序方式", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            if selection == nil {
                ToolbarItem(placement: .bottomBar) {
                    Menu("新建", systemImage: "plus") {
                        Button("新建文件夹", systemImage: "folder.badge.plus") {
                            folderName = ""
                            isNamingFolder = true
                        }
                        Button("新建播放列表", systemImage: "text.badge.plus") { isCreatingPlaylist = true }
                    }
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                if selection == nil {
                    Button("选择", systemImage: "checklist") { withAnimation { selection = [] } }
                } else {
                    Button("取消选择", systemImage: "xmark") { withAnimation { selection = nil } }
                }
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            NewPlaylistView(library: library, folderID: folderID)
        }
        .alert("新建文件夹", isPresented: $isNamingFolder) {
            TextField("文件夹名称", text: $folderName)
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
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
    }

    private func row(_ entry: PlaylistEntry) -> some View {
        let isSelected = if case .playlist(let playlist) = entry { selection?.contains(playlist.id) == true } else { false }
        return rowContent(entry)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(isSelected ? Color(.systemGray4) : nil)
    }

    @ViewBuilder private func rowContent(_ entry: PlaylistEntry) -> some View {
        switch entry {
        case .folder(let folder, _):
            // 多选时文件夹不可进入，显示为灰色。
            NavigationLink(value: folder.id) { label(entry) }
                .disabled(selection != nil)
        case .playlist(let playlist):
            Button {
                if var current = selection {
                    if current.remove(playlist.id) == nil { current.insert(playlist.id) }
                    selection = current
                } else {
                    let count = library.addSongs(songs, to: playlist.id)
                    added(.addedToPlaylist(count: count, title: playlist.title,
                                           artwork: library.displayArtwork(of: playlist), playlistID: playlist.id))
                    library.pendingAddition = nil
                }
            } label: {
                label(entry)
            }
            .foregroundStyle(.primary)
        }
    }

    private func label(_ entry: PlaylistEntry) -> some View {
        let separatorInset: CGFloat = selection != nil && !entry.isFolder ? 102 : 60
        return HStack(spacing: 12) {
            if let selection {
                switch entry {
                case .playlist(let playlist):
                    SelectionMark(isSelected: selection.contains(playlist.id))
                case .folder:
                    // 文件夹没有选择圈，封面与选择圈左缘对齐。
                    EmptyView()
                }
            }
            ArtworkView(artwork: artwork(entry), cornerRadius: 6)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body)
                if let note = containedNote(entry) {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(minHeight: 48)
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + separatorInset
        }
    }

    /// 已在播放列表里的歌曲：全部都在时只说“歌曲已在播放列表中”，部分在时写明数量。
    private func containedNote(_ entry: PlaylistEntry) -> String? {
        guard case .playlist(let playlist) = entry else { return nil }
        let existing = Set(library.songs(in: playlist.id).map(\.id))
        let count = songs.filter { existing.contains($0.id) }.count
        if count == 0 { return nil }
        return count == songs.count ? "歌曲已在播放列表中" : "\(count)首歌曲已在播放列表中"
    }

    private func addToSelection(_ ids: Set<String>) {
        let targets = library.playlists.filter { ids.contains($0.id) && !$0.isSystem && !$0.isReadOnly }
        let count = targets.reduce(0) { $0 + library.addSongs(songs, to: $1.id) }
        added(.addedToPlaylists(count: count, playlistCount: targets.count))
        library.pendingAddition = nil
    }
}

/// 多选时行首的选择圈。
private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary),
                             isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 30)
            .accessibilityLabel(isSelected ? "已选择" : "未选择")
    }
}

private extension AddToPlaylistList {
    func artwork(_ entry: PlaylistEntry) -> Artwork {
        switch entry {
        case .folder(_, let playlists): .folder(playlists.prefix(4).map(library.displayArtwork))
        case .playlist(let playlist): library.displayArtwork(of: playlist)
        }
    }
}

private extension PlaylistEntry {
    var isFolder: Bool { if case .folder = self { true } else { false } }
}
