import SwiftUI
import FullScreenPlayer
#if DEBUG
struct PlayerAudioQualityPreview: View {
    let openAudioQualitySettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content: PlayerAudioQualityPreviewContent?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let content {
                ReferenceNowPlayingView(onDismiss: { dismiss() })
                    .environment(content.player)
                    .environment(content.library)
                    .environment(PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                        addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in },
                        audioQuality: { id in
                            id == content.owner.current.id
                                ? PlayerAudioQuality(title: "无损", isLossless: true) : nil
                        }, openAudioQualitySettings: openAudioQualitySettings))
                    .overlay(alignment: .topLeading) {
                        Text("示例数据 · 暂停资源")
                            .font(.caption2).dynamicTypeSize(.large).lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16).padding(.top, 4)
                            .allowsHitTesting(false)
                    }
            } else if let loadError {
                ContentUnavailableView("无法读取示例", systemImage: "music.note", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            guard content == nil else { return }
            do { content = try PlayerAudioQualityPreviewContent() }
            catch { loadError = error.localizedDescription }
        }
    }
}

@MainActor private final class PlayerAudioQualityPreviewContent {
    let owner: NowPlayingModel
    let player: PlayerState
    let library: ReferenceLibrary
    private let directory: URL

    init() throws {
        guard let data = UIImage(named: "AlbumSample17")?.jpegData(compressionQuality: 0.92) else {
            throw URLError(.cannotDecodeContentData)
        }
        directory = URL.temporaryDirectory.appendingPathComponent("NeoMusicQualityPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artwork = directory.appendingPathComponent("cover.jpg")
        try data.write(to: artwork)
        let song = LibrarySongItem(id: "quality-preview", title: "Window Light", artist: "NeoMusic 示例",
            album: "音频质量版式预览", albumArtist: "NeoMusic 示例", trackNumber: 1,
            artwork: .file(artwork), artworkURL: artwork, duration: 243)
        owner = NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false, elapsed: 17)
        owner.repeatMode = .off
        player = PlayerState(model: owner)
        library = ReferenceLibrary(reader: ReferenceLyricsReader(storageDirectory: directory.appendingPathComponent("Lyrics"),
                                                                  root: directory, resolveAudioURL: { _ in nil }))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

#Preview("音频质量 · 示例数据") {
    NavigationStack { PlayerAudioQualityPreview(openAudioQualitySettings: {}) }
}
#endif
