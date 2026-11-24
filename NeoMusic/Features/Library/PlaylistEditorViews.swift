import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PlaylistDraftSnapshot: Equatable {
    let title: String
    let description: String
    let songIDs: [String]

    init(title: String = "", description: String = "", songIDs: [String] = []) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description
        self.songIDs = songIDs
    }

    func hasChanges(title: String, description: String = "", songIDs: [String] = [], hasCoverChange: Bool = false) -> Bool {
        hasCoverChange || self != Self(title: title, description: description, songIDs: songIDs)
    }
}

struct PlaylistEditor: View {
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
    @State private var coverSelection: PlaylistCoverSelection
    @State private var showsDiscard = false
    @State private var showsMusic = false
    @State private var initialDraft: PlaylistDraftSnapshot?

    init(playlistID: String, library: PlaylistLibrary, availableSongs: [LibrarySongItem],
         coverSelection: PlaylistCoverSelection? = nil) {
        self.playlistID = playlistID
        self.library = library
        self.availableSongs = availableSongs
        _coverSelection = State(initialValue: coverSelection ?? PlaylistCoverSelection())
    }

    private var hasChanges: Bool {
        initialDraft?.hasChanges(title: title, description: description, songIDs: tracks.map(\.id),
                                 hasCoverChange: coverSelection.image != nil) ?? false
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedTracks) {
                PlaylistEditorFields(title: $title, description: $description, artwork: artwork,
                                     coverSelection: coverSelection)
                    .selectionDisabled(true)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                    .listRowSeparator(.hidden)
                ForEach(tracks) { song in
                    HStack(spacing: 8) {
                        PlaylistSongArtwork(song: song, cornerRadius: DesignTokens.Radius.songRowCover)
                            .frame(width: DesignTokens.Artwork.rowCoverSize, height: DesignTokens.Artwork.rowCoverSize)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.body)
                                .foregroundStyle(song.unavailabilityReason == nil ? .primary : .secondary)
                            Text(song.unavailabilityReason ?? song.artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tag(song.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .onMove { tracks.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark", action: requestDismiss).tint(.primary)
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
                AddPlaylistMusicView(
                    title: title,
                    songs: availableSongs,
                    playlists: library.playlists,
                    existingIDs: Set(tracks.map(\.id)),
                    playlistLibrary: library
                ) { selected in tracks.append(contentsOf: selected) }
            }
            .modifier(PlaylistCoverPicker(selection: coverSelection))
            .interactiveDismissDisabled(hasChanges)
            .onSheetDismissAttempt(requestDismiss)
            .alert("", isPresented: $showsDiscard) {
                Button("放弃更改", role: .destructive, action: close)
                Button("取消", role: .cancel) {}
            } message: {
                Text("确定要放弃更改吗？")
            }
            .onAppear {
                guard initialDraft == nil, let playlist = library.playlist(playlistID) else { return }
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
                initialDraft = PlaylistDraftSnapshot(title: title, description: description, songIDs: tracks.map(\.id))
            }
        }
    }

    private func requestDismiss() {
        if hasChanges { showsDiscard = true } else { close() }
    }

    private func close() {
        coverSelection.cancelPendingLoad()
        dismiss()
    }
}

struct PlaylistFormCover: View {
    let selection: PlaylistCoverSelection
    var artwork: Artwork = .playlist
    let accessibilityLabel: String
    let bottomSpacing: CGFloat

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image = selection.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if case .image = artwork {
                ArtworkView(artwork: artwork, cornerRadius: DesignTokens.Radius.songRowCover)
            }
            PlaylistCoverMenu(selection: selection, accessibilityLabel: accessibilityLabel)
        }
        .frame(width: 180, height: 180)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.songRowCover))
        .overlay { RoundedRectangle(cornerRadius: DesignTokens.Radius.songRowCover).strokeBorder(.black.opacity(0.04)) }
        .padding(.top, 20)
        .padding(.bottom, bottomSpacing)
    }
}

private struct PlaylistEditorFields: View {
    @Binding var title: String
    @Binding var description: String
    var artwork: Artwork = .playlist
    let coverSelection: PlaylistCoverSelection
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = DesignTokens.Typography.sectionHeadingSize
    @ScaledMetric(relativeTo: .subheadline) private var descriptionSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var descriptionHeight: CGFloat = 58

