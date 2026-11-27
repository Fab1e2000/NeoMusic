import FrontAMNavigation
import FrontAMPlayer
import SwiftUI

extension EnvironmentValues {
    @Entry var searchMusicIntegration: SearchMusicIntegration? = nil
    @Entry var artistMusicIntegration: ArtistMusicIntegration? = nil
    @Entry var homeMusicIntegration: HomeMusicIntegration? = nil
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
        FrontAMShell(isPlayerPresented: $isPlayerPresented, currentRoute: { currentNavigation.topRoute },
                     openInCurrentTab: openInCurrentTab) { openFromPlayer, popupClosed in
            LibraryAppTabs(selection: $selection, tabOrder: visibleTabOrder, navigation: detailNavigation,
                library: library.libraryToasts(toasts).playlistDeletionConfirmation(playlistLibrary),
                destination: { AnyView((artists?.destination($0) ?? detailDestination($0)).libraryToasts(toasts)) },
                initialPath: libraryPath, colorScheme: chromeColorScheme,
                homeNavigation: homeNavigation,
                homeContent: AnyView(HomeFeedView(model: home?.model ?? emptyHome).libraryToasts(toasts)),
                homeDestination: { AnyView((artists?.destination($0) ?? home?.destination(for: $0) ?? detailDestination($0)).libraryToasts(toasts)) },
                searchNavigation: searchNavigation, searchContent: effectiveSearchContent, searchDestination: searchDestination ?? searchDetail,
                sectionNavigation: tabNavigations.navigation(for:), playlistTabs: playlistTabItems)
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
                                  onClose: popupClosed, barColorScheme: chromeColorScheme,
                                  toasts: toasts))
            .environment(referencePlayer)
            .environment(referenceLibrary)
            .environment(playlistLibrary)
            .environment(makePlayerActions(openFromPlayer,
                account.music == nil ? nil : { showsAudioQualitySettings = true }))
            .onChange(of: playlistLibrary.pendingAddition != nil) { _, pending in
                if pending { isPlayerPresented = false }
            }
            .onChange(of: nowPlaying?.errorMessage != nil, initial: true) { _, showsPlaybackError in
                if showsPlaybackError { LibraryHaptics.error() }
            }
            .alert("无法播放", isPresented: Binding(get: { nowPlaying?.errorMessage != nil }, set: {
                if !$0 { nowPlaying?.errorMessage = nil }
            })) {
                Button("好", role: .cancel) { nowPlaying?.errorMessage = nil }
            } message: { Text(nowPlaying?.errorMessage ?? "") }
        }
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
    private var currentNavigation: LibraryDetailNavigation {
        if selection == .search, effectiveSearchContent == nil { return detailNavigation }
        return tabNavigations.navigation(for: selection)
    }
    private func openInCurrentTab(_ route: LibraryRoute, preview: LibraryNavigationPreview?) {
        if selection == .search, effectiveSearchContent == nil {
            selection = .library
            detailNavigation.open(route, preview: preview)
            return
        }
        tabNavigations.navigation(for: selection).open(route, preview: preview)
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
