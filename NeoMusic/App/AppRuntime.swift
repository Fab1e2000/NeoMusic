import SwiftUI

@MainActor
final class AppRuntime {
    let container: AppContainer
    let account: NeteaseAccount
    let onlineLibrary: OnlineLibraryIntegration
    var integration: OnlineLibraryIntegration { onlineLibrary }
    let artists: ArtistMusicIntegration
    let home: HomeMusicIntegration
    let search: SearchMusicIntegration
    let downloads: DownloadMusicIntegration
    private(set) var startupTask: Task<Void, Never>?

    init(account: NeteaseAccount? = nil, container: AppContainer = .shared) {
        let account = account ?? NeteaseAccount(client: NeteaseAccountClient(), credentialStore: NeteaseCredentialStore(),
                                               avatarClient: NeteaseAvatarClient())
        self.account = account
        self.container = container
        onlineLibrary = OnlineLibraryIntegration(account: account, container: container)
        home = HomeMusicIntegration(account: account, container: container)
        artists = ArtistMusicIntegration(account: account, container: container)
        search = SearchMusicIntegration(account: account, container: container)
        let downloads = DownloadMusicIntegration(account: account, container: container)
        self.downloads = downloads
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task {
            guard !Task.isCancelled else { return }
            downloads.requestLogin = { [weak self] in self?.home.showsLogin = true }
            onlineLibrary.onPublication = { [weak self] in self?.downloads.scheduleMetadataPublication() }
            search.prepareNavigation = { [weak self] in self?.home.prepareNavigation($0) }
            search.onPublication = { [weak self] in self?.downloads.scheduleMetadataPublication() }
            downloads.connect()
            search.connect()
            home.connect()
            artists.connect()
            onlineLibrary.connect()
            await onlineLibrary.connectLyrics()
            do {
                let interval = PerformanceDiagnostics.begin("StartupRestore")
                defer { PerformanceDiagnostics.end("StartupRestore", interval) }
                async let local: Void = restoreInitialLibrary()
                async let online: Void = restoreInitialOnlineContent()
                _ = await (local, online)
                guard !Task.isCancelled else { return }
                completeRestoredPlayback()
            }
            async let scan: Void = container.runtime.refresh()
            async let validation: Void = restoreRemainingOnlineContent()
            async let artwork: Void = prepareInitialOnlineArtwork()
            _ = await (scan, validation, artwork)
        }
    }

    var artworkLoadAction: ArtworkLoadAction {
        ArtworkLoadAction(
            handler: requestArtwork,
            resolve: resolveArtworkFile,
            queueHandler: requestQueueArtwork,
            artistPortraits: artists.libraryPortraits
        )
    }

    func requestArtwork(for id: String) {
        switch DeferredArtworkKey(rawValue: id)?.domain {
        case .music:
            onlineLibrary.requestArtwork(for: id)
        case .home:
            home.requestArtwork(for: id)
        case .artists:
            artists.requestArtwork(for: id)
        case .search:
            search.requestArtwork(for: id)
        case .homePlaylist, nil:
            break
        }
    }

    // Playlist IDs may require a detail fetch to discover their cover URL.
    func resolveArtworkFile(for id: String) async -> URL? {
        switch DeferredArtworkKey(rawValue: id)?.domain {
        case .music:
            return await onlineLibrary.cachedArtworkFile(for: id)
        case .home, .homePlaylist:
            return await home.resolveArtworkFile(for: id)
        case .artists:
            return await artists.cachedArtworkFile(for: id)
        case .search:
            return await search.cachedArtworkFile(for: id)
        case nil:
            return nil
        }
    }

    func requestQueueArtwork(for id: String, foreground: Bool) -> Task<Void, Never>? {
        if DeferredArtworkKey(rawValue: id)?.domain == .home {
            return home.requestQueueArtwork(for: id, foreground: foreground)
        }
        if foreground { requestArtwork(for: id) }
        return nil
    }

    func sceneDidChange(from previous: ScenePhase, to phase: ScenePhase) {
        guard startupTask != nil else { return }
        if phase == .background {
            container.player.saveQueueForBackground()
            container.playlistLibrary.saveForBackground()
        }
        if previous == .background, phase != .background {
            Task { await container.runtime.refresh() }
            Task { await account.revalidate() }
        }
    }

    func completeRestoredPlayback() {
        guard startupTask?.isCancelled == false else { return }
        let owner: String?
        switch account.restoredPlaybackIdentity {
        case .pending:
            PerformanceDiagnostics.restoration("player.waitingForIdentity")
            return
        case .signedOut: owner = nil
        case .signedIn(let value): owner = value
        }
        container.runtime.completeInitialPlaybackRestoration(ownerID: owner, songs: container.allSongs)
    }

    private func restoreInitialLibrary() async {
        await container.runtime.restoreCachedState()
        guard !Task.isCancelled else { return }
        await LocalArtworkImages.prepare(initialLibraryArtwork)
        guard !Task.isCancelled else { return }
        container.runtime.completeInitialPresentation(songs: container.allSongs)
    }

    private var initialLibraryArtwork: [Artwork] {
        (Array(container.pinned.prefix(6)) + Array(container.recentlyAdded.prefix(4))).map(\.artwork)
    }

    private func restoreInitialOnlineContent() async {
        guard !Task.isCancelled else { return }
        await downloads.restore()
        guard !Task.isCancelled else { return }
        await account.restoreCachedContent()
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
            guard let file = await resolveArtworkFile(for: id), !Task.isCancelled else { continue }
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
