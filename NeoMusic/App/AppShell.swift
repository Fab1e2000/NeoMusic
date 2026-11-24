import FullScreenPlayer
import SwiftUI

extension EnvironmentValues {
    @Entry var searchMusicIntegration: SearchMusicIntegration? = nil
    @Entry var artistMusicIntegration: ArtistMusicIntegration? = nil
    @Entry var homeMusicIntegration: HomeMusicIntegration? = nil
}

enum AppTab: Hashable, Identifiable, RawRepresentable {
    case home, library, favorites, playlists, albums, artists, songs, search
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
    static let reorderable: [AppTab] = [.home, .library, .favorites, .playlists, .albums, .artists, .songs]
}

@MainActor
final class AppTabNavigationRegistry {
    private(set) var tabNavigations: [AppTab: LibraryDetailNavigation] = {
        var map: [AppTab: LibraryDetailNavigation] = [:]
        for tab in [AppTab.home, .library, .search, .favorites, .playlists, .albums, .artists, .songs] {
            map[tab] = LibraryDetailNavigation()
        }
        return map
    }()

    var items: [String: LibraryDetailNavigation] {
        get {
            var result: [String: LibraryDetailNavigation] = [:]
            for (tab, nav) in tabNavigations {
                if case .playlist(let id) = tab { result[id] = nav }
            }
            return result
        }
        set {
            tabNavigations = tabNavigations.filter {
                if case .playlist = $0.key { return false }
                return true
            }
            for (id, nav) in newValue {
                tabNavigations[.playlist(id)] = nav
            }
        }
    }

    func navigation(for tab: AppTab) -> LibraryDetailNavigation {
        if let existing = tabNavigations[tab] { return existing }
        let created = LibraryDetailNavigation()
        tabNavigations[tab] = created
        return created
    }

    func bridge(for id: String) -> LibraryDetailNavigation {
        navigation(for: .playlist(id))
    }

    func colorScheme(for tab: AppTab) -> ColorScheme? {
        tabNavigations[tab]?.displayedChrome?.colorScheme
    }

    func prunePlaylists(keeping liveIDs: Set<String>) {
        for key in tabNavigations.keys {
            if case .playlist(let id) = key, !liveIDs.contains(id) {
                tabNavigations[key] = nil
            }
        }
    }
}

typealias PlaylistTabBridges = AppTabNavigationRegistry

struct AppTabPlaylist: Equatable, Identifiable {
    let id: String
    var title: String
}

enum AppTabOrder {
    static let storageKey = AppDefaultsKey.appTabOrder
    static let hiddenKey = AppDefaultsKey.appTabHidden
    static let maxVisible = 4
    static let defaultHidden: Set<AppTab> = [.favorites, .playlists, .albums, .artists, .songs]
    static var defaultRaw: String { raw([.home, .library]) }

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

    static func hidden(from stored: String?) -> Set<AppTab> {
        guard let stored else { return defaultHidden }
        return Set(stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }.filter(\.isReorderable))
    }

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

    static func displayed(order raw: String, hidden: String? = nil, playlists: [String] = []) -> [AppTab] {
        visible(order: raw, hidden: hidden, playlists: playlists) + [.search]
    }

    static func raw(_ tabs: some Sequence<AppTab>) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }
}

struct PlayerNavigationHandoff {
    private var route: LibraryRoute?
    private var isClosing = false

    mutating func begin(_ route: LibraryRoute) -> Bool {
        if isClosing, self.route == route { return false }
        self.route = route
        isClosing = true
        return true
    }

    mutating func didFinishClosing() {
        isClosing = false
        route = nil
    }

    mutating func didBeginPresentation() {
        didFinishClosing()
    }
}

