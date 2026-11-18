import SwiftUI

/// Owns application-wide connections and restoration independently of page mounting.
@MainActor
final class AppRuntime {
    let account: NeteaseAccount
    let onlineLibrary: OnlineLibraryIntegration
    var integration: OnlineLibraryIntegration { onlineLibrary }
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
        onlineLibrary = OnlineLibraryIntegration(account: account)
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
            onlineLibrary.onPublication = { [weak self] in self?.downloads.scheduleMetadataPublication() }
            await downloads.restore()
            search.prepareNavigation = { [weak self] in self?.home.prepareNavigation($0) }
            search.onPublication = { [weak self] in self?.downloads.scheduleMetadataPublication() }
            search.connect()
            home.connect()
            artists.connect()
            onlineLibrary.connect()
            await onlineLibrary.connectLyrics()
            #if DEBUG
            await DebugLaunchRouter.runArtistReadProbeIfNeeded()
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
                DebugLaunchRouter.runPostRestoreReadProbesIfNeeded(account: account)
                #endif
            }
            async let scan: Void = LocalLibrary.runtime.refresh()
            async let validation: Void = restoreRemainingOnlineContent()
            async let artwork: Void = prepareInitialOnlineArtwork()
            _ = await (scan, validation, history, artwork)
        }
    }

    func requestArtwork(for id: String) {
        switch DeferredArtworkKey(rawValue: id)?.domain {
        case .music:
            onlineLibrary.requestArtwork(for: id)
        case .home, .homePlaylist:
            home.requestArtwork(for: id)
        case .artists:
            artists.requestArtwork(for: id)
        case .search:
            search.requestArtwork(for: id)
        case nil:
            home.requestArtwork(for: id)
            artists.requestArtwork(for: id)
            onlineLibrary.requestArtwork(for: id)
            search.requestArtwork(for: id)
        }
    }

    func cachedArtworkFile(for id: String) async -> URL? {
        switch DeferredArtworkKey(rawValue: id)?.domain {
        case .music:
            return await onlineLibrary.cachedArtworkFile(for: id)
        case .home, .homePlaylist:
            return await home.cachedArtworkFile(for: id)
        case .artists:
            return await artists.cachedArtworkFile(for: id)
        case .search:
            return nil
        case nil:
            if let found = await onlineLibrary.cachedArtworkFile(for: id) { return found }
            if let found = await artists.cachedArtworkFile(for: id) { return found }
            return await home.cachedArtworkFile(for: id)
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
            guard let file = await cachedArtworkFile(for: id), !Task.isCancelled else { continue }
            _ = await LocalArtworkImages.load(file, pixels: 512)
            guard !Task.isCancelled else { return }
            requestArtwork(for: id)
        }
    }

    private func restoreRemainingOnlineContent() async {
        await account.restoreHomeCachedContent()
        guard !Task.isCancelled else { return }
        await onlineLibrary.restoreReferencedMetadata()
        guard !Task.isCancelled else { return }
        await account.revalidate()
    }

}
