import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 用户播放列表的原生效果稿。所有编辑只作用于注入的内存资料库。
struct PlaylistDetailView: View {
    let playlistID: String
    let library: PlaylistLibrary
    let songs: [LibrarySongItem]
    /// 宿主提供示例最近播放，不将资料库顺序当作播放历史。
    var recentlyPlayedSongs: [LibrarySongItem] = []
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeLibraryDetail) private var closeLibraryDetail
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.collectionMenuActions) private var collectionActions
    @State private var query = ""
    @State private var sort = DetailSort.order
    @State private var showsAddMusic = false
    @State private var showsEditor = false
    @State private var showsDestinations = false

    private var playlist: LibraryPlaylistItem? { library.playlist(playlistID) }
    private var tracks: [LibrarySongItem] { library.songs(in: playlistID) }
    private var visibleTracks: [LibrarySongItem] {
        let filtered = tracks.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query) || $0.album.localizedStandardContains(query)
        }
        switch sort {
        case .order: return filtered
        case .title: return filtered.sorted(byName: \.title)
        case .artist: return filtered.sorted(byName: \.artist)
        case .album: return filtered.sorted(byName: \.album)
        }
    }
    var body: some View {
        Group {
            if let playlist {
                content(playlist)
            } else {
                ContentUnavailableView("播放列表已删除", systemImage: "music.note.list")
            }
        }
        .playlistDeletionConfirmation(library)
        .onChange(of: playlist == nil) { _, missing in
            if missing {
                if let close = closeLibraryDetail.handler { close() } else { dismiss() }
            }
        }
        .sheet(isPresented: $showsAddMusic) {
            AddPlaylistMusicView(title: playlist?.title ?? "播放列表", songs: songs,
                                 playlists: library.playlists, existingIDs: Set(tracks.map(\.id)),
                                 playlistSongs: Dictionary(uniqueKeysWithValues: library.playlists.map { playlist in
                                     (playlist.id, playlist.isSystem ? songs.filter(\.isFavorite) : library.songs(in: playlist.id))
                                 }), recentlyPlayedSongs: recentlyPlayedSongs) { selected in
                library.addSongs(selected, to: playlistID)
            }
        }
        .sheet(isPresented: $showsEditor) {
            PlaylistEditor(playlistID: playlistID, library: library, availableSongs: songs)
        }
        .sheet(isPresented: $showsDestinations) {
            PlaylistDestinationPicker(library: library, excluding: playlistID, songs: tracks)
        }
    }

    private func content(_ playlist: LibraryPlaylistItem) -> some View {
        List {
            header(playlist)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: tracks.isEmpty ? 39 : 24, trailing: 20))
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(query.isEmpty || !visibleTracks.isEmpty ? .visible : .hidden, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            Section {
                ForEach(visibleTracks) { song in
                    trackRow(song, title: playlist.title)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            !query.isEmpty && song.id == visibleTracks.last?.id ? 0 : 60
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        .swipeActions(edge: .leading) {
                            Button("插播", systemImage: "text.line.first.and.arrowtriangle.forward") { songActions.playNext(song) }
                                .labelStyle(.iconOnly)
                                .tint(.indigo)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation { library.removeSong(song.id, from: playlistID) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .accessibilityLabel("移除")
                            .tint(.red)
                        }
                }
                if query.isEmpty {
                    addMusicRow
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            .listSectionSeparator(.hidden, edges: .top)
            .listSectionSeparator(.visible, edges: .bottom)
            if query.isEmpty {
                if !tracks.isEmpty {
                    Text("\(tracks.count)首歌，\(tracks.reduce(0) { $0 + $1.duration } / 60)分钟")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 30)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }

            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .libraryTitleDisplayMode(.inline)
        .modifier(PlaylistDetailSearch(query: $query, enabled: !tracks.isEmpty))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("开始协作", systemImage: "person.fill.badge.plus") {}.disabled(true)
                Button("共享", systemImage: "square.and.arrow.up") {}.disabled(true)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    detailMenu(playlist)
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
                .menuOrder(.fixed)
            }
        }
    }

    private func header(_ playlist: LibraryPlaylistItem) -> some View {
        VStack(spacing: 0) {
            detailArtwork(playlist.artwork)
                .frame(width: 266, height: 266)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
                .padding(.top, 14)
                .padding(.bottom, 22)
            Text(playlist.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text("我").font(.title3).padding(.top, 4)
            Text("刚刚更新").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4 + 1.0 / 3)
            if !tracks.isEmpty {
                HStack(spacing: 14) {
                    Button {
                        collectionActions.play(.playlist(playlistID), true)
                    } label: { actionCircle("随机播放", image: "shuffle") }
                    Button {
                        collectionActions.play(.playlist(playlistID), false)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                            Text("播放")
                        }
                            .font(.headline)
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 160, height: 48)
                            .background(Color.primary, in: .capsule)
                    }
                    Button {} label: { actionCircle("下载", image: "arrow.down") }.disabled(true)
                }
                .buttonStyle(.plain)
                .padding(.top, 15)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func detailArtwork(_ artwork: Artwork) -> some View {
        if case .playlist = artwork {
            // 同尺寸 AM 截图：798px 封面内音符宽约311px；详情占位底色为中性灰。
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 229 / 255, green: 229 / 255, blue: 230 / 255))
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 266 * 0.391))
                        .foregroundStyle(Color(red: 176 / 255, green: 176 / 255, blue: 179 / 255))
                }
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.074), lineWidth: 1 / displayScale) }
                .accessibilityHidden(true)
        } else {
            ArtworkView(artwork: artwork, cornerRadius: 10)
        }
    }

    private func actionCircle(_ title: String, image: String) -> some View {
        Label(title, systemImage: image)
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .frame(width: 48, height: 48)
            .background(Color(.tertiarySystemFill), in: .circle)
    }

    private func trackRow(_ song: LibrarySongItem, title: String) -> some View {
        HStack(spacing: 12) {
            Button {
                let list = visibleTracks
                guard let index = list.firstIndex(where: { $0.id == song.id }) else { return }
                songActions.play(list, index, title)
            } label: { PlaylistDetailSongLabel(song: song) }
                .buttonStyle(.plain)
            Menu { SongMenuContents(song: song) } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 30, height: 44).offset(x: 1)
            }
            .accessibilityLabel("更多")
            .menuOrder(.fixed)
            .buttonStyle(.borderless)
            .tint(.secondary)
        }
        .songContextMenu(song)
    }

    private var addMusicRow: some View {
        Button { showsAddMusic = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 5))
                Text("添加音乐").font(.system(size: 16))
                Spacer()
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func detailMenu(_ playlist: LibraryPlaylistItem) -> some View {
        ControlGroup {
            Button("下载", systemImage: "arrow.down.circle.fill") {}.disabled(true)
            Button(playlist.isFavorite ? "撤销" : "喜爱", systemImage: playlist.isFavorite ? "star.slash.fill" : "star.fill") {
                library.toggleFavorite(playlistID)
            }
            Button("共享", systemImage: "square.and.arrow.up.fill") {}.disabled(true)
        }
        Section {
            Button(playlist.isPinned ? "取消置顶播放列表" : "置顶播放列表", systemImage: playlist.isPinned ? "pin.slash" : "pin") {
                library.togglePin(playlistID)
            }
            Button("添加到播放列表", systemImage: "text.badge.plus") { showsDestinations = true }.disabled(tracks.isEmpty)
        }
        Section {
            Button("编辑", systemImage: "pencil") { showsEditor = true }
            Button("开始协作", systemImage: "person.badge.plus") {}.disabled(true)
            Menu("排序方式", systemImage: "arrow.up.arrow.down") {
                Picker("排序方式", selection: $sort) {
                    ForEach(DetailSort.allCases) { value in Text(value.rawValue).tag(value) }
                }
            }
            Menu("移到文件夹", systemImage: "folder") {
                Button { library.move(playlistID: playlistID, to: nil) } label: {
                    Label("播放列表", systemImage: library.folderID(of: playlistID) == nil ? "checkmark" : "music.note.list")
                }
                ForEach(library.folders) { folder in
                    Button { library.move(playlistID: playlistID, to: folder.id) } label: {
                        Label(folder.name, systemImage: library.folderID(of: playlistID) == folder.id ? "checkmark" : "folder")
                    }
                }
            }
            .disabled(library.folders.isEmpty)
        }
        LibraryMenuContents(sections: [
            libraryQueueMenuItems(
                playbackSource: collectionActions.playbackSource(),
                isDisabled: tracks.isEmpty,
                playNext: { collectionActions.playNext(.playlist(playlistID)) },
                playLater: { collectionActions.playLater(.playlist(playlistID)) })
        ], firstSectionIsRow: false)
        Section {
            Button("从资料库删除", systemImage: "trash", role: .destructive) { library.pendingDeletion = playlist }
        }
    }

    private enum DetailSort: String, CaseIterable, Identifiable {
        case order = "播放列表顺序", title = "标题", artist = "艺人", album = "专辑"
        var id: Self { self }
    }
}

