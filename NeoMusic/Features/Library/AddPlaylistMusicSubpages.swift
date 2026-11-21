import SwiftUI


struct PickerArtistsListView: View {
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

struct PickerAlbumsListView: View {
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

struct PickerSongsListView: View {
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

struct PickerPlaylistsListView: View {
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

struct PickerRecentlyAddedListView: View {
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


struct PickerArtistLibraryView: View {
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

struct PickerArtistCatalogView: View {
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

struct PickerArtistCatalogSectionView: View {
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


struct PickerAlbumDetailView: View {
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

struct PickerPlaylistDetailView: View {
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


struct PickerCollectionDetailHeader: View {
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

struct PickerAlbumTrackRow: View {
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

struct PickerCollectionRowLabel: View {
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

struct PickerAlbumGridCard: View {
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

struct MusicPickerSongCarousel: View {
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

struct MusicPickerPage: Identifiable {
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
}
