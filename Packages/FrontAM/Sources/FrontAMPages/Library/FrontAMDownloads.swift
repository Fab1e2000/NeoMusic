import FrontAMCore
import SwiftUI

public enum FrontAMDownloadState: Equatable {
    case queued, waiting, downloading(Double), finishing, downloaded, failed(String)
    public var isActive: Bool {
        switch self { case .queued, .waiting, .downloading, .finishing: true; default: false }
    }
    public var accessibilityStatus: String {
        switch self {
        case .queued: pageText("等待下载")
        case .waiting: pageText("等待 Wi-Fi")
        case .downloading(let progress):
            pageText("正在下载，\(Int((progress.isFinite ? min(1, max(0, progress)) : 0) * 100))%")
        case .finishing: pageText("正在处理")
        case .downloaded: pageText("已下载")
        case .failed: pageText("下载失败")
        }
    }
}
public struct FrontAMCollectionDownloadState: Equatable {
    public var totalCount: Int
    public var completedCount: Int
    public var activeCount: Int
    public var failedCount: Int
    public var progress: Double
    public var isResolving = false
    public var isComplete: Bool { totalCount > 0 && completedCount == totalCount && !isResolving }
    public var isActive: Bool { activeCount > 0 || isResolving }
    public var failureSummary: String? {
        failedCount > 0 ? pageText("\(completedCount) / \(totalCount) 首已完成 · \(failedCount) 首失败") : nil
    }
    public var accessibilityValue: String {
        if isResolving { return pageText("正在读取完整曲目列表") }
        if isComplete { return pageText("\(totalCount) 首已下载") }
        var result = pageText("\(completedCount) / \(totalCount) 首已完成")
        if isActive { result += pageText("，进度 \(Int(min(1, max(0, progress)) * 100))%") }
        if failedCount > 0 { result += pageText("，\(failedCount) 首失败") }
        return result
    }

    public init(totalCount: Int,
                completedCount: Int,
                activeCount: Int,
                failedCount: Int,
                progress: Double,
                isResolving: Bool = false) {
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.activeCount = activeCount
        self.failedCount = failedCount
        self.progress = progress
        self.isResolving = isResolving
    }
}

@MainActor public protocol FrontAMDownloadSource: AnyObject {
    var managedSongIDs: Set<String> { get }
    var pendingRemoval: [LibrarySongItem] { get }
    var isDownloadable: (LibrarySongItem) -> Bool { get }
    func state(of songID: String) -> FrontAMDownloadState?
    func collectionState(of route: LibraryRoute) -> FrontAMCollectionDownloadState?
    func isDownloaded(_ songs: [LibrarySongItem]) -> Bool
    func isDownloading(_ songs: [LibrarySongItem]) -> Bool
    func progress(of songs: [LibrarySongItem]) -> Double
    func canRemove(_ song: LibrarySongItem) -> Bool
    func download(_ songs: [LibrarySongItem])
    func stop(_ songs: [LibrarySongItem])
    func requestRemoval(_ songs: [LibrarySongItem])
    func cancelRemoval()
    func confirmRemoval()
}

extension EnvironmentValues {
    @Entry public var libraryDownloads: (any FrontAMDownloadSource)?
}

