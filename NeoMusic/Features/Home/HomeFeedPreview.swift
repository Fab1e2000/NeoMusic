#if DEBUG
import SwiftUI

/// Isolated layout approval fixture; only the supplied quick-action covers are real service artwork.
struct HomeFeedPreview: View {
    private let feedbackOverride: String?
    @State private var selected: String?
    @State private var heroScrollID: HomeQuickAction?
    @ScaledMetric(relativeTo: .title3) private var headingSize: CGFloat = 20
    private let titles = ["推荐歌单", "你的雷达歌单", "排行榜", "你关注的艺人新动向", "场景歌单", "新歌速递"]
    private let cards = [
        ["夜晚散步", "在路上的那些天", "今天的好心情"],
        ["私人雷达", "宝藏雷达", "时光雷达"],
        ["热歌榜", "日语榜", "流行榜"],
        ["NEW ROMANCER", "塌陷于 38°C 的蓝", "我的流动"],
        ["悠闲时光", "游戏时间", "夜色温柔"],
        ["NEW ROMANCER", "我的流动", "いつか分かる"]
    ]
    init(feedbackMode: String? = nil) {
        feedbackOverride = feedbackMode
        let requestedAction = Self.argument("-homeQuickActionPreviewAction").flatMap(HomeQuickAction.init(rawValue:))
        let waiting = (feedbackMode ?? Self.argument("-homeFeedbackPreview")) == "waiting"
        _heroScrollID = State(initialValue: requestedAction ?? (waiting ? .heartMode : nil))
    }
    private static func argument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    private var previewStart: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-homeFeedPreviewSection"), arguments.indices.contains(index + 1) else { return nil }
        return Int(arguments[index + 1].replacingOccurrences(of: "section-", with: ""))
    }
    private var feedbackMode: String? { feedbackOverride ?? Self.argument("-homeFeedbackPreview") }
    var body: some View {
        NavigationStack {
            Group {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                        if previewStart == nil {
                            heroShelf.id("top")
                        }
                        if feedbackMode == "errors" {
                            HomeFeedIssueRow(issue: .init(id: "feed", title: "推荐内容", message: "部分推荐内容暂时未能更新。", sectionID: nil)) { selected = "重新载入推荐内容" }
                                .padding(.horizontal, HomeMetrics.margin)
                        }
                        if previewStart == nil {
                            songs("根据你喜欢的歌曲推荐", seed: 0)
                            songs("根据「Hortus Regis Alti」推荐", seed: 3)
                        }
                        ForEach(titles.indices.filter { $0 >= (previewStart ?? 0) }, id: \.self) { index in
                            shelf(titles[index], showsContent: feedbackMode != "errors" || index != 3, issue: previewIssue(index)) {
                                ForEach(cards[index].indices, id: \.self) { item in
                                    square(cards[index][item], subtitle: index == 3 ? ["RIM", "46", "晴空乐队"][item] : "", image: index * 3 + item)
                                }
                            }.id("section-\(index)")
                        }
                    }
                    .padding(.top, 15).padding(.bottom, 32)
                }

            }
            .background(Color(.systemBackground))
            .navigationTitle("主页")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { AccountToolbar() }
            .safeAreaInset(edge: .bottom) {
                Text("效果预览 · 功能卡与示例内容")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(.regularMaterial)
            }
            .alert("预览内容", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                Button("好", role: .cancel) { selected = nil }
            } message: { Text(selected ?? "") }
        }
    }
    private func image(_ index: Int) -> some View {
        Image(String(format: "AlbumSample%02d", index % 20 + 1)).resizable().scaledToFill()
    }
    private var heroShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: HomeMetrics.cardSpacing) {
                ForEach(quickActions) { item in
                    HomeQuickActionCard(item: item, state: previewState(for: item.action)) {
                        selected = item.action.title
                    }
                }
            }.scrollTargetLayout()
        }
        .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollPosition(id: $heroScrollID, anchor: .leading)
    }
    private var quickActions: [HomeQuickActionItem] {
        [
            .init(action: .dailySongs, artwork: quickArtwork("daily"), subtitle: "每天为你挑选的音乐。"),
            .init(action: .hotSongs, artwork: quickArtwork("hot"), subtitle: "网易云音乐热歌榜"),
            .init(action: .heartMode, artwork: quickArtwork("heart"), subtitle: "从喜欢的歌曲，听见更多心动。"),
            .init(action: .privateRadar, artwork: quickArtwork("radar"), subtitle: "你的专属雷达歌单"),
            .init(action: .privateRoaming, artwork: quickArtwork("roaming"), subtitle: "让下一首，带来新的发现。"),
            .init(action: .similarSongs, artwork: quickArtwork("similar"), subtitle: "以当前播放歌曲为起点")
        ]
    }
    private func quickArtwork(_ name: String) -> Artwork? {
        if Self.argument("-homeQuickActionPreviewState") == "missing" { return nil }
        guard let directory = Self.argument("-homeQuickActionArtworkDirectory") else { return nil }
        return .file(URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).jpg"))
    }
    private func previewState(for action: HomeQuickAction) -> HomeQuickActionState {
        if feedbackMode == "waiting", [.dailySongs, .heartMode].contains(action) { return .loading }
        let target = Self.argument("-homeQuickActionPreviewAction").flatMap(HomeQuickAction.init(rawValue:)) ?? .dailySongs
        guard action == target else { return .idle }
        if feedbackMode == "waiting" { return .loading }
        switch Self.argument("-homeQuickActionPreviewState") {
        case "loading": return .loading
        case "failed": return .failed("连接暂时中断，请重试。")
        case "missing": return .failed("请先播放一首网易云歌曲。")
        default: return .idle
        }
    }
    private func previewIssue(_ index: Int) -> HomeFeedIssue? {
        guard feedbackMode == "errors", [0, 3].contains(index) else { return nil }
        return .init(id: "section-\(index)", title: titles[index],
                     message: index == 0 ? "暂时未能更新，仍显示上次的推荐歌单。" : "艺人新动向载入失败，请重试。", sectionID: "section-\(index)")
    }
    private func shelf<Content: View>(_ title: String, snapping: Bool = false, showsContent: Bool = true,
                                      issue: HomeFeedIssue? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
            Text(title).font(.system(size: headingSize, weight: .bold)).padding(.horizontal, HomeMetrics.margin)
                .accessibilityAddTraits(.isHeader)
            let shelf = ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: HomeMetrics.cardSpacing, content: content).scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            if showsContent {
                if snapping { shelf.scrollTargetBehavior(.viewAligned) }
                else { shelf }
            }
            if let issue {
                HomeFeedIssueRow(issue: issue) { selected = "重新载入\(issue.title)" }
                    .padding(.horizontal, HomeMetrics.margin)
            }
        }
    }
    private func square(_ title: String, subtitle: String, image index: Int) -> some View {
        Button { selected = title } label: {
            VStack(alignment: .leading, spacing: 5) {
                image(index).frame(width: HomeMetrics.artworkSize, height: HomeMetrics.artworkSize).clipped().clipShape(.rect(cornerRadius: 8))
                Text(title).font(.subheadline).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(width: HomeMetrics.artworkSize, alignment: .leading)
        }.buttonStyle(.plain)
    }
    private func songs(_ title: String, seed: Int) -> some View {
        shelf(title, snapping: true) {
            ForEach(0..<3) { group in
                VStack(spacing: 0) {
                    ForEach(0..<3) { row in
                        let index = (seed + group * 3 + row) % 6
                        let name = ["before light", "束花线", "溶けきれない背景", "雨女", "コンパスローズ", "いつか分かる"][index]
                        Button { selected = name } label: {
                            HStack(spacing: 12) {
                                image(index + 10).frame(width: 48, height: 48).clipped().clipShape(.rect(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name).font(.subheadline).lineLimit(1)
                                    Text(["keeno", "花譜", "kiyuu", "TsukiP", "世界電情", "nananinari"][index]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.frame(height: 64).contentShape(.rect)
                        }.buttonStyle(.plain)
                        if row < 2 { Divider().padding(.leading, 60) }
                    }
                }.containerRelativeFrame(.horizontal, count: 1, spacing: 32).padding(.trailing, 12)
            }
        }
    }
}
#endif
