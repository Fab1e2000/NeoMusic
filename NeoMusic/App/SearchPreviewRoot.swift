#if DEBUG
import SwiftUI

/// Explicit pages use fixed display fixtures; the catalog preview can load public content.
struct SearchPreviewRoot: View {
    @State private var preview: SearchPreviewPresentation
    @State private var library = PlaylistLibrary(playlists: [], folders: [])
    @State private var toasts = LibraryToastCenter()
    @State private var player: NowPlayingModel
    private let lyrics: ReferenceLibrary

    init(page: String? = nil) {
        _preview = State(initialValue: SearchPreviewPresentation(page: page))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("player-cover.jpg")
        try? UIImage(named: "AlbumSample17")?.jpegData(compressionQuality: 0.9)?.write(to: cover)
        let song = LibrarySongItem(id: "search-preview", title: "物語りのワルツ", artist: "Isekaijoucho", album: "", albumArtist: "Isekaijoucho", trackNumber: 1,
                                  artwork: .file(cover), artworkURL: cover, duration: 240)
        _player = State(initialValue: NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false, elapsed: 0))
        lyrics = ReferenceLibrary(reader: ReferenceLyricsReader(storageDirectory: root, root: root, resolveAudioURL: { _ in nil }))
    }
    var body: some View {
        AppShell(library: { Text("搜索效果稿") }, detailDestination: { _ in AnyView(EmptyView()) },
            nowPlaying: player, playlistLibrary: library, toasts: toasts,
            referencePlayer: ReferencePlayerState(model: player), referenceLibrary: lyrics,
            makePlayerActions: { _, _ in .init(isFavorite: { _ in false }, toggleFavorite: { _ in }, addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in }) },
            searchContent: AnyView(previewContent.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(SearchPreviewPresentation.Mode.allCases, id: \.self) { mode in
                            Button(mode.title) { preview.show(mode) }
                        }
                    } label: { Text("预览").font(.subheadline) }
                }
            }), searchDestination: { _ in AnyView(SearchCategoryPage(model: preview.model, category: preview.model.category ?? "流行")) },
            selection: .search)
        .task { await preview.load() }
        .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { preview.artwork($0) }))
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-searchPreviewDark") ? .dark : nil)
    }
    @ViewBuilder private var previewContent: some View {
        if preview.isCategoryMode {
            SearchCategoryPage(model: preview.model, category: "流行")
                .librarySearchable(text: .constant(""), prompt: "", enabled: false)
        } else {
            SearchPageView(model: preview.model)
                .safeAreaInset(edge: .bottom) {
                    if preview.isDisplayFixture {
                        Text("隔离预览 · 固定示例搜索结果")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.regularMaterial)
                    }
                }
        }
    }
}

