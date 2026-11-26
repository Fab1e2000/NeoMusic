import FrontAMCore
import SwiftUI
import UIKit

public struct AddPlaylistMusicView: View {
    public let title: String
    public let songs: [LibrarySongItem]
    public let playlists: [LibraryPlaylistItem]
    public let existingIDs: Set<String>
    public var playlistLibrary: (any FrontAMPlaylistSource)? = nil
    public var playlistSongs: [String: [LibrarySongItem]] = [:]
    public var recentlyPlayedSongs: [LibrarySongItem] = []
    public let onCommit: ([LibrarySongItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.musicPickerSource) private var environmentSource
    @State private var selectedSongs: [LibrarySongItem] = []
    @State private var selectedIDSet: Set<String> = []
    @State private var query = ""
    @State private var confirmsDiscard = false
    @State private var path: [MusicPickerRoute] = []
    @State private var session = MusicPickerSession()

    private var source: MusicPickerSource {
        session.resolvedSource(environment: environmentSource) {
            MusicPickerSource.fallback(
                songs: songs,
                playlists: playlists,
                playlistLibrary: playlistLibrary,
                recentlyPlayed: recentlyPlayedSongs
            )
        }
    }

    private var statusHeading: String {
        selectedSongs.isEmpty ? pageText("添加到“\(title)”") : pageText("已将\(selectedSongs.count)首歌曲添加到“\(title)”")
    }

    public var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationTitle(statusHeading)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBehavior(prompt: nil, hidesNavBarOnSearch: false)
                .toolbar { rootControls }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: pageText("艺人、歌曲或专辑"))
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
            Button(pageText("放弃所选内容"), role: .destructive) { dismiss() }
            Button(pageText("保留所选内容"), role: .cancel) {}
        } message: {
            Text(pageText("确定要放弃所选内容吗？"))
        }
        .onAppear {
            session.prepareIfNeeded(using: source)
        }
    }

    @ToolbarContentBuilder private var rootControls: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(pageText("关闭"), systemImage: "xmark") {
                if selectedSongs.isEmpty { dismiss() } else { confirmsDiscard = true }
            }
            .tint(.primary)
        }
        confirmControl
    }

    @ToolbarContentBuilder private var confirmControl: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(selectedSongs.isEmpty ? pageText("完成") : pageText("添加\(selectedSongs.count)首"), systemImage: "checkmark") {
                onCommit(selectedSongs)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
        }
    }


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


    private var rootContent: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return List {
            if trimmed.isEmpty {
                Section {
                    Text(pageText("资料库"))
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
                    carouselSection(pageText("最近喜爱"), songs: session.recentFavorites)
                }
                if !session.recentlyPlayed.isEmpty {
                    carouselSection(pageText("最近播放"), songs: session.recentlyPlayed)
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


    @ViewBuilder private func destination(_ route: MusicPickerRoute) -> some View {
        switch route {
        case .artists:
            PickerArtistsListView(artists: session.sortedArtists)

        case .albums:
            PickerAlbumsListView(albums: session.sortedAlbums, emptyNoun: pageText("专辑"))

        case .downloaded:
            PickerAlbumsListView(albums: session.sortedDownloadedAlbums, emptyNoun: pageText("已下载专辑"))

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
                fallbackPlaylists: fallbackPlaylistRows,
                folderID: nil
            )

        case .playlistFolder(let id, _):
            PickerPlaylistsListView(
                library: source.playlistLibrary,
                fallbackPlaylists: fallbackPlaylistRows,
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
            let canOpenCatalog = source.canOpenCatalogArtist(id) && source.loadArtistDetail != nil
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
            let tracks = playlistTracks(for: playlist)
            let artwork = source.playlistLibrary?.displayArtwork(of: playlist) ?? fallbackDisplayArtwork(for: playlist)
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
        return fallbackTracks(for: playlist)
    }

    private var fallbackPlaylistRows: [LibraryPlaylistItem] {
        guard source.playlistLibrary == nil else { return [] }
        return playlists.map { playlist in
            var row = playlist
            row.artwork = fallbackDisplayArtwork(for: playlist)
            return row
        }
    }

    private func fallbackTracks(for playlist: LibraryPlaylistItem) -> [LibrarySongItem] {
        guard !playlist.isSystem, !playlist.isReadOnly else { return [] }
        var seen = Set<String>()
        return (playlistSongs[playlist.id] ?? []).filter { seen.insert($0.id).inserted }
    }

    private func fallbackDisplayArtwork(for playlist: LibraryPlaylistItem) -> Artwork {
        if case .playlist = playlist.artwork, let first = fallbackTracks(for: playlist).first { return first.artwork }
        return playlist.artwork
    }

    private func matching(_ entries: [LibrarySongItem], term: String) -> [LibrarySongItem] {
        guard !term.isEmpty else { return entries }
        return entries.filter { song in
            [song.title, song.artist, song.album].contains { $0.localizedStandardContains(term) }
        }
    }

    public init(title: String,
                songs: [LibrarySongItem],
                playlists: [LibraryPlaylistItem],
                existingIDs: Set<String>,
                playlistLibrary: (any FrontAMPlaylistSource)? = nil,
                playlistSongs: [String: [LibrarySongItem]] = [:],
                recentlyPlayedSongs: [LibrarySongItem] = [],
                onCommit: @escaping ([LibrarySongItem]) -> Void) {
        self.title = title
        self.songs = songs
        self.playlists = playlists
        self.existingIDs = existingIDs
        self.playlistLibrary = playlistLibrary
        self.playlistSongs = playlistSongs
        self.recentlyPlayedSongs = recentlyPlayedSongs
        self.onCommit = onCommit
    }
}



private extension View {
    func navigationBarBehavior(prompt: String?, hidesNavBarOnSearch: Bool) -> some View {
        background(
            NavigationBarBehaviorBridge(prompt: prompt, hidesNavBarOnSearch: hidesNavBarOnSearch)
                .frame(width: 0, height: 0)
        )
    }
}

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

