#if DEBUG
import SwiftUI

/// Isolated public catalog preview. It never modifies the user's library or starts audio.
struct SearchPreviewRoot: View {
    @State private var preview = SearchPreviewPresentation()
    @State private var library = PlaylistLibrary(playlists: [], folders: [])
    @State private var toasts = LibraryToastCenter()
    @State private var player: NowPlayingModel
    private let lyrics: ReferenceLibrary

    init() {
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
            makePlayerActions: { _ in .init(isFavorite: { _ in false }, toggleFavorite: { _ in }, addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in }) },
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
        } else { SearchPageView(model: preview.model) }
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
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-searchPreviewPage"), args.indices.contains(index + 1) {
            selectedMode = Mode(rawValue: args[index + 1]) ?? .browse
        }
        model.onArtwork = { [weak self] in self?.artwork($0) }
        model.onKind = { [weak self] in self?.filter() }
        model.onSubmit = { [weak self] in self?.show(.results) }
        model.onQuery = { [weak self] in
            guard let self else { return }
            self.model.keywords = self.model.query.isEmpty ? [] : [self.model.query, "洛天依", "洛天依 热门歌曲"].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
        model.onScope = { [weak self] in self?.model.syncStatus = self?.model.scope == .library ? "正在同步资料库 · 12 / 18 个集合" : nil }
        model.onRemoveHistory = { [weak self] word in self?.model.history.removeAll { word == nil || $0 == word } }
        model.onRetry = { [weak self] in self?.show(.syncing) }
        model.onRefresh = { [weak self] in await self?.load() }
        model.onCategory = { [weak self] category in
            guard let self else { return }
            self.model.category = category
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
        show(selectedMode)
    }
    func load() async {
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
            model.categories = snapshot.categories.enumerated().map { .init(id: $0.element.id, title: $0.element.name, colorIndex: $0.offset) }
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
        model.query = [.browse, .recent, .category].contains(mode) ? "" : "洛天依"
        model.submitted = [.results, .songs, .syncing, .error].contains(mode)
        model.kind = mode == .songs ? .song : .combined
        model.scope = [.syncing, .error].contains(mode) ? .library : .online
        model.syncStatus = mode == .syncing ? "正在同步资料库 · 12 / 18 个集合" : (mode == .error ? "还有 2 个集合未同步，已保留现有结果" : nil)
        model.syncFailed = mode == .error
        model.history = mode == .recent ? ["洛天依", "初音未来", "周杰伦"] : []
        model.keywords = ["洛天依", "洛天依 权御天下", "洛天依 普通DISCO"]
        filter()
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
