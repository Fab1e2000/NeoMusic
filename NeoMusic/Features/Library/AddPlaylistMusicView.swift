import SwiftUI
import UIKit

/// 资料库快照与按需加载入口，供「添加到播放列表」选单读取真实资料库数据。
@MainActor
struct MusicPickerSource {
    var songs: @MainActor () -> [LibrarySongItem] = { [] }
    var artists: @MainActor () -> [LibraryArtistItem] = { [] }
    var albums: @MainActor () -> [LibraryShelfItem] = { [] }
    var downloadedAlbums: @MainActor () -> [LibraryShelfItem] = { [] }
    var recentlyAdded: @MainActor () -> [LibraryShelfItem] = { [] }
    var recentlyPlayed: @MainActor () -> [LibrarySongItem] = { [] }
    var playlistLibrary: PlaylistLibrary? = nil
    var albumSongs: @MainActor (String) -> [LibrarySongItem] = { _ in [] }
    var loadAlbumSongs: (@MainActor (String) async throws -> [LibrarySongItem])? = nil
    var loadArtistDetail: (@MainActor (String) async throws -> ArtistDetail?)? = nil
    var songByID: @MainActor (String) -> LibrarySongItem? = { _ in nil }

    static func fallback(songs: [LibrarySongItem], playlists: [LibraryPlaylistItem],
                         playlistLibrary: PlaylistLibrary?, playlistSongs: [String: [LibrarySongItem]],
                         recentlyPlayed: [LibrarySongItem]) -> Self {
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupedArtists: [LibraryArtistItem] = {
            var seen = Set<String>()
            var result: [LibraryArtistItem] = []
            for song in songs {
                if !song.artistReferences.isEmpty {
                    for ref in song.artistReferences where seen.insert(ref.id).inserted {
                        result.append(LibraryArtistItem(id: ref.id, name: ref.name, artwork: nil))
                    }
                } else if !song.artist.isEmpty, seen.insert(song.artist).inserted {
                    result.append(LibraryArtistItem(id: song.artist, name: song.artist, artwork: nil))
                }
            }
            return result.sorted(byName: \.name)
        }()
        let groupedAlbums: [LibraryShelfItem] = {
            let byAlbum = Dictionary(grouping: songs, by: \.albumID)
            return byAlbum.compactMap { id, tracks in
                guard let first = tracks.first, !first.album.isEmpty else { return nil }
                return LibraryShelfItem(
                    id: id,
                    title: first.album,
                    subtitle: first.albumArtist.isEmpty ? first.artist : first.albumArtist,
                    artwork: first.artwork,
                    route: .album(id),
                    addedOrder: tracks.map(\.addedOrder).max() ?? 0
                )
            }
        }()
        let resolvedLibrary = playlistLibrary ?? {
            let temp = PlaylistLibrary(playlists: playlists)
            for (id, tracks) in playlistSongs {
                temp.addSongs(tracks, to: id)
            }
            return temp
        }()
        let recentCollections = (groupedAlbums + playlists.filter { !$0.isSystem }.map(\.shelfItem))
            .sorted { $0.addedOrder > $1.addedOrder }
        return Self(
            songs: { songs },
            artists: { groupedArtists },
            albums: { groupedAlbums },
            downloadedAlbums: { groupedAlbums },
            recentlyAdded: { recentCollections },
            recentlyPlayed: { recentlyPlayed },
            playlistLibrary: resolvedLibrary,
            albumSongs: { albumID in songs.filter { $0.albumID == albumID }.sorted(by: LibrarySongItem.albumOrder) },
            loadAlbumSongs: nil,
            loadArtistDetail: nil,
            songByID: { songsByID[$0] }
        )
    }
}

extension EnvironmentValues {
    @Entry var musicPickerSource: MusicPickerSource? = nil
}

