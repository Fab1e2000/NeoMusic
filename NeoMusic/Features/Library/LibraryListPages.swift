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
    private var artworkState: SongArtworkState
    var artwork: Artwork {
        get { artworkState.value.artwork }
        set { var value = artworkState.snapshot; value.artwork = newValue; artworkState = SongArtworkState(value) }
    }
    var albumDirectory: String? = nil
    var discNumber: Int = 1
    var artworkData: Data? {
        get { artworkState.value.artworkData }
        set { var value = artworkState.snapshot; value.artworkData = newValue; artworkState = SongArtworkState(value) }
    }
    var artworkURL: URL? {
        get { artworkState.value.artworkURL }
        set { var value = artworkState.snapshot; value.artworkURL = newValue; artworkState = SongArtworkState(value) }
    }
    /// Prepared with the original artwork before the song becomes visible.
    var artworkBackdrop: AlbumArtworkBackdrop? {
        get { artworkState.value.artworkBackdrop }
        set { var value = artworkState.snapshot; value.artworkBackdrop = newValue; artworkState = SongArtworkState(value) }
    }
    var duration: Int = 0
    var isPinned = false
    var addedOrder = 0
    var isFavorite = false
    var favoriteAddedAt: Date? = nil
    var unavailabilityReason: String? = nil
    var onlineAlbumID: Int64? = nil
    var artistReferences: [LibraryArtistReference] = []

    init(id: String, title: String, artist: String, album: String, albumArtist: String,
         trackNumber: Int, artwork: Artwork, albumDirectory: String? = nil, discNumber: Int = 1,
         artworkData: Data? = nil, artworkURL: URL? = nil, artworkBackdrop: AlbumArtworkBackdrop? = nil,
         duration: Int = 0, isPinned: Bool = false, addedOrder: Int = 0, isFavorite: Bool = false,
         favoriteAddedAt: Date? = nil, unavailabilityReason: String? = nil,
         onlineAlbumID: Int64? = nil, artistReferences: [LibraryArtistReference] = []) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.albumArtist = albumArtist; self.trackNumber = trackNumber
        self.albumDirectory = albumDirectory; self.discNumber = discNumber
        self.artworkState = SongArtworkState(.init(artwork: artwork, artworkData: artworkData,
                                                   artworkURL: artworkURL, artworkBackdrop: artworkBackdrop))
        self.duration = duration; self.isPinned = isPinned; self.addedOrder = addedOrder
        self.isFavorite = isFavorite; self.favoriteAddedAt = favoriteAddedAt
        self.unavailabilityReason = unavailabilityReason; self.onlineAlbumID = onlineAlbumID
        self.artistReferences = artistReferences
    }

    /// Resource arrivals notify image readers without replacing the song or its list.
    /// Ordinary property setters retain value semantics for metadata edits and snapshots.
    @discardableResult
    func publishArtwork(from replacement: Self) -> Bool {
        guard id == replacement.id else { return false }
        return artworkState.update(replacement.artworkState.snapshot)
    }

    var onlineOwnerID: String? {
        let parts = id.split(separator: ":")
        return parts.count == 3 && parts[0] == "netease" ? String(parts[1]) : nil
    }
    var onlineSongID: Int64? {
        guard onlineOwnerID != nil else { return nil }
        return id.split(separator: ":").last.flatMap { Int64($0) }
    }
    var isOnline: Bool { onlineOwnerID != nil }
    /// Whether this item represents a track from the NetEase catalog (online, guest catalog, or downloaded).
    var isNeteaseCatalogSong: Bool {
        isOnline || id.hasPrefix("catalog-guest:") || onlineAlbumID != nil || !artistReferences.isEmpty
    }
}

