import SwiftUI

/// 歌曲的下载状态。效果稿阶段用计时模拟下载进度，接入真实下载后由下载服务提供。
@MainActor @Observable
final class LibraryDownloads {
    enum SongState: Equatable {
        /// 已排队，尚未开始。
        case queued
        /// 下载中，进度 0...1。
        case downloading(Double)
        /// 刚完成：显示一下完整的白色圆环，再换成已下载图标。
        case finishing
        case downloaded
    }

    private(set) var states: [String: SongState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func state(of songID: String) -> SongState? { states[songID] }

    func isDownloaded(_ songs: [LibrarySongItem]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { states[$0.id] == .downloaded }
    }

    func isDownloading(_ songs: [LibrarySongItem]) -> Bool {
        songs.contains { song in
            switch states[song.id] {
            case .queued, .downloading, .finishing: true
            default: false
            }
        }
    }

    /// 整组的进度：已下载计 1，下载中按进度，排队计 0。
    func progress(of songs: [LibrarySongItem]) -> Double {
        guard !songs.isEmpty else { return 0 }
        let total = songs.reduce(0.0) { sum, song in
            switch states[song.id] {
            case .downloaded, .finishing: sum + 1
            case .downloading(let value): sum + value
            default: sum
            }
        }
        return total / Double(songs.count)
    }

    func setLocalSongs(_ songs: [LibrarySongItem]) {
        states = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, .downloaded) })
    }
    // 本地文件不提供在线下载或移除下载操作。
    func download(_ songs: [LibrarySongItem]) {}
    func stop(_ songs: [LibrarySongItem]) {}
    func remove(_ songs: [LibrarySongItem]) {}
}

extension EnvironmentValues {
    @Entry var libraryDownloads: LibraryDownloads?
}

/// 曲目行右侧的下载状态：排队为灰圈，下载中为白色进度弧，完成后为灰色下载图标。
struct SongDownloadIndicator: View {
    let state: LibraryDownloads.SongState?

    var body: some View {
        Group {
            switch state {
            case .queued:
                ring(progress: 0)
            case .downloading(let value):
                ring(progress: value)
            case .finishing:
                ring(progress: 1)
            case .downloaded:
                // 实测 Apple Music：灰色实心圆约为 25% 白，箭头镂空露出底色。
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.26))
                    .accessibilityLabel("已下载")
            case nil:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
    }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1.7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(progress > 0 ? "正在下载" : "等待下载")
    }
}
