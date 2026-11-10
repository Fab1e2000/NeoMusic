#if DEBUG
import SwiftUI

struct FrontendReviewPreview: View {
    private struct Page: Identifiable {
        let id: String
        let title: String
    }
    private let pages = [
        Page(id: "artist-release", title: "最新发行收藏与下载"),
        Page(id: "form", title: "草稿退出与提交文案"),
        Page(id: "errors", title: "账户错误与恢复"),
        Page(id: "login", title: "登录验证进度"),
        Page(id: "cover", title: "封面读取进度"),
        Page(id: "home", title: "主页浅色与深色"),
        Page(id: "home-waiting", title: "首页等待文案"),
        Page(id: "home-errors", title: "首页分区错误与恢复"),
        Page(id: "search-scope", title: "搜索范围与结果"),
        Page(id: "type", title: "文字缩放与重排"),
        Page(id: "contrast", title: "分类与专辑对比度"),
        Page(id: "status", title: "资料库状态承托"),
        Page(id: "toast", title: "反馈时间与辅助功能"),
        Page(id: "empty", title: "资料库筛选空态"),
        Page(id: "downloads", title: "下载阶段与失败重试"),
        Page(id: "categories", title: "分类分组"),
        Page(id: "artists", title: "艺人列表搜索"),
        Page(id: "lyrics", title: "原文与译文层级"),
        Page(id: "quality", title: "音质与输出入口"),
        Page(id: "editing", title: "封面恢复与删除确认"),
        Page(id: "settings", title: "账户与应用设置分组"),
        Page(id: "menus", title: "菜单动作精简")
    ]
    @State private var selectedPage: Page?
    @State private var showsAudioQualitySettings = false
    @State private var previewMusic = NeteaseMusicStore(
        directory: URL.temporaryDirectory.appendingPathComponent("FrontendQualityPreview", isDirectory: true),
        defaults: UserDefaults(suiteName: "FrontendQualityPreview")!)

    private var requestedPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-frontendReviewPreview"),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }

    var body: some View {
        root
            .sheet(isPresented: $showsAudioQualitySettings) {
                NavigationStack {
                    MusicQualitySettingsPage(music: previewMusic)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("关闭", systemImage: "xmark", role: .close) {
                                    showsAudioQualitySettings = false
                                }
                            }
                        }
                }
            }
    }

    @ViewBuilder private var root: some View {
        if let requestedPage {
            content(requestedPage)
        } else {
            NavigationStack {
                List(pages) { page in
                    Button(page.title) { selectedPage = page }
                }
                .navigationTitle("前端修复预览")
                .safeAreaInset(edge: .bottom) {
                    Text("隔离展示数据 · 可下拉关闭预览")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
                .sheet(item: $selectedPage) { page in content(page.id) }
            }
        }
    }

    @ViewBuilder private func content(_ page: String) -> some View {
        switch page {
        case "quality":
            NavigationStack {
                PlayerAudioQualityPreview { showsAudioQualitySettings = true }
            }
        case "home-waiting":
            HomeFeedPreview(feedbackMode: "waiting")
        case "home-errors":
            HomeFeedPreview(feedbackMode: "errors")
        case "search-scope":
            SearchPreviewRoot(page: "results")
        case "home", "type", "contrast", "status", "toast":
            FrontendReadabilityPreview(page: page)
        case "form", "errors", "login", "cover":
            FrontendFormsPreview(page: page)
        case "empty", "downloads", "artist-release":
            FrontendLibraryReviewPreview(page: page)
        default:
            FrontendOptionsPreview(page: page)
        }
    }
}