private struct PlaylistDetailSongLabel: View {
    let song: LibrarySongItem
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: song.artwork, cornerRadius: 5).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.callout).foregroundStyle(.primary)
                Text(song.artist).font(.footnote).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
    }
}

private struct PlaylistDetailSearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    func body(content: Content) -> some View {
        content.librarySearchable(text: $query, prompt: "搜索", enabled: enabled)
    }
}

extension View {
    /// 长按菜单等入口请求编辑播放列表时弹出编辑页，挂在应用根部。
    func playlistEditSheet(_ library: PlaylistLibrary, songs: [LibrarySongItem]) -> some View {
        modifier(PlaylistEditSheet(library: library, songs: songs))
    }
}

private struct PlaylistEditSheet: ViewModifier {
    @Bindable var library: PlaylistLibrary
    let songs: [LibrarySongItem]

    func body(content: Content) -> some View {
        content.sheet(item: $library.pendingEdit) { playlist in
            PlaylistEditor(playlistID: playlist.id, library: library, availableSongs: songs)
        }
    }
}

/// 编辑草稿仅在完成时提交；取消或放弃不改变资料库。
private struct PlaylistEditor: View {
    let playlistID: String
    let library: PlaylistLibrary
    let availableSongs: [LibrarySongItem]
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var showsOnProfile = true
    @State private var tracks: [LibrarySongItem] = []
    @State private var selectedTracks: Set<String> = []
    @State private var artwork: Artwork = .playlist
    @State private var coverSelection = PlaylistCoverSelection()
    @State private var showsDiscard = false
    @State private var showsMusic = false