@MainActor @Observable
private final class SearchPreviewPresentation {
    enum Mode: String, CaseIterable {
        case browse, recent, suggestions, results, songs, category, syncing, error
        var title: String {
            switch self { case .browse: "分类首页"; case .recent: "最近搜索"; case .suggestions: "输入联想"
            case .results: "综合结果"; case .songs: "歌曲结果"; case .category: "分类歌单"
            case .syncing: "资料库同步"; case .error: "同步失败" }
        }
    }
    let model = SearchPageModel()
    let isDisplayFixture: Bool
    private let client = NeteaseSearchClient()
    private var resources: [String: NeteaseSearchResource] = [:]
    private var allGroups: [MusicSearchGroup] = []
    private var artworkTasks: [String: Task<Void, Never>] = [:]
    private var selectedMode: Mode = .browse
    private struct Snapshot: Codable {
        let categories: [NeteaseSearchCategory]
        let result: NeteaseSearchPage
        let playlists: NeteaseSearchPage
    }
    private var snapshot: Snapshot?
    private let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("SearchPreview/catalog.json")
    var isCategoryMode: Bool { selectedMode == .category }
    init(page: String? = nil) {
        isDisplayFixture = page != nil
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-searchPreviewPage"), args.indices.contains(index + 1) {
            selectedMode = Mode(rawValue: args[index + 1]) ?? .browse
        }
        if let page { selectedMode = Mode(rawValue: page) ?? .browse }
        model.onArtwork = { [weak self] in self?.artwork($0) }
        model.onKind = { [weak self] in self?.filter() }
        model.onSubmit = { [weak self] in self?.show(.results) }
        model.onQuery = { [weak self] in
            guard let self else { return }
            self.model.keywords = self.model.query.isEmpty ? [] : [self.model.query, "洛天依", "洛天依 热门歌曲"].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
        model.onScope = { [weak self] in
            guard let self else { return }
            self.model.syncStatus = !self.isDisplayFixture && self.model.scope == .library ? "正在同步资料库 · 12 / 18 个集合" : nil
        }
        model.onRemoveHistory = { [weak self] word in self?.model.history.removeAll { word == nil || $0 == word } }
        model.onRetry = { [weak self] in self?.show(.syncing) }
        model.onRefresh = { [weak self] in await self?.load() }
        model.onCategory = { [weak self] category in
            guard let self else { return }
            self.model.category = category
            if self.isDisplayFixture {
                self.model.categoryItems = self.allGroups.first(where: { $0.kind == .playlist })?.items ?? []
                return
            }
            if category == "流行", let page = self.snapshot?.playlists {
                self.model.categoryItems = page.groups.flatMap(\.items).map(self.item)
                return
            }
            self.model.categoryItems = []
            Task {
                guard let page = try? await self.client.playlists(category: category, credential: nil), self.model.category == category else { return }
                self.model.categoryItems = page.groups.flatMap(\.items).map(self.item)
            }
        }
        if isDisplayFixture { loadDisplayFixture() }
        show(selectedMode)
    }
    func load() async {
        guard !isDisplayFixture else { return }
        guard model.categories.isEmpty else { return }
        model.isLoading = true
        defer { model.isLoading = false }
        do {
            // Keep one real public snapshot across preview modes; UI checks do not requery the service.
            if let data = try? Data(contentsOf: snapshotURL), let cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
                snapshot = cached
            } else {
                async let categories = client.categories(credential: nil)
                async let combined = client.search("洛天依", kind: .combined, credential: nil)
                async let playlists = client.playlists(category: "流行", credential: nil)
                snapshot = try await Snapshot(categories: categories, result: combined, playlists: playlists)
                saveSnapshot()
            }
            guard let snapshot else { return }
            await NeteaseArtworkCache.shared.restore(scope: "search-preview")
            model.categories = snapshot.categories.enumerated().map {
                .init(id: $0.element.id, title: $0.element.name, colorIndex: $0.offset,
                      group: $0.element.group, isHot: $0.element.isHot)
            }
            allGroups = snapshot.result.groups.map { .init(kind: MusicSearchKind(rawValue: $0.kind.rawValue)!, items: $0.items.map(item), hasMore: $0.hasMore) }
            model.categoryItems = snapshot.playlists.groups.flatMap(\.items).map(item)
            model.suggestions = allGroups.filter { $0.kind == .artist || $0.kind == .album }.compactMap { $0.items.first }
            filter()
        } catch { model.error = error.localizedDescription }
    }
    private func saveSnapshot() {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
    func show(_ mode: Mode) {
        selectedMode = mode
        model.isSearching = mode != .browse && mode != .category
        model.query = [.browse, .recent, .category].contains(mode) ? "" : (isDisplayFixture ? "晨光" : "洛天依")
        model.submitted = [.results, .songs, .syncing, .error].contains(mode)
        model.kind = mode == .songs ? .song : .combined
        model.scope = [.syncing, .error].contains(mode) ? .library : .online
        model.syncStatus = mode == .syncing ? "正在同步资料库 · 12 / 18 个集合" : (mode == .error ? "还有 2 个集合未同步，已保留现有结果" : nil)
        model.syncFailed = mode == .error
        model.history = mode == .recent ? ["洛天依", "初音未来", "周杰伦"] : []
        model.keywords = ["洛天依", "洛天依 权御天下", "洛天依 普通DISCO"]
        filter()
    }
    private func loadDisplayFixture() {
        allGroups = [
            .init(kind: .song, items: [
                displayItem(id: "song-1", kind: .song, title: "晨光", subtitle: "示例艺人", image: 1),
                displayItem(id: "song-2", kind: .song, title: "晨光（现场版）", subtitle: "示例乐队", image: 2),
                displayItem(id: "song-3", kind: .song, title: "晨光（钢琴版）", subtitle: "示例演奏者", image: 3),
                displayItem(id: "song-4", kind: .song, title: "晨光与远山", subtitle: "示例艺人", image: 4)
            ]),
            .init(kind: .artist, items: [
                displayItem(id: "artist-1", kind: .artist, title: "晨光乐队", subtitle: "示例艺人", image: 5),
                displayItem(id: "artist-2", kind: .artist, title: "晨光音乐人", subtitle: "示例艺人", image: 6)
            ]),
            .init(kind: .album, items: [
                displayItem(id: "album-1", kind: .album, title: "晨光集", subtitle: "示例乐队", image: 7),
                displayItem(id: "album-2", kind: .album, title: "晨光之后", subtitle: "示例艺人", image: 8)
            ]),
            .init(kind: .playlist, items: [
                displayItem(id: "playlist-1", kind: .playlist, title: "晨光通勤选集", subtitle: "示例作者", image: 9),
                displayItem(id: "playlist-2", kind: .playlist, title: "晨光里的钢琴", subtitle: "示例作者", image: 10)
            ])
        ]
        model.categories = ["流行", "摇滚", "轻音乐", "电子", "民谣", "古典"].enumerated().map {
            .init(id: $0.element, title: $0.element, colorIndex: $0.offset)
        }
        model.categoryItems = allGroups.first(where: { $0.kind == .playlist })?.items ?? []
        model.suggestions = allGroups.filter { $0.kind == .artist || $0.kind == .album }.compactMap { $0.items.first }
    }
    private func displayItem(id: String, kind: MusicSearchKind, title: String, subtitle: String, image: Int) -> MusicSearchItem {
        let artwork = Artwork.image(Image(String(format: "AlbumSample%02d", image)))
        let song = kind == .song ? LibrarySongItem(id: "preview-search:\(id)", title: title, artist: subtitle,
            album: "示例专辑", albumArtist: subtitle, trackNumber: 0, artwork: artwork, duration: 240) : nil
        return .init(id: "display:\(id)", kind: kind, title: title, subtitle: subtitle, artwork: artwork, song: song)
    }
    private func filter() {
        model.groups = model.kind == .combined ? allGroups : allGroups.filter { $0.kind == model.kind }
    }
    private func item(_ resource: NeteaseSearchResource) -> MusicSearchItem {
        resources[resource.id] = resource
        let artwork: Artwork = resource.artworkURL.flatMap { NeteaseArtworkCache.shared.cachedURL(for: $0, scope: "search-preview") }.map(Artwork.file)
            ?? .deferred(id: resource.id, placeholder: .missing)
        let song = resource.song.map { LibrarySongItem(id: "preview-search:\($0.id)", title: $0.title, artist: $0.artist, album: $0.album, albumArtist: $0.artist, trackNumber: 0, artwork: artwork, duration: Int($0.duration)) }
        return .init(id: resource.id, kind: MusicSearchKind(rawValue: resource.kind.rawValue)!, title: resource.title, subtitle: resource.subtitle, artwork: artwork, song: song)
    }
    func artwork(_ id: String) {
        guard artworkTasks[id] == nil, let url = resources[id]?.artworkURL else { return }
        artworkTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.artworkTasks[id] = nil }
            guard let file = try? await NeteaseArtworkCache.shared.imageURL(for: url, scope: "search-preview"), !Task.isCancelled else { return }
            for group in self.allGroups.indices {
                for row in self.allGroups[group].items.indices where self.allGroups[group].items[row].id == id {
                    self.allGroups[group].items[row].artwork = .file(file)
                    self.allGroups[group].items[row].song?.artwork = .file(file)
                }
            }
            for index in self.model.categoryItems.indices where self.model.categoryItems[index].id == id { self.model.categoryItems[index].artwork = .file(file) }
            for index in self.model.suggestions.indices where self.model.suggestions[index].id == id { self.model.suggestions[index].artwork = .file(file) }
            self.filter()
        }
    }
}
#endif
