import SwiftUI

extension EnvironmentValues {
    @Entry var searchMusicIntegration: SearchMusicIntegration? = nil
    @Entry var artistMusicIntegration: ArtistMusicIntegration? = nil
    @Entry var homeMusicIntegration: HomeMusicIntegration? = nil
}

enum AppTab: Hashable, Identifiable, RawRepresentable {
    case home, library, favorites, playlists, albums, artists, songs, search
    /// 用户自己的歌单。喜爱歌曲仍用固定的 `favorites`。
    case playlist(String)

    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .home: "home"
        case .library: "library"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .search: "search"
        case .playlist(let id): "playlist:\(id)"
        }
    }
    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "library": self = .library
        case "favorites": self = .favorites
        case "playlists": self = .playlists
        case "albums": self = .albums
        case "artists": self = .artists
        case "songs": self = .songs
        case "search": self = .search
        default:
            guard rawValue.hasPrefix("playlist:") else { return nil }
            let id = String(rawValue.dropFirst("playlist:".count))
            guard !id.isEmpty, !id.contains(",") else { return nil }
            self = .playlist(id)
        }
    }
    var title: String {
        switch self {
        case .home: "主页"
        case .library: "资料库"
        case .favorites: "喜爱歌曲"
        case .playlists: "播放列表"
        case .albums: "专辑"
        case .artists: "艺人"
        case .songs: "歌曲"
        case .search: "搜索"
        case .playlist: "播放列表"
        }
    }
    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .library: "music.note.square.stack.fill"
        case .favorites: "star.fill"
        case .playlists, .playlist: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .songs: "music.note"
        case .search: "magnifyingglass"
        }
    }
    var rootRoute: LibraryRoute? {
        switch self {
        case .favorites: .playlist("favorites")
        case .playlists: .category(.playlists)
        case .albums: .category(.albums)
        case .artists: .category(.artists)
        case .songs: .category(.songs)
        case .playlist(let id): .playlist(id)
        case .home, .library, .search: nil
        }
    }
    var isReorderable: Bool {
        if case .search = self { return false }
        return true
    }
    static let defaultOrder: [AppTab] = [.home, .library, .search]
    /// 固定的可排序标签。具体歌单随资料库增减，不在这张表里。搜索固定在末尾。
    static let reorderable: [AppTab] = [.home, .library, .favorites, .playlists, .albums, .artists, .songs]
}

/// 标签栏上的普通歌单。页面由同一套导航持有，避免重复创建。
@MainActor
final class PlaylistTabBridges {
    var items: [String: LibraryDetailNavigation] = [:]
    func bridge(for id: String) -> LibraryDetailNavigation {
        if let existing = items[id] { return existing }
        let created = LibraryDetailNavigation()
        items[id] = created
        return created
    }
}

struct AppTabPlaylist: Equatable, Identifiable {
    let id: String
    var title: String
}

enum AppTabOrder {
    static let storageKey = "appTabOrder.v1"
    static let hiddenKey = "appTabHidden.v1"
    /// 连同固定在末尾的搜索，标签栏最多 5 个。再多系统会变成「更多」。
    static let maxVisible = 4
    static let defaultHidden: Set<AppTab> = [.favorites, .playlists, .albums, .artists, .songs]
    static var defaultRaw: String { raw([.home, .library]) }

    /// 只保留可排序标签。未知项和搜索丢掉，缺的固定标签按默认顺序补上。
    /// 还在资料库里、但顺序里没写过的歌单补在末尾，默认不显示。
    static func resolve(_ raw: String, playlists: [String] = []) -> [AppTab] {
        let allowed = Set(playlists.filter { !$0.isEmpty && !$0.contains(",") })
        var seen = Set<AppTab>()
        var order: [AppTab] = []
        for part in raw.split(separator: ",") {
            guard let tab = AppTab(rawValue: String(part)), tab.isReorderable, seen.insert(tab).inserted else { continue }
            if case .playlist(let id) = tab, !allowed.contains(id) { seen.remove(tab); continue }
            order.append(tab)
        }
        for tab in AppTab.reorderable where seen.insert(tab).inserted { order.append(tab) }
        for id in playlists where !id.isEmpty && !id.contains(",") && seen.insert(.playlist(id)).inserted {
            order.append(.playlist(id))
        }
        return order
    }

