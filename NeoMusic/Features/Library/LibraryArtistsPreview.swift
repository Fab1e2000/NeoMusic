#if DEBUG
import SwiftUI

struct LibraryArtistsPreview: View {
    enum Scene: String {
        case artistsList = "artists-list"
        case detailGrid = "artist-detail-grid"
        case detailList = "artist-detail-list"
        case pinnedArtist = "pinned-artist"
    }

    private enum Page: Hashable {
        case artists
        case artist(String)
    }

    private struct MiniPlayerItem {
        let title: String
        let artist: String
        let artwork: Artwork
    }

    @State private var path: [Page]
    @State private var favorites: Set<String> = ["Isekaijoucho"]
    @State private var pins: Set<String> = ["ASU"]
    @State private var isPlaying = false
    @State private var track = 0
    @State private var queue: [MiniPlayerItem] = [
        .init(title: "Farewell in the Morning (feat. Nayuta)", artist: "ときも", artwork: .image(Image("AlbumSample06"))),
        .init(title: "NEW ROMANCER", artist: "理芽", artwork: .image(Image("AlbumSample17")))
    ]

    init(scene: Scene = .artistsList) {
        switch scene {
        case .artistsList: _path = State(initialValue: [.artists])
        case .detailGrid: _path = State(initialValue: [.artists, .artist("Albemuth")])
        case .detailList: _path = State(initialValue: [.artists, .artist("Isekaijoucho")])
        case .pinnedArtist: _path = State(initialValue: [])
        }
    }

    var body: some View {
        TabView(selection: .constant(AppTab.library)) {
            Tab("主页", systemImage: AppTab.home.systemImage, value: AppTab.home) { Color.clear }
            Tab("资料库", systemImage: AppTab.library.systemImage, value: AppTab.library) {
                NavigationStack(path: $path) {
                    library
                        .navigationDestination(for: Page.self) { page in
                            switch page {
                            case .artists:
                                PreviewArtistsList(favorites: favorites) { artist in
                                    NavigationLink(value: Page.artist(artist.name)) {
                                        PreviewArtistRow(artist: artist, isFavorite: favorites.contains(artist.name))
                                    }
                                }
                            case .artist(let name):
                                if let artist = PreviewLibraryArtist.samples.first(where: { $0.name == name }) {
                                    PreviewArtistDetail(artist: artist,
                                                        isFavorite: membership(of: name, in: $favorites),
                                                        isPinned: membership(of: name, in: $pins)) { albums in
                                        track = 0
                                        queue = albums.map { .init(title: $0.title, artist: name, artwork: $0.artwork) }
                                        isPlaying = true
                                    }
                                }
                            }
                        }
                }
                .tint(.primary)
            }
            Tab("搜索", systemImage: AppTab.search.systemImage, value: AppTab.search) { Color.clear }
        }
        .tabViewBottomAccessory { miniPlayer }
        .background(Color(.systemBackground))
    }