/// Image resource state is observed separately from song metadata and list ordering.
@Observable private final class SongArtworkState: Equatable {
    struct Snapshot: Equatable {
        var artwork: Artwork
        var artworkData: Data?
        var artworkURL: URL?
        var artworkBackdrop: AlbumArtworkBackdrop?
    }
    @ObservationIgnored private(set) var snapshot: Snapshot
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }

    var value: Snapshot {
        access(keyPath: \.value)
        return snapshot
    }

    func update(_ value: Snapshot) -> Bool {
        guard snapshot != value else { return false }
        withMutation(keyPath: \.value) { snapshot = value }
        return true
    }

    // Comparing list inputs must not subscribe the list to individual image arrivals.
    static func == (lhs: SongArtworkState, rhs: SongArtworkState) -> Bool {
        lhs === rhs || lhs.snapshot == rhs.snapshot
    }
}

extension LibrarySongItem {
    /// Online metadata refreshes keep an available cover while a new source is loading.
    /// The new deferred identity remains responsible for requesting its replacement.
    func retainingArtwork(from previous: Self?) -> Self {
        guard isOnline, let previous, previous.id == id, unavailabilityReason == nil,
              artworkURL == nil else { return self }
        let file: URL?
        if let url = previous.artworkURL { file = url }
        else if case .file(let url) = previous.artwork { file = url }
        else { file = nil }
        let availableFile = file.flatMap { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard availableFile != nil || previous.artworkData != nil else { return self }
        var result = self
        result.artworkURL = availableFile
        result.artworkData = previous.artworkData
        result.artworkBackdrop = previous.artworkBackdrop
        if artwork.loadID == nil { result.artwork = availableFile.map(Artwork.file) ?? previous.artwork }
        return result
    }

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
    @ArtworkResource var artwork: Artwork?
    var isFavorite = false
}

// MARK: - 歌曲

/// 歌曲列表的排序方式，对照 Apple Music：名称、添加日期、艺人（A-Z）。
/// 按艺人时依次按专辑艺人、专辑、曲目号排列，并按专辑艺人首字母分组。
enum SongSort: Hashable, Sendable {
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
    @State private var projection = AsyncListProjection<ProjectionInput, Projection>()
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute

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

    private struct SongSortEntry: Sendable {
        let index: Int
        let title: String
        let artist: String
        let album: String
        let albumArtist: String
        let discNumber: Int
        let trackNumber: Int
        let addedOrder: Int
        let isFavorite: Bool
    }

    private struct GroupedIndices: Sendable {
        let letter: String
        let indices: [Int]
    }

