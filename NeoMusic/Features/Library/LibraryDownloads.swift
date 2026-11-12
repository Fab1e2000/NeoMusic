import SwiftUI

/// Presentation state for downloads. File and account work is injected by app assembly.
@MainActor @Observable
final class LibraryDownloads {
    enum SongState: Equatable {
        case queued, waiting, downloading(Double), finishing, downloaded, failed(String)
        var isActive: Bool {
            switch self { case .queued, .waiting, .downloading, .finishing: true; default: false }
        }
    }
    struct CollectionState: Equatable {
        var totalCount: Int
        var completedCount: Int
        var activeCount: Int
        var failedCount: Int
        var progress: Double
        var isResolving = false
        var isComplete: Bool { totalCount > 0 && completedCount == totalCount && !isResolving }
        var isActive: Bool { activeCount > 0 || isResolving }
        var failureSummary: String? {
            failedCount > 0 ? "\(completedCount) / \(totalCount) 首已完成 · \(failedCount) 首失败" : nil
        }
        var accessibilityValue: String {
            if isResolving { return "正在读取完整曲目列表" }
            if isComplete { return "\(totalCount) 首已下载" }
            var result = "\(completedCount) / \(totalCount) 首已完成"
            if isActive { result += "，进度 \(Int(min(1, max(0, progress)) * 100))%" }
            if failedCount > 0 { result += "，\(failedCount) 首失败" }
            return result
        }
    }
    @MainActor @Observable final class SongStatus { var value: SongState? }
    @MainActor @Observable final class CollectionStatus { var value: CollectionState? }
    @ObservationIgnored private var songStatuses: [String: SongStatus] = [:]
    @ObservationIgnored private var collectionStatuses: [LibraryRoute: CollectionStatus] = [:]
    @ObservationIgnored private var localIDs: Set<String> = []
    @ObservationIgnored private var remoteStates: [String: SongState] = [:]
    private(set) var managedSongIDs: Set<String> = []
    private(set) var pendingRemoval: [LibrarySongItem] = []
    var downloadAction: ([LibrarySongItem]) -> Void = { _ in }
    var stopAction: ([LibrarySongItem]) -> Void = { _ in }
    var removeAction: ([LibrarySongItem]) -> Void = { _ in }
    var isDownloadable: (LibrarySongItem) -> Bool = { _ in false }
    var isRemovable: (LibrarySongItem) -> Bool = { _ in false }

    var states: [String: SongState] { songStatuses.compactMapValues(\.value) }
    func status(of id: String) -> SongStatus {
        if let status = songStatuses[id] { return status }
        let status = SongStatus(); songStatuses[id] = status
        status.value = remoteStates[id] ?? (!managedSongIDs.contains(id) && localIDs.contains(id) ? .downloaded : nil)
        return status
    }
    func state(of songID: String) -> SongState? { status(of: songID).value }
    func collectionState(of route: LibraryRoute) -> CollectionState? {
        if let status = collectionStatuses[route] { return status.value }
        let status = CollectionStatus(); collectionStatuses[route] = status
        return status.value
    }
    func publish(states: [String: SongState], managedSongIDs: Set<String>) {
        let changed = Set(remoteStates.keys).union(states.keys).union(self.managedSongIDs).union(managedSongIDs)
        remoteStates = states
        if self.managedSongIDs != managedSongIDs { self.managedSongIDs = managedSongIDs }
        for id in changed {
            let value = states[id] ?? (!managedSongIDs.contains(id) && localIDs.contains(id) ? .downloaded : nil)
            let status = status(of: id)
            if status.value != value { status.value = value }
        }
    }
    func publishCollections(_ values: [LibraryRoute: CollectionState]) {
        for route in Set(collectionStatuses.keys).union(values.keys) {
            let status = collectionStatuses[route] ?? CollectionStatus()
            collectionStatuses[route] = status
            if status.value != values[route] { status.value = values[route] }
        }
    }
    func setLocalSongs(_ songs: [LibrarySongItem]) {
        let updated = Set(songs.map(\.id)), changed = localIDs.symmetricDifference(updated)
        localIDs = updated
        for id in changed { status(of: id).value = remoteStates[id] ?? (!managedSongIDs.contains(id) && updated.contains(id) ? .downloaded : nil) }
    }
    func isDownloaded(_ songs: [LibrarySongItem]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { state(of: $0.id) == .downloaded }
    }
    func isDownloading(_ songs: [LibrarySongItem]) -> Bool { songs.contains { state(of: $0.id)?.isActive == true } }
    func progress(of songs: [LibrarySongItem]) -> Double {
        guard !songs.isEmpty else { return 0 }
        return songs.reduce(0) { total, song in
            switch state(of: song.id) {
            case .downloaded, .finishing: return total + 1
            case .downloading(let progress): return total + min(1, max(0, progress))
            default: return total
            }
        } / Double(songs.count)
    }
    func canRemove(_ song: LibrarySongItem) -> Bool { managedSongIDs.contains(song.id) && isRemovable(song) }
    func download(_ songs: [LibrarySongItem]) { downloadAction(songs.filter(isDownloadable)) }
    func stop(_ songs: [LibrarySongItem]) { stopAction(songs.filter { state(of: $0.id)?.isActive == true }) }
    func remove(_ songs: [LibrarySongItem]) {
        let removable = songs.filter(canRemove)
        if !removable.isEmpty { removeAction(removable) }
    }
    func requestRemoval(_ songs: [LibrarySongItem]) { pendingRemoval = songs.filter(canRemove) }
    func cancelRemoval() { pendingRemoval = [] }
    func confirmRemoval() {
        let songs = pendingRemoval
        pendingRemoval = []
        guard !songs.isEmpty else { return }
        LibraryHaptics.impact()
        remove(songs)
    }
}

