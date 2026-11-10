#if DEBUG
import SwiftUI

struct FrontendFormsPreview: View {
    let page: String
    @State private var library: PlaylistLibrary
    @State private var showsNewPlaylist = false
    @State private var showsAddMusic = false
    @State private var showsCoverPreview = false
    @State private var coverSelection = PlaylistCoverSelection()

    private static let songs = [
        LibrarySongItem(id: "preview:one", title: "半梦", artist: "胧", album: "日常片段",
                        albumArtist: "胧", trackNumber: 1, artwork: .missing),
        LibrarySongItem(id: "preview:two", title: "半梦-星尘 Ver-", artist: "胧", album: "日常片段",
                        albumArtist: "胧", trackNumber: 2, artwork: .missing),
        LibrarySongItem(id: "preview:three", title: "晚风", artist: "林间", album: "日常片段",
                        albumArtist: "林间", trackNumber: 3, artwork: .missing)
    ]

    init(page: String) {
        self.page = page
        let library = PlaylistLibrary(playlists: [
            LibraryPlaylistItem(id: "preview:playlist", title: "2", artwork: .playlist)
        ])
        library.addSongs(Array(Self.songs.prefix(2)), to: "preview:playlist")
        _library = State(initialValue: library)
    }

    var body: some View {
        switch page {
        case "errors": errorPreview
        case "login": loginPreview
        case "cover": coverPreview
        default: formPreview
        }
    }

    private var formPreview: some View {
        NavigationStack {
            List {
                Section("草稿关闭") {
                    Button("新建播放列表") { showsNewPlaylist = true }
                    Button("编辑播放列表") { library.pendingEdit = library.playlist("preview:playlist") }
                    Button("封面读取进度") { showsCoverPreview = true }
                    Button("添加音乐") { showsAddMusic = true }
                }
                Section("本次预览的播放列表") {
                    ForEach(library.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.title)
                            Text("\(library.songs(in: playlist.id).count)首歌曲")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("播放列表表单")
        }
        .sheet(isPresented: $showsNewPlaylist) { NewPlaylistView(library: library) }
        .sheet(isPresented: $showsAddMusic) {
            AddPlaylistMusicView(title: library.playlist("preview:playlist")?.title ?? "播放列表", songs: Self.songs, playlists: library.playlists,
                                 existingIDs: Set(library.songs(in: "preview:playlist").map(\.id))) {
                library.addSongs($0, to: "preview:playlist")
            }
        }
        .playlistEditSheet(library, songs: { Self.songs })
        .sheet(isPresented: $showsCoverPreview) {
            coverPreview
        }
    }

    private var errorPreview: some View {
        NavigationStack {
            List {
                Section {
                    Label("登录网易云音乐", systemImage: "person.crop.circle")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        AccountErrorMessage(message: NeteaseAccountError.keychain(-34018).localizedDescription,
                                            technicalDetails: NeteaseAccountError.keychain(-34018).technicalDetails)
                        Button("重新验证") {}.foregroundStyle(.tint)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("账户验证状态")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var loginPreview: some View {
        NavigationStack {
            Color(.systemBackground)
                .navigationTitle("登录网易云音乐")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {} label: { LoginCompletionLabel(checking: true) }
                            .disabled(true)
                    }
                }
        }
    }

    private var coverPreview: some View {
        PlaylistEditor(playlistID: "preview:playlist", library: library, availableSongs: Self.songs, coverSelection: coverSelection)
            .task { coverSelection.isLoading = true }
    }
}
#endif