    private func membership(of name: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding {
            values.wrappedValue.contains(name)
        } set: { contains in
            if contains { values.wrappedValue.insert(name) }
            else { values.wrappedValue.remove(name) }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: PreviewArtistMetrics.columns(3), spacing: 16) {
                    pinnedCard("夜语花", artwork: .image(Image("AlbumSample09")))
                    pinnedCard("GUMigazer", artwork: .image(Image("AlbumSample07")))
                    pinnedCard("lost in tianyi", artwork: .image(Image("AlbumSample15")))
                    pinnedCard("喜爱歌曲", artwork: .favorites)
                    ForEach(PreviewLibraryArtist.samples.filter { pins.contains($0.name) }.sorted(byName: \.name)) { artist in
                        NavigationLink(value: Page.artist(artist.name)) {
                            pinnedTile(artist.name) {
                                PreviewArtistAvatar(artwork: artist.artwork)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(spacing: 0) {
                    category("播放列表", icon: "music.note.list")
                    categorySeparator
                    NavigationLink(value: Page.artists) {
                        category("艺人", icon: "music.microphone")
                    }
                    .buttonStyle(.plain)
                    categorySeparator
                    category("专辑", icon: "square.stack")
                    categorySeparator
                    category("歌曲", icon: "music.note")
                    categorySeparator
                    category("已下载", icon: "arrow.down.circle")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近添加")
                        .font(.system(size: DesignTokens.Typography.sectionHeadingSize, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: PreviewArtistMetrics.columns(2)) {
                        ArtworkView(artwork: .image(Image("AlbumSample15")))
                        ArtworkView(artwork: .image(Image("AlbumSample17")))
                    }
                }
            }
            .padding(PreviewArtistMetrics.margin)
        }
        .navigationTitle("资料库")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private func pinnedCard(_ title: String, artwork: Artwork) -> some View {
        pinnedTile(title) { ArtworkView(artwork: artwork, cornerRadius: DesignTokens.Radius.card) }
    }

    private func pinnedTile<Cover: View>(_ title: String, @ViewBuilder cover: () -> Cover) -> some View {
        VStack(spacing: 5) {
            cover()
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }

    private func category(_ title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 27)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
    }

    private var categorySeparator: some View {
        Divider().padding(.leading, 41)
    }

    private var miniPlayer: some View {
        let item = queue[track]
        return HStack(spacing: 11) {
            ArtworkView(artwork: item.artwork, cornerRadius: 4)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                isPlaying.toggle()
            }
            Button("下一首", systemImage: "forward.fill") { track = (track + 1) % queue.count }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 16)
    }
}

private struct PreviewArtistsList<Row: View>: View {
    let favorites: Set<String>
    @ViewBuilder let row: (PreviewLibraryArtist) -> Row
    @State private var filter = LibraryFilter.all
    @State private var query = ""

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var artists: [PreviewLibraryArtist] {
        PreviewLibraryArtist.samples.filter { artist in
            switch filter {
            case .all: true
            case .favorites: favorites.contains(artist.name)
            case .downloaded: artist.isDownloaded
            }
        }
        .filter {
            searchTerm.isEmpty || $0.name.localizedStandardContains(searchTerm)
                || TitleSection<PreviewLibraryArtist>.sortKey($0.name).localizedStandardContains(searchTerm)
        }
        .sorted(byName: \.name)
    }

    var body: some View {
        let results = artists
        List(results) { artist in
            row(artist)
                .listRowInsets(.init(top: 4, leading: PreviewArtistMetrics.margin, bottom: 4,
                                     trailing: PreviewArtistMetrics.margin))
                .listRowSeparator(artist.id == results.first?.id ? .hidden : .automatic, edges: .top)
                .listRowSeparator(artist.id == results.last?.id ? .hidden : .automatic, edges: .bottom)
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                if !searchTerm.isEmpty {
                    ContentUnavailableView.search(text: searchTerm)
                } else {
                    ContentUnavailableView(filter == .favorites ? "没有喜爱的艺人" : "没有已下载的艺人",
                                           systemImage: filter == .favorites ? "star" : "arrow.down.circle")
                }
            }
        }
        .navigationTitle("艺人")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索艺人")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("筛选", systemImage: "line.3.horizontal.decrease") {
                    Toggle("所有艺人", systemImage: "music.microphone", isOn: selection(.all))
                    Section {
                        Toggle("喜爱", systemImage: "star", isOn: selection(.favorites))
                        Toggle("下载", systemImage: "arrow.down.circle", isOn: selection(.downloaded))
                    }
                }
                .menuOrder(.fixed)
                .menuActionDismissBehavior(.enabled)
            }
        }
    }

    private func selection(_ value: LibraryFilter) -> Binding<Bool> {
        Binding(get: { filter == value }, set: { selected in
            if selected { filter = value }
        })
    }
}

private struct PreviewArtistRow: View {
    let artist: PreviewLibraryArtist
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            PreviewArtistAvatar(artwork: artist.artwork)
                .frame(width: DesignTokens.Artwork.rowCoverSize)
                .modifier(PreviewFavoriteGutter(isFavorite: isFavorite))
            Text(artist.name).lineLimit(1)
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + DesignTokens.Spacing.rowDividerInset }
    }
}

private struct PreviewArtistDetail: View {
    private enum Sort: Hashable {
        case name, dateAdded, year
    }

    let artist: PreviewLibraryArtist
    @Binding var isFavorite: Bool
    @Binding var isPinned: Bool
    let play: ([PreviewArtistAlbum]) -> Void

    @State private var layout: LibraryLayout
    @State private var sort = Sort.name
    @State private var showsOnlineArtist = false
    @State private var selectedAlbum: PreviewArtistAlbum?

