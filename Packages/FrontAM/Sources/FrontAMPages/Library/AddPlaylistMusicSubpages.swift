import FrontAMCore
import SwiftUI


public struct PickerArtistsListView: View {
    public let artists: [LibraryArtistItem]
    @State private var query = ""

    private var filtered: [LibraryArtistItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return artists }
        return artists.filter { $0.name.localizedStandardContains(term) }
    }

    public var body: some View {
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

public struct PickerAlbumsListView: View {
    public let albums: [LibraryShelfItem]
    public let emptyNoun: String
    @State private var query = ""

    private var filtered: [LibraryShelfItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedStandardContains(term) || ($0.subtitle?.localizedStandardContains(term) ?? false)
        }
    }

    public var body: some View {
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

public struct PickerSongsListView: View {
    public let songs: [LibrarySongItem]
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void
    @State private var query = ""

    private var filtered: [LibrarySongItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return songs }
        return songs.filter { song in
            [song.title, song.artist, song.album].contains { $0.localizedStandardContains(term) }
        }
    }

    public var body: some View {
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

public struct PickerPlaylistsListView: View {
    public let library: (any FrontAMPlaylistSource)?
    public let fallbackPlaylists: [LibraryPlaylistItem]
    public let folderID: String?
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

    public var body: some View {
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

public struct PickerRecentlyAddedListView: View {
    public let items: [LibraryShelfItem]
    public let source: MusicPickerSource
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void
    @State private var query = ""

    private var filtered: [LibraryShelfItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(term) || ($0.subtitle?.localizedStandardContains(term) ?? false)
        }
    }

    public var body: some View {
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


public struct PickerArtistLibraryView: View {
    public let artist: LibraryArtistItem
    public let albums: [LibraryShelfItem]
    public let fallbackSongs: [LibrarySongItem]
    public let canOpenCatalog: Bool
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: textSize.isAccessibilitySize ? 1 : 2)
    }

    public var body: some View {
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

public struct PickerArtistCatalogView: View {
    public let artistID: String
    public let artistName: String
    public let source: MusicPickerSource
    public let session: MusicPickerSession
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void

    @State private var detail: ArtistDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?

    public var body: some View {
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

public struct PickerArtistCatalogSectionView: View {
    public let detail: ArtistDetail?
    public let section: ArtistSection
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void

    public var body: some View {
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


public struct PickerAlbumDetailView: View {
    public let album: LibraryShelfItem
    public let source: MusicPickerSource
    public let session: MusicPickerSession
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggleSong: (LibrarySongItem) -> Void
    public let onToggleAll: ([LibrarySongItem]) -> Void

    @State private var tracks: [LibrarySongItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var allSelected: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isSelected($0.id) }
    }

    private var allAlreadyAdded: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isExisting($0.id) }
    }

    public var body: some View {
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

public struct PickerPlaylistDetailView: View {
    public let playlist: LibraryPlaylistItem
    public let artwork: Artwork
    public let tracks: [LibrarySongItem]
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggleSong: (LibrarySongItem) -> Void
    public let onToggleAll: ([LibrarySongItem]) -> Void

    private var allSelected: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isSelected($0.id) }
    }

    private var allAlreadyAdded: Bool {
        !tracks.isEmpty && tracks.allSatisfy { isExisting($0.id) }
    }

    public var body: some View {
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


public struct PickerCollectionDetailHeader: View {
    public let artwork: Artwork
    public let title: String
    public let artist: String?
    public let isFavorite: Bool
    public let songCount: Int
    public let isAllSelected: Bool
    public let isAllDisabled: Bool
    public let onToggleAll: () -> Void

    public var body: some View {
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

public struct PickerAlbumTrackRow: View {
    public let song: LibrarySongItem
    public let trackNumber: Int
    public let selected: Bool
    public let alreadyAdded: Bool
    public let toggle: () -> Void

    public var body: some View {
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

public struct PickerCollectionRowLabel: View {
    public let artwork: Artwork
    public let title: String
    public let subtitle: String?
    public let isFavorite: Bool

    public var body: some View {
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

public struct PickerAlbumGridCard: View {
    public let album: LibraryShelfItem

    public var body: some View {
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

public struct MusicPickerSongCarousel: View {
    public let songs: [LibrarySongItem]
    public let isSelected: (String) -> Bool
    public let isExisting: (String) -> Bool
    public let onToggle: (LibrarySongItem) -> Void

    public var body: some View {
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

public struct MusicPickerPage: Identifiable {
    public let songs: [LibrarySongItem]
    public var id: String { songs[0].id }
    public static func pages(_ songs: [LibrarySongItem]) -> [Self] {
        stride(from: 0, to: songs.count, by: 4).map { start in
            Self(songs: Array(songs[start..<min(start + 4, songs.count)]))
        }
    }
}

public struct MusicPickerSongRow: View {
    public let song: LibrarySongItem
    public let selected: Bool
    public let alreadyAdded: Bool
    public var showsFavoriteMark: Bool = false
    public let toggle: () -> Void

    public var body: some View {
        Button(action: toggle) {
            MusicPickerSongRowLabel(song: song, selected: selected, showsFavoriteMark: showsFavoriteMark)
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .accessibilityLabel("\(song.title)，\(song.artist)")
        .accessibilityValue(alreadyAdded ? "已在播放列表中" : selected ? "已选择" : "未选择")
        .accessibilityHint(alreadyAdded ? "" : selected ? "轻点取消选择" : "轻点添加")
    }

    public init(song: LibrarySongItem,
                selected: Bool,
                alreadyAdded: Bool,
                showsFavoriteMark: Bool = false,
                toggle: @escaping () -> Void) {
        self.song = song
        self.selected = selected
        self.alreadyAdded = alreadyAdded
        self.showsFavoriteMark = showsFavoriteMark
        self.toggle = toggle
    }
}

public struct MusicPickerSongRowLabel: View {
    public let song: LibrarySongItem
    public let selected: Bool
    public var showsFavoriteMark: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    public var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: song.artwork, cornerRadius: DesignTokens.Radius.songRowCover)
                .environment(\.nativeArtworkSurfaceEnabled, false)
                .frame(width: DesignTokens.Artwork.rowCoverSize, height: DesignTokens.Artwork.rowCoverSize)
                .overlay(alignment: .leading) {
                    if showsFavoriteMark {
                        FavoriteMark(isFavorite: song.isFavorite, leadingOffset: -14)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.body).foregroundStyle(.primary)
                Text(song.artist).font(.footnote)
                    .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
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

    public init(song: LibrarySongItem,
                selected: Bool,
                showsFavoriteMark: Bool = false) {
        self.song = song
        self.selected = selected
        self.showsFavoriteMark = showsFavoriteMark
    }
}
