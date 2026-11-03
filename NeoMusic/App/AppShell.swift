import SwiftUI

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
    private var chromeColorScheme: ColorScheme? {
        switch selection {
        case .home: .light
        case .library: detailNavigation.colorScheme
        default: nil
        }
    }

    var body: some View {
        LibraryAppTabs(selection: $selection, navigation: detailNavigation,
            library: library.libraryToasts(toasts).playlistDeletionConfirmation(playlistLibrary),
            destination: { AnyView(detailDestination($0).libraryToasts(toasts)) },
            initialPath: libraryPath, colorScheme: chromeColorScheme)
        .ignoresSafeArea()
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
                selection = .library
                detailNavigation.open(route)
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
    private func finishPlayerNavigation() {
        isPlayerPresented = false
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        selection = .library
        detailNavigation.open(route)
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
