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

@MainActor private final class NativePlayerPreviewFixtures {
    let owner: NowPlayingModel
    let player: PlayerState
    let library: ReferenceLibrary
    let actions: PlayerActions
    private let directory: URL

    init() throws {
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
        for index in titles.indices {
            guard let artworkData = UIImage(named: "AlbumSample\(17 + index)")?.jpegData(compressionQuality: 0.92) else {
                throw URLError(.cannotDecodeContentData)
            }
            let id = "motion-preview-\(index + 1)"
            let artwork = directory.appendingPathComponent("\(id).jpg")
            let audio = directory.appendingPathComponent("\(id).wav")
            try artworkData.write(to: artwork)
            try Self.silentWave(duration: 60).write(to: audio)
            let lrc = lyricTexts[index].enumerated().map { offset, text in
                String(format: "[00:%02d.00]%@", offset * 10, text)
            }.joined(separator: "\n")
            try lrc.write(to: audio.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            audioURLs[id] = audio
            songs.append(LibrarySongItem(id: id, title: titles[index], artist: "NeoMusic 示例",
                                         album: "本地切页预览", albumArtist: "NeoMusic 示例", trackNumber: index + 1,
                                         artwork: .file(artwork), artworkURL: artwork, duration: 60))
        }
        let localURLs = audioURLs
        owner = NowPlayingModel(queue: songs, currentIndex: 0, isPlaying: true, elapsed: 12)
        player = PlayerState(model: owner)
        library = ReferenceLibrary(reader: ReferenceLyricsReader(
            storageDirectory: directory.appendingPathComponent("Lyrics"), root: directory,
            resolveAudioURL: { localURLs[$0] }
        ))
        actions = PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                                         addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Local fixtures support the real lyric reader without starting an audio session.
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