extension View {
    func downloadRemovalConfirmation() -> some View { modifier(DownloadRemovalConfirmation()) }
}
private struct DownloadRemovalConfirmation: ViewModifier {
    @Environment(\.libraryDownloads) private var downloads
    func body(content: Content) -> some View {
        content.alert("", isPresented: Binding(
            get: { downloads?.pendingRemoval.isEmpty == false },
            set: { if !$0 { downloads?.cancelRemoval() } })) {
                Button("移除下载", role: .destructive) { downloads?.confirmRemoval() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除所选歌曲的本机文件。使用同一文件的其他播放列表也需要联网播放，收藏和播放列表会保留。")
            }
    }
}

/// Shared detail control; collection summaries describe the full collection, including unloaded pages.
struct CollectionDownloadButton: View {
    let route: LibraryRoute
    let songs: [LibrarySongItem]
    var compact = false
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.collectionMenuActions) private var actions
    @State private var feedback = 0
    @State private var downloadedHere = false

    var body: some View {
        let summary = downloads?.collectionState(of: route)
        let completed = summary?.isComplete ?? actions.isDownloaded(route)
        let active = summary?.isActive ?? downloads?.isDownloading(songs) ?? false
        let failed = (summary?.failedCount ?? 0) > 0
        Button {
            guard active || actions.canDownload(route) || (completed && actions.canRemoveDownload(route)) else { return }
            feedback &+= 1
            if active { actions.stopDownload(route) }
            else if completed { actions.removeDownload(route) }
            else { downloadedHere = true; actions.download(route) }
        } label: {
            Group {
                if active {
                    if summary?.isResolving == true { ProgressView().tint(.primary) }
                    else { DownloadProgressRing(progress: summary?.progress ?? downloads?.progress(of: songs) ?? 0) }
                } else if completed { DrawnCheckmark(animates: downloadedHere) }
                else { Image(systemName: failed ? "arrow.clockwise" : "arrow.down").font(.system(size: compact ? 20 : 17, weight: .semibold)) }
            }
            .frame(width: compact ? 32 : 48, height: compact ? 32 : 48)
            .background(Color.primary.opacity(compact ? 0.2 : 0.08), in: .circle)
            .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!active && !(completed ? actions.canRemoveDownload(route) : actions.canDownload(route)))
        .accessibilityLabel(completed ? "已下载，移除下载" : active ? "停止下载" : failed ? "重试未完成的下载" : "下载")
        .accessibilityValue(summary?.accessibilityValue ?? "")
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: feedback)
    }
}

struct CollectionDownloadSummary: View {
    let route: LibraryRoute
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.collectionMenuActions) private var actions
    var body: some View {
        if let summary = downloads?.collectionState(of: route), let text = summary.failureSummary {
            VStack(spacing: 8) {
                Text(text).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !summary.isActive {
                    Button("重试未完成的\(summary.totalCount - summary.completedCount)首", systemImage: "arrow.clockwise") {
                        LibraryHaptics.impact()
                        actions.download(route)
                    }
                    .disabled(!actions.canDownload(route))
                }
            }
            .font(.footnote)
            .padding(.top, 10)
        }
    }
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
            case .waiting:
                ring(progress: 0).accessibilityLabel("等待 Wi-Fi")
            case .downloading(let value):
                ring(progress: value)
            case .finishing:
                ProgressView().controlSize(.mini).accessibilityLabel("正在处理")
            case .downloaded:
                // 实测 Apple Music：灰色实心圆约为 25% 白，箭头镂空露出底色。
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.26))
                    .accessibilityLabel("已下载")
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14)).accessibilityLabel("下载失败，可重试")
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
        .accessibilityValue(progress > 0 ? "\(Int(min(1, max(0, progress)) * 100))%" : "")
    }
}

/// Observation is confined to this song's status; transfer progress leaves its surrounding list intact.
struct SongDownloadStatus: View {
    let song: LibrarySongItem
    var showsImported = true
    @Environment(\.libraryDownloads) private var downloads
    @State private var feedback = 0
    var body: some View {
        let state = downloads?.state(of: song.id)
        Group {
            if showsImported || song.isOnline || downloads?.managedSongIDs.contains(song.id) == true {
            if case .failed = state {
                Button {
                    guard downloads?.isDownloadable(song) == true else { return }
                    feedback &+= 1; downloads?.download([song])
                } label: {
                    SongDownloadIndicator(state: state)
                        .frame(width: 28, height: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .accessibilityLabel("下载失败，轻点重试")
            } else if state?.isActive == true {
                Button { feedback &+= 1; downloads?.stop([song]) } label: {
                    SongDownloadIndicator(state: state)
                        .frame(width: 28, height: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                    .accessibilityLabel(state == .waiting ? "等待 Wi-Fi，轻点停止下载" : "停止下载")
            } else { SongDownloadIndicator(state: state) }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: feedback)
    }
}
