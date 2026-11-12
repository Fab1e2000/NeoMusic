#if DEBUG
import SwiftUI
import UIKit

/// Production library components with an unsaved catalog and observable, in-memory actions.
struct FrontendLibraryAuditPreview: View {
    @State private var fixture = LibraryAuditFixture()
    @State private var navigation = LibraryDetailNavigation()
    @State private var showsLayoutCandidate = ProcessInfo.processInfo.arguments.contains("-libraryAuditLayoutCandidate")

    private var initialPath: [LibraryRoute] {
        switch LibraryAuditFixture.argument("-libraryAuditPage") {
        case "album": [.album(LibraryAuditFixture.primaryAlbumID)]
        case "playlist": [.playlist(LibraryAuditFixture.primaryPlaylistID)]
        case "songs": [.category(.songs)]
        case "playlists": [.category(.playlists)]
        default: []
        }
    }

    var body: some View {
        LibraryNavigationContainer(
            navigation: navigation,
            root: LibraryAuditHome(fixture: fixture),
            destination: { AnyView(LibraryAuditDestination(route: $0, fixture: fixture)) },
            initialPath: initialPath
        )
        .environment(\.libraryDownloads, fixture.downloads)
        .environment(\.collectionMenuActions, fixture.collectionActions)
        .environment(\.songMenuActions, fixture.songActions)
        .environment(\.dynamicTypeSize, fixture.textSize.value)
        .preferredColorScheme(fixture.appearance.colorScheme)
        .sheet(isPresented: $fixture.showsSettings, onDismiss: {
            if fixture.requestsLayoutCandidate {
                fixture.requestsLayoutCandidate = false
                showsLayoutCandidate = true
            }
        }) {
            LibraryAuditSettings(fixture: fixture)
                .dynamicTypeSize(.large)
        }
        .fullScreenCover(isPresented: $showsLayoutCandidate) {
            LibraryAuditRecentLayoutCandidate(fixture: fixture)
        }
        .accessibilityIdentifier("library-audit.root")
    }
}

/// Preview-only text sizing is applied inside the system menu's preview closure.
struct FrontendMenuSizingPreview: View {
    @State private var usesAdaptiveSizing = true
    @State private var previewTextSize = LibraryAuditFixture.TextSize.ax5
    @State private var showsOpenedContent = false
    @State private var closeCount = 0
    @Environment(\.dismiss) private var dismiss

    private let lines = [
        "沿着城市边缘一直走到海边的那些漫长夜晚与清晨",
        "The Northern Lights Collective with Friends",
        "完整现场录音特别纪念版 · Complete Live Sessions"
    ]
    private var artwork: Artwork { .image(Image("AlbumSample01")) }
    private var previewSize: CGSize {
        let traits = UITraitCollection(preferredContentSizeCategory: previewTextSize.contentSizeCategory)
        var size = MenuPreviewCard.size(for: lines, compatibleWith: traits)
        if !usesAdaptiveSizing { size.height = 123 }
        return size
    }