    init(artist: PreviewLibraryArtist, isFavorite: Binding<Bool>, isPinned: Binding<Bool>,
         play: @escaping ([PreviewArtistAlbum]) -> Void) {
        self.artist = artist
        _isFavorite = isFavorite
        _isPinned = isPinned
        self.play = play
        _layout = State(initialValue: artist.name == "Isekaijoucho" ? .list : .grid)
    }

    private var albums: [PreviewArtistAlbum] {
        switch sort {
        case .name: artist.albums.sorted(byName: \.title)
        case .dateAdded: artist.albums.sorted { $0.addedOrder > $1.addedOrder }
        case .year: artist.albums.sorted { ($0.year, $0.addedOrder) > ($1.year, $1.addedOrder) }
        }
    }

    var body: some View {
        let albums = albums
        List {
            header
                .listRowInsets(.init(top: 20, leading: PreviewArtistMetrics.margin, bottom: 24,
                                     trailing: PreviewArtistMetrics.margin))
                .listRowSeparator(.hidden)
            if layout == .grid {
                LazyVGrid(columns: PreviewArtistMetrics.columns(2), spacing: 16) {
                    ForEach(albums) { album in
                        Button {
                            selectedAlbum = album
                        } label: {
                            AlbumCard(item: .init(id: album.id, title: album.title,
                                                  subtitle: album.yearLabel, artwork: album.artwork))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(.init(top: 0, leading: PreviewArtistMetrics.margin, bottom: 0,
                                     trailing: PreviewArtistMetrics.margin))
                .listRowSeparator(.hidden)
            } else {
                ForEach(albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: album.artwork, cornerRadius: DesignTokens.Radius.songRowCover)
                                .frame(width: PreviewArtistMetrics.albumRowCover)
                                .modifier(PreviewFavoriteGutter(isFavorite: album.isFavorite))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.title).lineLimit(1)
                                Text(album.yearLabel).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + PreviewArtistMetrics.albumRowCover + 12 }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(.init(top: 8, leading: PreviewArtistMetrics.margin, bottom: 8,
                                         trailing: PreviewArtistMetrics.margin))
                    .listRowSeparator(album.id == albums.first?.id ? .hidden : .automatic, edges: .top)
                    .listRowSeparator(album.id == albums.last?.id ? .hidden : .automatic, edges: .bottom)
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isFavorite ? "取消喜爱" : "喜爱", systemImage: isFavorite ? "star.fill" : "star") {
                    isFavorite.toggle()
                }
                .tint(isFavorite ? .yellow : .primary)
                LibrarySortMenu(layout: $layout, sort: $sort, options: [
                    .init(sort: .name, title: "名称", subtitle: "A-Z"),
                    .init(sort: .dateAdded, title: "添加日期"),
                    .init(sort: .year, title: "年份")
                ], leading: menuActions)
                .menuOrder(.fixed)
            }
        }
        .alert("前往艺人", isPresented: $showsOnlineArtist) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这里预览从资料库前往「\(artist.name)」的在线艺人主页。")
        }
        .alert("资料库专辑", isPresented: Binding(
            get: { selectedAlbum != nil }, set: { if !$0 { selectedAlbum = nil } }
        ), presenting: selectedAlbum) { _ in
            Button("好", role: .cancel) {}
        } message: { album in
            Text(album.title)
        }
    }

    private var menuActions: LibraryMenuSections {
        var actions: LibraryMenuSections = [
            [.init(title: isFavorite ? "取消喜爱" : "喜爱", systemImage: isFavorite ? "star.slash" : "star") {
                isFavorite.toggle()
            }],
            [.init(title: isPinned ? "取消置顶" : "置顶艺人", systemImage: isPinned ? "pin.slash" : "pin") {
                isPinned.toggle()
            }]
        ]
        if artist.hasOnlinePage {
            actions.append([.init(title: "前往艺人", systemImage: "music.microphone") { showsOnlineArtist = true }])
        }
        return actions
    }

    private var header: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                PreviewArtistAvatar(artwork: artist.artwork)
                    .frame(width: PreviewArtistMetrics.heroAvatar)
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                if artist.hasOnlinePage {
                    Button {
                        showsOnlineArtist = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(artist.name)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("前往在线艺人主页的预览")
                } else {
                    Text(artist.name)
                }
            }
            .font(.title.bold())
            PlayShuffleButtons(play: { play(albums) }, shuffle: { play(albums.shuffled()) })
                .disabled(albums.isEmpty)
        }
    }
}