    var body: some View {
        VStack(spacing: 0) {
            PlaylistFormCover(selection: coverSelection, artwork: artwork,
                              accessibilityLabel: "编辑播放列表封面", bottomSpacing: 58 + 2.0 / 3)
            TextField("播放列表标题", text: $title)
                .font(.system(size: titleSize, weight: .semibold)).multilineTextAlignment(.center).submitLabel(.done)
                .frame(minHeight: 44)
            Divider()
            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("描述").font(.system(size: descriptionSize)).foregroundStyle(Color(.placeholderText))
                        .padding(.top, 10).allowsHitTesting(false)
                }
                PlaylistDescriptionTextView(text: $description)
            }
            .frame(height: descriptionHeight)
            Divider()
            Toggle("在个人资料页和搜索中显示", isOn: .constant(false))
                .font(.subheadline).tint(.green).frame(minHeight: 40)
                .disabled(true)
                .accessibilityHint("本地播放列表暂不支持公开显示")
            Divider()
        }
        .frame(maxWidth: .infinity)
    }
}

struct PlaylistDescriptionTextView: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.accessibilityLabel = "描述"
        updateTextAndStyle(view)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        updateTextAndStyle(view)
    }

    func updateTextAndStyle(_ view: UITextView) {
        let font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15), compatibleWith: view.traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph
        ]
        if view.text != text {
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
        } else if view.font != font {
            view.textStorage.addAttributes(attributes, range: NSRange(location: 0, length: view.textStorage.length))
        }
        view.font = font
        view.typingAttributes = attributes
        view.adjustsFontForContentSizeCategory = true
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: PlaylistDescriptionTextView
        init(_ parent: PlaylistDescriptionTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

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
        cancelPendingLoad()
    }

    func cancelPendingLoad() {
        generation += 1
        photo = nil
        isLoading = false
        photoError = false
    }

    func loadPhoto(using loader: @MainActor () async throws -> Data?) async {
        await loadImage {
            guard let data = try await loader() else { return nil }
            return UIImage(data: data)
        }
    }

    func importFile(_ result: Result<URL, Error>) async {
        await loadImage {
            try await Self.decodeFile(try result.get())
        }
    }

    private func loadImage(using loader: @MainActor () async throws -> UIImage?) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        photoError = false
        defer {
            if generation == requestGeneration { isLoading = false }
        }
        do {
            let loaded = try await loader()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard let loaded else { photoError = true; return }
            image = loaded
        } catch {
            if generation == requestGeneration, !Task.isCancelled, !Self.isCancellation(error) {
                photoError = true
            }
        }
    }

    @concurrent private static func decodeFile(_ url: URL) async throws -> UIImage? {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return ImageSourceThumbnail.image(at: url, maxPixels: 1536).map { UIImage(cgImage: $0) }
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
            Group {
                if selection.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "photo").font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 64, height: 64).background(.black, in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.isLoading ? "正在读取照片" : accessibilityLabel)
    }
}

struct PlaylistCoverPicker: ViewModifier {
    @Bindable var selection: PlaylistCoverSelection

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $selection.showsCamera) {
                PlaylistCoverCamera(image: $selection.image).ignoresSafeArea()
            }
            .photosPicker(isPresented: $selection.showsPhotoPicker, selection: $selection.photo, matching: .images)
            .fileImporter(isPresented: $selection.showsFilePicker, allowedContentTypes: [.image]) { result in
                Task { await selection.importFile(result) }
            }
            .task(id: selection.photo) {
                guard let photo = selection.photo else { return }
                await selection.loadPhoto { try await photo.loadTransferable(type: Data.self) }
            }
            .onDisappear { selection.cancelPendingLoad() }
            .alert("无法读取图片", isPresented: $selection.photoError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请选择其他图片重试。")
            }
    }
}

#if DEBUG
#Preview("封面照片读取进度") {
    let selection = PlaylistCoverSelection()
    selection.isLoading = true
    let library = PlaylistLibrary(playlists: [LibraryPlaylistItem(id: "preview:playlist", title: "2", artwork: .playlist)])
    return PlaylistEditor(playlistID: "preview:playlist", library: library, availableSongs: [], coverSelection: selection)
}
#endif

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

struct PlaylistDestinationPicker: View {
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
                        ArtworkView(artwork: playlist.artwork)
                            .frame(width: DesignTokens.Artwork.rowCoverSize, height: DesignTokens.Artwork.rowCoverSize)
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
