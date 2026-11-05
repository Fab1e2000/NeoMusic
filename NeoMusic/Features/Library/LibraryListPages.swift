import SwiftUI

/// 资料库里的一首歌。
struct LibrarySongItem: Identifiable, Equatable {
    let id: String
    var albumID: String { onlineAlbumID.map { "catalog:album:" + String($0) } ?? albumDirectory.map { "folder:" + $0 } ?? (albumArtist + "\u{001F}" + album) }
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int
    var artwork: Artwork
    var albumDirectory: String? = nil
    var discNumber: Int = 1
    var artworkData: Data? = nil
    var artworkURL: URL? = nil
    /// Prepared with the original artwork before the song becomes visible.
    var artworkBackdrop: AlbumArtworkBackdrop? = nil
    var duration: Int = 0
    var isPinned = false
    var addedOrder = 0
    var isFavorite = false
    var favoriteAddedAt: Date? = nil
    var unavailabilityReason: String? = nil
    var onlineAlbumID: Int64? = nil
    var artistReferences: [LibraryArtistReference] = []

    var onlineOwnerID: String? {
        let parts = id.split(separator: ":")
        return parts.count == 3 && parts[0] == "netease" ? String(parts[1]) : nil
    }
    var onlineSongID: Int64? {
        guard onlineOwnerID != nil else { return nil }
        return id.split(separator: ":").last.flatMap { Int64($0) }
    }
    var isOnline: Bool { onlineOwnerID != nil }
}

extension LibrarySongItem {
    func replacingArtwork(from value: Self) -> Self {
        var result = self
        result.artwork = value.artwork
        result.artworkData = value.artworkData
        result.artworkURL = value.artworkURL
        result.artworkBackdrop = value.artworkBackdrop
        return result
    }