    var body: some View {
        let size = previewSize
        let sourceSize = MenuPreviewCard.size(for: lines)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("菜单高度", selection: $usesAdaptiveSizing) {
                        Text("旧版").tag(false)
                        Text("正式").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("menu-sizing.mode")
                    Picker("菜单卡片字号", selection: $previewTextSize) {
                        ForEach(LibraryAuditFixture.TextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("menu-sizing.text-size")
                    Text("菜单卡片字号：\(previewTextSize.title)；预览高度：\(Int(size.height)) pt")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("menu-sizing.metrics")
                    MenuPreviewCard(artwork: artwork, lines: lines)
                        .frame(width: sourceSize.width, height: sourceSize.height)
                        .contextMenu {
                            Button("打开", systemImage: "arrow.up.right.square") { showsOpenedContent = true }
                                .accessibilityIdentifier("menu-sizing.open")
                            Button("关闭菜单", systemImage: "xmark") { closeCount += 1 }
                                .accessibilityIdentifier("menu-sizing.close")
                        } preview: {
                            MenuPreviewCard(artwork: artwork, lines: lines)
                                .dynamicTypeSize(previewTextSize.value)
                                .frame(width: size.width, height: size.height)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("长按打开菜单")
                        .accessibilityIdentifier("menu-sizing.source")
                    Text("长按卡片打开原生菜单。选择“打开”查看完整文字，选择“关闭菜单”或轻点空白处关闭。")
                    Text("自适应高度已接入正式菜单。选择卡片字号后，长按对照旧版固定高度与正式排版。封面和单行省略保持，页面与菜单动作沿用系统字号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("已关闭菜单", value: String(closeCount))
                        .accessibilityIdentifier("menu-sizing.close-count")
                }
                .padding(20)
            }
            .navigationTitle("菜单高度核验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("menu-sizing.done")
                }
            }
            .navigationDestination(isPresented: $showsOpenedContent) {
                List {
                    ArtworkView(artwork: artwork, cornerRadius: 16)
                        .frame(width: 92, height: 92)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .navigationTitle("预览已打开")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("menu-sizing.opened")
            }
        }
        .accessibilityIdentifier("menu-sizing.root")
    }
}

private struct LibraryAuditHome: View {
    let fixture: LibraryAuditFixture

    var body: some View {
        LibraryHomeView(
            pinned: fixture.pinned,
            recentlyAdded: fixture.recentlyAdded,
            playlistLibrary: fixture.library,
            reorderPinned: fixture.reorderPinned,
            playSong: { id in fixture.recordPlay(fixture.songs.first { $0.id == id }) },
            songForMenu: { id in fixture.songs.first { $0.id == id } }
        )
        .modifier(LibraryAuditControls(fixture: fixture))
        .accessibilityIdentifier("library-audit.home")
    }
}

private struct LibraryAuditDestination: View {
    let route: LibraryRoute
    let fixture: LibraryAuditFixture
    var showSettings: (() -> Void)? = nil

    var body: some View {
        content
            .modifier(LibraryAuditControls(fixture: fixture, showSettings: showSettings))
            .downloadRemovalConfirmation()
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .album(let id):
            if let album = fixture.albums.first(where: { $0.id == id }) {
                CollectionDetailView(detail: CollectionDetail(
                    kind: .album, title: album.title, subtitle: album.subtitle, caption: "2026年",
                    artwork: album.artwork, tint: Color(.systemBackground), isFavorite: album.isFavorite,
                    isPinned: fixture.pinnedRoutes.contains(route), songs: fixture.songs(for: route), route: route
                ))
                .accessibilityIdentifier("library-audit.album")
            }
        case .playlist(let id):
            PlaylistDetailView(playlistID: id, library: fixture.library, songs: [],
                               availableSongs: { fixture.songs }, recentlyPlayedSongs: Array(fixture.songs.prefix(8)))
                .accessibilityIdentifier("library-audit.playlist")
        case .playlistFolder(let id):
            PlaylistsListView(library: fixture.library, folderID: id)
        case .category(.playlists), .downloadedCategory(.playlists):
            PlaylistsListView(library: fixture.library)
                .accessibilityIdentifier("library-audit.playlists")
        case .category(.albums), .downloadedCategory(.albums):
            AlbumsGridView(albums: fixture.albums, playAll: { ids, _ in
                fixture.recordPlay(ids.first.flatMap { fixture.songs(for: .album($0)).first })
            })
        case .category(.songs), .downloadedCategory(.songs):
            SongsListView(songs: fixture.songs, playAll: { songs, _ in fixture.recordPlay(songs.first) })
                .accessibilityIdentifier("library-audit.songs")
        case .category(.artists), .downloadedCategory(.artists):
            ArtistsListView(artists: fixture.artists)
        case .category(.downloaded), .downloadedCategory(.downloaded):
            DownloadedMockView(albums: fixture.albums)
        case .artist(let id):
            ArtistDetailView(detail: fixture.artistDetail(id), playSong: { fixture.recordPlay($0) })
        case .artistSection(let id, let section):
            ArtistSectionView(detail: fixture.artistDetail(id), section: section, playSong: { fixture.recordPlay($0) })
        }
    }
}

private struct LibraryAuditControls: ViewModifier {
    let fixture: LibraryAuditFixture
    var showSettings: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let showSettings { showSettings() }
                    else { fixture.showsSettings = true }
                } label: {
                    Label("核验 \(fixture.actionCount)", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("核验设置")
                .accessibilityValue(fixture.counterSummary)
                .accessibilityIdentifier("library-audit.settings")
            }
        }
    }
}

