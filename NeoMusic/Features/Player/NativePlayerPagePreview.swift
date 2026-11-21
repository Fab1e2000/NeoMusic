#if DEBUG
import SwiftUI
import FullScreenPlayer

struct NativePlayerPagePreview: View {
    @State private var fixtures: NativePlayerPreviewFixtures?
    @State private var loadError: String?
    var body: some View {
        Group {
            if let fixtures {
                PlayerPagePreview(player: fixtures.player,
                    services: NeoMusicPlayerServices.make(actions: fixtures.actions, library: fixtures.library))
            } else if let loadError {
                ContentUnavailableView("无法读取本地示例", systemImage: "music.note", description: Text(loadError))
            } else { ProgressView("准备本地示例") }
        }.task {
            guard fixtures == nil else { return }
            do { fixtures = try NativePlayerPreviewFixtures() }
            catch { loadError = error.localizedDescription }
        }
    }
}

struct PlayerPerformancePreview: View {
    @State private var fixtures: NativePlayerPreviewFixtures?
    @State private var loadError: String?
    @State private var isPresented = true
    @State private var nativeTapCount = 0

    var body: some View {
        Group {
            if let fixtures {
                NavigationStack {
                    VStack(spacing: 24) {
                        Button("打开播放器") { isPresented = true }
                            .accessibilityIdentifier("performance.open")
                        Button("原生按钮对照") { nativeTapCount += 1 }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("performance.nativeButton")
                        Text("\(nativeTapCount)")
                            .accessibilityIdentifier("performance.nativeTapCount")
                    }
                    .navigationTitle("播放器性能测试")
                }
                .modifier(PlayerPopup(isPresented: $isPresented, isSuppressed: false, onClose: {}))
                .environment(fixtures.player)
                .environment(fixtures.library)
                .environment(fixtures.actions)
            } else if let loadError {
                Text(loadError)
            } else {
                ProgressView("准备测试歌曲")
            }
        }
        .task {
            guard fixtures == nil else { return }
            do { fixtures = try NativePlayerPreviewFixtures(performance: true) }
            catch { loadError = error.localizedDescription }
        }
    }
}

@MainActor private final class NativePlayerPreviewFixtures {
    let owner: NowPlayingModel
    let player: PlayerState
    let library: ReferenceLibrary
    let actions: PlayerActions
    private let directory: URL

    init(performance: Bool = false) throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("NeoMusicMotionPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let titles = ["窗边的光", "沿着海岸", "晚风经过"]
        let lyricTexts = [
            ["第一束光落在窗边", "留一段安静给清晨", "让熟悉的旋律慢慢展开", "这一刻不必走得太远", "看云经过，听风停留", "把今天写成一首歌"],
            ["沿着海岸向前走", "脚步跟着潮汐起落", "远处的灯回应着波纹", "回头仍能看见来时的路", "让风把故事带到明天", "此刻的海和我们同在"],
            ["晚风经过这一条街", "把白天的喧闹留在身后", "一盏灯点亮安静的房间", "旋律陪着夜色慢慢落下", "还没说完的话留给星光", "明天再从这里出发"]
        ]
        var songs: [LibrarySongItem] = []
        var audioURLs: [String: URL] = [:]
        let duration = performance ? 600 : 60
        let count = performance ? 30 : titles.count
        let silentAudio = directory.appendingPathComponent("source.wav")
        try Self.silentWave(duration: duration).write(to: silentAudio)
        for index in 0..<count {
            guard let artworkData = UIImage(named: "AlbumSample\(17 + index % titles.count)")?.jpegData(compressionQuality: 0.92) else {
                throw URLError(.cannotDecodeContentData)
            }
            let id = "motion-preview-\(index + 1)"
            let artwork = directory.appendingPathComponent("\(id).jpg")
            let audio = directory.appendingPathComponent("\(id).wav")
            try artworkData.write(to: artwork)
            try FileManager.default.linkItem(at: silentAudio, to: audio)
            let text = lyricTexts[index % lyricTexts.count]
            let lines = performance ? (0..<200).map { "\($0 + 1) · \(text[$0 % text.count])" } : text
            let lrc = lines.enumerated().map { offset, text in
                let seconds = offset * (performance ? 3 : 10)
                return String(format: "[%02d:%02d.00]%@", seconds / 60, seconds % 60, text)
            }.joined(separator: "\n")
            try lrc.write(to: audio.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            audioURLs[id] = audio
            songs.append(LibrarySongItem(id: id, title: performance ? "\(index + 1) · \(titles[index % titles.count])" : titles[index], artist: "NeoMusic 示例",
                                         album: "本地切页预览", albumArtist: "NeoMusic 示例", trackNumber: index + 1,
                                         artwork: .file(artwork), artworkURL: artwork, duration: duration))
        }
        let localURLs = audioURLs
        owner = NowPlayingModel(queue: songs, currentIndex: 0, isPlaying: !performance, elapsed: 12)
        if performance {
            owner.configurePlayback(resolveURL: { localURLs[$0] },
                                    persistenceURL: directory.appendingPathComponent("playback.json"))
            owner.togglePlayback()
        }
        player = PlayerState(model: owner)
        library = ReferenceLibrary(reader: ReferenceLyricsReader(
            storageDirectory: directory.appendingPathComponent("Lyrics"), root: directory,
            resolveAudioURL: { localURLs[$0] }
        ))
        actions = PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                                         addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static func silentWave(duration: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let byteCount = UInt32(duration) * sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
}


#Preview("播放器 · 原生切页对照") { NativePlayerPagePreview() }
#endif
