#if DEBUG
import SwiftUI

/// Isolated visual fixture. Its controls only change preview state and never start a download.
struct DownloadsPreview: View {
    private enum Page: String, CaseIterable {
        case songs, actions, settings
        var title: String {
            switch self { case .songs: "歌曲状态"; case .actions: "详情按钮"; case .settings: "下载设置" }
        }
    }

    @State private var page: Page

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "-downloadsPreviewPage")
        let requested = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        _page = State(initialValue: requested.flatMap(Page.init(rawValue:)) ?? .songs)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("效果稿页面", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Group {
                    switch page {
                    case .songs: DownloadSongsPreview()
                    case .actions: DownloadActionsPreview()
                    case .settings: DownloadSettingsPreview()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("下载效果稿")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("效果预览 · 示例曲目不会下载")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
            }
        }
        .tint(.primary)
    }
}

private struct DownloadSongsPreview: View {
    private enum SongStatus: Equatable {
        case waiting, downloading, processing, completed, failed, idle
        var title: String {
            switch self {
            case .waiting: "等待 Wi-Fi"
            case .downloading: "下载中 · 42%"
            case .processing: "正在处理"
            case .completed: "已下载"
            case .failed: "下载失败"
            case .idle: "未下载"
            }
        }
    }
    private let songs = [
        ("夜曲", "周杰伦"), ("晴天", "周杰伦"), ("七里香", "周杰伦"),
        ("稻香", "周杰伦"), ("一路向北", "周杰伦")
    ]
    @State private var states: [SongStatus] = [.waiting, .downloading, .processing, .completed, .failed]
    @State private var confirmation: Int?
    @State private var feedback = 0

    var body: some View {
        List {
            Section {
                ForEach(songs.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        ArtworkView(artwork: .image(Image(String(format: "AlbumSample%02d", index + 1))), cornerRadius: 6)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(songs[index].0).font(.callout)
                            Text(songs[index].1).font(.footnote).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        status(index)
                        Menu {
                            if states[index] == .failed {
                                Text("网络连接已中断")
                                Button("重试下载", systemImage: "arrow.clockwise") { update(index, to: .waiting) }
                            } else if states[index] == .completed {
                                Button("移除下载", systemImage: "xmark.circle", role: .destructive) { confirmation = index }
                            } else if states[index] == .idle {
                                Button("下载", systemImage: "arrow.down.circle") { update(index, to: .waiting) }
                            } else {
                                Button("停止下载", systemImage: "stop.circle") { update(index, to: .idle) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                                .frame(width: 24, height: 44)
                        }
                        .accessibilityLabel("\(songs[index].0)，更多")
                    }
                    .frame(minHeight: 56)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
                }
            } header: {
                Text("歌曲列表")
            } footer: {
                Text("等待时保留灰色圆环；处理时显示系统进度指示。失败可原位重试，完成后沿用现有下载标记。")
            }
            Section("状态说明") {
                ForEach(songs.indices, id: \.self) { index in
                    LabeledContent(songs[index].0, value: states[index].title)
                }
            }
        }
        .listStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: feedback)
        .confirmationDialog("移除下载", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("移除下载", role: .destructive) {
                if let index = confirmation { update(index, to: .idle) }
                confirmation = nil
            }
        } message: {
            Text("这首歌将从本机移除。使用同一文件的其他播放列表也需要联网播放，收藏和播放列表会保留。")
        }
    }

    @ViewBuilder private func status(_ index: Int) -> some View {
        switch states[index] {
        case .waiting:
            Button { update(index, to: .idle) } label: { SongDownloadIndicator(state: .queued) }
                .buttonStyle(.plain).accessibilityLabel("等待 Wi-Fi，轻点停止下载")
        case .downloading:
            Button { update(index, to: .idle) } label: { SongDownloadIndicator(state: .downloading(0.42)) }
                .buttonStyle(.plain).accessibilityLabel("已下载百分之四十二，轻点停止下载")
        case .processing:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14).accessibilityLabel("正在处理")
        case .completed:
            SongDownloadIndicator(state: .downloaded)
        case .failed:
            Button { update(index, to: .waiting) } label: {
                Image(systemName: "exclamationmark.circle").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载失败，轻点重试")
        case .idle: EmptyView()
        }
    }