private struct LibraryAuditSettings: View {
    @Bindable var fixture: LibraryAuditFixture
    var showCurrentLayout: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("正式组件显示设置") {
                    Picker("文字大小", selection: $fixture.textSize) {
                        ForEach(LibraryAuditFixture.TextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library-audit.text-size")
                    Picker("外观", selection: $fixture.appearance) {
                        ForEach(LibraryAuditFixture.Appearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library-audit.appearance")
                }
                Section("最近添加排版对照") {
                    if let showCurrentLayout {
                        Button("返回当前首页") {
                            showCurrentLayout()
                            dismiss()
                        }
                        .accessibilityIdentifier("library-audit.layout-current.open")
                    } else {
                        Button("最近添加的大字号排版候选") {
                            fixture.requestsLayoutCandidate = true
                            dismiss()
                        }
                        .accessibilityIdentifier("library-audit.layout-candidate.open")
                    }
                    Text("候选只在辅助功能字号采用单列，默认与 XXXL 保留两列。复用首页最近添加的六张卡片和正式详情页。")
                }
                Section("已触发的内存动作") {
                    LabeledContent("停止次数", value: String(fixture.stopCount))
                        .accessibilityIdentifier("library-audit.count.stop")
                    LabeledContent("重试次数", value: String(fixture.retryCount))
                        .accessibilityIdentifier("library-audit.count.retry")
                    LabeledContent("播放次数", value: String(fixture.playCount))
                        .accessibilityIdentifier("library-audit.count.play")
                    LabeledContent("发起下载次数", value: String(fixture.downloadCount))
                        .accessibilityIdentifier("library-audit.count.download")
                    Text(fixture.lastAction)
                        .accessibilityIdentifier("library-audit.last-action")
                    Button("重置下载状态与计数") { fixture.resetDownloads() }
                        .accessibilityIdentifier("library-audit.reset")
                }
                Section("核验步骤") {
                    Text("返回资料库，滚动查看最近添加的六张长标题卡片。切换字号后继续停留原页面，再进入专辑或播放列表并返回。")
                    Text("专辑第一首处于下载中，第二首处于失败状态。点行内状态图标，再查看停止、重试及播放次数；更多菜单和侧滑提供同一动作的对照入口。")
                    Text("下载和播放只记录内存动作。每轮使用重置按钮恢复状态，便于连续重复五轮。")
                }
            }
            .navigationTitle("资料库核验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("library-audit.settings.done")
                }
            }
        }
        .accessibilityIdentifier("library-audit.settings.sheet")
    }
}

private struct LibraryAuditRecentLayoutCandidate: View {
    let fixture: LibraryAuditFixture
    @State private var navigation = LibraryDetailNavigation()
    @State private var showsSettings = false
    @State private var returnsToCurrentLayout = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LibraryNavigationContainer(
            navigation: navigation,
            root: LibraryAuditRecentShelf(fixture: fixture, close: { dismiss() },
                                          showSettings: { showsSettings = true }),
            destination: {
                AnyView(LibraryAuditDestination(route: $0, fixture: fixture,
                                               showSettings: { showsSettings = true }))
            }
        )
        .environment(\.libraryDownloads, fixture.downloads)
        .environment(\.collectionMenuActions, fixture.collectionActions)
        .environment(\.songMenuActions, fixture.songActions)
        .environment(\.dynamicTypeSize, fixture.textSize.value)
        .preferredColorScheme(fixture.appearance.colorScheme)
        .sheet(isPresented: $showsSettings, onDismiss: {
            if returnsToCurrentLayout { dismiss() }
        }) {
            LibraryAuditSettings(fixture: fixture, showCurrentLayout: { returnsToCurrentLayout = true })
                .dynamicTypeSize(.large)
        }
    }
}

