import SwiftUI

struct LibrarySongItem: Identifiable, Equatable {
    let id: String
    var albumID: String { onlineAlbumID.map(CatalogRouteIdentity.albumID) ?? albumDirectory.map { "folder:" + $0 } ?? (albumArtist + "\u{001F}" + album) }
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int
    private var artworkState: SongArtworkState
    var artworkIdentity: ObjectIdentifier { ObjectIdentifier(artworkState) }
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
    var year: Int?

    init(id: String, title: String, artist: String, album: String, albumArtist: String,
         trackNumber: Int, artwork: Artwork, albumDirectory: String? = nil, discNumber: Int = 1,
         artworkData: Data? = nil, artworkURL: URL? = nil, artworkBackdrop: AlbumArtworkBackdrop? = nil,
         duration: Int = 0, isPinned: Bool = false, addedOrder: Int = 0, isFavorite: Bool = false,
         favoriteAddedAt: Date? = nil, unavailabilityReason: String? = nil,
         onlineAlbumID: Int64? = nil, artistReferences: [LibraryArtistReference] = [], year: Int? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.albumArtist = albumArtist; self.trackNumber = trackNumber
        self.albumDirectory = albumDirectory; self.discNumber = discNumber
        self.artworkState = SongArtworkState(.init(artwork: artwork, artworkData: artworkData,
                                                   artworkURL: artworkURL, artworkBackdrop: artworkBackdrop))
        self.duration = duration; self.isPinned = isPinned; self.addedOrder = addedOrder
        self.isFavorite = isFavorite; self.favoriteAddedAt = favoriteAddedAt
        self.unavailabilityReason = unavailabilityReason; self.onlineAlbumID = onlineAlbumID
        self.artistReferences = artistReferences
        self.year = year
    }

    @discardableResult
    func publishArtwork(from replacement: Self) -> Bool {
        guard id == replacement.id else { return false }
        return artworkState.update(replacement.artworkState.snapshot)
    }

    var onlineOwnerID: String? {
        OnlineSongIdentity.parseOwnerAndSong(id)?.ownerID
    }
    var onlineSongID: Int64? {
        OnlineSongIdentity.parseOwnerAndSong(id)?.songID
    }
    var isOnline: Bool { onlineOwnerID != nil }
    var isNeteaseCatalogSong: Bool {
        isOnline || id.hasPrefix("catalog-guest:") || onlineAlbumID != nil || !artistReferences.isEmpty
    }
}

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

    static func == (lhs: SongArtworkState, rhs: SongArtworkState) -> Bool {
        lhs === rhs || lhs.snapshot == rhs.snapshot
    }
}

extension LibrarySongItem {
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
    var artwork: Artwork?
}

struct LibraryArtistItem: Identifiable, Equatable {
    let id: String
    let name: String
    @ArtworkResource var artwork: Artwork?
    var isFavorite = false
}


enum SongSort: Hashable, Sendable {
    case name, addedDate, artist

    static let options = [
        LibrarySortOption(sort: SongSort.name, title: "名称"),
        LibrarySortOption(sort: SongSort.addedDate, title: "添加日期", subtitle: "最新的排最前"),
        LibrarySortOption(sort: SongSort.artist, title: "艺人"),
    ]
}