    var body: some View {
        let displayedCover = coverSelection.image
        let displayedArtwork = artwork
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Color(.tertiarySystemFill)
                        if let displayedCover { Image(uiImage: displayedCover).resizable().scaledToFill() }
                        else if case .image = displayedArtwork { ArtworkView(artwork: displayedArtwork, cornerRadius: 6) }
                        PlaylistCoverMenu(selection: coverSelection, accessibilityLabel: "编辑播放列表封面")
                    }
                    .frame(width: 180, height: 180).clipShape(.rect(cornerRadius: 6))
                    .padding(.top, 20).padding(.bottom, 58 + 2.0 / 3)
                    TextField("播放列表标题", text: $title)
                        .font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center).submitLabel(.done)
                        .frame(minHeight: 44)
                    Divider()
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("描述").font(.system(size: 15)).foregroundStyle(Color(.placeholderText))
                                .padding(.top, 10).allowsHitTesting(false)
                        }
                        PlaylistDescriptionTextView(text: $description)
                    }
                    .frame(height: 58)
                    Divider()
                    Toggle("在个人资料页和搜索中显示", isOn: $showsOnProfile)
                        .font(.subheadline).tint(.green).frame(minHeight: 40)
                    Divider()
                    if !tracks.isEmpty {
                        ForEach(tracks) { song in
                            HStack {
                                Button {
                                    if !selectedTracks.insert(song.id).inserted { selectedTracks.remove(song.id) }
                                } label: {
                                    HStack {
                                        Image(systemName: selectedTracks.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                        PlaylistDetailSongLabel(song: song)
                                    }
                                }.buttonStyle(.plain)
                                Menu("调整顺序", systemImage: "line.3.horizontal") {
                                    Button("上移") { move(song.id, by: -1) }
                                    Button("下移") { move(song.id, by: 1) }
                                }.labelStyle(.iconOnly)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                }.padding(.horizontal, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { showsDiscard = true }.tint(.primary)
                        .popover(isPresented: $showsDiscard) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(title).font(.headline).padding(.leading, 14).padding(.bottom, 8)
                                Text("确定要放弃更改吗？").font(.subheadline).foregroundStyle(.secondary)
                                    .padding(.leading, 14).padding(.bottom, 20)
                                Button("放弃更改", role: .destructive) { showsDiscard = false; dismiss() }
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(Color.primary.opacity(0.125), in: .capsule)
                            }
                            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 16).frame(width: 240)
                            .presentationCompactAdaptation(.popover)
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") {
                        let result = coverSelection.image.map { Artwork.image(Image(uiImage: $0)) } ?? artwork
                        library.savePlaylist(playlistID, title: title, description: description,
                                             showsOnProfile: showsOnProfile, artwork: result, songs: tracks)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent).tint(.blue)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coverSelection.isLoading)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("移除所选歌曲", systemImage: "trash") {
                        tracks.removeAll { selectedTracks.contains($0.id) }
                        selectedTracks.removeAll()
                    }.disabled(selectedTracks.isEmpty)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("添加音乐", systemImage: "plus") { showsMusic = true }
                }
            }
            .sheet(isPresented: $showsMusic) {
                AddPlaylistMusicView(title: title, songs: availableSongs, playlists: library.playlists,
                                     existingIDs: Set(tracks.map(\.id))) { selected in tracks.append(contentsOf: selected) }
            }
            .modifier(PlaylistCoverPicker(selection: coverSelection))
            .interactiveDismissDisabled()
            // 下拉时与点叉号一样，弹出锚定在叉号上的“放弃更改”确认。
            .onSheetDismissAttempt { showsDiscard = true }
            .onAppear {
                guard let playlist = library.playlist(playlistID) else { return }
                title = playlist.title
                description = playlist.description
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-mockDescription"), index + 1 < arguments.count {
                    description = arguments[index + 1]
                    title = "2"
                }
                #endif
                showsOnProfile = playlist.showsOnProfile
                artwork = playlist.artwork
                tracks = library.songs(in: playlistID)
            }
        }
    }
    private func move(_ id: String, by distance: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }),
              tracks.indices.contains(index + distance) else { return }
        tracks.swapAt(index, index + distance)
    }

}