    nonisolated private static func computeGroupedIndices(entries: [SongSortEntry], query: String,
                                                          filter: LibraryFilter, sort: SongSort) -> [GroupedIndices] {
        let matching = query.isEmpty ? entries : entries.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query)
        }
        if Task.isCancelled { return [] }
        let shown = filter == .favorites ? matching.filter(\.isFavorite) : matching
        if Task.isCancelled { return [] }
        switch sort {
        case .name:
            return TitleSection.group(shown, by: \.title).map { GroupedIndices(letter: $0.letter, indices: $0.items.map(\.index)) }
        case .artist:
            return TitleSection.group(shown) { entry in
                [entry.albumArtist, entry.album, String(format: "%04d", entry.discNumber), String(format: "%04d", entry.trackNumber)].joined(separator: "\u{1}")
            }.map { GroupedIndices(letter: $0.letter, indices: $0.items.map(\.index)) }
        case .addedDate:
            return [GroupedIndices(letter: "", indices: shown.sorted { $0.addedOrder > $1.addedOrder }.map(\.index))]
        }
    }

    private static func fastPath(_ input: ProjectionInput) -> Projection? {
        input.songs.count <= 120 ? input.calculate() : nil
    }

    var body: some View {
        let input = ProjectionInput(songs: songs, query: query, filter: filter, sort: sort)
        let result = projection.currentValue(for: input, fastPath: Self.fastPath,
                                             placeholder: { _ in Projection(sections: [], ordered: []) })
        let ordered = result.ordered
        
        GenericCollectionList(
            items: ordered,
            menu: { song in
                let sections = actions.rowMenuSections(for: song) { openLibraryRoute($0) }
                return sections.nativeMenu(firstSectionIsRow: (sections.first?.count ?? 0) > 1)
            },
            open: { song, _ in
                actions.play(ordered, ordered.firstIndex { $0.id == song.id } ?? 0, "歌曲")
            },
            moveItem: nil,
            shelfItem: { song in
                LibraryShelfItem(id: song.id, title: song.title, subtitle: song.artist, artwork: song.artwork,
                                 route: nil, songID: song.id)
            },
            route: { song in .album(song.albumID) },
            deselectsImmediately: true
        )
        .libraryNavigationTitle("歌曲")
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: "搜索歌曲")
        .libraryRootAccountButton()
        .task(id: input) {
            let entries = input.songs.enumerated().map { index, song in
                SongSortEntry(index: index, title: song.title, artist: song.artist, album: song.album,
                              albumArtist: song.albumArtist, discNumber: song.discNumber,
                              trackNumber: song.trackNumber, addedOrder: song.addedOrder, isFavorite: song.isFavorite)
            }
            let currentQuery = input.query
            let currentFilter = input.filter
            let currentSort = input.sort
            await projection.computeIfNeeded(
                for: input,
                fastPath: Self.fastPath,
                background: {
                    Self.computeGroupedIndices(entries: entries, query: currentQuery, filter: currentFilter, sort: currentSort)
                },
                finish: { groups in
                    let sections = groups.map { TitleSection(letter: $0.letter, items: $0.indices.map { input.songs[$0] }) }
                    return Projection(sections: sections, ordered: sections.flatMap(\.items))
                }
            )
        }
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SharedSongRow(
            song: song,
            appearance: SongRowAppearance(
                titleSubtitleSpacing: 0,
                moreColor: Color.secondaryContentColor(on: Color(.systemBackground), colorScheme: colorScheme),
                favoriteMarkOffset: -15,
                usesPlainButtonStyle: true
            ),
            play: play
        ) {
            ArtworkView(artwork: song.artwork, cornerRadius: 6)
                .environment(\.nativeArtworkSurfaceEnabled, false)
                .frame(width: 48)
        }
        .songListRow(song, mode: .libraryDownloads, swipeBackground: Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 60 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

// MARK: - 专辑

/// 专辑页的排序方式，对照 Apple Music：名称、添加日期、艺人（A-Z）、年份。
enum AlbumSort: Hashable, Sendable {
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
    @State private var projection = AsyncListProjection<ProjectionInput, [LibraryShelfItem]>()
    @Environment(\.dynamicTypeSize) private var textSize
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: textSize.isAccessibilitySize ? 1 : 2)
    }

    private struct ProjectionInput: Equatable {
        let albums: [LibraryShelfItem]
        let query: String
        let filter: LibraryFilter
        let sort: AlbumSort

        func calculate() -> [LibraryShelfItem] {
            let matching = query.isEmpty ? albums : albums.filter {
                $0.title.localizedStandardContains(query) || ($0.subtitle?.localizedStandardContains(query) ?? false)
            }
            return sort.apply(to: filter == .favorites ? matching.filter(\.isFavorite) : matching)
        }
    }

    private struct AlbumSortEntry: Sendable {
        let index: Int
        let title: String
        let subtitle: String
        let addedOrder: Int
        let year: Int
        let isFavorite: Bool
    }

    private static func fastPath(_ input: ProjectionInput) -> [LibraryShelfItem]? {
        input.albums.count <= 80 ? input.calculate() : nil
    }

    nonisolated private static func computeAlbumIndices(entries: [AlbumSortEntry], query: String,
                                                        filter: LibraryFilter, sort: AlbumSort) -> [Int] {
        let matching = query.isEmpty ? entries : entries.filter {
            $0.title.localizedStandardContains(query) || $0.subtitle.localizedStandardContains(query)
        }
        if Task.isCancelled { return [] }
        let filtered = filter == .favorites ? matching.filter(\.isFavorite) : matching
        if Task.isCancelled { return [] }
        let ordered: [AlbumSortEntry]
        switch sort {
        case .name:
            ordered = filtered.sorted(byName: \.title)
        case .addedDate:
            ordered = filtered.sorted { $0.addedOrder > $1.addedOrder }
        case .artist:
            ordered = filtered.sorted(byName: { [$0.subtitle, $0.title].joined(separator: "\u{1}") })
        case .year:
            ordered = filtered.sorted { ($0.year, $1.title) > ($1.year, $0.title) }
        }
        return ordered.map(\.index)
    }

    var body: some View {
        let input = ProjectionInput(albums: albums, query: query, filter: filter, sort: sort)
        let shown = projection.currentValue(for: input, fastPath: Self.fastPath, placeholder: { _ in [] })
        ScrollView {
            VStack(spacing: 24) {
                if !shown.isEmpty {
                    PlayShuffleButtons(play: { playAll(shown.map(\.id), false) }, shuffle: { playAll(shown.map(\.id), true) })
                }
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
        .overlay {
            if shown.isEmpty, projection.isResolved(for: input, fastPath: Self.fastPath) {
                LibraryListEmptyState(noun: "专辑", symbol: "square.stack", query: $query, filter: $filter)
            }
        }
        .libraryNavigationTitle("专辑")
        .libraryTitleDisplayMode(.large)
        .libraryRootAccountButton()
        // Keep the search drawer independent of the library home’s whole-bar minimization during push/pop.
        .librarySearchable(text: $query, prompt: "搜索专辑")
        .task(id: input) {
            let entries = input.albums.enumerated().map { index, album in
                AlbumSortEntry(index: index, title: album.title, subtitle: album.subtitle ?? "",
                               addedOrder: album.addedOrder, year: album.year ?? 0, isFavorite: album.isFavorite)
            }
            let currentQuery = input.query
            let currentFilter = input.filter
            let currentSort = input.sort
            await projection.computeIfNeeded(
                for: input,
                fastPath: Self.fastPath,
                background: {
                    Self.computeAlbumIndices(entries: entries, query: currentQuery, filter: currentFilter, sort: currentSort)
                },
                finish: { indices in indices.map { input.albums[$0] } }
            )
        }
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
    @Environment(\.dynamicTypeSize) private var textSize

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
            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
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

struct LibraryListEmptyState: View {
    let noun: String
    let symbol: String
    @Binding var query: String
    @Binding var filter: LibraryFilter

    var body: some View {
        ContentUnavailableView {
            Label(query.isEmpty ? (filter == .favorites ? "暂无喜爱的\(noun)" : "暂无\(noun)") : "没有找到结果",
                  systemImage: query.isEmpty ? symbol : "magnifyingglass")
        } description: {
            if !query.isEmpty {
                Text("没有符合“\(query)”的\(noun)。")
            } else if filter == .favorites {
                Text("将\(noun)加入喜爱后，会显示在这里。")
            } else {
                Text("添加到资料库的\(noun)会显示在这里。")
            }
        } actions: {
            if !query.isEmpty {
                Button("清除搜索") { query = "" }
                    .accessibilityIdentifier("library.empty.clear-search")
            }
            if filter == .favorites {
                Button("显示全部") {
                    query = ""
                    filter = .all
                }
                .accessibilityIdentifier("library.empty.show-all")
            }
        }
        .accessibilityIdentifier("library.empty-state")
    }
}

// MARK: - 艺人

struct ArtistsListView: View {
    let artists: [LibraryArtistItem]
    @State private var filter = LibraryFilter.all
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    var body: some View {
        let artists = filter == .favorites ? artists.filter(\.isFavorite) : artists
        GenericCollectionList(
            items: artists,
            menu: { _ in UIMenu() },
            open: { artist, source in
                openLibraryRoute(.artist(artist.id), sourceProvider: source)
            },
            moveItem: nil,
            shelfItem: { artist in
                LibraryShelfItem(id: artist.id, title: artist.name, artwork: artist.artwork ?? .missing, route: .artist(artist.id))
            },
            route: { artist in .artist(artist.id) }
        )
        .libraryNavigationTitle("艺人")
        .libraryTitleDisplayMode(.large)
        .libraryRootAccountButton()
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
