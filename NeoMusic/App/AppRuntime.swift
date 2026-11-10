import SwiftUI

/// Owns application-wide connections and restoration independently of page mounting.
@MainActor
final class AppRuntime {
    let account: NeteaseAccount
    let integration: OnlineMusicIntegration
    let artists: ArtistMusicIntegration
    let home: HomeMusicIntegration
    let search: SearchMusicIntegration
    let downloads: DownloadMusicIntegration
    private(set) var restorationTask: Task<Void, Never>?
    private(set) var startupTask: Task<Void, Never>?

    init(account: NeteaseAccount? = nil) {
        let account = account ?? NeteaseAccount(client: NeteaseAccountClient(), credentialStore: NeteaseCredentialStore(),
                                               avatarClient: NeteaseAvatarClient())
        self.account = account
        integration = OnlineMusicIntegration(account: account)
        home = HomeMusicIntegration(account: account)
        artists = ArtistMusicIntegration(account: account)
        search = SearchMusicIntegration(account: account)
        let downloads = DownloadMusicIntegration(account: account)
        self.downloads = downloads
    }

    func start() {
        guard startupTask == nil else { return }
        downloads.connect()
        restorationTask = Task {
            await downloads.restore()
            await account.restoreCachedContent()
        }
        startupTask = Task {
            downloads.requestLogin = { [weak self] in self?.home.showsLogin = true }
            integration.onPublication = { [weak self] in self?.downloads.publishMetadata() }
            await downloads.restore()
            search.prepareNavigation = { [weak self] in self?.home.prepareNavigation($0) }
            search.onPublication = { [weak self] in self?.downloads.publishMetadata() }
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
    }

    func sceneDidChange(from previous: ScenePhase, to phase: ScenePhase) {
        guard startupTask != nil else { return }
        if phase == .background {
            LocalLibrary.player.saveQueueForBackground()
            LocalLibrary.playlistLibrary.saveForBackground()
            home.flushHistoryForBackground()
        }
        if previous == .background, phase != .background {
            Task { await LocalLibrary.runtime.refresh() }
            Task { await account.revalidate() }
        }
    }

    func completeRestoredPlayback() {
        guard startupTask != nil else { return }
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

    private func restoreInitialLibrary() async {
        await LocalLibrary.runtime.restoreCachedState()
        guard !Task.isCancelled else { return }
        await LocalArtworkImages.prepare(initialLibraryArtwork)
        guard !Task.isCancelled else { return }
        LocalLibrary.runtime.completeInitialPresentation(songs: LocalLibrary.allSongs)
    }

    private var initialLibraryArtwork: [Artwork] {
        (Array(LocalLibrary.pinned.prefix(6)) + Array(LocalLibrary.recentlyAdded.prefix(4))).map(\.artwork)
    }

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

    private func restoreRemainingOnlineContent() async {
        await account.restoreHomeCachedContent()
        guard !Task.isCancelled else { return }
        await integration.restoreReferencedMetadata()
        guard !Task.isCancelled else { return }
        await account.revalidate()
    }

}