struct SongsListView: View {
    let songs: [LibrarySongItem]
    let playAll: ([LibrarySongItem], Bool) -> Void
    @State private var sort = SongSort.addedDate
    @State private var filter = LibraryFilter.all
    @State private var query = ""
    @State private var projection = AsyncListProjection<ProjectionInput, Projection>()
    @Environment(\.songMenuActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    struct ProjectionInput: Equatable {
        let songs: [LibrarySongItem]
        let query: String
        let filter: LibraryFilter
        let sort: SongSort

        func calculate() -> Projection {
            finish(SongsListView.computeGroupedIndices(entries: entries, query: query, filter: filter, sort: sort))
        }

        fileprivate var entries: [SongSortEntry] {
            songs.enumerated().map { index, song in
                SongSortEntry(index: index, title: song.title, artist: song.artist, album: song.album,
                              albumArtist: song.albumArtist, discNumber: song.discNumber,
                              trackNumber: song.trackNumber, addedOrder: song.addedOrder, isFavorite: song.isFavorite)
            }
        }

        fileprivate func finish(_ groups: [GroupedIndices]) -> Projection {
            let sections = groups.map { TitleSection(letter: $0.letter, items: $0.indices.map { songs[$0] }) }
            return Projection(sections: sections, ordered: sections.flatMap(\.items))
        }
    }
    struct Projection {
        let sections: [TitleSection<LibrarySongItem>]
        let ordered: [LibrarySongItem]
    }

    fileprivate struct SongSortEntry: Sendable {
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

    fileprivate struct GroupedIndices: Sendable {
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
            }.reversed().map { GroupedIndices(letter: $0.letter, indices: $0.items.map(\.index)) }
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
        let groups = result.sections.first?.letter.isEmpty == false
            ? result.sections.map { NativeTrackSection(title: $0.letter, songIDs: $0.items.map(\.id)) } : nil

        NativePlaylistTrackList(songs: ordered, title: "歌曲",
            header: ordered.isEmpty ? nil : AnyView(
                PlayShuffleButtons(play: { playAll(ordered, false) }, shuffle: { playAll(ordered, true) })
                    .padding(.horizontal, DesignTokens.Spacing.pageMargin)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            ),
            banner: nil, footer: nil, showsAddMusicRow: false,
            pageColor: UIColor(Color(.systemBackground)), scheme: colorScheme,
            indexedSections: groups, usesLibrarySongAppearance: true,
            rowCornerRadius: DesignTokens.Radius.songRowCover, lastSongSeparatorLeading: 80,
            onPlaySong: { _, index in actions.play(ordered, index, "歌曲") }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .overlay {
            if ordered.isEmpty, input.songs.count <= 120 || projection.resolvedValue(for: input) != nil {
                LibraryListEmptyState(noun: "歌曲", symbol: "music.note", query: $query, filter: $filter)
            }
        }
        .libraryNavigationTitle("歌曲")
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: "搜索歌曲", usesStackedPlacement: true)
        .libraryRootAccountButton()
        .task(id: input) {
            let entries = input.entries
            let currentQuery = input.query
            let currentFilter = input.filter
            let currentSort = input.sort
            await projection.computeIfNeeded(
                for: input,
                fastPath: Self.fastPath,
                background: {
                    Self.computeGroupedIndices(entries: entries, query: currentQuery, filter: currentFilter, sort: currentSort)
                },
                finish: input.finish
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有歌曲", allImage: "music.note")
                LibrarySortMenu(sort: $sort, options: SongSort.options).menuOrder(.fixed)
            }
        }
    }
}

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
            PlaylistSongArtwork(song: song, cornerRadius: DesignTokens.Radius.songRowCover)
                .frame(width: DesignTokens.Artwork.rowCoverSize)
        }
        .songListRow(song, mode: .libraryDownloads, swipeBackground: Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.pageMargin, bottom: 0, trailing: DesignTokens.Spacing.pageMargin))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + DesignTokens.Spacing.rowDividerInset }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}


enum AlbumSort: Hashable, Sendable {
    case name, addedDate, artist, year

    static let options = [
        LibrarySortOption(sort: AlbumSort.name, title: "名称"),
        LibrarySortOption(sort: AlbumSort.addedDate, title: "添加日期"),
        LibrarySortOption(sort: AlbumSort.artist, title: "艺人", subtitle: "A-Z"),
        LibrarySortOption(sort: AlbumSort.year, title: "年份"),
    ]
}

