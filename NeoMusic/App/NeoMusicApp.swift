import SwiftUI

@main
struct NeoMusicApp: App {
    @UIApplicationDelegateAdaptor(DownloadBackgroundDelegate.self) private var downloadDelegate
    @State private var account: NeteaseAccount
    @State private var integration: OnlineMusicIntegration
    @State private var artists: ArtistMusicIntegration
    @State private var home: HomeMusicIntegration
    @State private var search: SearchMusicIntegration
    @State private var downloads: DownloadMusicIntegration
    init() {
        let interval = PerformanceDiagnostics.begin("AppInitialization")
        defer { PerformanceDiagnostics.end("AppInitialization", interval) }
        Task.detached(priority: .userInitiated) {
            let preparation = PerformanceDiagnostics.begin("ImageCachePreparation")
            defer { PerformanceDiagnostics.end("ImageCachePreparation", preparation) }
            ArtworkImagePipeline.configureMemoryCache()
        }
        let account = NeteaseAccount(client: NeteaseAccountClient(), credentialStore: NeteaseCredentialStore(),
                                     avatarClient: NeteaseAvatarClient())
        _account = State(initialValue: account)
        _integration = State(initialValue: OnlineMusicIntegration(account: account))
        _home = State(initialValue: HomeMusicIntegration(account: account))
        _artists = State(initialValue: ArtistMusicIntegration(account: account))
        _search = State(initialValue: SearchMusicIntegration(account: account))
        let downloads = DownloadMusicIntegration(account: account)
        _downloads = State(initialValue: downloads)
        downloads.connect()
        Task {
            await downloads.restore()
            await account.restoreCachedContent()
        }
    }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-searchPreview") {
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
            .task {
                downloads.requestLogin = { home.showsLogin = true }
                integration.onPublication = { downloads.publishMetadata() }
                await downloads.restore()
                search.prepareNavigation = { home.prepareNavigation($0) }
                search.onPublication = { downloads.publishMetadata() }
                search.connect()
                home.connect()
                artists.connect()
                integration.connect()
                await integration.connectLyrics()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-artistReadProbe") { await NeteaseArtistReadProbe.run() }
                #endif
                async let history: Void = home.restore()
                do {
                    let interval = PerformanceDiagnostics.begin("StartupRestore")
                    defer { PerformanceDiagnostics.end("StartupRestore", interval) }
                    async let local: Void = restoreInitialLibrary()
                    async let online: Void = account.restoreCachedContent()
                    _ = await (local, online)
                    guard !Task.isCancelled else { return }
                    completeRestoredPlayback()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-searchReadProbe") {
                        Task { await NeteaseSearchReadProbe.run(account: account) }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-playbackReadProbe") {
                        Task { await NeteasePlaybackReadProbe.run() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-downloadReadProbe"), let store = account.downloads {
                        Task { await NeteaseDownloadReadProbe.run(store: store) }
                    }
                    #endif
                }
                async let scan: Void = LocalLibrary.runtime.refresh()
                async let validation: Void = restoreRemainingOnlineContent()
                async let artwork: Void = prepareInitialOnlineArtwork()
                _ = await (scan, validation, history, artwork)
            }
            .onChange(of: account.restoredPlaybackIdentity) { _, _ in completeRestoredPlayback() }
            .onChange(of: account.profile?.userID) { _, _ in downloads.publishMetadata() }
            .onChange(of: LocalLibrary.runtime.hasRestoredPlayback) { _, _ in completeRestoredPlayback() }
            .onChange(of: LocalLibrary.player.hasCurrent) { _, _ in completeRestoredPlayback() }
            .onChange(of: scenePhase) { previous, phase in
                if phase == .background {
                    LocalLibrary.player.saveQueueForBackground()
                    LocalLibrary.playlistLibrary.persistRestoredMetadata()
                    home.flushHistoryForBackground()
                }
                // Initial activation is already covered by the task above.
                if previous == .background, phase != .background {
                    Task { await LocalLibrary.runtime.refresh() }
                    Task { await account.revalidate() }
                }
            }
    }

    @MainActor
    private func completeRestoredPlayback() {
        let owner: String?
        switch account.restoredPlaybackIdentity {
        case .pending:
            PerformanceDiagnostics.restoration("player.waitingForIdentity")
            return
        case .signedOut: owner = nil
        case .signedIn(let value): owner = value
        }
        LocalLibrary.runtime.completeInitialPlaybackRestoration(ownerID: owner, songs: LocalLibrary.allSongs)
    }

    @MainActor
    private func restoreInitialLibrary() async {
        await LocalLibrary.runtime.restoreCachedState()
        guard !Task.isCancelled else { return }
        await LocalArtworkImages.prepare(initialLibraryArtwork)
        guard !Task.isCancelled else { return }
        LocalLibrary.runtime.completeInitialPresentation(songs: LocalLibrary.allSongs)
    }

    @MainActor
    private var initialLibraryArtwork: [Artwork] {
        (Array(LocalLibrary.pinned.prefix(6)) + Array(LocalLibrary.recentlyAdded.prefix(4))).map(\.artwork)
    }

    @MainActor
    private func prepareInitialOnlineArtwork() async {
        var ids: [String] = []
        func collect(_ artwork: Artwork) {
            if let id = artwork.loadID, !ids.contains(id), ids.count < 10 { ids.append(id) }
            if case .folder(let children) = artwork { children.prefix(4).forEach(collect) }
        }
        initialLibraryArtwork.forEach(collect)
        for id in ids {
            guard !Task.isCancelled else { return }
            let file: URL?
            if let found = await integration.cachedArtworkFile(for: id) { file = found }
            else if let found = await artists.cachedArtworkFile(for: id) { file = found }
            else { file = await home.cachedArtworkFile(for: id) }
            guard !Task.isCancelled, let file else { continue }
            _ = await LocalArtworkImages.load(file, pixels: 512)
            guard !Task.isCancelled else { return }
            integration.requestArtwork(for: id)
            artists.requestArtwork(for: id)
            home.requestArtwork(for: id)
        }
    }

    @MainActor
    private func restoreRemainingOnlineContent() async {
        await account.restoreHomeCachedContent()
        guard !Task.isCancelled else { return }
        await integration.restoreReferencedMetadata()
        guard !Task.isCancelled else { return }
        await account.revalidate()
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
