import SwiftUI

@main
struct NeoMusicApp: App {
    @State private var account: NeteaseAccount
    @State private var integration: OnlineMusicIntegration
    @State private var home: HomeMusicIntegration
    init() {
        ArtworkImagePipeline.configureMemoryCache()
        let account = NeteaseAccount(client: NeteaseAccountClient(), credentialStore: NeteaseCredentialStore(),
                                     avatarClient: NeteaseAvatarClient())
        _account = State(initialValue: account)
        _integration = State(initialValue: OnlineMusicIntegration(account: account))
        _home = State(initialValue: HomeMusicIntegration(account: account))
    }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let mode = homePreviewMode {
                HomeRecommendationPreview(mode: mode)
                    .environment(account)
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("-homeReadProbe") {
                            await NeteaseHomeReadProbe.run()
                        }
                    }
            } else if let page = onlinePreviewPage {
                if page == "quality" {
                    OnlineLibraryPreviewRoot()
                } else {
                    OnlineLibraryShellPreview(initialPage: page).environment(account)
                }
            } else if let state = accountPreviewState {
                AccountPreviewRoot(state: state)
            } else {
                libraryApp
            }
            #else
            libraryApp
            #endif
        }
    }

    private var libraryApp: some View {
        LocalLibrary.app
            .environment(account)
            .environment(\.homeMusicIntegration, home)
            .task {
                home.connect()
                integration.connect()
                await integration.connectLyrics()
                async let local: Void = LocalLibrary.runtime.refresh()
                async let online: Void = account.restore()
                _ = await (local, online)
            }
            .onChange(of: scenePhase) { previous, phase in
                // Initial activation is already covered by the task above.
                if previous == .background, phase != .background {
                    Task { await LocalLibrary.runtime.refresh() }
                    Task { await account.revalidate() }
                }
            }
    }

    #if DEBUG
    private var homePreviewMode: HomeRecommendationPreview.Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-homeRecommendationPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        return HomeRecommendationPreview.Mode(rawValue: arguments[index + 1])
    }

    private var onlinePreviewPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-onlineLibraryPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        let page = arguments[index + 1]
        return ["playlists", "favorites", "detail", "queue", "quality"].contains(page) ? page : nil
    }

    private var accountPreviewState: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-neteaseAccountPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        let state = arguments[index + 1]
        return ["signed-out", "signed-in", "settings"].contains(state) ? state : nil
    }
    #endif
}
