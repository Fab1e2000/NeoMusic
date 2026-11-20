import SwiftUI

@main
struct NeoMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadBackgroundDelegate.self) private var downloadDelegate
    @State private var runtime: AppRuntime
    @Environment(\.scenePhase) private var scenePhase

    private var account: NeteaseAccount { runtime.account }
    private var onlineLibrary: OnlineLibraryIntegration { runtime.onlineLibrary }
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
        if !DebugLaunchRouter.isPreviewLaunch { runtime.start() }
        #else
        runtime.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DebugLaunchRouter.isPreviewLaunch {
                DebugLaunchRouter.previewRoot(account: account)
            } else {
                libraryApp
            }
            #else
            libraryApp
            #endif
        }
        .onChange(of: account.restoredPlaybackIdentity) { _, _ in runtime.completeRestoredPlayback() }
        .onChange(of: account.profile?.userID) { _, _ in
            if runtime.startupTask != nil { runtime.downloads.scheduleMetadataPublication() }
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
            .environment(\.artworkLoadAction, ArtworkLoadAction(
                handler: { id in runtime.requestArtwork(for: id) },
                resolve: { id in await home.cachedArtworkFile(for: id) }
            ))
    }
}