struct AlbumsGridView: View {
    let albums: [LibraryShelfItem]
    let playAll: ([String], Bool) -> Void
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var sort = AlbumSort.artist
    @State private var layout = LibraryLayout.grid
    @State private var projection = AsyncListProjection<ProjectionInput, [LibraryShelfItem]>()
    @Environment(\.collectionMenuActions) private var collectionActions
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    private struct ProjectionInput: Equatable {
        let albums: [LibraryShelfItem]
        let query: String
        let filter: LibraryFilter
        let sort: AlbumSort

        var entries: [AlbumSortEntry] {
            albums.enumerated().map { index, album in
                AlbumSortEntry(index: index, title: album.title, subtitle: album.subtitle ?? "",
                               addedOrder: album.addedOrder, year: album.year ?? 0, isFavorite: album.isFavorite)
            }
        }

        func finish(_ indices: [Int]) -> [LibraryShelfItem] { indices.map { albums[$0] } }

        func calculate() -> [LibraryShelfItem] {
            finish(AlbumsGridView.computeAlbumIndices(entries: entries, query: query, filter: filter, sort: sort))
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
        content(shown)
        .overlay {
            if shown.isEmpty, projection.isResolved(for: input, fastPath: Self.fastPath) {
                LibraryListEmptyState(noun: "专辑", symbol: "square.stack", query: $query, filter: $filter)
            }
        }
        .libraryNavigationTitle("专辑")
        .libraryTitleDisplayMode(.large)
        .libraryRootAccountButton()
        .librarySearchable(text: $query, prompt: "搜索专辑")
        .task(id: input) {
            let entries = input.entries
            let currentQuery = input.query
            let currentFilter = input.filter
            let currentSort = input.sort
            await projection.computeIfNeeded(
                for: input,
                fastPath: Self.fastPath,
                background: {
                    Self.computeAlbumIndices(entries: entries, query: currentQuery, filter: currentFilter, sort: currentSort)
                },
                finish: input.finish
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有专辑", allImage: "square.stack")
                LibrarySortMenu(layout: $layout, sort: $sort, options: AlbumSort.options)
            }
        }
    }

    private func playButtons(_ shown: [LibraryShelfItem]) -> some View {
        PlayShuffleButtons(play: { playAll(shown.map(\.id), false) }, shuffle: { playAll(shown.map(\.id), true) })
    }

    @ViewBuilder private func content(_ shown: [LibraryShelfItem]) -> some View {
        switch layout {
        case .grid:
            ScrollView {
                VStack(spacing: 24) {
                    if !shown.isEmpty { playButtons(shown) }
                    LibraryCollectionGrid(rowSpacing: 21, columnAlignment: nil) {
                        ForEach(shown) { item in CollectionCardLink(item: item) { AlbumCard(item: item) } }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        case .list:
            GenericCollectionList(items: shown,
                menu: { item in collectionActions.sections(for: item, route: item.route ?? .album(item.id)).nativeMenu(firstSectionIsRow: true) },
                open: { item, source in openLibraryRoute(item, sourceProvider: source) },
                moveItem: nil, shelfItem: { $0 }, route: { $0.route ?? .album($0.id) },
                header: shown.isEmpty ? nil : AnyView(playButtons(shown)
                    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)),
                wrapsAccessibilityText: true, bottomPadding: 24)
                .ignoresSafeArea(.container, edges: .vertical)
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


struct ArtistsListView: View {
    let artists: [LibraryArtistEntry]
    @State var filter = LibraryFilter.all
    @State private var query = ""

    var body: some View {
        let results = LibraryArtistEntry.visible(artists, filter: filter, query: query)
        List(results) { artist in
            LibraryRouteLink(value: .libraryArtist(artist.id)) {
                HStack(spacing: 12) {
                    ArtistAvatar(source: artist.libraryAvatar, identity: artist.id)
                        .frame(width: DesignTokens.Artwork.rowCoverSize)
                        .modifier(ArtistFavoriteGutter(isFavorite: artist.isFavorite))
                    Text(artist.name).lineLimit(1)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + DesignTokens.Spacing.rowDividerInset }
            }
            .listRowInsets(.init(top: 4, leading: DesignTokens.Spacing.pageMargin, bottom: 4,
                                 trailing: DesignTokens.Spacing.pageMargin))
            .listRowSeparator(artist.id == results.first?.id ? .hidden : .automatic, edges: .top)
            .listRowSeparator(artist.id == results.last?.id ? .hidden : .automatic, edges: .bottom)
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    ContentUnavailableView.search(text: term)
                } else {
                    switch filter {
                    case .all: ContentUnavailableView("暂无艺人", systemImage: "music.microphone")
                    case .favorites: ContentUnavailableView("暂无喜爱的艺人", systemImage: "star")
                    case .downloaded: ContentUnavailableView("暂无已下载的艺人", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .libraryNavigationTitle("艺人")
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: "搜索艺人")
        .libraryRootAccountButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: "所有艺人", allImage: "music.microphone", supportsDownloads: true)
                    .menuOrder(.fixed)
            }
        }
    }
}

enum ArtistAvatarArtwork: Equatable {
    case portrait(Artwork)
    case album(Artwork, AlbumArtworkBackdrop?)
    case missing
}

struct ArtistAvatar: View {
    let source: ArtistAvatarArtwork
    let identity: LibraryArtistIdentity?
    @Environment(\.artworkLoadAction) private var artworkLoader

    private struct Demand: Equatable {
        let identity: LibraryArtistIdentity
        let snapshot: LibraryArtistPortraitAccess.Snapshot
    }

    init(source: ArtistAvatarArtwork, identity: LibraryArtistIdentity? = nil) {
        self.source = source
        self.identity = identity
    }
    init(artwork: Artwork?) {
        source = artwork.flatMap { $0 == .missing ? nil : .portrait($0) } ?? .missing
        identity = nil
    }

    var body: some View {
        let access = artworkLoader.artistPortraits
        let demand = identity.flatMap { id in access?.snapshot(id).map { Demand(identity: id, snapshot: $0) } }
        let current = demand?.snapshot.file.map { ArtistAvatarArtwork.portrait(.file($0)) } ?? source
        Group {
            switch current {
            case .portrait(let artwork):
                ArtworkView(artwork: artwork, cornerRadius: 0, showsBorder: false)
            case .album(let artwork, let backdrop):
                ArtistAlbumAvatar(artwork: artwork, backdrop: backdrop)
            case .missing:
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
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: demand) {
            guard let demand, demand.snapshot.file == nil else { return }
            await access?.resolve(demand.identity, demand.snapshot.session)
        }
    }
}

private struct ArtistAlbumAvatar: View {
    let artwork: Artwork
    let backdrop: AlbumArtworkBackdrop?
    @Environment(\.artworkLoadAction) private var loader
    @State private var prepared: (Artwork, AlbumArtworkBackdrop)?

    var body: some View {
        let color = backdrop ?? (prepared?.0 == artwork ? prepared?.1 : nil)
            ?? LocalArtworkImages.cachedBackdrop(for: artwork)
        GeometryReader { proxy in
            let side = proxy.size.width * 0.62
            Circle()
                .fill(color?.color ?? Color(.secondarySystemFill))
                .overlay {
                    ArtworkView(artwork: artwork, cornerRadius: side * 0.06, showsBorder: false)
                        .frame(width: side)
                }
        }
        .task(id: artwork) {
            guard color == nil else { return }
            let file: URL?
            switch artwork {
            case .file(let url): file = url
            case .deferred(let id, _):
                if let cached = LocalArtworkImages.resolvedURL(for: id) { file = cached }
                else { file = await loader.resolve?(id) }
            default: file = nil
            }
            guard let file, let sampled = await LocalArtworkImages.loadBackdrop(for: file),
                  !Task.isCancelled else { return }
            prepared = (artwork, sampled)
        }
    }
}

struct ArtistFavoriteGutter: ViewModifier {
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
