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
        startupTask = Task { [self] in
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
                async let local: Void = container.runtime.restoreCachedState()
                async let online: Void = restoreInitialOnlineContent()
                _ = await (local, online)
                guard !Task.isCancelled else { return }
                await onlineLibrary.finishPendingPublication()
                await downloads.publishMetadataAsync()
                guard !Task.isCancelled else { return }
                completeRestoredPlayback()
                await prepareInitialLibraryArtwork()
                guard !Task.isCancelled else { return }
                container.runtime.completeInitialPresentation(songs: container.allSongs)
            }
            async let scan: Void = container.runtime.refresh()
            async let validation: Void = restoreRemainingOnlineContent()
            _ = await (scan, validation)
        }
    }

    var artworkLoadAction: ArtworkLoadAction {
        ArtworkLoadAction(
            handler: requestArtwork,
            resolve: { [self] in await resolveArtworkFile(for: $0) },
            queueHandler: requestQueueArtwork,
            artistPortraits: artists.libraryPortraits,
            artworkProvider: LocalArtworkImages.provider
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
        case .libraryPlaylist, .homePlaylist, nil:
            break
        }
    }

    // Playlist IDs may require a detail fetch to discover their cover URL.
    func resolveArtworkFile(for id: String, cachedOnly: Bool = false) async -> URL? {
        switch DeferredArtworkKey(rawValue: id)?.domain {
        case .music:
            return await onlineLibrary.cachedArtworkFile(for: id)
        case .libraryPlaylist:
            return await onlineLibrary.resolvePlaylistArtworkFile(for: id, cachedOnly: cachedOnly)
        case .home, .homePlaylist:
            return await home.resolveArtworkFile(for: id, cachedOnly: cachedOnly)
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
        if previous == .background, phase != .background, container.runtime.isInitialPresentationReady {
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

    private func restoreInitialOnlineContent() async {
        guard !Task.isCancelled else { return }
        await downloads.restore()
        guard !Task.isCancelled else { return }
        await account.restoreCachedContent()
    }

    private func prepareInitialLibraryArtwork() async {
        let items = Array(container.pinned.prefix(6)) + Array(container.recentlyAdded.prefix(6))
        let covers = items.map { item in
            switch item.artistAvatar {
            case .portrait(let artwork), .album(let artwork, _): artwork
            case .missing, nil: item.artwork
            }
        }
        let identities = items.compactMap { item -> LibraryArtistIdentity? in
            guard case .libraryArtist(let identity) = item.route else { return nil }
            return identity
        }
        await LocalArtworkImages.prepareFirstShelf(covers, preparePortraits: { [artists] in
            await artists.prepareCachedLibraryPortraits(identities)
        }) { [self] id in
            await resolveArtworkFile(for: id, cachedOnly: true)
        }
    }

    private func restoreRemainingOnlineContent() async {
        await account.resumeRestoredDownloads()
        guard !Task.isCancelled else { return }
        await account.restoreHomeCachedContent()
        guard !Task.isCancelled else { return }
        await onlineLibrary.restoreReferencedMetadata()
        guard !Task.isCancelled else { return }
        await account.revalidate()
    }

}
