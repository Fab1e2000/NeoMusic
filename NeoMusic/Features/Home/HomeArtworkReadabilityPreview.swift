#if DEBUG
import SwiftUI

struct HomeArtworkReadabilityPreview: View {
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @State private var phase = HomeReadabilityPhase.failed
    @State private var textSize = HomeReadabilityTextSize.system
    @State private var artworkScene = HomeReadabilityArtworkScene.noData
    @State private var selections = 0

    private var item: HomeQuickActionItem {
        .init(action: .dailySongs,
              artwork: artworkScene.artwork,
              subtitle: "每天更新，为你发现喜欢的歌曲。")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    controls
                    VStack(alignment: .leading, spacing: 12) {
                        HomeQuickActionCard(item: item, state: phase.state,
                                            sourceID: "home-readability.formal") {
                            selections += 1
                        }
                        .environment(\.dynamicTypeSize, textSize.value ?? systemTextSize)
                        .accessibilityHint("选择本页示例")
                        .accessibilityIdentifier("home-readability.formal")
                        result(selections)
                    }
                    .frame(width: HomeMetrics.heroWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HomeMetrics.margin)
                .padding(.vertical, 20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("首页封面与文字")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("frontend.home-artwork-readability")
        }
        .environment(\.artworkLoadAction, ArtworkLoadAction())
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本页使用正式首页卡片。封面尚未显示时使用系统衬底与文字色，封面出现后显示有图效果。")
                .font(.subheadline)
            Picker("卡片状态", selection: $phase) {
                ForEach(HomeReadabilityPhase.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("home-readability.phase")
            Picker("封面场景", selection: $artworkScene) {
                ForEach(HomeReadabilityArtworkScene.allCases) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("home-readability.artwork")
            Picker("预览字号", selection: $textSize) {
                ForEach(HomeReadabilityTextSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("home-readability.text-size")
            Text("点击会记录示例选择；载入状态保持禁用。可在系统设置中切换浅深色和提高对比度。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .dynamicTypeSize(.large)
    }

    private func result(_ count: Int) -> some View {
        Text(count == 0 ? "尚未选择" : "已选择每日推荐 · \(count) 次")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .dynamicTypeSize(.large)
    }
}

private enum HomeReadabilityArtworkScene: String, CaseIterable, Identifiable {
    case noData = "无数据", waiting = "等待封面", readFailed = "读取失败", loaded = "已有封面"
    var id: Self { self }
    private static let missingFile = URL.temporaryDirectory.appending(path: "home-readability-\(UUID().uuidString).jpg")
    var artwork: Artwork? {
        switch self {
        case .noData: nil
        case .waiting: .deferred(id: "home-readability:waiting", placeholder: .playlist)
        case .readFailed: .file(Self.missingFile)
        case .loaded: .image(Image("AlbumSample17"))
        }
    }
}

private enum HomeReadabilityPhase: String, CaseIterable, Identifiable {
    case idle = "待机", loading = "载入", failed = "失败"
    var id: Self { self }
    var state: HomeQuickActionState {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case .failed: .failed("连接暂时中断，请重试。")
        }
    }
}

private enum HomeReadabilityTextSize: String, CaseIterable, Identifiable {
    case system = "跟随系统", normal = "默认", xxxl = "XXXL", ax5 = "AX5"
    var id: Self { self }
    var value: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .normal: .large
        case .xxxl: .xxxLarge
        case .ax5: .accessibility5
        }
    }
}

#Preview { HomeArtworkReadabilityPreview() }
#endif