private struct LibraryAuditRecentShelf: View {
    let fixture: LibraryAuditFixture
    let close: () -> Void
    let showSettings: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("首页“最近添加”区域的排版候选。辅助功能字号使用单列，卡片随文字内容增高。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("最近添加")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if textSize.isAccessibilitySize {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        cards
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                        GridItem(.flexible(), spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 20) {
                        cards
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 17)
            .padding(.bottom, 24)
        }
        .libraryNavigationTitle("最近添加排版候选")
        .libraryTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭候选", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("library-audit.layout-candidate.close")
            }
        }
        .modifier(LibraryAuditControls(fixture: fixture, showSettings: showSettings))
        .accessibilityIdentifier("library-audit.layout-candidate")
    }

    private var cards: some View {
        ForEach(fixture.recentlyAdded) { item in
            CollectionCardLink(item: item) {
                AlbumCard(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("library-audit.layout-candidate.card.\(item.id)")
        }
    }
}

@MainActor @Observable
private final class LibraryAuditFixture {
    static let primaryAlbumID = "catalog:album:9001"
    static let primaryPlaylistID = "library-audit-playlist-1"

    enum TextSize: String, CaseIterable, Identifiable {
        case standard = "default", xxxl, ax5
        var id: Self { self }
        var title: String { switch self { case .standard: "默认"; case .xxxl: "XXXL"; case .ax5: "AX5" } }
        var value: DynamicTypeSize { switch self { case .standard: .large; case .xxxl: .xxxLarge; case .ax5: .accessibility5 } }
        var contentSizeCategory: UIContentSizeCategory {
            switch self {
            case .standard: .large
            case .xxxl: .extraExtraExtraLarge
            case .ax5: .accessibilityExtraExtraExtraLarge
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var title: String { switch self { case .system: "系统"; case .light: "浅色"; case .dark: "深色" } }
        var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    }

    let library: PlaylistLibrary
    let downloads = LibraryDownloads()
    var albums: [LibraryShelfItem]
    var songs: [LibrarySongItem]
    var pinnedRoutes: [LibraryRoute] = []
    var textSize: TextSize
    var appearance: Appearance
    var showsSettings = false
    var requestsLayoutCandidate = false
    private(set) var stopCount = 0
    private(set) var retryCount = 0
    private(set) var playCount = 0
    private(set) var downloadCount = 0
    private(set) var lastAction = "尚未触发下载或播放动作"

    init() {
        textSize = Self.argument("-libraryAuditTextSize").flatMap(TextSize.init(rawValue:)) ?? .standard
        appearance = Self.argument("-libraryAuditAppearance").flatMap(Appearance.init(rawValue:)) ?? .system
        let albumFixtures = [
            LibraryShelfItem(id: Self.primaryAlbumID,
                title: "沿着城市边缘一直走到海边的那些漫长夜晚与清晨：完整现场录音特别纪念版",
                subtitle: "来自北方的独立音乐人与远方朋友们组成的联合室内乐团",
                artwork: .image(Image("AlbumSample01")), route: .album(Self.primaryAlbumID)),
            LibraryShelfItem(id: "catalog:album:9002",
                title: "The Long Road Between the Last Train Home and the First Light of a New Morning — Complete Live Sessions",
                subtitle: "The Northern Lights Collective with Friends from Every Corner of the City",
                artwork: .image(Image("AlbumSample02")), route: .album("catalog:album:9002")),
            LibraryShelfItem(id: "catalog:album:9003", title: "从一条安静的小街开始，经过春天、夏天与秋天，最后回到有音乐的地方",
                subtitle: "夜晚散步乐队与城市交响室内乐团共同演奏",
                artwork: .image(Image("AlbumSample03")), route: .album("catalog:album:9003")),
            LibraryShelfItem(id: "catalog:album:9004", title: "Songs for Every Window, Every Journey, and Every Quiet Moment We Keep",
                subtitle: "A Collaboration Between the Riverside Ensemble and the Midnight Walking Orchestra",
                artwork: .image(Image("AlbumSample04")), route: .album("catalog:album:9004"))
        ]
        let songFixtures = Self.makeSongs(albumFixtures)
        var first = LibraryPlaylistItem(id: Self.primaryPlaylistID,
            title: "在漫长通勤与夜晚散步途中循环播放的那些歌：从第一束晨光到最后一班列车",
            artwork: .image(Image("AlbumSample05")))
        first.subtitle = "一位把城市里每个安静角落都收藏进音乐的听众"
        first.description = "供资料库核验使用的长标题与长描述。所有播放、下载和编辑状态均来自本次预览的内存数据。"
        var second = LibraryPlaylistItem(id: "library-audit-playlist-2",
            title: "Every Song for the Journey from the Last Streetlight to the First Train of the Morning",
            artwork: .image(Image("AlbumSample06")))
        second.subtitle = "A Listener Collecting the Quiet Moments Between Every Destination"
        albums = albumFixtures
        songs = songFixtures
        library = PlaylistLibrary(playlists: [first, second])
        library.addSongs(Array(songs.prefix(6)), to: first.id)
        library.addSongs(Array(songs.dropFirst(6).prefix(6)), to: second.id)
        downloads.isDownloadable = { _ in true }
        downloads.isRemovable = { _ in true }
        downloads.downloadAction = { [weak self] in self?.startDownloads($0) }
        downloads.stopAction = { [weak self] in self?.stopDownloads($0) }
        downloads.removeAction = { [weak self] in self?.removeDownloads($0) }
        resetDownloads()
    }

    var recentlyAdded: [LibraryShelfItem] {
        let playlists = library.playlists.map(\.shelfItem)
        return Array(albums.prefix(2)) + playlists + Array(albums.dropFirst(2))
    }

    var pinned: [LibraryShelfItem] {
        pinnedRoutes.compactMap { route in recentlyAdded.first { $0.route == route } }
    }

    var artists: [LibraryArtistItem] {
        [.init(id: "catalog:artist:9001", name: "来自北方的独立音乐人与远方朋友们组成的联合室内乐团", artwork: albums.first?.artwork)]
    }

    var actionCount: Int { stopCount + downloadCount + playCount }
    var counterSummary: String { "停止 \(stopCount)，重试 \(retryCount)，播放 \(playCount)" }

    func songs(for route: LibraryRoute) -> [LibrarySongItem] {
        switch route {
        case .album(let id): songs.filter { $0.albumID == id }
        case .playlist(let id): library.songs(in: id)
        default: songs
        }
    }

    func artistDetail(_ id: String) -> ArtistDetail {
        ArtistDetail(name: artists[0].name, artwork: albums.first?.artwork, albums: albums,
                     id: id, biography: "隔离资料库的示例艺人，供长文本与原生导航核验。", songs: Array(songs.prefix(6)))
    }

    func recordPlay(_ song: LibrarySongItem?) {
        guard let song else { return }
        playCount += 1
        lastAction = "播放已记录：\(song.title)"
    }

    func resetDownloads() {
        stopCount = 0
        retryCount = 0
        playCount = 0
        downloadCount = 0
        lastAction = "已重置：每张专辑第一首下载中，第二首下载失败"
        var states: [String: LibraryDownloads.SongState] = [:]
        for song in songs {
            switch song.trackNumber {
            case 1: states[song.id] = .downloading(0.42)
            case 2: states[song.id] = .failed("隔离预览：网络连接已中断")
            case 3: states[song.id] = .waiting
            case 4: states[song.id] = .downloaded
            default: break
            }
        }
        publish(states)
    }

    private func startDownloads(_ items: [LibrarySongItem]) {
        guard !items.isEmpty else { return }
        var states = downloads.states
        var retries = 0
        for song in items {
            if case .failed = states[song.id] { retries += 1 }
            states[song.id] = .downloading(0.08)
        }
        retryCount += retries
        downloadCount += items.count
        lastAction = "已记录 \(items.count) 次下载，其中 \(retries) 次重试：\(items[0].title)"
        publish(states)
    }

    private func stopDownloads(_ items: [LibrarySongItem]) {
        guard !items.isEmpty else { return }
        var states = downloads.states
        for song in items { states[song.id] = nil }
        stopCount += items.count
        lastAction = "停止已记录：\(items.map(\.title).joined(separator: "、"))"
        publish(states)
    }

    private func removeDownloads(_ items: [LibrarySongItem]) {
        var states = downloads.states
        for song in items { states[song.id] = nil }
        lastAction = "已从示例状态移除 \(items.count) 首下载"
        publish(states)
    }

    private func publish(_ states: [String: LibraryDownloads.SongState]) {
        downloads.publish(states: states, managedSongIDs: Set(songs.map(\.id)))
        let routes = albums.compactMap(\.route) + library.playlists.map { LibraryRoute.playlist($0.id) }
        var summaries: [LibraryRoute: LibraryDownloads.CollectionState] = [:]
        for route in routes {
            let tracks = songs(for: route)
            let current = tracks.compactMap { states[$0.id] }
            summaries[route] = .init(totalCount: tracks.count,
                completedCount: current.filter { $0 == .downloaded }.count,
                activeCount: current.filter(\.isActive).count,
                failedCount: current.filter { if case .failed = $0 { true } else { false } }.count,
                progress: downloads.progress(of: tracks))
        }
        downloads.publishCollections(summaries)
    }

    func reorderPinned(_ routes: [LibraryRoute]) -> Bool {
        guard routes.count == pinnedRoutes.count, Set(routes) == Set(pinnedRoutes) else { return false }
        pinnedRoutes = routes
        return true
    }

    var collectionActions: CollectionMenuActions {
        var actions = CollectionMenuActions()
        actions.play = { [weak self] route, _ in self?.recordPlay(self?.songs(for: route).first) }
        actions.playNext = { [weak self] _ in self?.lastAction = "已记录插播集合" }
        actions.playLater = { [weak self] _ in self?.lastAction = "已记录集合加入队列" }
        actions.toggleFavorite = { [weak self] route in
            guard let self else { return }
            if case .playlist(let id) = route { library.toggleFavorite(id) }
            if case .album(let id) = route, let index = albums.firstIndex(where: { $0.id == id }) {
                albums[index].isFavorite.toggle()
            }
        }
        actions.togglePin = { [weak self] route in
            guard let self else { return }
            if pinnedRoutes.contains(route) { pinnedRoutes.removeAll { $0 == route } }
            else { pinnedRoutes.append(route) }
        }
        actions.addToPlaylist = { [weak self] _ in self?.lastAction = "已记录添加到播放列表请求" }
        actions.notify = { [weak self] in self?.lastAction = $0.title }
        actions.isDownloaded = { [weak self] route in self?.downloads.isDownloaded(self?.songs(for: route) ?? []) == true }
        actions.download = { [weak self] route in self?.downloads.download(self?.songs(for: route) ?? []) }
        actions.canDownload = { _ in true }
        actions.canRemoveDownload = { [weak self] route in
            self?.songs(for: route).contains { self?.downloads.state(of: $0.id) == .downloaded } == true
        }
        actions.removeDownload = { [weak self] route in self?.downloads.requestRemoval(self?.songs(for: route) ?? []) }
        actions.stopDownload = { [weak self] route in self?.downloads.stop(self?.songs(for: route) ?? []) }
        actions.downloads = downloads
        return actions
    }

    var songActions: SongMenuActions {
        var actions = SongMenuActions()
        actions.downloads = downloads
        actions.play = { [weak self] songs, index, _ in
            guard songs.indices.contains(index) else { return }
            self?.recordPlay(songs[index])
        }
        actions.playNext = { [weak self] song in self?.lastAction = "已记录插播：\(song.title)" }
        actions.playLater = { [weak self] song in self?.lastAction = "已记录加入队列：\(song.title)" }
        actions.toggleFavorite = { [weak self] song in
            guard let self, let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
            songs[index].isFavorite.toggle()
        }
        actions.addToPlaylist = { [weak self] song in self?.lastAction = "已记录添加歌曲：\(song.title)" }
        actions.notify = { [weak self] in self?.lastAction = $0.title }
        return actions
    }

    static func argument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func makeSongs(_ albums: [LibraryShelfItem]) -> [LibrarySongItem] {
        albums.enumerated().flatMap { albumIndex, album in
            let titles = ["停止按钮核验曲目", "重试按钮核验曲目", "等待 Wi-Fi 的曲目", "已下载的曲目",
                          "走过长长的街道和所有尚未结束的故事之后，仍然想听见你的声音",
                          "A Very Long Song Title About the Last Streetlight and the First Train Home"]
            return titles.enumerated().map { index, title in
                LibrarySongItem(id: "netease:0:\(900_100 + albumIndex * 100 + index)", title: title,
                    artist: album.subtitle ?? "示例艺人", album: album.title, albumArtist: album.subtitle ?? "示例艺人",
                    trackNumber: index + 1, artwork: album.artwork, duration: 240, isFavorite: true,
                    onlineAlbumID: Int64(9001 + albumIndex),
                    artistReferences: [.init(id: "catalog:artist:9001", name: album.subtitle ?? "示例艺人")])
            }
        }
    }
}

#Preview("资料库核验设置") { LibraryAuditSettings(fixture: LibraryAuditFixture()) }
#endif