/// 固定两行的原生文本区域，文本较长时在内部滚动。
private struct PlaylistDescriptionTextView: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 15)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 6, right: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        view.typingAttributes = [.font: UIFont.systemFont(ofSize: 15), .paragraphStyle: paragraph]
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.accessibilityLabel = "描述"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            view.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: PlaylistDescriptionTextView
        init(_ parent: PlaylistDescriptionTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

/// Each form owns its own selection draft; only the form's save action persists it.
@MainActor @Observable
final class PlaylistCoverSelection {
    var image: UIImage?
    var isLoading = false
    var photo: PhotosPickerItem?
    var showsCamera = false
    var showsPhotoPicker = false
    var showsFilePicker = false
    var photoError = false
    private(set) var generation = 0

    func prepareForSelection() {
        generation += 1
        photo = nil
        isLoading = false
        photoError = false
    }

    func loadPhoto(using loader: @MainActor () async throws -> Data?) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        photoError = false
        defer {
            // Cancellation may finish this request, but never a newer request's loading state.
            if generation == requestGeneration { isLoading = false }
        }
        do {
            let data = try await loader()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            accept(data)
        } catch {
            if generation == requestGeneration, !Task.isCancelled, !Self.isCancellation(error) {
                photoError = true
            }
        }
    }

    func importFile(_ result: Result<URL, Error>) {
        generation += 1
        isLoading = false
        photoError = false
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            accept(try Data(contentsOf: url))
        } catch {
            if !Self.isCancellation(error) { photoError = true }
        }
    }

    private func accept(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else { photoError = true; return }
        self.image = image
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

struct PlaylistCoverMenu: View {
    let selection: PlaylistCoverSelection
    let accessibilityLabel: String

    var body: some View {
        Menu {
            Button("拍照", systemImage: "camera") {
                selection.prepareForSelection()
                selection.showsCamera = true
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("选取照片", systemImage: "photo.on.rectangle") {
                selection.prepareForSelection()
                selection.showsPhotoPicker = true
            }
            Button("选取文件", systemImage: "folder") {
                selection.prepareForSelection()
                selection.showsFilePicker = true
            }
        } label: {
            Image(systemName: "photo").font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white).frame(width: 64, height: 64).background(.black, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Present pickers from the persistent form, not from transient menu contents.
struct PlaylistCoverPicker: ViewModifier {
    @Bindable var selection: PlaylistCoverSelection

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $selection.showsCamera) {
                PlaylistCoverCamera(image: $selection.image).ignoresSafeArea()
            }
            .photosPicker(isPresented: $selection.showsPhotoPicker, selection: $selection.photo, matching: .images)
            .fileImporter(isPresented: $selection.showsFilePicker, allowedContentTypes: [.image]) { result in
                selection.importFile(result)
            }
            .task(id: selection.photo) {
                guard let photo = selection.photo else { return }
                await selection.loadPhoto { try await photo.loadTransferable(type: Data.self) }
            }
            .alert("无法读取图片", isPresented: $selection.photoError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请选择其他图片重试。")
            }
    }
}

private struct PlaylistCoverCamera: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PlaylistCoverCamera
        init(_ parent: PlaylistCoverCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

private struct PlaylistDestinationPicker: View {
    let library: PlaylistLibrary
    let excluding: String
    let songs: [LibrarySongItem]
    @Environment(\.dismiss) private var dismiss
    private var destinations: [LibraryPlaylistItem] { library.playlists.filter { !$0.isSystem && $0.id != excluding } }
    var body: some View {
        NavigationStack {
            List(destinations) { playlist in
                Button {
                    library.addSongs(songs, to: playlist.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(artwork: playlist.artwork).frame(width: 48, height: 48)
                        Text(playlist.title).foregroundStyle(.primary)
                    }
                }
            }
            .overlay {
                if destinations.isEmpty { ContentUnavailableView("没有其他播放列表", systemImage: "music.note.list") }
            }
            .navigationTitle("添加到播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } } }
        }
    }
}
