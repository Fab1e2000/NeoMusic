#if DEBUG
import SwiftUI

struct SearchCategoryReadabilityPreview: View {
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @State private var model = Self.makeModel()
    @State private var textSize = SearchReadabilityTextSize.system
    @State private var selectedItem: MusicSearchItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                SearchCategoryPage(model: model, category: "华语")
                    .environment(\.dynamicTypeSize, textSize.value ?? systemTextSize)
            }
            .environment(\.openLibraryRoute, OpenLibraryRouteAction(handler: { route in
                selectedItem = model.categoryItems.first { $0.route == route }
            }))
            .sheet(item: $selectedItem) { item in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ArtworkView(artwork: item.artwork, contentID: item.id, cornerRadius: 8)
                                .aspectRatio(1, contentMode: .fit)
                            Text(item.title).font(.title2.bold())
                            Text(item.subtitle).font(.body).foregroundStyle(.secondary)
                            Text("已选择这张示例歌单。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                    }
                    .navigationTitle("选择结果")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { selectedItem = nil }
                        }
                    }
                }
                .environment(\.dynamicTypeSize, textSize.value ?? systemTextSize)
            }
            .accessibilityIdentifier("frontend.search-category-readability")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正式分类页在辅助功能字号下使用单列并展开标题和作者；默认与 XXXL 保持两列。点击歌单可查看示例选择结果。")
                .font(.subheadline)
            Picker("预览字号", selection: $textSize) {
                ForEach(SearchReadabilityTextSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("search-readability.text-size")
        }
        .padding(20)
        .dynamicTypeSize(.large)
    }

    private static func makeModel() -> SearchPageModel {
        let model = SearchPageModel()
        model.categoryItems = [
            .init(id: "search-readability:1", kind: .playlist,
                  title: "华语流行：把温柔留给每一个普通的日子", subtitle: "云音乐华语编辑组",
                  artwork: .image(Image("AlbumSample17")), route: .playlist("search-readability:1")),
            .init(id: "search-readability:2", kind: .playlist,
                  title: "午后独处时，听一首熟悉的歌", subtitle: "云音乐独立音乐编辑组",
                  artwork: .image(Image("AlbumSample01")), route: .playlist("search-readability:2")),
            .init(id: "search-readability:3", kind: .playlist,
                  title: "夜色渐深，旋律仍在轻轻陪伴", subtitle: "云音乐流行音乐编辑组",
                  artwork: .image(Image("AlbumSample08")), route: .playlist("search-readability:3")),
            .init(id: "search-readability:4", kind: .playlist,
                  title: "那些值得反复聆听的现场", subtitle: "云音乐现场音乐编辑组",
                  artwork: .image(Image("AlbumSample12")), route: .playlist("search-readability:4"))
        ]
        return model
    }
}

private enum SearchReadabilityTextSize: String, CaseIterable, Identifiable {
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

#Preview { SearchCategoryReadabilityPreview() }
#endif
