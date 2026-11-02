import SwiftUI

extension View {
    /// 播放列表等待移到文件夹时弹出选择页，挂在应用根部。
    func moveToFolderSheet(_ library: PlaylistLibrary) -> some View {
        modifier(MoveToFolderSheet(library: library))
    }
}

private struct MoveToFolderSheet: ViewModifier {
    @Bindable var library: PlaylistLibrary

    func body(content: Content) -> some View {
        content.sheet(item: $library.pendingMove) { playlist in
            MoveToFolderView(library: library, playlist: playlist)
        }
    }
}

/// 选择播放列表要移入的位置，对照 Apple Music：只有文件夹可以进入，播放列表显示为灰色；
/// 进入目标位置后点右上角确认。顶部小字说明正在移动哪个播放列表。
private struct MoveToFolderView: View {
    let library: PlaylistLibrary
    let playlist: LibraryPlaylistItem
    @State private var sort = PlaylistSort.type

    var body: some View {
        // 说明文字单独一行，在导航栏上方，与 Apple Music 一致。
        VStack(spacing: -6) {
            Text("将“\(playlist.title)”移到")
                .font(.footnote)
                .lineLimit(1)
                .padding(.top, 24)
                .padding(.horizontal, 60)
            NavigationStack {
                MoveToFolderList(library: library, playlist: playlist, folderID: nil, sort: $sort)
                    .navigationDestination(for: String.self) { folderID in
                        MoveToFolderList(library: library, playlist: playlist, folderID: folderID, sort: $sort)
                    }
            }
        }
    }
}

private struct MoveToFolderList: View {
    let library: PlaylistLibrary
    let playlist: LibraryPlaylistItem
    let folderID: String?
    @Binding var sort: PlaylistSort
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isNamingFolder = false
    @State private var folderName = ""

    private var entries: [PlaylistEntry] {
        let folders = library.folders(in: folderID).map { PlaylistEntry.folder($0, playlists: library.playlists(in: $0.id)) }
        let all = (folders + library.playlists(in: folderID).map(PlaylistEntry.playlist)).sorted(by: sort)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? all : all.filter { $0.title.localizedStandardContains(trimmed) }
    }

    /// 已经在这个位置时不能确认。
    private var isCurrentLocation: Bool { library.folderID(of: playlist.id) == folderID }

    var body: some View {
        List {
            Text("所有播放列表")
                .font(.subheadline.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
            ForEach(entries) { row($0) }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: folderID == nil ? "在播放列表中查找" : "在文件夹中查找")
        .searchDictationBehavior(.inline(activation: .onLook))
        .navigationTitle(folderID.flatMap { library.folder($0)?.name } ?? "所有播放列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sort) {
                        ForEach(PlaylistSort.options) { Text($0.title).tag($0.sort) }
                    }
                } label: {
                    Label("排序方式", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("移到这里", systemImage: "checkmark", role: .confirm) {
                    library.pendingMove = nil
                    withAnimation { library.move(playlistID: playlist.id, to: folderID) }
                }
                .disabled(isCurrentLocation)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("新建文件夹", systemImage: "plus") {
                    folderName = ""
                    isNamingFolder = true
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
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

    @ViewBuilder private func row(_ entry: PlaylistEntry) -> some View {
        switch entry {
        case .folder(let folder, _):
            NavigationLink(value: folder.id) { label(entry) }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        case .playlist:
            // 播放列表不是可选的目标，显示为灰色。
            label(entry)
                .opacity(0.45)
                .accessibilityAddTraits(.isStaticText)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private func label(_ entry: PlaylistEntry) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artwork(entry), cornerRadius: 6)
                .frame(width: 48)
                .overlay(alignment: .leading) { FavoriteMark(isFavorite: entry.shelfItem.isFavorite, color: .yellow) }
            Text(entry.title).font(.body).lineLimit(1)
        }
        .frame(minHeight: 48)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
    }

    private func artwork(_ entry: PlaylistEntry) -> Artwork {
        switch entry {
        case .folder(_, let playlists): .folder(playlists.prefix(4).map(library.displayArtwork))
        case .playlist(let playlist): library.displayArtwork(of: playlist)
        }
    }
}