    /// 没保存过时，资料库分类先不挂到标签栏。保存过（包括全部显示时的空串）就以保存的为准。
    static func hidden(from stored: String?) -> Set<AppTab> {
        guard let stored else { return defaultHidden }
        return Set(stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }.filter(\.isReorderable))
    }

    /// 用户藏起来的，还没加入过顺序的歌单，再加上超出上限、排在后面的。
    static func effectiveHidden(order: String, hidden: String?, playlists: [String] = []) -> Set<AppTab> {
        var hidden = self.hidden(from: hidden)
        let mentioned = Set(order.split(separator: ",").compactMap { AppTab(rawValue: String($0)) })
        let resolved = resolve(order, playlists: playlists)
        for tab in resolved {
            if case .playlist = tab, !mentioned.contains(tab) { hidden.insert(tab) }
        }
        let overflow = resolved.filter { !hidden.contains($0) }.dropFirst(maxVisible)
        return hidden.union(overflow)
    }

    static func visible(order: String, hidden: String?, playlists: [String] = []) -> [AppTab] {
        let hidden = effectiveHidden(order: order, hidden: hidden, playlists: playlists)
        let visible = resolve(order, playlists: playlists).filter { !hidden.contains($0) }
        return visible.isEmpty ? [.library] : visible
    }

    /// 标签栏实际顺序：显示中的在前，搜索固定在末尾。
    static func displayed(order raw: String, hidden: String? = nil, playlists: [String] = []) -> [AppTab] {
        visible(order: raw, hidden: hidden, playlists: playlists) + [.search]
    }

    static func raw(_ tabs: some Sequence<AppTab>) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }
}

/// 根标签栏与迷你播放条。显示哪些标签、以及它们的顺序，由账户页里的标签页设置决定。
struct AppShell<Library: View>: View {
    @ViewBuilder var library: Library
    let detailDestination: (LibraryRoute) -> AnyView
    let nowPlaying: NowPlayingModel?
    let playlistLibrary: PlaylistLibrary
    let toasts: LibraryToastCenter
    /// 全屏播放页；迷你播放条与业务只通过 `isPlayerPresented` 打开或关闭它，转场实现可单独替换。
    let referencePlayer: ReferencePlayerState
    let referenceLibrary: ReferenceLibrary
    let makePlayerActions: (@escaping (LibraryRoute) -> Void, (() -> Void)?) -> ReferencePlayerActions
    var isInitialContentReady = true
    var searchContent: AnyView? = nil
    var searchDestination: ((LibraryRoute) -> AnyView)? = nil
    @State private var pendingRoute: LibraryRoute?
    @State var selection = AppTab.library
    @State var libraryPath: [LibraryRoute] = []
    @State var isPlayerPresented = false
    @State private var showsAudioQualitySettings = false
    @State private var detailNavigation = LibraryDetailNavigation()
    @State private var homeNavigation = LibraryDetailNavigation()
    @State private var searchNavigation = LibraryDetailNavigation()
    @State private var favoritesNavigation = LibraryDetailNavigation()
    @State private var playlistsNavigation = LibraryDetailNavigation()
    @State private var albumsNavigation = LibraryDetailNavigation()
    @State private var artistsNavigation = LibraryDetailNavigation()
    @State private var songsNavigation = LibraryDetailNavigation()
    @State private var playlistBridges = PlaylistTabBridges()
    @State private var emptyHome = HomeContentModel()
    @Environment(\.homeMusicIntegration) private var home
    @Environment(\.artistMusicIntegration) private var artists
    @Environment(\.searchMusicIntegration) private var search
    @Environment(NeteaseAccount.self) private var account
    @AppStorage(AppTabOrder.storageKey) private var rawTabOrder = AppTabOrder.defaultRaw
    @AppStorage(AppTabOrder.hiddenKey) private var rawHiddenTabs: String?
    private var playlistTabItems: [AppTabPlaylist] {
        playlistLibrary.playlists.compactMap { item in
            guard !item.isSystem, !item.isDownloadedSnapshot, !item.id.isEmpty, !item.id.contains(",") else { return nil }
            return AppTabPlaylist(id: item.id, title: item.title)
        }
    }
    private var visibleTabOrder: [AppTab] {
        AppTabOrder.displayed(order: rawTabOrder, hidden: rawHiddenTabs, playlists: playlistTabItems.map(\.id))
    }
    private var chromeColorScheme: ColorScheme? {
        switch selection {
        case .home: homeNavigation.colorScheme
        case .library: detailNavigation.colorScheme
        case .search: searchNavigation.colorScheme
        case .favorites: favoritesNavigation.colorScheme
        case .playlists: playlistsNavigation.colorScheme
        case .albums: albumsNavigation.colorScheme
        case .artists: artistsNavigation.colorScheme
        case .songs: songsNavigation.colorScheme
        case .playlist(let id): playlistBridges.items[id]?.colorScheme
        }
    }

