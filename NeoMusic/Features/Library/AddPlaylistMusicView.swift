import SwiftUI

/// 添加音乐效果稿：选择只保留在本次会话中，完成后才交给播放列表宿主。
struct AddPlaylistMusicView: View {
    let title: String
    let songs: [LibrarySongItem]
    let playlists: [LibraryPlaylistItem]
    let existingIDs: Set<String>
    var playlistSongs: [String: [LibrarySongItem]] = [:]
    var recentlyPlayedSongs: [LibrarySongItem] = []
    let onCommit: ([LibrarySongItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: [String] = []
    @State private var query = ""
    @State private var confirmsDiscard = false
    @State private var path: [MusicPickerRoute] = []

    private var heading: String {
        selectedIDs.isEmpty ? "添加到“\(title)”" : "已选择\(selectedIDs.count)首歌曲"
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationTitle(heading)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { controls }
                .navigationDestination(for: MusicPickerRoute.self) { route in
                    destination(route)
                        .navigationTitle(route.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { controls }
                }
        }
        .padding(.top, 34)
        .background(Color(.systemBackground).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(.blue)
        .interactiveDismissDisabled(!selectedIDs.isEmpty)
        .onSheetDismissAttempt { confirmsDiscard = true }
        .alert("", isPresented: $confirmsDiscard) {
            Button("放弃所选内容", role: .destructive) { dismiss() }
            Button("保留所选内容", role: .cancel) {}
        } message: {
            Text("确定要放弃所选内容吗？")
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark") {
                if selectedIDs.isEmpty { dismiss() } else { confirmsDiscard = true }
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(selectedIDs.isEmpty ? "完成" : "添加\(selectedIDs.count)首", systemImage: "checkmark") {
                let available = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                onCommit(selectedIDs.compactMap { available[$0] })
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
        }
    }

    private var rootContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    libraryCategories
                    carousel("最近喜爱", songs: songs.filter(\.isFavorite))
                    carousel("最近播放", songs: recentlyPlayedSongs)
                } else {
                    songRows(matching(songs))
                        .padding(.horizontal, 20)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .frame(width: 17)
                .accessibilityHidden(true)
            TextField("歌曲、艺人或专辑", text: $query, prompt: Text("歌曲、艺人或专辑").fontWeight(.semibold).foregroundStyle(Color(white: 0.58)))
                .submitLabel(.search)
                .autocorrectionDisabled()
            Button("语音搜索暂不可用", systemImage: "mic") {}
                .labelStyle(.iconOnly)
                .font(.system(size: 18)).frame(width: 22).offset(x: 1.0 / 3, y: -1.0 / 3)
                .foregroundStyle(.secondary)
                .disabled(true)
            if !query.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var libraryCategories: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("资料库").font(.headline).padding(.horizontal, 20)
            VStack(spacing: 0) {
                ForEach(MusicPickerRoute.categories, id: \.self) { route in
                    NavigationLink(value: route) {
                        HStack(spacing: 18) {
                            Image(systemName: route.image).font(.title2).frame(width: 25).offset(x: 1.67)
                            Text(route.title).font(.body)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary).offset(x: -4.0 / 3)
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 52)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if route != .recent { Divider().padding(.leading, 43).padding(.trailing, -10) }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder private func carousel(_ title: String, songs: [LibrarySongItem]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).padding(.horizontal, 20)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(MusicPickerPage.pages(songs)) { page in
                            songRows(page.songs)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder private func songRows(_ entries: [LibrarySongItem]) -> some View {
        if entries.isEmpty {
            ContentUnavailableView("没有歌曲", systemImage: "music.note", description: Text("试试其他分类或搜索内容。"))
        } else {
            VStack(spacing: 0) {
                ForEach(entries) { song in
                    MusicPickerSongRow(song: song,
                                       selected: selectedIDs.contains(song.id) || existingIDs.contains(song.id),
                                       alreadyAdded: existingIDs.contains(song.id)) {
                        if let index = selectedIDs.firstIndex(of: song.id) {
                            selectedIDs.remove(at: index)
                        } else {
                            selectedIDs.append(song.id)
                        }
                    }
                    if song.id != entries.last?.id { Divider().padding(.leading, 64) }
                }
            }
        }
    }

    @ViewBuilder private func destination(_ route: MusicPickerRoute) -> some View {
        switch route {
        case .artists:
            groupList(songs, by: \.artist, isArtist: true)
        case .albums:
            groupList(songs, by: \.album, isArtist: false)
        case .playlists:
            List(playlists) { playlist in
                NavigationLink(value: MusicPickerRoute.playlist(playlist.id, playlist.title)) {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: playlist.artwork, cornerRadius: 6).frame(width: 48, height: 48)
                        Text(playlist.title)
                    }
                }
            }
            .listStyle(.plain)
        case .songs:
            songsPage(songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        case .recent:
            songsPage(songs.sorted { $0.addedOrder > $1.addedOrder })
        case .artist(let name): songsPage(songs.filter { $0.artist == name })
        case .album(let name): songsPage(songs.filter { $0.album == name })
        case .playlist(let id, _): songsPage(playlistSongs[id] ?? [])
        }
    }

    private func groupList(_ songs: [LibrarySongItem], by key: KeyPath<LibrarySongItem, String>, isArtist: Bool) -> some View {
        let names = Set(songs.map { $0[keyPath: key] }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return List(names, id: \.self) { name in
            NavigationLink(value: isArtist ? MusicPickerRoute.artist(name) : .album(name)) {
                Label(name, systemImage: isArtist ? "music.microphone" : "square.stack")
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
            }
        }
        .listStyle(.plain)
    }

    private func songsPage(_ songs: [LibrarySongItem]) -> some View {
        ScrollView {
            songRows(matching(songs)).padding(.horizontal, 20)
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .scrollDismissesKeyboard(.interactively)
    }

    private func matching(_ songs: [LibrarySongItem]) -> [LibrarySongItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return songs }
        return songs.filter { song in
            [song.title, song.artist, song.album].contains { $0.localizedStandardContains(term) }
        }
    }
}

private enum MusicPickerRoute: Hashable {
    case artists, albums, songs, playlists, recent
    case artist(String), album(String), playlist(String, String)

    static let categories: [Self] = [.artists, .albums, .songs, .playlists, .recent]
    var title: String {
        switch self {
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        case .recent: "最近添加"
        case .artist(let name), .album(let name), .playlist(_, let name): name
        }
    }
    var image: String {
        switch self {
        case .artists, .artist: "music.microphone"
        case .albums, .album: "square.stack"
        case .songs: "music.note"
        case .playlists, .playlist: "music.note.list"
        case .recent: "clock"
        }
    }
}

private struct MusicPickerPage: Identifiable {
    let songs: [LibrarySongItem]
    var id: String { songs[0].id }
    static func pages(_ songs: [LibrarySongItem]) -> [Self] {
        stride(from: 0, to: songs.count, by: 4).map { start in
            Self(songs: Array(songs[start..<min(start + 4, songs.count)]))
        }
    }
}

struct MusicPickerSongRow: View {
    let song: LibrarySongItem
    let selected: Bool
    let alreadyAdded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            MusicPickerSongRowLabel(song: song, selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .accessibilityLabel("\(song.title)，\(song.artist)")
        .accessibilityValue(alreadyAdded ? "已在播放列表中" : selected ? "已选择" : "未选择")
        .accessibilityHint(alreadyAdded ? "" : selected ? "轻点取消选择" : "轻点添加")
    }
}

struct MusicPickerSongRowLabel: View {
    let song: LibrarySongItem
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: song.artwork, cornerRadius: 5).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.body).foregroundStyle(.primary)
                Text(song.artist).font(.footnote)
                    .foregroundStyle(contrast == .increased ? Color.primary : Color(white: 0.60))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark" : "plus.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? Color.blue : Color.primary)
                .frame(width: 40)
                .padding(.trailing, 4)
        }
        .frame(minHeight: 64)
        .contentShape(.rect)
    }
}
