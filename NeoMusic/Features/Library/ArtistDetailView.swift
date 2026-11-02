import SwiftUI

/// 艺人详情页的展示数据；专辑副标题为发行年份。
struct ArtistDetail {
    let name: String
    var artwork: Artwork?
    var isFavorite = false
    let albums: [LibraryShelfItem]
}

/// 艺人详情：头像、名称、播放按钮与该艺人的专辑网格。
struct ArtistDetailView: View {
    @Environment(\.collectionMenuActions) private var actions
    let detail: ArtistDetail
    @State private var query = ""
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let albums = detail.albums.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        ScrollView {
            VStack(spacing: 0) {
                ArtistAvatar(artwork: detail.artwork)
                    .frame(width: 86, height: 86)
                    .shadow(color: .black.opacity(0.15), radius: 7, y: 4)
                    .padding(.top, 12)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                PlayShuffleButtons(play: { actions.play(.artist(detail.name), false) }, shuffle: { actions.play(.artist(detail.name), true) })
                    .padding(.top, 17)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(albums) { item in CollectionCardLink(item: item) { AlbumCard(item: item) } }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .libraryCollectionAnimation(value: albums.map(\.id))
        }
        .libraryTitleDisplayMode(.inline)
        .librarySearchable(text: $query, prompt: "搜索专辑")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(detail.isFavorite ? "取消喜爱" : "喜爱", systemImage: detail.isFavorite ? "star.fill" : "star") { actions.toggleFavorite(.artist(detail.name)) }
                    .tint(detail.isFavorite ? .yellow : nil)
                Menu("更多", systemImage: "ellipsis") {
                    Button("播放下一首", systemImage: "text.line.first.and.arrowtriangle.forward") { actions.playNext(.artist(detail.name)) }
                }
            }
        }
    }
}