    var body: some View {
        LibraryAppTabs(selection: $selection, tabOrder: visibleTabOrder, navigation: detailNavigation,
            library: library.libraryToasts(toasts).playlistDeletionConfirmation(playlistLibrary),
            destination: { AnyView((artists?.destination($0) ?? detailDestination($0)).libraryToasts(toasts)) },
            initialPath: libraryPath, colorScheme: chromeColorScheme,
            homeNavigation: homeNavigation,
            homeContent: AnyView(HomeFeedView(model: home?.model ?? emptyHome).libraryToasts(toasts)),
            homeDestination: { AnyView((artists?.destination($0) ?? home?.destination(for: $0) ?? detailDestination($0)).libraryToasts(toasts)) },
            searchNavigation: searchNavigation, searchContent: effectiveSearchContent, searchDestination: searchDestination ?? searchDetail,
            sectionNavigation: sectionBridge, playlistTabs: playlistTabItems)
        .onChange(of: playlistTabItems.map(\.id)) { _, ids in
            let live = Set(ids)
            for id in playlistBridges.items.keys where !live.contains(id) { playlistBridges.items[id] = nil }
        }
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { home?.showsLogin == true }, set: { home?.showsLogin = $0 }),
               onDismiss: { home?.loginDismissed() }) {
            AccountPage(account: account, initialRoute: .login)
        }
        .sheet(isPresented: Binding(get: { artists?.showsLogin == true }, set: { artists?.showsLogin = $0 })) {
            AccountPage(account: account, initialRoute: .login)
        }
        .sheet(isPresented: Binding(get: { search?.showsLogin == true }, set: { search?.showsLogin = $0 })) {
            AccountPage(account: account, initialRoute: .login)
        }
        .sheet(isPresented: $showsAudioQualitySettings) {
            if let music = account.music {
                NavigationStack {
                    MusicQualitySettingsPage(music: music, downloads: account.downloads)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("关闭", systemImage: "xmark", role: .close) {
                                    showsAudioQualitySettings = false
                                }
                            }
                        }
                }
                .environment(\.songRowPlayback, nowPlaying)
            }
        }
        .onChange(of: account.profile?.userID) { _, id in
            if id != nil { home?.resumePendingPlayback() }
        }
        .onChange(of: selection) { _, tab in
            if tab != .home { home?.cancelPendingPlayback() }
        }
        .libraryToastFeedback(toasts)
        .addToPlaylistSheet(playlistLibrary, toasts: toasts)
        .moveToFolderSheet(playlistLibrary)
        .modifier(ClearQueueConfirmation(player: nowPlaying))
        .modifier(PlayerPopup(isPresented: $isPlayerPresented, isSuppressed: !isInitialContentReady,
                              onClose: finishPlayerNavigation, barColorScheme: chromeColorScheme))
        .environment(referencePlayer)
        .environment(referenceLibrary)
        .environment(makePlayerActions({ route in
            if isPlayerPresented {
                pendingRoute = route
                isPlayerPresented = false
            } else {
                openInCurrentTab(route)
            }
        }, account.music == nil ? nil : { showsAudioQualitySettings = true }))
        .onChange(of: playlistLibrary.pendingAddition != nil) { _, pending in
            if pending { isPlayerPresented = false }
        }
        .alert("无法播放", isPresented: Binding(get: { nowPlaying?.errorMessage != nil }, set: {
            if !$0 { nowPlaying?.errorMessage = nil }
        })) {
            Button("好", role: .cancel) { nowPlaying?.errorMessage = nil }
        } message: { Text(nowPlaying?.errorMessage ?? "") }

    }
    private var effectiveSearchContent: AnyView? {
        if let searchContent { return searchContent }
        guard let search else { return nil }
        return AnyView(SearchPageView(model: search.model).environment(\.songMenuActions, search.songActions).libraryToasts(toasts))
    }
    private func searchDetail(_ route: LibraryRoute) -> AnyView {
        if case .playlistFolder(let key) = route, key.hasPrefix("search-category:"), let search {
            return AnyView(SearchCategoryPage(model: search.model, category: String(key.dropFirst("search-category:".count))).libraryToasts(toasts))
        }
        return AnyView((artists?.destination(route) ?? home?.destination(for: route) ?? detailDestination(route)).libraryToasts(toasts))
    }
    private func sectionBridge(_ tab: AppTab) -> LibraryDetailNavigation {
        switch tab {
        case .favorites: favoritesNavigation
        case .playlists: playlistsNavigation
        case .albums: albumsNavigation
        case .artists: artistsNavigation
        case .songs: songsNavigation
        case .playlist(let id): playlistBridges.bridge(for: id)
        case .home: homeNavigation
        case .search: searchNavigation
        case .library: detailNavigation
        }
    }
    private func openInCurrentTab(_ route: LibraryRoute) {
        switch selection {
        case .home: homeNavigation.open(route)
        case .search:
            if effectiveSearchContent != nil { searchNavigation.open(route) }
            else { selection = .library; detailNavigation.open(route) }
        case .library: detailNavigation.open(route)
        case .favorites, .playlists, .albums, .artists, .songs, .playlist: sectionBridge(selection).open(route)
        }
    }
    private func finishPlayerNavigation() {
        isPlayerPresented = false
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        openInCurrentTab(route)
    }

}

struct PlaceholderTab: View {
    let title: LocalizedStringKey

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("本阶段暂未开放。"))
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar { AccountToolbar() }
        }
    }
}

/// 整组播放会清除手动加入的队列时的确认。居中提示，只有一句说明。
private struct ClearQueueConfirmation: ViewModifier {
    let player: NowPlayingModel?

    func body(content: Content) -> some View {
        content.alert("", isPresented: Binding(
            get: { player?.pendingPlay != nil },
            set: { if !$0 { player?.pendingPlay = nil } }
        )) {
            Button("清除队列", role: .destructive) { player?.confirmPendingPlay() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("播放此项目将清除队列。")
        }
    }
}