public struct CollectionDownloadButton: View {
    public let route: LibraryRoute
    public let songs: [LibrarySongItem]
    public var compact = false
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.collectionPagePalette) private var palette
    @State private var downloadedHere = false

    public var body: some View {
        let summary = downloads?.collectionState(of: route)
        let completed = summary?.isComplete ?? actions.isDownloaded(route)
        let active = summary?.isActive ?? downloads?.isDownloading(songs) ?? false
        let failed = (summary?.failedCount ?? 0) > 0
        let label = Group {
                if active {
                    if summary?.isResolving == true { ProgressView().tint(.primary) }
                    else { DownloadProgressRing(progress: summary?.progress ?? downloads?.progress(of: songs) ?? 0) }
                } else if completed { DrawnCheckmark(animates: downloadedHere) }
                else { Image(systemName: failed ? "arrow.clockwise" : "arrow.down").font(.system(size: compact ? 20 : 17, weight: .semibold)) }
            }
            .frame(width: compact ? 32 : 48, height: compact ? 32 : 48)
            .background(compact ? Color.primary.opacity(0.2) : (palette?.controlFill ?? Color.primary.opacity(0.08)), in: .circle)
            .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
            .contentShape(.rect)
        Group {
            if completed && !active && !actions.canRemoveDownload(route) {
                label.accessibilityElement(children: .ignore)
                    .accessibilityLabel(pageText("已下载"))
            } else {
                Button {
                    guard active || actions.canDownload(route) || (completed && actions.canRemoveDownload(route)) else { return }
                    if active {
                        actions.stopDownload(route)
                    } else if completed {
                        actions.removeDownload(route)
                    } else {
                        downloadedHere = true
                        actions.download(route)
                    }
                } label: { label }
                .buttonStyle(PlainButtonStyle().preparingFeedback { LibraryHaptics.prepareImpact() })
                .disabled(!active && !(completed ? actions.canRemoveDownload(route) : actions.canDownload(route)))
                .accessibilityLabel(completed ? pageText("已下载，移除下载") : active ? pageText("停止下载") : failed ? pageText("重试未完成的下载") : pageText("下载"))
            }
        }
        .accessibilityValue(summary?.accessibilityValue ?? "")
    }

    public init(route: LibraryRoute,
                songs: [LibrarySongItem],
                compact: Bool = false) {
        self.route = route
        self.songs = songs
        self.compact = compact
    }
}

public struct CollectionDownloadSummary: View {
    public let route: LibraryRoute
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.collectionMenuActions) private var actions
    public var body: some View {
        if let summary = downloads?.collectionState(of: route), let text = summary.failureSummary {
            VStack(spacing: 8) {
                Text(text).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !summary.isActive {
                    Button(pageText("重试未完成的\(summary.totalCount - summary.completedCount)首"), systemImage: "arrow.clockwise") {
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

public struct SongDownloadIndicator: View {
    public let state: FrontAMDownloadState?
    public var secondaryStyle = AnyShapeStyle(Color.primary.opacity(0.26))

    public var body: some View {
        Group {
            switch state {
            case .queued:
                ring(progress: 0)
            case .waiting:
                ring(progress: 0)
            case .downloading(let value):
                ring(progress: value)
            case .finishing:
                ProgressView().controlSize(.mini).accessibilityLabel(pageText("正在处理"))
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(secondaryStyle)
                    .accessibilityLabel(pageText("已下载"))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14)).accessibilityLabel(pageText("下载失败，可重试"))
            case nil:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state?.accessibilityStatus ?? "")
        .accessibilityHidden(state == nil)
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
    }

    public init(state: FrontAMDownloadState? = nil, secondaryStyle: AnyShapeStyle = AnyShapeStyle(Color.primary.opacity(0.26))) {
        self.state = state
        self.secondaryStyle = secondaryStyle
    }
}

public struct SongDownloadStatus: View {
    public let song: LibrarySongItem
    public var showsImported = true
    public var secondaryStyle = AnyShapeStyle(Color.primary.opacity(0.26))
    @Environment(\.libraryDownloads) private var downloads
    @Environment(\.dynamicTypeSize) private var textSize
    public var body: some View {
        let state = downloads?.state(of: song.id)
        Group {
            if showsImported || song.isOnline || downloads?.managedSongIDs.contains(song.id) == true {
            if case .failed = state {
                Button {
                    guard downloads?.isDownloadable(song) == true else { return }
                    downloads?.download([song])
                } label: {
                    SongDownloadIndicator(state: state, secondaryStyle: secondaryStyle)
                        .frame(width: textSize.isAccessibilitySize ? 44 : 40, height: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .padding(.leading, -12)
                .accessibilityLabel(pageText("下载失败，轻点重试"))
            } else if state?.isActive == true {
                Button { downloads?.stop([song]) } label: {
                    SongDownloadIndicator(state: state, secondaryStyle: secondaryStyle)
                        .frame(width: textSize.isAccessibilitySize ? 44 : 40, height: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .padding(.leading, -12)
                .accessibilityLabel(state == .waiting ? pageText("等待 Wi-Fi，轻点停止下载") : pageText("停止下载"))
                .accessibilityValue(state?.accessibilityStatus ?? "")
            } else { SongDownloadIndicator(state: state, secondaryStyle: secondaryStyle) }
            }
        }
        .buttonStyle(PlainButtonStyle().preparingFeedback { LibraryHaptics.prepareImpact() })
    }
}
