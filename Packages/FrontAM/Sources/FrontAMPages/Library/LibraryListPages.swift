import FrontAMCore
import FrontAMNavigation
import SwiftUI

public struct LibrarySongDisplaySource: Equatable, Sendable {
    public let catalogAlbumIDPrefix: String?
    public let isOnline: Bool
    public let isCatalogGuest: Bool

    public init(catalogAlbumIDPrefix: String? = nil, isOnline: Bool = false, isCatalogGuest: Bool = false) {
        self.catalogAlbumIDPrefix = catalogAlbumIDPrefix
        self.isOnline = isOnline
        self.isCatalogGuest = isCatalogGuest
    }
}

public struct LibrarySongItem: Identifiable, Equatable {
    public let displaySource: LibrarySongDisplaySource
    public let id: String
    public var albumID: String {
        if let onlineAlbumID, let prefix = displaySource.catalogAlbumIDPrefix { return prefix + String(onlineAlbumID) }
        return albumDirectory.map { "folder:" + $0 } ?? (albumArtist + "\u{001F}" + album)
    }
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String
    public let trackNumber: Int
    private var artworkState: SongArtworkState
    public var artworkIdentity: ObjectIdentifier { ObjectIdentifier(artworkState) }
    public var artwork: Artwork {
        get { artworkState.value.artwork }
        set { var value = artworkState.snapshot; value.artwork = newValue; artworkState = SongArtworkState(value) }
    }
    public var albumDirectory: String? = nil
    public var discNumber: Int = 1
    public var artworkData: Data? {
        get { artworkState.value.artworkData }
        set { var value = artworkState.snapshot; value.artworkData = newValue; artworkState = SongArtworkState(value) }
    }
    public var artworkURL: URL? {
        get { artworkState.value.artworkURL }
        set { var value = artworkState.snapshot; value.artworkURL = newValue; artworkState = SongArtworkState(value) }
    }
    public var artworkBackdrop: AlbumArtworkBackdrop? {
        get { artworkState.value.artworkBackdrop }
        set { var value = artworkState.snapshot; value.artworkBackdrop = newValue; artworkState = SongArtworkState(value) }
    }
    public var duration: Int = 0
    public var isPinned = false
    public var addedOrder = 0
    public var isFavorite = false
    public var favoriteAddedAt: Date? = nil
    public var unavailabilityReason: String? = nil
    public var onlineAlbumID: Int64? = nil
    public var artistReferences: [LibraryArtistReference] = []
    public var year: Int?