private struct FrontendLibraryReviewPreview: View {
    let page: String
    @State private var candidate = true
    @State private var query = "不存在的歌曲"
    @State private var favoritesOnly = false
    @State private var retried = false
    @State private var collected = false
    @State private var releaseFeedback = 0
    @State private var downloads = LibraryDownloads()
    private let route = LibraryRoute.album("preview-album")

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case "artist-release": artist
                case "downloads": downloadStates
                default: emptyResults
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page != "artist-release" {
                    ToolbarItem(placement: .principal) {
                        Picker("对照版本", selection: $candidate) {
                            Text("当前").tag(false)
                            Text("候选").tag(true)
                        }.pickerStyle(.segmented).frame(width: 160)
                    }
                }
            }
            .environment(\.libraryDownloads, downloads)
            .environment(\.collectionMenuActions, actions)
        }
        .preferredColorScheme(page == "artist-release" ? .dark : nil)
        .task { publishDownloadState() }
    }

    private var title: String {
        switch page {
        case "artist-release": "最新发行"
        case "downloads": "下载恢复"
        default: "资料库筛选"
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 0) {
            Toggle("仅显示喜爱", isOn: $favoritesOnly).padding()
            if query.isEmpty && !favoritesOnly {
                List {
                    Label("示例歌曲", systemImage: "music.note")
                    Label("示例专辑", systemImage: "square.stack")
                }
            } else if candidate {
                ContentUnavailableView {
                    Label(query.isEmpty ? "没有符合筛选的内容" : "没有搜索结果", systemImage: "magnifyingglass")
                } description: {
                    Text(query.isEmpty ? "可以显示资料库中的全部内容。" : "试试其他关键词，或清除搜索。")
                } actions: {
                    Button(query.isEmpty ? "显示全部" : "清除搜索") {
                        query = ""
                        favoritesOnly = false
                    }
                }
            } else {
                PlayShuffleButtons(play: {}, shuffle: {}).disabled(true).padding()
                Spacer()
            }
        }
        .searchable(text: $query, prompt: "歌曲、艺人或专辑")
    }

    private var downloadStates: some View {
        List {
            Section("歌曲状态") {
                downloadRow("排队歌曲", state: .queued, message: "正在排队")
                downloadRow("无线网络下载", state: .waiting, message: "等待 Wi-Fi")
                downloadRow("正在传输", state: .downloading(0.42), message: "已下载 42%")
                downloadRow("写入音乐资料", state: .finishing, message: "正在处理")
                downloadRow("已保存的音乐", state: .downloaded, message: "已下载")
            }
            Section("部分下载失败") {
                HStack {
                    Label("示例专辑", systemImage: "square.stack")
                    Spacer()
                    CollectionDownloadButton(route: route, songs: [])
                }
                if candidate {
                    if retried {
                        Label("正在重试未完成的 2 首", systemImage: "arrow.clockwise")
                    } else {
                        Text("8 / 10 首已完成 · 2 首失败").foregroundStyle(.secondary)
                        Button("重试未完成的 2 首", systemImage: "arrow.clockwise") {
                            retried = true
                            publishDownloadState()
                        }
                    }
                } else {
                    Text("8 / 10 首已完成 · 2 首失败，轻点重试").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func downloadRow(_ title: String, state: LibraryDownloads.SongState, message: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                if candidate { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            SongDownloadIndicator(state: state)
        }.frame(minHeight: 44)
    }

    private var artist: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image("AlbumSample01").resizable().scaledToFill().frame(width: 96, height: 96).clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text("最新发行").font(.system(size: 14))
                    Text("示例专辑").font(.system(size: 16, weight: .semibold))
                    Text("10 首歌曲").font(.system(size: 14))
                }.frame(maxWidth: .infinity, alignment: .leading)
                if collected {
                    CollectionDownloadButton(route: route, songs: [], compact: true)
                } else {
                    Button {
                        releaseFeedback &+= 1
                        collected = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                            .frame(width: 32, height: 32).background(.white.opacity(0.2), in: .circle)
                            .frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .accessibilityLabel("将示例专辑加入资料库")
                }
            }
            .padding(12).background(.white.opacity(0.13), in: .rect(cornerRadius: 26))
            Text(collected ? "已加入资料库，右侧操作为下载。" : "加号用于加入资料库。")
                .font(.subheadline)
            Button("还原演示状态") { collected = false; retried = false; publishDownloadState() }
            Spacer()
        }.padding(20).foregroundStyle(.white).background(Color(white: 0.12))
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: releaseFeedback)
    }

    private var actions: CollectionMenuActions {
        CollectionMenuActions(isDownloaded: { _ in false }, download: { _ in
            retried = true
            publishDownloadState()
        }, canDownload: { _ in true }, stopDownload: { _ in
            retried = false
            publishDownloadState()
        }, downloads: downloads)
    }

    private func publishDownloadState() {
        let completed = page == "downloads" || retried ? 8 : 0
        let progress = retried ? 0.84 : Double(completed) / 10
        downloads.publishCollections([route: .init(totalCount: 10, completedCount: completed,
            activeCount: retried ? 2 : 0, failedCount: page == "downloads" && !retried ? 2 : 0,
            progress: progress)])
    }
}
#endif