private enum PreviewArtistMetrics {
    static let margin = DesignTokens.Spacing.pageMargin
    static let heroAvatar: CGFloat = 86
    static let albumRowCover: CGFloat = 64
    static let gridSpacing: CGFloat = 12

    static func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: count)
    }
}

private struct PreviewFavoriteGutter: ViewModifier {
    let isFavorite: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: -14)
                    .accessibilityLabel("已喜爱")
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PreviewArtistAvatar: View {
    let artwork: PreviewLibraryArtist.Avatar

    var body: some View {
        Group {
            switch artwork {
            case .portrait(let asset):
                ArtistAvatar(artwork: .image(Image(asset)))
            case .album(let asset, let dominantColor):
                Circle().fill(dominantColor.color).overlay {
                    GeometryReader { proxy in
                        let side = proxy.size.width * 0.62
                        ArtworkView(artwork: .image(Image(asset)), cornerRadius: side * 0.06, showsBorder: false)
                            .frame(width: side)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .missing:
                ArtistAvatar(artwork: nil)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct PreviewArtistAlbum: Identifiable {
    let title: String
    let year: Int
    let addedOrder: Int
    let asset: String
    var isFavorite = false
    var id: String { title }
    var artwork: Artwork { .image(Image(asset)) }
    var yearLabel: String { "\(year.formatted(.number.grouping(.never)))年" }
}

private struct PreviewLibraryArtist: Identifiable {
    enum Avatar {
        case portrait(String)
        case album(String, AlbumArtworkBackdrop)
        case missing
    }

    let name: String
    let artwork: Avatar
    var hasOnlinePage = true
    var isDownloaded = false
    var albums: [PreviewArtistAlbum] = []
    var id: String { name }

    static let samples: [Self] = [
        .init(name: "Albemuth", artwork: .album("AlbumSample08", .init(red: 0.72, green: 0.75, blue: 0.84)),
              albums: [.init(title: "ADAM (feat. 存流 & 明透)", year: 2023, addedOrder: 1, asset: "AlbumSample13")]),
        .init(name: "ASU", artwork: .album("AlbumSample14", .init(red: 0.48, green: 0.53, blue: 0.69)), isDownloaded: true,
              albums: [.init(title: "BELOVED", year: 2026, addedOrder: 1, asset: "AlbumSample14")]),
        .init(name: "北极圈 Arcticlab", artwork: .missing, hasOnlinePage: false, isDownloaded: true,
              albums: [.init(title: "极光", year: 2024, addedOrder: 1, asset: "AlbumSample04")]),
        .init(name: "磁带君", artwork: .missing, hasOnlinePage: false),
        .init(name: "CIEL", artwork: .portrait("AlbumSample03")),
        .init(name: "導凰", artwork: .portrait("AlbumSample15")),
        .init(name: "DECO*27", artwork: .portrait("AlbumSample16")),
        .init(name: "Isekaijoucho", artwork: .portrait("AlbumSample10"), isDownloaded: true, albums: [
            .init(title: "BREATHE - Single", year: 2025, addedOrder: 2, asset: "AlbumSample11", isFavorite: true),
            .init(title: "創生", year: 2021, addedOrder: 4, asset: "AlbumSample13"),
            .init(title: "色彩", year: 2024, addedOrder: 1, asset: "AlbumSample20"),
            .init(title: "システムズコア - Single", year: 2024, addedOrder: 3, asset: "AlbumSample21")
        ]),
        .init(name: "IV015", artwork: .missing, hasOnlinePage: false),
        .init(name: "久石让", artwork: .portrait("AlbumSample05")),
        .init(name: "KAF", artwork: .portrait("AlbumSample17")),
        .init(name: "Laterne", artwork: .album("AlbumSample06", .init(red: 0.49, green: 0.62, blue: 0.69))),
        .init(name: "理芽 with Guiano", artwork: .portrait("AlbumSample09")),
        .init(name: "铃蓝 SuzuSnow", artwork: .missing, hasOnlinePage: false)
    ]
}

#Preview("艺人列表") { LibraryArtistsPreview() }
#Preview("艺人详情 · 网格") { LibraryArtistsPreview(scene: .detailGrid) }
#Preview("艺人详情 · 列表") { LibraryArtistsPreview(scene: .detailList) }
#Preview("资料库 · 置顶艺人") { LibraryArtistsPreview(scene: .pinnedArtist) }
#endif