    private func update(_ index: Int, to state: SongStatus) {
        states[index] = state
        feedback &+= 1
    }
}

private struct DownloadActionsPreview: View {
    @State private var stopped = false
    @State private var retrying = false
    @State private var showRemoval = false
    @State private var removed = false
    @State private var feedback = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                example("专辑 · 未收藏", detail: "保留现有收藏操作，收藏后显示下载。") {
                    Image(systemName: "plus")
                } action: { feedback &+= 1 }
                example("播放列表 · \(stopped ? "未下载" : "下载中")", detail: stopped ? "点击下载可继续未完成的歌曲。" : "8 / 20 首 · 轻点进度环停止下载") {
                    if stopped { Image(systemName: "arrow.down") }
                    else { DownloadPreviewProgressRing(progress: 0.4) }
                } action: { stopped.toggle(); feedback &+= 1 }
                example("专辑 · \(removed ? "未下载" : "已下载")", detail: "移除前确认，保留云端收藏。") {
                    if removed { Image(systemName: "arrow.down") }
                    else { DownloadPreviewCheckmark().stroke(.primary, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)) }
                } action: { showRemoval = true; feedback &+= 1 }
                example("播放列表 · \(retrying ? "等待下载" : "部分完成")", detail: retrying ? "16 / 20 首已完成 · 正在等待其余歌曲" : "16 / 20 首已完成 · 4 首失败，轻点重试") {
                    if retrying { DownloadPreviewProgressRing(progress: 0.8) }
                    else { Image(systemName: "arrow.clockwise") }
                } action: { retrying.toggle(); feedback &+= 1 }
            }
            .padding(20)
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: feedback)
        .confirmationDialog("移除下载", isPresented: $showRemoval) {
            Button("移除下载", role: .destructive) { removed = true }
        } message: {
            Text("将移除这张专辑的本机文件。使用这些歌曲的其他播放列表也需要联网播放，收藏和播放列表会保留。")
        }
    }

    private func example<Content: View>(_ title: String, detail: String, @ViewBuilder icon: () -> Content, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 14) {
                Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48).background(Color.primary.opacity(0.08), in: .circle)
                HStack(spacing: 5.5) {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold))
                    Text("播放")
                }
                .font(.headline).foregroundStyle(Color(.systemBackground))
                .frame(width: 160, height: 48).background(Color.primary, in: .capsule)
                Button(action: action) {
                    icon().font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48).background(Color.primary.opacity(0.08), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
            }
            .frame(maxWidth: .infinity)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct DownloadPreviewProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.3), lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 2.5).fill(.primary).frame(width: 10, height: 10)
        }
        .frame(width: 27, height: 27)
    }
}

private struct DownloadPreviewCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return Path { path in
            path.move(to: CGPoint(x: center.x - 6.8, y: center.y + 1.3))
            path.addLine(to: CGPoint(x: center.x - 1.7, y: center.y + 7.7))
            path.addLine(to: CGPoint(x: center.x + 8, y: center.y - 6.3))
        }
    }
}

private struct DownloadSettingsPreview: View {
    @State private var quality = "无损"
    @State private var cellular = true
    var body: some View {
        Form {
            Section("流播放音质") {
                LabeledContent("Wi-Fi 播放", value: "无损")
                LabeledContent("蜂窝网络播放", value: "高品质")
            }
            Section {
                Picker(selection: $quality) {
                    ForEach(["标准", "高品质", "无损", "Hi-Res"], id: \.self) { Text($0).tag($0) }
                } label: { Text("下载音质") }
                .pickerStyle(.navigationLink)
                Toggle("允许蜂窝网络下载", isOn: $cellular)
            } header: {
                Text("下载")
            } footer: {
                Text("更高音质会占用更多空间和流量。所选音质不可用时使用可用的较低音质。更改音质仅影响新的下载，已下载文件保持原样。")
            }
            Section {
                LabeledContent("当前音质", value: "无损")
            }
        }
    }
}

#Preview { DownloadsPreview() }
#endif