    public init(id: String, title: String, artist: String, album: String, albumArtist: String,
         trackNumber: Int, artwork: Artwork, albumDirectory: String? = nil, discNumber: Int = 1,
         artworkData: Data? = nil, artworkURL: URL? = nil, artworkBackdrop: AlbumArtworkBackdrop? = nil,
         duration: Int = 0, isPinned: Bool = false, addedOrder: Int = 0, isFavorite: Bool = false,
         favoriteAddedAt: Date? = nil, unavailabilityReason: String? = nil,
         onlineAlbumID: Int64? = nil, artistReferences: [LibraryArtistReference] = [], year: Int? = nil,
         displaySource: LibrarySongDisplaySource) {
        self.displaySource = displaySource
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
    public func publishArtwork(from replacement: Self) -> Bool {
        guard id == replacement.id else { return false }
        return artworkState.update(replacement.artworkState.snapshot)
    }

    public var isOnline: Bool { displaySource.isOnline }
    public var hasCatalogActions: Bool {
        isOnline || displaySource.isCatalogGuest || onlineAlbumID != nil || !artistReferences.isEmpty
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
    public func replacingArtwork(from value: Self) -> Self {
        var result = self
        result.artwork = value.artwork
        result.artworkData = value.artworkData
        result.artworkURL = value.artworkURL
        result.artworkBackdrop = value.artworkBackdrop
        return result
    }

    public static func albumOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        let left = lhs.trackNumber > 0 ? lhs.trackNumber : Int.max
        let right = rhs.trackNumber > 0 ? rhs.trackNumber : Int.max
        if left != right { return left < right }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

public struct LibraryArtistReference: Equatable {
    public let id: String
    public let name: String
    public var artwork: Artwork?

    public init(id: String,
                name: String,
                artwork: Artwork? = nil) {
        self.id = id
        self.name = name
        self.artwork = artwork
    }
}

public struct LibraryArtistItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    @ArtworkResource public var artwork: Artwork?
    public var isFavorite = false

    public init(id: String,
                name: String,
                artwork: Artwork? = nil,
                isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.isFavorite = isFavorite
    }
}


public enum SongSort: Hashable, Sendable {
    case name, addedDate, artist

    public static let options = [
        LibrarySortOption(sort: SongSort.name, title: pageText("名称")),
        LibrarySortOption(sort: SongSort.addedDate, title: pageText("添加日期"), subtitle: pageText("最新的排最前")),
        LibrarySortOption(sort: SongSort.artist, title: pageText("艺人")),
    ]
}

public struct SongsListView: View {
    public let songs: [LibrarySongItem]
    public let playAll: ([LibrarySongItem], Bool) -> Void
    @State private var sort = SongSort.addedDate
    @State private var filter = LibraryFilter.all
    @State private var query = ""
    @State private var projection = AsyncListProjection<ProjectionInput, Projection>()
    @Environment(\.songMenuActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    public struct ProjectionInput: Equatable {
        public let songs: [LibrarySongItem]
        public let query: String
        public let filter: LibraryFilter
        public let sort: SongSort

        public func calculate() -> Projection {
            finish(SongsListView.computeGroupedIndices(entries: entries, query: query, filter: filter, sort: sort))
        }

        @MainActor public func project(using projection: AsyncListProjection<Self, Projection>) async {
            let entries = entries
            let query = query, filter = filter, sort = sort
            await projection.computeIfNeeded(
                for: self,
                fastPath: SongsListView.fastPath,
                background: {
                    SongsListView.computeGroupedIndices(entries: entries, query: query, filter: filter, sort: sort)
                },
                finish: finish
            )
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
    public struct Projection {
        public let sections: [TitleSection<LibrarySongItem>]
        public let ordered: [LibrarySongItem]

        public var indexedSections: [NativeTrackSection]? {
            guard sections.first?.letter.isEmpty == false else { return nil }
            return sections.map { NativeTrackSection(title: $0.letter, songIDs: $0.items.map(\.id)) }
        }
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

    public var body: some View {
        let input = ProjectionInput(songs: songs, query: query, filter: filter, sort: sort)
        let result = projection.currentValue(for: input, fastPath: Self.fastPath,
                                             placeholder: { _ in Projection(sections: [], ordered: []) })
        let ordered = result.ordered
        NativePlaylistTrackList(songs: ordered, title: pageText("歌曲"),
            header: ordered.isEmpty ? nil : AnyView(
                PlayShuffleButtons(play: { playAll(ordered, false) }, shuffle: { playAll(ordered, true) })
                    .padding(.horizontal, DesignTokens.Spacing.pageMargin)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            ),
            banner: nil, footer: nil, showsAddMusicRow: false,
            pageColor: UIColor(Color(.systemBackground)), scheme: colorScheme,
            indexedSections: result.indexedSections, usesLibrarySongAppearance: true,
            rowCornerRadius: DesignTokens.Radius.songRowCover, lastSongSeparatorLeading: 80,
            onPlaySong: { _, index in actions.play(ordered, index, pageText("歌曲")) }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .overlay {
            if ordered.isEmpty, input.songs.count <= 120 || projection.resolvedValue(for: input) != nil {
                LibraryListEmptyState(noun: pageText("歌曲"), symbol: "music.note", query: $query, filter: $filter)
            }
        }
        .libraryNavigationTitle(pageText("歌曲"))
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: pageText("搜索歌曲"), usesStackedPlacement: true)
        .libraryRootAccountButton()
        .task(id: input) { await input.project(using: projection) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: pageText("所有歌曲"), allImage: "music.note")
                LibrarySortMenu(sort: $sort, options: SongSort.options).menuOrder(.fixed)
            }
        }
    }

    public init(songs: [LibrarySongItem],
                playAll: @escaping ([LibrarySongItem], Bool) -> Void) {
        self.songs = songs
        self.playAll = playAll
    }
}

public struct SongRow: View {
    public let song: LibrarySongItem
    public var play: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
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

    public init(song: LibrarySongItem,
                play: @escaping () -> Void = {}) {
        self.song = song
        self.play = play
    }
}


public enum AlbumSort: Hashable, Sendable {
    case name, addedDate, artist, year

    public static let options = [
        LibrarySortOption(sort: AlbumSort.name, title: pageText("名称")),
        LibrarySortOption(sort: AlbumSort.addedDate, title: pageText("添加日期")),
        LibrarySortOption(sort: AlbumSort.artist, title: pageText("艺人"), subtitle: "A-Z"),
        LibrarySortOption(sort: AlbumSort.year, title: pageText("年份")),
    ]
}

public struct AlbumsGridView: View {
    public let albums: [LibraryShelfItem]
    public let playAll: ([String], Bool) -> Void
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

    public var body: some View {
        let input = ProjectionInput(albums: albums, query: query, filter: filter, sort: sort)
        let shown = projection.currentValue(for: input, fastPath: Self.fastPath, placeholder: { _ in [] })
        content(shown)
        .overlay {
            if shown.isEmpty, projection.isResolved(for: input, fastPath: Self.fastPath) {
                LibraryListEmptyState(noun: pageText("专辑"), symbol: "square.stack", query: $query, filter: $filter)
            }
        }
        .libraryNavigationTitle(pageText("专辑"))
        .libraryTitleDisplayMode(.large)
        .libraryRootAccountButton()
        .librarySearchable(text: $query, prompt: pageText("搜索专辑"))
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
                LibraryFilterMenu(filter: $filter, allTitle: pageText("所有专辑"), allImage: "square.stack")
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

    public init(albums: [LibraryShelfItem],
                playAll: @escaping ([String], Bool) -> Void) {
        self.albums = albums
        self.playAll = playAll
    }
}

public struct LibraryListEmptyState: View {
    public let noun: String
    public let symbol: String
    @Binding public var query: String
    @Binding public var filter: LibraryFilter

    public var body: some View {
        ContentUnavailableView {
            Label(query.isEmpty ? (filter == .favorites ? pageText("暂无喜爱的\(noun)") : pageText("暂无\(noun)")) : pageText("没有找到结果"),
                  systemImage: query.isEmpty ? symbol : "magnifyingglass")
        } description: {
            if !query.isEmpty {
                Text(pageText("没有符合“\(query)”的\(noun)。"))
            } else if filter == .favorites {
                Text(pageText("将\(noun)加入喜爱后，会显示在这里。"))
            } else {
                Text(pageText("添加到资料库的\(noun)会显示在这里。"))
            }
        } actions: {
            if !query.isEmpty {
                Button(pageText("清除搜索")) { query = "" }
                    .accessibilityIdentifier("library.empty.clear-search")
            }
            if filter == .favorites {
                Button(pageText("显示全部")) {
                    query = ""
                    filter = .all
                }
                .accessibilityIdentifier("library.empty.show-all")
            }
        }
    }
}


public struct ArtistsListView: View {
    public let artists: [LibraryArtistEntry]
    @State private var filter: LibraryFilter
    @State private var query = ""

    public var body: some View {
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
                    case .all: ContentUnavailableView(pageText("暂无艺人"), systemImage: "music.microphone")
                    case .favorites: ContentUnavailableView(pageText("暂无喜爱的艺人"), systemImage: "star")
                    case .downloaded: ContentUnavailableView(pageText("暂无已下载的艺人"), systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .libraryNavigationTitle(pageText("艺人"))
        .libraryTitleDisplayMode(.large)
        .librarySearchable(text: $query, prompt: pageText("搜索艺人"))
        .libraryRootAccountButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFilterMenu(filter: $filter, allTitle: pageText("所有艺人"), allImage: "music.microphone", supportsDownloads: true)
                    .menuOrder(.fixed)
            }
        }
    }

    public init(artists: [LibraryArtistEntry], filter: LibraryFilter = .all) {
        self.artists = artists
        _filter = State(initialValue: filter)
    }
}

public enum ArtistAvatarArtwork: Equatable {
    case portrait(Artwork)
    case album(Artwork, AlbumArtworkBackdrop?)
    case missing
}

public struct ArtistAvatar: View {
    public let source: ArtistAvatarArtwork
    public let identity: LibraryArtistIdentity?
    @Environment(\.artworkLoadAction) private var artworkLoader

    private struct Demand: Equatable {
        let identity: LibraryArtistIdentity
        let snapshot: LibraryArtistPortraitAccess.Snapshot
    }

    public init(source: ArtistAvatarArtwork, identity: LibraryArtistIdentity? = nil) {
        self.source = source
        self.identity = identity
    }
    public init(artwork: Artwork?) {
        source = artwork.flatMap { $0 == .missing ? nil : .portrait($0) } ?? .missing
        identity = nil
    }

    public var body: some View {
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
            ?? loader.provider.cachedBackdrop(for: artwork)
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
                if let cached = loader.provider.resolvedURL(for: id) { file = cached }
                else { file = await loader.resolve?(id) }
            default: file = nil
            }
            guard let file, let sampled = await loader.provider.loadBackdrop(for: file),
                  !Task.isCancelled else { return }
            prepared = (artwork, sampled)
        }
    }
}

public struct ArtistFavoriteGutter: ViewModifier {
    public let isFavorite: Bool

    public func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: -14)
                    .accessibilityLabel(pageText("已喜爱"))
                    .allowsHitTesting(false)
            }
        }
    }
}
