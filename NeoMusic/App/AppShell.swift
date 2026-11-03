import SwiftUI

extension EnvironmentValues {
    @Entry var artistMusicIntegration: ArtistMusicIntegration? = nil
    @Entry var homeMusicIntegration: HomeMusicIntegration? = nil
}

enum AppTab: String, Hashable {
    case home, discover, radio, library, search
}

/// 根标签栏与迷你播放条，包含资料库和主页展示；其余标签暂为占位页。
struct AppShell<Library: View>: View {
    @ViewBuilder var library: Library
    let detailDestination: (LibraryRoute) -> AnyView
    let nowPlaying: NowPlayingModel?
    let playlistLibrary: PlaylistLibrary
    let toasts: LibraryToastCenter
    /// 全屏播放页；迷你播放条与业务只通过 `isPlayerPresented` 打开或关闭它，转场实现可单独替换。
    let referencePlayer: ReferencePlayerState
    let referenceLibrary: ReferenceLibrary
    let makePlayerActions: (@escaping (LibraryRoute) -> Void) -> ReferencePlayerActions
    @State private var pendingRoute: LibraryRoute?
    @State private var selection = AppTab.library
    @State var libraryPath: [LibraryRoute] = []
    @State var isPlayerPresented = false
    @State private var detailNavigation = LibraryDetailNavigation()
    @State private var homeNavigation = LibraryDetailNavigation()
    @State private var emptyHome = HomeContentModel()
    @Environment(\.homeMusicIntegration) private var home
    @Environment(\.artistMusicIntegration) private var artists
    @Environment(NeteaseAccount.self) private var account
    private var chromeColorScheme: ColorScheme? {
        switch selection {
        case .home: homeNavigation.colorScheme ?? .light
        case .library: detailNavigation.colorScheme
        default: nil
        }
    }

    var body: some View {
        LibraryAppTabs(selection: $selection, navigation: detailNavigation,
            library: library.libraryToasts(toasts).playlistDeletionConfirmation(playlistLibrary),
            destination: { AnyView((artists?.destination($0) ?? detailDestination($0)).libraryToasts(toasts)) },
            initialPath: libraryPath, colorScheme: chromeColorScheme,
            homeNavigation: homeNavigation,
            homeContent: AnyView(HomeFeedView(model: home?.model ?? emptyHome)),
            homeDestination: { artists?.destination($0) ?? home?.destination(for: $0) ?? detailDestination($0) })
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { home?.showsLogin == true }, set: { home?.showsLogin = $0 }),
               onDismiss: { home?.loginDismissed() }) {
            AccountPage(account: account, initialRoute: .login)
        }
        .sheet(isPresented: Binding(get: { artists?.showsLogin == true }, set: { artists?.showsLogin = $0 })) {
            AccountPage(account: account, initialRoute: .login)
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
        .modifier(PlayerPopup(isPresented: $isPlayerPresented, isSuppressed: false,
                              onClose: finishPlayerNavigation, barColorScheme: chromeColorScheme))
        .environment(referencePlayer)
        .environment(referenceLibrary)
        .environment(makePlayerActions { route in
            if isPlayerPresented {
                pendingRoute = route
                isPlayerPresented = false
            } else {
                openInCurrentTab(route)
            }
        })
        .onChange(of: playlistLibrary.pendingAddition != nil) { _, pending in
            if pending { isPlayerPresented = false }
        }
        .alert("无法播放", isPresented: Binding(get: { nowPlaying?.errorMessage != nil }, set: {
            if !$0 { nowPlaying?.errorMessage = nil }
        })) {
            Button("好", role: .cancel) { nowPlaying?.errorMessage = nil }
        } message: { Text(nowPlaying?.errorMessage ?? "") }

    }
    private func openInCurrentTab(_ route: LibraryRoute) {
        if selection == .home { homeNavigation.open(route) }
        else { selection = .library; detailNavigation.open(route) }
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

/// 整组播放会清除手动加入的队列时的确认，对照 Apple Music：只有一句说明，取消与红色“清除队列”并排。
private struct ClearQueueConfirmation: ViewModifier {
    let player: NowPlayingModel?

    func body(content: Content) -> some View {
        content.alert("播放此项目将清除队列。", isPresented: Binding(
            get: { player?.pendingPlay != nil },
            set: { if !$0 { player?.pendingPlay = nil } }
        )) {
            Button("取消", role: .cancel) {}
            Button("清除队列", role: .destructive) { player?.confirmPendingPlay() }
        }
    }
}