    static func unavailable(_ id: String) -> Self {
        if id.hasPrefix("netease:") {
            return Self(id: id, title: "在线歌曲", artist: "登录原账号后可用", album: "", albumArtist: "", trackNumber: 0,
                        artwork: .missing, unavailabilityReason: "请登录原网易云账号后重试")
        }
        return Self(id: id, title: URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent,
             artist: "文件不可用", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
    }

    static func albumOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        let left = lhs.trackNumber > 0 ? lhs.trackNumber : Int.max
        let right = rhs.trackNumber > 0 ? rhs.trackNumber : Int.max
        if left != right { return left < right }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

struct LibraryArtistReference: Equatable {
    let id: String
    let name: String
}

/// 资料库里的一位艺人；本地音乐没有艺人照片时使用占位图。
struct LibraryArtistItem: Identifiable, Equatable {
    let id: String
    let name: String
    var artwork: Artwork?
    var isFavorite = false
}

// MARK: - 歌曲

/// 歌曲列表的排序方式，对照 Apple Music：名称、添加日期、艺人（A-Z）。
/// 按艺人时依次按专辑艺人、专辑、曲目号排列，并按专辑艺人首字母分组。
enum SongSort: Hashable {
    case name, addedDate, artist

    static let options = [
        LibrarySortOption(sort: SongSort.name, title: "名称"),
        LibrarySortOption(sort: SongSort.addedDate, title: "添加日期"),
        LibrarySortOption(sort: SongSort.artist, title: "艺人", subtitle: "A-Z"),
    ]

    func sections(of songs: [LibrarySongItem]) -> [TitleSection<LibrarySongItem>] {
        switch self {
        case .name:
            TitleSection.group(songs, by: \.title)
        case .artist:
            TitleSection.group(songs) { song in
                [song.albumArtist, song.album, String(format: "%04d", song.discNumber), String(format: "%04d", song.trackNumber)].joined(separator: "\u{1}")
            }
        case .addedDate:
            [TitleSection(letter: "", items: songs.sorted { $0.addedOrder > $1.addedOrder })]
        }
    }
}

struct SongsListView: View {
    let songs: [LibrarySongItem]
    let playAll: ([LibrarySongItem], Bool) -> Void
    @State private var sort = SongSort.artist
    @State private var filter = LibraryFilter.all
    @State private var query = ""
    @State private var projection = LibraryListProjection<ProjectionInput, Projection>()
    @Environment(\.songMenuActions) private var actions

    struct ProjectionInput: Equatable {
        let songs: [LibrarySongItem]
        let query: String
        let filter: LibraryFilter
        let sort: SongSort

        func calculate() -> Projection {
            let matching = query.isEmpty ? songs : songs.filter {
                $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) || $0.album.localizedStandardContains(query)
            }
            let shown = filter == .favorites ? matching.filter(\.isFavorite) : matching
            let sections = sort.sections(of: shown)
            return Projection(sections: sections, ordered: sections.flatMap(\.items))
        }
    }
    struct Projection {
        let sections: [TitleSection<LibrarySongItem>]
        let ordered: [LibrarySongItem]
    }

    var body: some View {
        let input = ProjectionInput(songs: songs, query: query, filter: filter, sort: sort)
        let result = projection.value(for: input, calculate: input.calculate)
        let sections = result.sections
        let ordered = result.ordered
        List {
            PlayShuffleButtons(play: { playAll(ordered, false) }, shuffle: { playAll(ordered, true) })
                .disabled(ordered.isEmpty)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
            ForEach(sections) { section in
                // 字母标题作为普通行而非分组标题，滚动时不吸顶，与 Apple Music 一致。
                Section {
                    if !section.letter.isEmpty {
                        Text(section.letter)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .listRowInsets(EdgeInsets(top: 22, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(section.items) { song in
                        SongRow(song: song) {
                            actions.play(ordered, ordered.firstIndex { $0.id == song.id } ?? 0, "歌曲")
                        }
                        .listRowSeparator(.visible, edges: .bottom)
                    }
                }
                .sectionIndexLabel(section.letter.isEmpty ? nil : Text(section.letter))
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(sort == .addedDate ? .hidden : .visible)
        .environment(\.defaultMinListRowHeight, 0)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .libraryNavigationTitle("歌曲")
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: "搜索歌曲")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有歌曲", allImage: "music.note")
                LibrarySortMenu(sort: $sort, options: SongSort.options)
            }
        }
    }
}

/// 歌曲行：点按播放，长按弹出菜单与预览，“…”按钮弹出同一份菜单。
struct SongRow: View {
    let song: LibrarySongItem
    var play: () -> Void = {}
    @Environment(\.songMenuActions) private var actions
    @Environment(\.libraryDownloads) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ArtworkView(artwork: song.artwork, cornerRadius: 6)
                        .environment(\.nativeArtworkSurfaceEnabled, false)
                        .frame(width: 48)
                        .overlay(alignment: .leading) { FavoriteMark(isFavorite: song.isFavorite) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title).font(.callout)
                        Text(song.artist).font(.footnote).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            SongDownloadStatus(song: song, showsImported: false)
            TrackMoreButton(song: song)
        }
        .frame(minHeight: 56)
        .songContextMenu(song)
        // 右滑插播，左滑下载；本地导入文件保留原有布局。
        .swipeActions(edge: .leading) {
            Button("插播", systemImage: "text.line.first.and.arrowtriangle.forward") { actions.playNext(song) }
                .labelStyle(.iconOnly)
                .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            if downloads?.state(of: song.id)?.isActive == true {
                Button("停止下载", systemImage: "stop.fill") { downloads?.stop([song]) }.tint(.blue)
            } else if downloads?.canRemove(song) == true {
                Button("移除下载", systemImage: "xmark.circle") { downloads?.requestRemoval([song]) }.tint(.red)
            } else {
                Button("下载", systemImage: "arrow.down") { downloads?.download([song]) }
                    .labelStyle(.iconOnly)
                    .tint(downloads?.isDownloadable(song) == true ? .blue : .gray)
                    .disabled(downloads?.isDownloadable(song) != true)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

// MARK: - 专辑

/// 专辑页的排序方式，对照 Apple Music：名称、添加日期、艺人（A-Z）、年份。
enum AlbumSort: Hashable {
    case name, addedDate, artist, year

    static let options = [
        LibrarySortOption(sort: AlbumSort.name, title: "名称"),
        LibrarySortOption(sort: AlbumSort.addedDate, title: "添加日期"),
        LibrarySortOption(sort: AlbumSort.artist, title: "艺人", subtitle: "A-Z"),
        LibrarySortOption(sort: AlbumSort.year, title: "年份"),
    ]

    func apply(to albums: [LibraryShelfItem]) -> [LibraryShelfItem] {
        switch self {
        case .name: albums.sorted(byName: \.title)
        case .addedDate: albums.sorted { $0.addedOrder > $1.addedOrder }
        case .artist: albums.sorted(byName: { [$0.subtitle ?? "", $0.title].joined(separator: "\u{1}") })
        case .year: albums.sorted { ($0.year ?? 0, $1.title) > ($1.year ?? 0, $0.title) }
        }
    }
}

struct AlbumsGridView: View {
    let albums: [LibraryShelfItem]
    let playAll: ([String], Bool) -> Void
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = AlbumSort.artist
    @State private var layout = LibraryLayout.grid
    @State private var projection = LibraryListProjection<ProjectionInput, [LibraryShelfItem]>()
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private struct ProjectionInput: Equatable {
        let albums: [LibraryShelfItem]
        let query: String
        let filter: LibraryFilter
        let sort: AlbumSort
    }

    var body: some View {
        let shown = projection.value(for: ProjectionInput(albums: albums, query: query, filter: filter, sort: sort)) {
            let matching = query.isEmpty ? albums : albums.filter {
                $0.title.localizedStandardContains(query) || ($0.subtitle?.localizedStandardContains(query) ?? false)
            }
            return sort.apply(to: filter == .favorites ? matching.filter(\.isFavorite) : matching)
        }
        ScrollView {
            VStack(spacing: 24) {
                PlayShuffleButtons(play: { playAll(shown.map(\.id), false) }, shuffle: { playAll(shown.map(\.id), true) })
                    .disabled(shown.isEmpty)
                switch layout {
                case .grid:
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 21) {
                        ForEach(shown) { item in CollectionCardLink(item: item) { AlbumCard(item: item) } }
                    }
                case .list:
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            CollectionCardLink(item: item) {
                                CollectionListRow(item: item, showsSeparator: index < shown.count - 1)
                            }
                        }
                    }
                    .padding(.horizontal, -20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .libraryNavigationTitle("专辑")
        .libraryTitleDisplayMode(.large)
        // Keep the search drawer independent of the library home’s whole-bar minimization during push/pop.
        .librarySearchable(text: $query, prompt: "搜索专辑")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有专辑", allImage: "square.stack")
                LibrarySortMenu(layout: $layout, sort: $sort, options: AlbumSort.options)
            }
        }
    }
}

/// 专辑、播放列表在列表显示方式下的一行：封面、标题、副标题与箭头；分隔线从标题起点画起。
struct CollectionListRow: View {
    let item: LibraryShelfItem
    let showsSeparator: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: item.artwork, cornerRadius: 6)
                .frame(width: 64)
                .overlay(alignment: .leading) { FavoriteMark(isFavorite: item.isFavorite, color: .yellow) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 80)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle().fill(.separator).frame(height: 1 / 3)
                    .padding(.leading, 96)
                    .padding(.trailing, 20)
            }
        }
    }
}

// MARK: - 艺人

struct ArtistsListView: View {
    let artists: [LibraryArtistItem]
    @State private var filter = LibraryFilter.all

    var body: some View {
        List(filter == .favorites ? artists.filter(\.isFavorite) : artists) { artist in
            LibraryRouteLink(value: LibraryRoute.artist(artist.id)) {
                HStack(spacing: 12) {
                    ArtistAvatar(artwork: artist.artwork)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .leading) { FavoriteMark(isFavorite: artist.isFavorite, color: .yellow) }
                    Text(artist.name).font(.callout).lineLimit(1)
                }
                .frame(minHeight: 56)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .libraryNavigationTitle("艺人")
        .libraryTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有艺人", allImage: "music.microphone")
            }
        }
    }
}

/// 圆形艺人头像；没有图片时为浅灰底上的麦克风。
struct ArtistAvatar: View {
    let artwork: Artwork?

    var body: some View {
        Group {
            if let artwork {
                ArtworkView(artwork: artwork, cornerRadius: 0)
            } else {
                GeometryReader { proxy in
                    Color(.secondarySystemFill)
                        .overlay {
                            Image(systemName: "music.microphone")
                                .font(.system(size: proxy.size.width * 0.4))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
        }
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