/// 添加音乐选单：直接读取真实资料库结构，选择只保留在本次会话中，完成后才交给播放列表宿主。
struct AddPlaylistMusicView: View {
    let title: String
    let songs: [LibrarySongItem]
    let playlists: [LibraryPlaylistItem]
    let existingIDs: Set<String>
    var playlistLibrary: PlaylistLibrary? = nil
    var playlistSongs: [String: [LibrarySongItem]] = [:]
    var recentlyPlayedSongs: [LibrarySongItem] = []
    let onCommit: ([LibrarySongItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.musicPickerSource) private var environmentSource
    @State private var selectedSongs: [LibrarySongItem] = []
    @State private var selectedIDSet: Set<String> = []
    @State private var query = ""
    @State private var confirmsDiscard = false
    @State private var path: [MusicPickerRoute] = []
    @State private var session = MusicPickerSession()

    private var source: MusicPickerSource {
        environmentSource ?? MusicPickerSource.fallback(
            songs: songs,
            playlists: playlists,
            playlistLibrary: playlistLibrary,
            playlistSongs: playlistSongs,
            recentlyPlayed: recentlyPlayedSongs
        )
    }

    private var statusHeading: String {
        selectedSongs.isEmpty ? "添加到“\(title)”" : "已将\(selectedSongs.count)首歌曲添加到“\(title)”"
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationTitle(statusHeading)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBehavior(prompt: nil, hidesNavBarOnSearch: false)
                .toolbar { rootControls }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "艺人、歌曲或专辑")
                .navigationDestination(for: MusicPickerRoute.self) { route in
                    destination(route)
                        .navigationTitle(route.navigationTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarBehavior(prompt: statusHeading, hidesNavBarOnSearch: false)
                        .toolbar { confirmControl }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(.blue)
        .interactiveDismissDisabled(!selectedSongs.isEmpty)
        .onSheetDismissAttempt { confirmsDiscard = true }
        .alert("", isPresented: $confirmsDiscard) {
            Button("放弃所选内容", role: .destructive) { dismiss() }
            Button("保留所选内容", role: .cancel) {}
        } message: {
            Text("确定要放弃所选内容吗？")
        }
        .onAppear {
            session.prepareIfNeeded(using: source)
        }
    }

    @ToolbarContentBuilder private var rootControls: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark") {
                if selectedSongs.isEmpty { dismiss() } else { confirmsDiscard = true }
            }
            .tint(.primary)
        }
        confirmControl
    }

    @ToolbarContentBuilder private var confirmControl: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(selectedSongs.isEmpty ? "完成" : "添加\(selectedSongs.count)首", systemImage: "checkmark") {
                onCommit(selectedSongs)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
        }
    }

    // MARK: - Selection Helpers

    private func isSelected(_ id: String) -> Bool {
        selectedIDSet.contains(id) || existingIDs.contains(id)
    }

    private func toggleSong(_ song: LibrarySongItem) {
        guard !existingIDs.contains(song.id) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedIDSet.remove(song.id) != nil {
                selectedSongs.removeAll { $0.id == song.id }
            } else {
                selectedIDSet.insert(song.id)
                selectedSongs.append(song)
            }
        }
    }

    private func toggleCollection(_ tracks: [LibrarySongItem]) {
        let addable = tracks.filter { !existingIDs.contains($0.id) }
        guard !addable.isEmpty else { return }
        let allSelected = addable.allSatisfy { selectedIDSet.contains($0.id) }
        withAnimation(.easeInOut(duration: 0.2)) {
            if allSelected {
                let ids = Set(addable.map(\.id))
                selectedIDSet.subtract(ids)
                selectedSongs.removeAll { ids.contains($0.id) }
            } else {
                for song in addable where selectedIDSet.insert(song.id).inserted {
                    selectedSongs.append(song)
                }
            }
        }
    }

    // MARK: - Root Screen

    private var rootContent: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return List {
            if trimmed.isEmpty {
                Section {
                    Text("资料库")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)

                    ForEach(MusicPickerRoute.categories, id: \.self) { route in
                        NavigationLink(value: route) {
                            HStack(spacing: 17) {
                                Image(systemName: route.categoryImage)
                                    .font(.title2)
                                    .foregroundStyle(.primary)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                Text(route.categoryTitle)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                            .frame(minHeight: 44)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 41 }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(route == MusicPickerRoute.categories.last ? .hidden : .visible, edges: .bottom)
                        .listRowSeparator(route == MusicPickerRoute.categories.first ? .hidden : .visible, edges: .top)
                    }
                }
                .listSectionSeparator(.hidden)

                if !session.recentFavorites.isEmpty {
                    carouselSection("最近喜爱", songs: session.recentFavorites)
                }
                if !session.recentlyPlayed.isEmpty {
                    carouselSection("最近播放", songs: session.recentlyPlayed)
                }
            } else {
                let matches = matching(session.sortedSongs, term: trimmed)
                if matches.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(matches) { song in
                            songListRow(song, showsFavoriteMark: false)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private func carouselSection(_ heading: String, songs: [LibrarySongItem]) -> some View {
        Section {
            Text(heading)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 2, trailing: 20))
                .listRowSeparator(.hidden)

            MusicPickerSongCarousel(
                songs: songs,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
        }
        .listSectionSeparator(.hidden)
    }

    private func songListRow(_ song: LibrarySongItem, showsFavoriteMark: Bool) -> some View {
        MusicPickerSongRow(
            song: song,
            selected: isSelected(song.id),
            alreadyAdded: existingIDs.contains(song.id),
            showsFavoriteMark: showsFavoriteMark
        ) {
            toggleSong(song)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
    }

    // MARK: - Destinations

    @ViewBuilder private func destination(_ route: MusicPickerRoute) -> some View {
        switch route {
        case .artists:
            PickerArtistsListView(artists: session.sortedArtists)

        case .albums:
            PickerAlbumsListView(albums: session.sortedAlbums, emptyNoun: "专辑")

        case .downloaded:
            PickerAlbumsListView(albums: session.sortedDownloadedAlbums, emptyNoun: "已下载专辑")

        case .songs:
            PickerSongsListView(
                songs: session.sortedSongs,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )

        case .playlists:
            PickerPlaylistsListView(
                library: source.playlistLibrary,
                fallbackPlaylists: playlists,
                folderID: nil
            )

        case .playlistFolder(let id, _):
            PickerPlaylistsListView(
                library: source.playlistLibrary,
                fallbackPlaylists: playlists,
                folderID: id
            )

        case .recent:
            PickerRecentlyAddedListView(
                items: session.recentlyAdded,
                source: source,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )

        case .artist(let id, let name):
            let artist = session.artist(id: id) ?? LibraryArtistItem(id: id, name: name, artwork: nil)
            let albums = session.albums(for: artist)
            let fallbackSongs = albums.isEmpty ? session.songs(for: artist) : []
            let canOpenCatalog = CatalogRouteIdentity.isCatalogID(id) && source.loadArtistDetail != nil
            PickerArtistLibraryView(
                artist: artist,
                albums: albums,
                fallbackSongs: fallbackSongs,
                canOpenCatalog: canOpenCatalog,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )

        case .artistCatalog(let id, let name):
            PickerArtistCatalogView(
                artistID: id,
                artistName: name,
                source: source,
                session: session,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )

        case .artistCatalogSection(let id, _, let section):
            PickerArtistCatalogSectionView(
                detail: session.catalogArtist(id: id),
                section: section,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggle: toggleSong
            )

        case .album(let id, let title, let subtitle):
            let item = session.album(id: id) ?? LibraryShelfItem(id: id, title: title, subtitle: subtitle, artwork: .missing, route: .album(id))
            PickerAlbumDetailView(
                album: item,
                source: source,
                session: session,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggleSong: toggleSong,
                onToggleAll: toggleCollection
            )

        case .playlist(let id, let title):
            let playlist = source.playlistLibrary?.playlist(id)
                ?? playlists.first { $0.id == id }
                ?? LibraryPlaylistItem(id: id, title: title, artwork: .playlist)
            let artwork = source.playlistLibrary?.displayArtwork(of: playlist) ?? playlist.artwork
            let tracks = playlistTracks(for: playlist)
            PickerPlaylistDetailView(
                playlist: playlist,
                artwork: artwork,
                tracks: tracks,
                isSelected: isSelected,
                isExisting: { existingIDs.contains($0) },
                onToggleSong: toggleSong,
                onToggleAll: toggleCollection
            )
        }
    }

    private func playlistTracks(for playlist: LibraryPlaylistItem) -> [LibrarySongItem] {
        if playlist.isSystem {
            return session.recentFavorites
        }
        if let lib = source.playlistLibrary {
            return lib.songs(in: playlist.id)
        }
        return playlistSongs[playlist.id] ?? []
    }

    private func matching(_ entries: [LibrarySongItem], term: String) -> [LibrarySongItem] {
        guard !term.isEmpty else { return entries }
        return entries.filter { song in
            [song.title, song.artist, song.album].contains { $0.localizedStandardContains(term) }
        }
    }
}

// MARK: - Session Cache

@MainActor @Observable
private final class MusicPickerSession {
    private(set) var prepared = false
    private(set) var allSongs: [LibrarySongItem] = []
    private(set) var sortedSongs: [LibrarySongItem] = []
    private(set) var recentFavorites: [LibrarySongItem] = []
    private(set) var recentlyPlayed: [LibrarySongItem] = []
    private(set) var sortedArtists: [LibraryArtistItem] = []
    private(set) var sortedAlbums: [LibraryShelfItem] = []
    private(set) var sortedDownloadedAlbums: [LibraryShelfItem] = []
    private(set) var recentlyAdded: [LibraryShelfItem] = []

    private var artistsByID: [String: LibraryArtistItem] = [:]
    private var albumsByID: [String: LibraryShelfItem] = [:]
    private var albumSongsCache: [String: [LibrarySongItem]] = [:]
    private var artistCatalogCache: [String: ArtistDetail] = [:]

    func prepareIfNeeded(using source: MusicPickerSource) {
        guard !prepared else { return }
        prepared = true
        let songs = source.songs()
        allSongs = songs
        sortedSongs = songs.sorted(byName: \.title)
        recentFavorites = songs
            .filter(\.isFavorite)
            .sorted { lhs, rhs in
                if lhs.favoriteAddedAt != rhs.favoriteAddedAt {
                    return (lhs.favoriteAddedAt ?? .distantPast) > (rhs.favoriteAddedAt ?? .distantPast)
                }
                return lhs.addedOrder > rhs.addedOrder
            }
        recentlyPlayed = source.recentlyPlayed()

        let artists = source.artists().sorted(byName: \.name)
        sortedArtists = artists
        artistsByID = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let albums = source.albums().sorted(byName: \.title)
        sortedAlbums = albums
        let downloaded = source.downloadedAlbums().sorted(byName: \.title)
        sortedDownloadedAlbums = downloaded
        let recent = source.recentlyAdded()
        recentlyAdded = recent

        var map: [String: LibraryShelfItem] = [:]
        for item in recent { map[item.id] = item }
        for item in downloaded { map[item.id] = item }
        for item in albums { map[item.id] = item }
        albumsByID = map
    }

    func artist(id: String) -> LibraryArtistItem? { artistsByID[id] }
    func album(id: String) -> LibraryShelfItem? { albumsByID[id] }

    func registerAlbums(_ items: [LibraryShelfItem]) {
        for item in items where albumsByID[item.id] == nil {
            albumsByID[item.id] = item
        }
    }

    func albums(for artist: LibraryArtistItem) -> [LibraryShelfItem] {
        let matchedAlbumIDs = Set(songs(for: artist).map(\.albumID))
        let filtered = sortedAlbums.filter { album in
            matchedAlbumIDs.contains(album.id) || album.subtitle == artist.name
        }
        return filtered.sorted { ($0.year ?? 0, $1.title) > ($1.year ?? 0, $0.title) }
    }

    func songs(for artist: LibraryArtistItem) -> [LibrarySongItem] {
        allSongs.filter { song in
            song.artistReferences.contains { $0.id == artist.id }
                || song.albumArtist == artist.name
                || song.artist == artist.name
        }
    }

    func cachedAlbumSongs(id: String) -> [LibrarySongItem]? { albumSongsCache[id] }
    func storeAlbumSongs(_ tracks: [LibrarySongItem], for id: String) { albumSongsCache[id] = tracks }

    func catalogArtist(id: String) -> ArtistDetail? { artistCatalogCache[id] }
    func storeCatalogArtist(_ detail: ArtistDetail, for id: String) {
        artistCatalogCache[id] = detail
        var extra = detail.albums + detail.singles
        if let latest = detail.latest { extra.append(latest) }
        registerAlbums(extra)
    }
}

// MARK: - Routes

private enum MusicPickerRoute: Hashable {
    case artists, albums, songs, playlists, downloaded, recent
    case artist(id: String, name: String)
    case artistCatalog(id: String, name: String)
    case artistCatalogSection(id: String, name: String, section: ArtistSection)
    case album(id: String, title: String, subtitle: String?)
    case playlist(id: String, title: String)
    case playlistFolder(id: String, title: String)

    static let categories: [Self] = [.artists, .albums, .songs, .playlists, .downloaded, .recent]

    var navigationTitle: String {
        switch self {
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        case .downloaded: "已下载"
        case .recent: "最近添加"
        case .artist(_, let name), .artistCatalog(_, let name): name
        case .artistCatalogSection(_, _, let section): section.title
        case .playlistFolder(_, let title): title
        case .album, .playlist: ""
        }
    }

    var categoryTitle: String {
        switch self {
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        case .downloaded: "已下载"
        case .recent: "最近添加"
        default: navigationTitle
        }
    }

    var categoryImage: String {
        switch self {
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .downloaded: "arrow.down.circle"
        case .recent: "clock"
        default: "music.note"
        }
    }
}

// MARK: - Native UIKit Navigation Bar Bridge

private extension View {
    func navigationBarBehavior(prompt: String?, hidesNavBarOnSearch: Bool) -> some View {
        background(
            NavigationBarBehaviorBridge(prompt: prompt, hidesNavBarOnSearch: hidesNavBarOnSearch)
                .frame(width: 0, height: 0)
        )
    }
}

/// 通过 UIKit 原生 `UINavigationItem.prompt` 与 `UISearchController.hidesNavigationBarDuringPresentation`
/// 保持顶部状态提示与搜索聚焦时导航栏可见，避免拟合实现。
private struct NavigationBarBehaviorBridge: UIViewControllerRepresentable {
    let prompt: String?
    let hidesNavBarOnSearch: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.promptText = prompt
        controller.hidesNavBarOnSearch = hidesNavBarOnSearch
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.promptText = prompt
        controller.hidesNavBarOnSearch = hidesNavBarOnSearch
        controller.apply()
    }

    final class Controller: UIViewController {
        var promptText: String?
        var hidesNavBarOnSearch = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        func apply() {
            var current: UIViewController? = self
            while let vc = current {
                if vc.parent is UINavigationController {
                    if vc.navigationItem.prompt != promptText {
                        vc.navigationItem.prompt = promptText
                    }
                    if let searchController = vc.navigationItem.searchController,
                       searchController.hidesNavigationBarDuringPresentation != hidesNavBarOnSearch {
                        searchController.hidesNavigationBarDuringPresentation = hidesNavBarOnSearch
                    }
                    return
                }
                current = vc.parent
            }
        }
    }
}

// MARK: - Sub-pages

private struct PickerArtistsListView: View {
    let artists: [LibraryArtistItem]
    @State private var query = ""

    private var filtered: [LibraryArtistItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return artists }
        return artists.filter { $0.name.localizedStandardContains(term) }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered) { artist in
                    NavigationLink(value: MusicPickerRoute.artist(id: artist.id, name: artist.name)) {
                        HStack(spacing: 14) {
                            ArtistAvatar(artwork: artist.artwork)
                                .frame(width: 48, height: 48)
                            HStack(spacing: 6) {
                                Text(artist.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if artist.isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                        .frame(minHeight: 56)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 62 }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无艺人" : "没有找到结果", systemImage: query.isEmpty ? "music.microphone" : "magnifyingglass")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "查找")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct PickerAlbumsListView: View {
    let albums: [LibraryShelfItem]
    let emptyNoun: String
    @State private var query = ""

    private var filtered: [LibraryShelfItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedStandardContains(term) || ($0.subtitle?.localizedStandardContains(term) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered) { album in
                    NavigationLink(value: MusicPickerRoute.album(id: album.id, title: album.title, subtitle: album.subtitle)) {
                        PickerCollectionRowLabel(
                            artwork: album.artwork,
                            title: album.title,
                            subtitle: album.subtitle,
                            isFavorite: album.isFavorite
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无\(emptyNoun)" : "没有找到结果", systemImage: query.isEmpty ? "square.stack" : "magnifyingglass")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "查找")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct PickerSongsListView: View {
    let songs: [LibrarySongItem]
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void
    @State private var query = ""

    private var filtered: [LibrarySongItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return songs }
        return songs.filter { song in
            [song.title, song.artist, song.album].contains { $0.localizedStandardContains(term) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered) { song in
                    MusicPickerSongRow(
                        song: song,
                        selected: isSelected(song.id),
                        alreadyAdded: isExisting(song.id)
                    ) {
                        onToggle(song)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无歌曲" : "没有找到结果", systemImage: query.isEmpty ? "music.note" : "magnifyingglass")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "查找")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct PickerPlaylistsListView: View {
    let library: PlaylistLibrary?
    let fallbackPlaylists: [LibraryPlaylistItem]
    let folderID: String?
    @State private var query = ""

    private var entries: [PlaylistEntry] {
        let raw: [PlaylistEntry]
        if let library {
            let placement = library.placement
            let playlists = library.playlists.filter { placement[$0.id] == folderID }
            let folders = library.folders.filter { $0.parentID == folderID }.map { folder in
                PlaylistEntry.folder(folder, playlists: library.playlists.filter { placement[$0.id] == folder.id })
            }
            raw = (folders + playlists.map(PlaylistEntry.playlist)).sorted(by: .type)
        } else {
            raw = fallbackPlaylists.map(PlaylistEntry.playlist).sorted(by: .type)
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return raw }
        return raw.filter { $0.title.localizedStandardContains(term) }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    switch entry {
                    case .folder(let folder, _):
                        NavigationLink(value: MusicPickerRoute.playlistFolder(id: folder.id, title: folder.name)) {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(.secondarySystemFill))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        Image(systemName: "folder")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                Text(folder.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(minHeight: 56)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 62 }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))

                    case .playlist(let playlist):
                        let artwork = library?.displayArtwork(of: playlist) ?? playlist.artwork
                        NavigationLink(value: MusicPickerRoute.playlist(id: playlist.id, title: playlist.title)) {
                            PickerCollectionRowLabel(
                                artwork: artwork,
                                title: playlist.title,
                                subtitle: nil,
                                isFavorite: playlist.isFavorite
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无播放列表" : "没有找到结果", systemImage: query.isEmpty ? "music.note.list" : "magnifyingglass")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "查找")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct PickerRecentlyAddedListView: View {
    let items: [LibraryShelfItem]
    let source: MusicPickerSource
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void
    @State private var query = ""

    private var filtered: [LibraryShelfItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(term) || ($0.subtitle?.localizedStandardContains(term) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered) { item in
                    if let songID = item.songID, let song = source.songByID(songID) {
                        MusicPickerSongRow(
                            song: song,
                            selected: isSelected(song.id),
                            alreadyAdded: isExisting(song.id)
                        ) {
                            onToggle(song)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
                    } else if case .playlist(let id) = item.route {
                        NavigationLink(value: MusicPickerRoute.playlist(id: id, title: item.title)) {
                            PickerCollectionRowLabel(
                                artwork: item.artwork,
                                title: item.title,
                                subtitle: nil,
                                isFavorite: item.isFavorite
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    } else {
                        NavigationLink(value: MusicPickerRoute.album(id: item.id, title: item.title, subtitle: item.subtitle)) {
                            PickerCollectionRowLabel(
                                artwork: item.artwork,
                                title: item.title,
                                subtitle: item.subtitle,
                                isFavorite: item.isFavorite
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "暂无最近添加" : "没有找到结果", systemImage: query.isEmpty ? "clock" : "magnifyingglass")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "查找")
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Artist Library & Catalog Views

private struct PickerArtistLibraryView: View {
    let artist: LibraryArtistItem
    let albums: [LibraryShelfItem]
    let fallbackSongs: [LibrarySongItem]
    let canOpenCatalog: Bool
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: textSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    ArtistAvatar(artwork: artist.artwork)
                        .frame(width: 88, height: 88)
                    if canOpenCatalog {
                        NavigationLink(value: MusicPickerRoute.artistCatalog(id: artist.id, name: artist.name)) {
                            HStack(spacing: 4) {
                                Text(artist.name)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(artist.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("专辑")
                            .font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(albums) { album in
                                NavigationLink(value: MusicPickerRoute.album(id: album.id, title: album.title, subtitle: album.subtitle ?? artist.name)) {
                                    PickerAlbumGridCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if !fallbackSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("歌曲")
                            .font(.title3.weight(.bold))
                        LazyVStack(spacing: 0) {
                            ForEach(fallbackSongs) { song in
                                MusicPickerSongRow(
                                    song: song,
                                    selected: isSelected(song.id),
                                    alreadyAdded: isExisting(song.id)
                                ) {
                                    onToggle(song)
                                }
                                if song.id != fallbackSongs.last?.id {
                                    Divider().padding(.leading, 64)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("暂无资料库内容", systemImage: "music.note")
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}

private struct PickerArtistCatalogView: View {
    let artistID: String
    let artistName: String
    let source: MusicPickerSource
    let session: MusicPickerSession
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void

    @State private var detail: ArtistDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                catalogContent(detail)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("暂时无法读取", systemImage: "exclamationmark.circle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("正在载入艺人")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: artistID) {
            if let cached = session.catalogArtist(id: artistID) {
                detail = cached
                return
            }
            await load()
        }
    }

    private func load() async {
        guard let loader = source.loadArtistDetail else {
            errorMessage = "当前无法加载在线艺人目录"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            if let loaded = try await loader(artistID) {
                session.storeCatalogArtist(loaded, for: artistID)
                detail = loaded
            } else {
                errorMessage = "未找到艺人信息"
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func catalogContent(_ detail: ArtistDetail) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let latest = detail.latest {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最新发行")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 20)
                        NavigationLink(value: MusicPickerRoute.album(id: latest.id, title: latest.title, subtitle: latest.subtitle ?? detail.name)) {
                            HStack(spacing: 14) {
                                ArtworkView(artwork: latest.artwork, cornerRadius: 8)
                                    .frame(width: 96, height: 96)
                                VStack(alignment: .leading, spacing: 3) {
                                    if let caption = detail.latestCaption {
                                        Text(caption)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(latest.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    if let subtitle = latest.subtitle {
                                        Text(subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !detail.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("歌曲排行", route: .artistCatalogSection(id: artistID, name: artistName, section: .songs))
                        MusicPickerSongCarousel(
                            songs: detail.songs,
                            isSelected: isSelected,
                            isExisting: isExisting,
                            onToggle: onToggle
                        )
                    }
                }

                if !detail.albums.isEmpty {
                    releaseShelf("专辑", items: detail.albums, section: .albums, fallbackArtist: detail.name)
                }

                if !detail.singles.isEmpty {
                    releaseShelf("单曲与 EP", items: detail.singles, section: .singles, fallbackArtist: detail.name)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func sectionHeader(_ heading: String, route: MusicPickerRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 4) {
                Text(heading)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    private func releaseShelf(_ heading: String, items: [LibraryShelfItem], section: ArtistSection, fallbackArtist: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(heading, route: .artistCatalogSection(id: artistID, name: artistName, section: section))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: MusicPickerRoute.album(id: item.id, title: item.title, subtitle: item.subtitle ?? fallbackArtist)) {
                            PickerAlbumGridCard(album: item)
                                .frame(width: 164)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

private struct PickerArtistCatalogSectionView: View {
    let detail: ArtistDetail?
    let section: ArtistSection
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void

    var body: some View {
        if let detail {
            switch section {
            case .songs:
                PickerSongsListView(
                    songs: detail.songs,
                    isSelected: isSelected,
                    isExisting: isExisting,
                    onToggle: onToggle
                )
            case .albums:
                PickerAlbumsListView(albums: detail.albums, emptyNoun: "专辑")
            case .singles:
                PickerAlbumsListView(albums: detail.singles, emptyNoun: "单曲与 EP")
            case .similar:
                PickerArtistsListView(artists: detail.similar)
            }
        } else {
            ContentUnavailableView("暂无内容", systemImage: "music.note")
        }
    }
}

// MARK: - Album & Playlist Detail Views

private struct PickerAlbumDetailView: View {
    let album: LibraryShelfItem
    let source: MusicPickerSource
    let session: MusicPickerSession
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggleSong: (LibrarySongItem) -> Void
    let onToggleAll: ([LibrarySongItem]) -> Void

    @State private var tracks: [LibrarySongItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var allSelected: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isSelected($0.id) }
    }

    private var allAlreadyAdded: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isExisting($0.id) }
    }

    var body: some View {
        List {
            Section {
                PickerCollectionDetailHeader(
                    artwork: album.artwork,
                    title: album.title,
                    artist: album.subtitle,
                    isFavorite: album.isFavorite,
                    songCount: tracks.count,
                    isAllSelected: allSelected,
                    isAllDisabled: tracks.isEmpty || allAlreadyAdded
                ) {
                    onToggleAll(tracks)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 16))
                .listRowSeparator(.hidden, edges: .top)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

                if isLoading && tracks.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                } else if let errorMessage, tracks.isEmpty {
                    ContentUnavailableView {
                        Label("暂时无法读取", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, song in
                        let number = song.trackNumber > 0 ? song.trackNumber : index + 1
                        PickerAlbumTrackRow(
                            song: song,
                            trackNumber: number,
                            selected: isSelected(song.id),
                            alreadyAdded: isExisting(song.id)
                        ) {
                            onToggleSong(song)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                        .listRowSeparator(index == tracks.count - 1 ? .hidden : .visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 32 }
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .task(id: album.id) {
            await load()
        }
    }

    private func load() async {
        if let cached = session.cachedAlbumSongs(id: album.id), !cached.isEmpty {
            tracks = cached
            return
        }
        let immediate = source.albumSongs(album.id)
        if !immediate.isEmpty {
            tracks = immediate
            session.storeAlbumSongs(immediate, for: album.id)
            return
        }
        guard let loader = source.loadAlbumSongs else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await loader(album.id)
            tracks = loaded
            session.storeAlbumSongs(loaded, for: album.id)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct PickerPlaylistDetailView: View {
    let playlist: LibraryPlaylistItem
    let artwork: Artwork
    let tracks: [LibrarySongItem]
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggleSong: (LibrarySongItem) -> Void
    let onToggleAll: ([LibrarySongItem]) -> Void

    private var allSelected: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isSelected($0.id) }
    }

    private var allAlreadyAdded: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isExisting($0.id) }
    }

    var body: some View {
        List {
            Section {
                PickerCollectionDetailHeader(
                    artwork: artwork,
                    title: playlist.title,
                    artist: nil,
                    isFavorite: playlist.isFavorite,
                    songCount: tracks.count,
                    isAllSelected: allSelected,
                    isAllDisabled: tracks.isEmpty || allAlreadyAdded
                ) {
                    onToggleAll(tracks)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 16))
                .listRowSeparator(.hidden, edges: .top)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

                if tracks.isEmpty {
                    ContentUnavailableView("没有歌曲", systemImage: "music.note")
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, song in
                        MusicPickerSongRow(
                            song: song,
                            selected: isSelected(song.id),
                            alreadyAdded: isExisting(song.id),
                            showsFavoriteMark: true
                        ) {
                            onToggleSong(song)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                        .listRowSeparator(index == tracks.count - 1 ? .hidden : .visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 64 }
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
    }
}

// MARK: - Shared Picker Components

private struct PickerCollectionDetailHeader: View {
    let artwork: Artwork
    let title: String
    let artist: String?
    let isFavorite: Bool
    let songCount: Int
    let isAllSelected: Bool
    let isAllDisabled: Bool
    let onToggleAll: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: artwork, cornerRadius: 8)
                .frame(width: 100, height: 100)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if isFavorite && artist == nil {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                Text("\(songCount)首歌曲")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onToggleAll) {
                Image(systemName: isAllSelected ? "checkmark" : "plus.circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isAllSelected ? Color.blue : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(isAllDisabled)
            .accessibilityLabel(isAllSelected ? "已添加全部歌曲" : "添加全部歌曲")
        }
    }
}

private struct PickerAlbumTrackRow: View {
    let song: LibrarySongItem
    let trackNumber: Int
    let selected: Bool
    let alreadyAdded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Text("\(trackNumber)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 20, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if song.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                                .offset(x: -14)
                        }
                    }
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark" : "plus.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.blue : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40)
            }
            .frame(minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .accessibilityLabel("\(song.title)")
        .accessibilityValue(alreadyAdded ? "已在播放列表中" : selected ? "已选择" : "未选择")
    }
}

private struct PickerCollectionRowLabel: View {
    let artwork: Artwork
    let title: String
    let subtitle: String?
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: artwork, cornerRadius: 6)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: 56)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 62 }
    }
}

private struct PickerAlbumGridCard: View {
    let album: LibraryShelfItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: album.artwork, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let year = album.year, year > 0 {
                Text("\(year)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let subtitle = album.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct MusicPickerSongCarousel: View {
    let songs: [LibrarySongItem]
    let isSelected: (String) -> Bool
    let isExisting: (String) -> Bool
    let onToggle: (LibrarySongItem) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(MusicPickerPage.pages(songs)) { page in
                    VStack(spacing: 0) {
                        ForEach(page.songs) { song in
                            MusicPickerSongRow(
                                song: song,
                                selected: isSelected(song.id),
                                alreadyAdded: isExisting(song.id)
                            ) {
                                onToggle(song)
                            }
                            if song.id != page.songs.last?.id {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in max(240, width - 16) }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

private struct MusicPickerPage: Identifiable {
    let songs: [LibrarySongItem]
    var id: String { songs[0].id }
    static func pages(_ songs: [LibrarySongItem]) -> [Self] {
        stride(from: 0, to: songs.count, by: 4).map { start in
            Self(songs: Array(songs[start..<min(start + 4, songs.count)]))
        }
    }
}

struct MusicPickerSongRow: View {
    let song: LibrarySongItem
    let selected: Bool
    let alreadyAdded: Bool
    var showsFavoriteMark: Bool = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            MusicPickerSongRowLabel(song: song, selected: selected, showsFavoriteMark: showsFavoriteMark)
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .accessibilityLabel("\(song.title)，\(song.artist)")
        .accessibilityValue(alreadyAdded ? "已在播放列表中" : selected ? "已选择" : "未选择")
        .accessibilityHint(alreadyAdded ? "" : selected ? "轻点取消选择" : "轻点添加")
    }
}

struct MusicPickerSongRowLabel: View {
    let song: LibrarySongItem
    let selected: Bool
    var showsFavoriteMark: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: song.artwork, cornerRadius: 5)
                .frame(width: 48, height: 48)
                .overlay(alignment: .leading) {
                    if showsFavoriteMark && song.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .offset(x: -14)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.body).foregroundStyle(.primary)
                Text(song.artist).font(.footnote)
                    .foregroundStyle(contrast == .increased ? Color.primary : Color(white: 0.60))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark" : "plus.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? Color.blue : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: selected)
                .frame(width: 40)
        }
        .frame(minHeight: 64)
        .contentShape(.rect)
    }
}
