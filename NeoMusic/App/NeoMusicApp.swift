import SwiftUI

@main
struct NeoMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadBackgroundDelegate.self) private var downloadDelegate
    @State private var runtime: AppRuntime
    @Environment(\.scenePhase) private var scenePhase

    private var account: NeteaseAccount { runtime.account }
    private var integration: OnlineMusicIntegration { runtime.integration }
    private var artists: ArtistMusicIntegration { runtime.artists }
    private var home: HomeMusicIntegration { runtime.home }
    private var search: SearchMusicIntegration { runtime.search }

    init() {
        let interval = PerformanceDiagnostics.begin("AppInitialization")
        defer { PerformanceDiagnostics.end("AppInitialization", interval) }
        Task.detached(priority: .userInitiated) {
            let preparation = PerformanceDiagnostics.begin("ImageCachePreparation")
            defer { PerformanceDiagnostics.end("ImageCachePreparation", preparation) }
            ArtworkImagePipeline.configureMemoryCache()
        }
        let runtime = AppRuntime()
        _runtime = State(initialValue: runtime)
        #if DEBUG
        if !isPreviewLaunch { runtime.start() }
        #else
        runtime.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-frontendReviewPreview") {
                FrontendReviewPreview().environment(account)
            } else if ProcessInfo.processInfo.arguments.contains("-searchPreview") {
                SearchPreviewRoot().environment(account)
            } else if ProcessInfo.processInfo.arguments.contains("-downloadsPreview") {
                DownloadsPreview()
            } else if ProcessInfo.processInfo.arguments.contains("-homeFeedPreview") {
                HomeFeedPreview().environment(account)
            } else if ProcessInfo.processInfo.arguments.contains("-artistPagePreview") {
                ArtistPagePreview()
            } else if let mode = homePreviewMode {
                HomeRecommendationPreview(mode: mode)
                    .environment(account)
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("-assessmentReadProbe") {
                            await NeteaseAssessmentReadProbe.run()
                        } else if ProcessInfo.processInfo.arguments.contains("-homeReadProbe") {
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
        .onChange(of: account.restoredPlaybackIdentity) { _, _ in runtime.completeRestoredPlayback() }
        .onChange(of: account.profile?.userID) { _, _ in
            if runtime.startupTask != nil { runtime.downloads.publishMetadata() }
        }
        .onChange(of: LocalLibrary.runtime.hasRestoredPlayback) { _, _ in runtime.completeRestoredPlayback() }
        .onChange(of: LocalLibrary.player.hasCurrent) { _, _ in runtime.completeRestoredPlayback() }
        .onChange(of: scenePhase) { previous, phase in runtime.sceneDidChange(from: previous, to: phase) }
    }

    private var libraryApp: some View {
        LocalLibrary.app
            .downloadRemovalConfirmation()
            .environment(\.libraryDownloads, LocalLibrary.downloads)
            .environment(account)
            .environment(\.homeMusicIntegration, home)
            .environment(\.artistMusicIntegration, artists)
            .environment(\.searchMusicIntegration, search)
            .environment(\.artworkLoadAction, ArtworkLoadAction { id in
                home.requestArtwork(for: id)
                artists.requestArtwork(for: id)
                integration.requestArtwork(for: id)
                search.requestArtwork(for: id)
            })
    }

    #if DEBUG
    private var isPreviewLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let directPreviews = ["-frontendReviewPreview", "-searchPreview", "-downloadsPreview", "-homeFeedPreview", "-artistPagePreview"]
        return directPreviews.contains(where: arguments.contains) || homePreviewMode != nil ||
            onlinePreviewPage != nil || accountPreviewState != nil
    }

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