struct AppShell<Library: View>: View {
    @ViewBuilder var library: Library
    let detailDestination: (LibraryRoute) -> AnyView
    let nowPlaying: NowPlayingModel?
    let playlistLibrary: PlaylistLibrary
    let toasts: LibraryToastCenter
    let referencePlayer: PlayerState
    let referenceLibrary: ReferenceLibrary
    let makePlayerActions: (@escaping (LibraryRoute, LibraryNavigationPreview?) -> Void, (() -> Void)?) -> PlayerActions
    var isInitialContentReady = true
    var searchContent: AnyView? = nil
    var searchDestination: ((LibraryRoute) -> AnyView)? = nil
    @State private var playerNavigation = PlayerNavigationHandoff()
    @State var selection = AppTab.library
    @State var libraryPath: [LibraryRoute] = []
    @State var isPlayerPresented = false
    @State private var showsAudioQualitySettings = false
    @State private var loginIncludesHome = false
    @State private var tabNavigations = AppTabNavigationRegistry()
    @State private var emptyHome = HomeContentModel()
    @Environment(\.homeMusicIntegration) private var home
    @Environment(\.artistMusicIntegration) private var artists
    @Environment(\.searchMusicIntegration) private var search
    @Environment(NeteaseAccount.self) private var account
    @AppStorage(AppTabOrder.storageKey) private var rawTabOrder = AppTabOrder.defaultRaw
    @AppStorage(AppTabOrder.hiddenKey) private var rawHiddenTabs: String?
    private var detailNavigation: LibraryDetailNavigation { tabNavigations.navigation(for: .library) }
    private var homeNavigation: LibraryDetailNavigation { tabNavigations.navigation(for: .home) }
    private var searchNavigation: LibraryDetailNavigation { tabNavigations.navigation(for: .search) }
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
        tabNavigations.colorScheme(for: selection)
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
            tabNavigations.prunePlaylists(keeping: Set(ids))
        }
        .ignoresSafeArea()
        .onChange(of: home?.showsLogin == true, initial: true) { _, requested in
            if requested { loginIncludesHome = true }
        }
        .sheet(isPresented: loginPresentation, onDismiss: finishLoginPresentation) {
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
                              onClose: finishPlayerNavigation, barColorScheme: chromeColorScheme,
                              toasts: toasts))
        .environment(referencePlayer)
        .environment(referenceLibrary)
        .environment(playlistLibrary)
        .environment(makePlayerActions({ route, preview in
            startPlayerNavigation(route, preview: preview)
        }, account.music == nil ? nil : { showsAudioQualitySettings = true }))
        .onChange(of: isPlayerPresented) { _, presented in
            if presented { playerNavigation.didBeginPresentation() }
        }
        .onChange(of: playlistLibrary.pendingAddition != nil) { _, pending in
            if pending { isPlayerPresented = false }
        }
        .alert("无法播放", isPresented: Binding(get: { nowPlaying?.errorMessage != nil }, set: {
            if !$0 { nowPlaying?.errorMessage = nil }
        })) {
            Button("好", role: .cancel) { nowPlaying?.errorMessage = nil }
        } message: { Text(nowPlaying?.errorMessage ?? "") }

    }

    private var loginPresentation: Binding<Bool> {
        Binding(get: {
            home?.showsLogin == true || artists?.showsLogin == true || search?.showsLogin == true
        }, set: { presented in
            guard !presented else { return }
            if home?.showsLogin == true { loginIncludesHome = true }
            home?.showsLogin = false
            artists?.showsLogin = false
            search?.showsLogin = false
        })
    }

    private func finishLoginPresentation() {
        if loginIncludesHome { home?.loginDismissed() }
        loginIncludesHome = home?.showsLogin == true
    }

    private var effectiveSearchContent: AnyView? {
        if let searchContent { return searchContent }
        guard let search else { return nil }
        return AnyView(SearchPageView(model: search.model).environment(\.songMenuActions, search.songActions).libraryToasts(toasts))
    }
    private func searchDetail(_ route: LibraryRoute) -> AnyView {
        if case .searchCategory(let category) = route, let search {
            return AnyView(SearchCategoryPage(model: search.model, category: category).libraryToasts(toasts))
        }
        if case .playlistFolder(let key) = route, key.hasPrefix("search-category:"), let search {
            return AnyView(SearchCategoryPage(model: search.model, category: String(key.dropFirst("search-category:".count))).libraryToasts(toasts))
        }
        return AnyView((artists?.destination(route) ?? home?.destination(for: route) ?? detailDestination(route)).libraryToasts(toasts))
    }
    private func sectionBridge(_ tab: AppTab) -> LibraryDetailNavigation {
        tabNavigations.navigation(for: tab)
    }
    private var currentNavigation: LibraryDetailNavigation {
        switch selection {
        case .home: return homeNavigation
        case .search: return effectiveSearchContent != nil ? searchNavigation : detailNavigation
        case .library: return detailNavigation
        case .favorites, .playlists, .albums, .artists, .songs, .playlist: return sectionBridge(selection)
        }
    }
    private func openInCurrentTab(_ route: LibraryRoute, preview: LibraryNavigationPreview?) {
        if selection == .search, effectiveSearchContent == nil {
            selection = .library
            detailNavigation.open(route, preview: preview)
            return
        }
        tabNavigations.navigation(for: selection).open(route, preview: preview)
    }
    private func startPlayerNavigation(_ route: LibraryRoute, preview: LibraryNavigationPreview?) {
        guard playerNavigation.begin(route) else { return }
        if currentNavigation.topRoute != route { openInCurrentTab(route, preview: preview) }
        isPlayerPresented = false
    }
    private func finishPlayerNavigation() {
        playerNavigation.didFinishClosing()
        isPlayerPresented = false
    }

}

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
