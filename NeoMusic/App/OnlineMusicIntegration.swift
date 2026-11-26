import SwiftUI

typealias OnlineMusicIntegration = OnlineLibraryIntegration

@MainActor
final class OnlineLibraryIntegration {
    private let account: NeteaseAccount
    private let container: AppContainer
    var onPublication: (() -> Void)?
    private struct Content: Equatable, Sendable {
        let owner: Int64
        let revision: UUID
        let playlists: [NeteaseMusicPlaylist]
        let songs: [Int64: NeteaseMusicSong]
        let tracks: [Int64: [Int64]]
        let liked: Set<Int64>
        let likedAt: [Int64: Date]
    }
    private var published: Content?
    private var artworkSongs: [URL: [NeteaseMusicSong]] = [:]
    private var retainedArtworkByID: [Int64: NeteaseMusicSong] = [:]
    private let projectionCache = OnlineSongProjectionCache()
    private var publishTask: Task<Void, Never>?
    private let artworkBatcher = ArtworkUpdateBatcher()
    private var publishGeneration = 0
    convenience init(account: NeteaseAccount) {
        self.init(account: account, container: .shared)
    }

    init(account: NeteaseAccount, container: AppContainer) {
        self.account = account
        self.container = container
    }

    func connect() {
        guard let music = account.music else { return }
        let container = container
        music.onChange = { [weak self] in
            guard let self, let music = self.account.music else { return }
            if self.published == nil && music.songs.count <= 250 { self.publish() } else { self.schedulePublish() }
        }
        music.onArtworkChange = { [weak self] in self?.scheduleArtworkPublish($0) }
        music.onSessionInvalidated = { [weak self] in
            self?.publishGeneration &+= 1
            self?.publishTask?.cancel()
            self?.publishTask = nil
            self?.artworkBatcher.cancel()
            self?.published = nil
            self?.artworkSongs = [:]
            self?.retainedArtworkByID = [:]
            self?.projectionCache.removeAll()
            container.player.invalidateOnlinePlayback(ownerID: nil)
            container.songLibrary.replaceOnline([])
            container.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
            self?.onPublication?()
        }
        music.onQualityChange = { container.player.reloadCurrentResource() }
        container.runtime.onLibraryRestored = { [weak self] in
            self?.publish()
        }
        container.runtime.configureOnlineResolver { [weak music] id in
            guard let music, let parts = OnlineSongIdentity.parse(id), music.userID == parts.owner else {
                throw NeteaseAccountError.authenticationRequired
            }
            let stream = try await music.stream(songID: parts.song)
            return PlaybackResource(url: stream.url, expiresAt: stream.expiresAt, quality: stream.quality.rawValue)
        }
        container.songLibrary.onlineFavoriteAction = { [weak music, toasts = container.toasts] id, liked, playsSuccessHaptic in
            guard let music, let parts = OnlineSongIdentity.parse(id), music.userID == parts.owner else {
                toasts.show(.error("请登录原网易云账号后重试"))
                return
            }
            let revision = music.sessionRevision
            Task {
                await OnlineFavoriteAction.perform(music: music, revision: revision, songID: parts.song,
                    liked: liked, playsSuccessHaptic: playsSuccessHaptic, toasts: toasts,
                    isCurrent: { music.userID == parts.owner })
            }
        }
        container.playlistLibrary.loadOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music, let playlistID = Self.playlistID(id, music: music) else { return }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return }
            await music.loadPlaylist(id: playlistID)
            guard revision == music.sessionRevision else { return }
            await self.publishAsync()
        }
        container.playlistLibrary.loadMoreOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music, let playlistID = Self.playlistID(id, music: music) else { return }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return }
            await music.loadMorePlaylist(id: playlistID)
            guard revision == music.sessionRevision else { return }
            await self.publishAsync()
        }
        container.playlistLibrary.completeOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music else { return false }
            guard let playlistID = Self.playlistID(id, music: music) else { return id == "favorites" }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return false }
            let complete = await music.completePlaylist(id: playlistID)
            guard revision == music.sessionRevision, !Task.isCancelled else { return false }
            await self.publishAsync()
            return complete
        }
        container.playlistLibrary.retryOnline = { [weak music] in await music?.refresh(force: true) }
        container.playlistLibrary.unsubscribeOnlinePlaylist = { [weak self] id in self?.changePlaylistCollection(id, subscribed: false) }
        publish()
    }

    private func restoreHomePlaylist(_ id: Int64, music: NeteaseMusicStore, revision: UUID) async {
        guard music.playlistTracks[id] == nil, !music.playlists.contains(where: { $0.id == id }),
              let owner = music.userID, account.profile?.userID == owner,
              let home = account.home, home.userID == owner else { return }
        let homeRevision = home.sessionRevision
        guard let detail = try? await home.restoreCachedDetail(id: id),
              revision == music.sessionRevision, homeRevision == home.sessionRevision,
              home.userID == owner, account.profile?.userID == owner, !Task.isCancelled else { return }
        music.adoptCachedPlaylist(detail, ownerID: owner, revision: revision)
    }

    func restoreReferencedMetadata() async {
        await restoreReferencedMetadata(player: container.player, playlistLibrary: container.playlistLibrary)
    }

    func restoreReferencedMetadata(player: NowPlayingModel, playlistLibrary: PlaylistLibrary) async {
        guard let music = account.music, let owner = music.userID, account.profile?.userID == owner,
              !Task.isCancelled else { return }
        let home = account.home, artists = account.artists
        guard home == nil || home?.userID == owner, artists == nil || artists?.userID == owner else { return }
        let referenced = ReferencedLibrarySongs.collect(player: player, playlists: playlistLibrary)
        let ids = Set(referenced.compactMap { item -> Int64? in
            guard let identity = OnlineSongIdentity.parse(item.id), identity.owner == owner else { return nil }
            let needsArtwork = item.artworkData == nil && (item.artworkURL == nil
                || item.artworkURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
            guard item.unavailabilityReason != nil || needsArtwork else { return nil }
            return identity.song
        })
        guard !ids.isEmpty else { return }
        let musicRevision = music.sessionRevision, homeRevision = home?.sessionRevision, artistRevision = artists?.sessionRevision
        async let librarySongs = music.restoreCachedSongs(ids: ids)
        async let homeSongs = home?.restoreCachedSongs(ids: ids)
        async let artistSongs = artists?.restoreCachedSongs(ids: ids)
        let recovered = await (librarySongs, homeSongs, artistSongs)
        guard musicRevision == music.sessionRevision, homeRevision == home?.sessionRevision,
              artistRevision == artists?.sessionRevision, music.userID == owner,
              home == nil || home?.userID == owner, artists == nil || artists?.userID == owner,
              account.profile?.userID == owner, !Task.isCancelled else { return }
        var recoveredByID: [Int64: NeteaseMusicSong] = [:]
        for value in recovered.0 + (recovered.1 ?? []) + (recovered.2 ?? []) where !value.unavailable {
            if recoveredByID[value.id] == nil || recoveredByID[value.id]?.artworkURL == nil {
                recoveredByID[value.id] = value
            }
        }
        let unresolved = ids.filter { recoveredByID[$0]?.artworkURL == nil }
        if !unresolved.isEmpty {
            let resolved = await music.resolveReferencedSongs(ids: unresolved)
            guard musicRevision == music.sessionRevision, homeRevision == home?.sessionRevision,
                  artistRevision == artists?.sessionRevision, music.userID == owner,
                  account.profile?.userID == owner, !Task.isCancelled else { return }
            for value in resolved { recoveredByID[value.id] = value }
        }
        guard !recoveredByID.isEmpty else { return }
        let currentReferences = ReferencedLibrarySongs.collect(player: player, playlists: playlistLibrary)
        let currentIDs = Set(currentReferences.filter { $0.onlineOwnerID == String(owner) }.compactMap(\.onlineSongID))
        let values = recoveredByID.values.filter { currentIDs.contains($0.id) }
        updateArtworkIndex(Array(values), retainingIDs: currentIDs.union(music.songs.keys))
        var merged = Dictionary((container.allSongs + currentReferences).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for value in values {
            let id = OnlineSongIdentity.format(owner: owner, song: value.id)
            merged[id] = song(value, owner: owner, music: music).retainingArtwork(from: merged[id])
        }
        let songs = Array(merged.values)
        player.reconcileAvailability(songs: songs)
        playlistLibrary.reconcileOnlineSongs(songs)
        player.saveQueue()
        let adjacent = Set([player.current.onlineSongID, player.previous?.onlineSongID, player.next?.onlineSongID].compactMap { $0 })
        music.requestArtwork(values.filter { adjacent.contains($0.id) }.compactMap(\.artworkURL))
    }

    private func updateArtworkIndex(_ values: [NeteaseMusicSong], retainingIDs: Set<Int64>) {
        let updated = Self.updatedArtworkIndex(existingByID: retainedArtworkByID, values: values, retainingIDs: retainingIDs)
        retainedArtworkByID = updated.byID
        artworkSongs = updated.byURL
    }

    nonisolated private static func updatedArtworkIndex(existingByID: [Int64: NeteaseMusicSong],
                                                        values: [NeteaseMusicSong],
                                                        retainingIDs: Set<Int64>) -> (byID: [Int64: NeteaseMusicSong], byURL: [URL: [NeteaseMusicSong]]) {
        var byID: [Int64: NeteaseMusicSong] = [:]
        byID.reserveCapacity(retainingIDs.count + values.count)
        for (id, song) in existingByID where retainingIDs.contains(id) {
            byID[id] = song
        }
        for value in values { byID[value.id] = value }
        let byURL = Dictionary(grouping: byID.values.filter { $0.artworkURL != nil }, by: { $0.artworkURL! })
        return (byID, byURL)
    }

    func connectLyrics() async {
        guard let music = account.music else { return }
        let downloads = account.downloads
        await container.referenceLibrary.reader.configureRemoteLyrics { [weak music, weak downloads] id in
            try Task.checkCancellation()
            guard let parts = OnlineSongIdentity.parse(id) else {
                throw NeteaseAccountError.authenticationRequired
            }
            if let file = downloads?.lyricsURL(songID: parts.song),
               let lyrics = try? await LyricsReader.loadDownloadedFile(file) {
                return lyrics
            }
            try Task.checkCancellation()
            guard let music, music.userID == parts.owner else {
                throw NeteaseAccountError.authenticationRequired
            }
            let revision = music.sessionRevision
            let lyrics = try await music.lyrics(songID: parts.song)
            let document = try await LyricsDocument.onlineLyrics(original: lyrics.original, translation: lyrics.translation)
            guard revision == music.sessionRevision else { throw CancellationError() }
            return document
        }
    }

    @discardableResult
    static func changePlaylistSubscription(_ id: String,
                                           subscribed: Bool,
                                           account: NeteaseAccount,
                                           container: AppContainer = .shared,
                                           onSubscribedChanged: (@MainActor () -> Void)? = nil) -> Bool {
        guard let music = account.music, let owner = music.userID, account.profile?.userID == owner else {
            return false
        }
        let playlistID: Int64?
        switch PlaylistRouteIdentity(id) {
        case .account(let ownerID, let number) where Int64(ownerID) == owner:
            playlistID = number
        case .homePlaylist(let number):
            playlistID = number
        default:
            playlistID = nil
        }
        guard let playlistID else { return false }
        let revision = music.sessionRevision
        Task {
            do {
                try await music.setPlaylistSubscribed(id: playlistID, subscribed: subscribed)
                guard revision == music.sessionRevision, music.userID == owner,
                      account.profile?.userID == owner else { return }
                if !subscribed, music.playlists.contains(where: { $0.id == playlistID && $0.isSubscribed == true }) == false {
                    container.playlistLibrary.releaseRetainedOnlinePlaylist(PlaylistRouteIdentity.accountID(owner: owner, playlistID: playlistID))
                }
                if subscribed { LibraryHaptics.success() }
                onSubscribedChanged?()
            } catch is CancellationError { }
            catch {
                guard revision == music.sessionRevision, music.userID == owner,
                      account.profile?.userID == owner else { return }
                container.toasts.show(.error(error.localizedDescription))
            }
        }
        return true
    }

    private func changePlaylistCollection(_ id: String, subscribed: Bool) {
        _ = Self.changePlaylistSubscription(id, subscribed: subscribed, account: account, container: container)
    }

    private static func playlistID(_ id: String, music: NeteaseMusicStore) -> Int64? {
        switch PlaylistRouteIdentity(id) {
        case .favorites:
            return music.playlists.first(where: \.isFavorites)?.id
        case .account(let ownerID, let playlistID) where Int64(ownerID) == music.userID:
            return playlistID
        default:
            return nil
        }
    }

    private enum PublicationPlan: Sendable {
        case unchanged
        case favoriteDelta(content: Content, changedIDs: [Int64], favoriteOrder: [Int64], uniqueArtworkURLs: [URL])
        case full(content: Content, order: [Int64], artworkSongs: [URL: [NeteaseMusicSong]],
                  retainedArtworkByID: [Int64: NeteaseMusicSong], ownerChanged: Bool,
                  removedProjectedIDs: [Int64], uniqueArtworkURLs: [URL])
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishGeneration &+= 1
        let generation = publishGeneration
        publishTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.publishGeneration == generation else { return }
            await self.runOffMainPublish(generation: generation, music: self.account.music)
            if self.publishGeneration == generation { self.publishTask = nil }
        }
    }

    func finishPendingPublication() async {
        while let task = publishTask, !Task.isCancelled {
            await task.value
        }
    }

    private func publishAsync() async {
        publishTask?.cancel()
        publishTask = nil
        publishGeneration &+= 1
        let generation = publishGeneration
        await runOffMainPublish(generation: generation, music: account.music)
    }

    private func runOffMainPublish(generation: Int, music: NeteaseMusicStore?) async {
        guard container.runtime.hasRestoredPlayback else { return }
        guard let music else { return }
        if container.playlistLibrary.onlineStatus != music.error { container.playlistLibrary.onlineStatus = music.error }
        if container.playlistLibrary.isRefreshingOnline != music.isLoading { container.playlistLibrary.isRefreshingOnline = music.isLoading }
        guard let owner = music.userID else {
            applySignedOutState()
            return
        }
        let ownerID = String(owner)
        let revision = music.sessionRevision
        container.player.restoreOnlineIdentity(ownerID: ownerID)
        let content = Content(owner: owner, revision: revision, playlists: music.playlists, songs: music.songs,
                              tracks: music.playlistTracks, liked: music.likedIDs, likedAt: music.likedAt)
        let previous = published
        let referenced = ReferencedLibrarySongs.collect(player: container.player, playlists: container.playlistLibrary)
        let referencedIDs = Set(referenced.filter { $0.onlineOwnerID == ownerID }.compactMap(\.onlineSongID))
        let existingRetained = (previous?.owner == owner) ? retainedArtworkByID : [:]
        let existingProjectedKeys = (previous?.owner == owner) ? Set(projectionCache.keys) : []
        let plan = await Task.detached(priority: .userInitiated) {
            Self.preparePublicationPlan(previous: previous, content: content,
                                        existingRetained: existingRetained,
                                        referencedIDs: referencedIDs,
                                        existingProjectedKeys: existingProjectedKeys)
        }.value
        guard !Task.isCancelled, publishGeneration == generation,
              let currentMusic = account.music, currentMusic.sessionRevision == revision,
              currentMusic.userID == owner, account.profile?.userID == owner,
              container.runtime.hasRestoredPlayback else { return }
        applyPublicationPlan(plan, owner: owner, music: currentMusic)
    }

    private func publish() {
        publishTask?.cancel()
        publishTask = nil
        publishGeneration &+= 1
        guard container.runtime.hasRestoredPlayback else { return }
        guard let music = account.music else { return }
        if container.playlistLibrary.onlineStatus != music.error { container.playlistLibrary.onlineStatus = music.error }
        if container.playlistLibrary.isRefreshingOnline != music.isLoading { container.playlistLibrary.isRefreshingOnline = music.isLoading }
        guard let owner = music.userID else {
            applySignedOutState()
            return
        }
        let ownerID = String(owner)
        container.player.restoreOnlineIdentity(ownerID: ownerID)
        let content = Content(owner: owner, revision: music.sessionRevision, playlists: music.playlists, songs: music.songs,
                              tracks: music.playlistTracks, liked: music.likedIDs, likedAt: music.likedAt)
        let referenced = ReferencedLibrarySongs.collect(player: container.player, playlists: container.playlistLibrary)
        let referencedIDs = Set(referenced.filter { $0.onlineOwnerID == ownerID }.compactMap(\.onlineSongID))
        let existingRetained = (published?.owner == owner) ? retainedArtworkByID : [:]
        let existingProjectedKeys = (published?.owner == owner) ? Set(projectionCache.keys) : []
        let plan = Self.preparePublicationPlan(previous: published, content: content,
                                               existingRetained: existingRetained,
                                               referencedIDs: referencedIDs,
                                               existingProjectedKeys: existingProjectedKeys)
        applyPublicationPlan(plan, owner: owner, music: music)
    }

    private func applySignedOutState() {
        var notifiedChange = false
        defer { if notifiedChange { onPublication?() } }
        if published != nil || projectionCache.count > 0 { notifiedChange = true }
        published = nil
        artworkSongs = [:]
        retainedArtworkByID = [:]
        projectionCache.removeAll()
        container.songLibrary.replaceOnline([])
        container.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
    }

    nonisolated private static func preparePublicationPlan(previous: Content?,
                                                           content: Content,
                                                           existingRetained: [Int64: NeteaseMusicSong],
                                                           referencedIDs: Set<Int64>,
                                                           existingProjectedKeys: Set<Int64>) -> PublicationPlan {
        if let previous, previous == content {
            return .unchanged
        }
        if let previous, Self.isFavoriteOnlyChange(from: previous, to: content) {
            let changed = previous.liked.symmetricDifference(content.liked).union(
                Set(previous.likedAt.keys).union(content.likedAt.keys).filter { previous.likedAt[$0] != content.likedAt[$0] }
            )
            let favoritesOrder = content.playlists.first(where: \.isFavorites).flatMap { content.tracks[$0.id] } ?? []
            var urls = Set<URL>()
            for id in changed {
                if let url = content.songs[id]?.artworkURL { urls.insert(url) }
            }
            return .favoriteDelta(content: content, changedIDs: Array(changed),
                                  favoriteOrder: favoritesOrder, uniqueArtworkURLs: Array(urls))
        }
        let ownerChanged = previous?.owner != content.owner
        let allValues = Array(content.songs.values)
        let artworkIndex = Self.updatedArtworkIndex(existingByID: ownerChanged ? [:] : existingRetained,
                                                    values: allValues,
                                                    retainingIDs: referencedIDs)
        let favoritesID = content.playlists.first(where: \.isFavorites)?.id
        let favoritesOrder = favoritesID.flatMap { content.tracks[$0] } ?? []
        var seen = Set<Int64>()
        seen.reserveCapacity(content.songs.count)
        var order: [Int64] = []
        order.reserveCapacity(content.songs.count)
        for id in favoritesOrder where seen.insert(id).inserted { order.append(id) }
        for id in content.songs.keys.sorted() where seen.insert(id).inserted { order.append(id) }

        let removed = ownerChanged ? [] : Array(existingProjectedKeys.filter { content.songs[$0] == nil })
        var urls = Set<URL>()
        for song in allValues {
            if let url = song.artworkURL { urls.insert(url) }
        }
        for playlist in content.playlists where playlist.creatorID == content.owner {
            if let url = playlist.artworkURL { urls.insert(url) }
        }
        return .full(content: content, order: order, artworkSongs: artworkIndex.byURL,
                     retainedArtworkByID: artworkIndex.byID, ownerChanged: ownerChanged,
                     removedProjectedIDs: removed, uniqueArtworkURLs: Array(urls))
    }

    private func applyPublicationPlan(_ plan: PublicationPlan, owner: Int64, music: NeteaseMusicStore) {
        var notifiedChange = false
        defer { if notifiedChange { onPublication?() } }
        let ownerID = String(owner)
        switch plan {
        case .unchanged:
            break
        case .favoriteDelta(let content, let changedIDs, let favoriteOrder, let uniqueArtworkURLs):
            let cachedCovers = Dictionary(uniqueArtworkURLs.compactMap { remote in
                music.cachedArtworkURL(remote).map { (remote, $0) }
            }, uniquingKeysWith: { first, _ in first })
            var replacements: [String: LibrarySongItem] = [:]
            replacements.reserveCapacity(changedIDs.count)
            for id in changedIDs {
                if let value = music.songs[id] {
                    let item = projectedSong(value, owner: owner, music: music, cachedCovers: cachedCovers)
                    replacements[item.id] = item
                }
            }
            container.songLibrary.updateOnlineFavorites(replacements, order: favoriteOrder.map { OnlineSongIdentity.format(owner: owner, song: $0) })
            container.playlistLibrary.updateSongFavorites(replacements)
            container.player.reconcileAvailability(songs: container.allSongs)
            published = content
            notifiedChange = true
        case .full(let content, let order, let newArtworkSongs, let newRetainedByID, let ownerChanged, let removedProjectedIDs, let uniqueArtworkURLs):
            if ownerChanged {
                artworkSongs = [:]
                retainedArtworkByID = [:]
                projectionCache.removeAll()
            }
            published = content
            notifiedChange = true
            artworkSongs = newArtworkSongs
            retainedArtworkByID = newRetainedByID
            for key in removedProjectedIDs { projectionCache.removeValue(forKey: key) }

            let cachedCovers = Dictionary(uniqueArtworkURLs.compactMap { remote in
                music.cachedArtworkURL(remote).map { (remote, $0) }
            }, uniquingKeysWith: { first, _ in first })

            var songs: [LibrarySongItem] = []
            songs.reserveCapacity(order.count)
            var byID: [String: LibrarySongItem] = [:]
            byID.reserveCapacity(order.count)
            for id in order {
                guard let value = music.songs[id] else { continue }
                let item = projectedSong(value, owner: owner, music: music, cachedCovers: cachedCovers)
                songs.append(item)
                byID[item.id] = item
            }

            let songsChanged = container.songLibrary.replaceOnline(songs)
            let playlists = music.playlists.filter { !$0.isFavorites }.enumerated().map { index, value in
                let cover: Artwork
                if value.creatorID == owner {
                    cover = artwork(value.artworkURL, music: music, placeholder: .playlist, cachedCovers: cachedCovers)
                } else if let remote = music.loadedPlaylistCover(id: value.id) {
                    cover = artwork(remote, music: music, placeholder: .playlist, cachedCovers: cachedCovers)
                } else {
                    let key = DeferredArtworkKey(domain: .libraryPlaylist, session: music.sessionRevision, playlistID: value.id)
                    cover = .deferred(id: key.rawValue, placeholder: .playlist)
                }
                var item = LibraryPlaylistItem(id: PlaylistRouteIdentity.accountID(owner: owner, playlistID: value.id), title: value.title,
                    artwork: cover, addedOrder: music.playlists.count - index,
                    sourceOwnerID: ownerID, subtitle: value.creator)
                item.addedAt = value.createTime
                item.updatedAt = value.updateTime
                item.isSubscribed = value.isSubscribed == true
                return item
            }
            var contents: [String: [LibrarySongItem]] = [:]
            contents.reserveCapacity(music.playlistTracks.count)
            for (id, tracks) in music.playlistTracks {
                contents[PlaylistRouteIdentity.accountID(owner: owner, playlistID: id)] = tracks.map {
                    let stableID = OnlineSongIdentity.format(owner: owner, song: $0)
                    return byID[stableID] ?? .unavailable(stableID)
                }
            }
            container.playlistLibrary.replaceOnlinePlaylists(items: playlists, songs: contents, ownerID: ownerID)
            if songsChanged || ownerChanged {
                container.playlistLibrary.reconcileOnlineSongs(container.allSongs, excludingReadOnly: true)
                container.player.reconcileAvailability(songs: container.allSongs)
            }
        }
        let localFavoritesCount = container.songLibrary.localSongs.filter(\.isFavorite).count
        for item in container.playlistLibrary.playlists where item.sourceOwnerID == ownerID || item.id == "favorites" {
            guard let id = Self.playlistID(item.id, music: music) else {
                container.playlistLibrary.setOnlineHasMore(item.id, false)
                continue
            }
            container.playlistLibrary.setPlaylistDetailReceived(music.hasReceivedPlaylistPage(id: id), for: item.id)
            let localCount = item.id == "favorites" ? localFavoritesCount : 0
            container.playlistLibrary.setOnlineHasMore(item.id, music.hasMorePlaylist(id: id), totalCount: music.playlistTotalCount(id: id) + localCount)
            container.playlistLibrary.updateOnlineSongs(playlistID: item.id, songs: container.playlistLibrary.songs(in: item.id),
                error: music.playlistErrors[id], loading: music.loadingPlaylists.contains(id))
        }
    }

    nonisolated private static func isFavoriteOnlyChange(from old: Content, to new: Content) -> Bool {
        guard old.liked != new.liked || old.likedAt != new.likedAt else { return false }
        guard old.owner == new.owner, old.revision == new.revision, old.songs == new.songs,
              old.playlists.filter({ !$0.isFavorites }) == new.playlists.filter({ !$0.isFavorites }) else { return false }
        let favorites = Set((old.playlists + new.playlists).filter(\.isFavorites).map(\.id))
        return old.tracks.filter { !favorites.contains($0.key) } == new.tracks.filter { !favorites.contains($0.key) }
    }

    private func projectedSong(_ value: NeteaseMusicSong, owner: Int64, music: NeteaseMusicStore,
                               cachedCovers: [URL: URL]? = nil) -> LibrarySongItem {
        let liked = music.likedIDs.contains(value.id)
        let likedAt = music.likedAt[value.id]
        let cachedCover = value.artworkURL.flatMap { cachedCovers?[$0] ?? music.cachedArtworkURL($0) }
        return projectionCache.project(
            value,
            owner: String(owner),
            revision: music.sessionRevision,
            isFavorite: liked,
            favoriteAddedAt: likedAt,
            cachedArtworkURL: cachedCover
        ) {
            song(value, owner: owner, music: music, cachedCovers: cachedCovers)
        }
    }

    private func song(_ value: NeteaseMusicSong, owner: Int64, music: NeteaseMusicStore,
                      cachedCovers: [URL: URL]? = nil) -> LibrarySongItem {
        let item = makeSong(value, owner: owner, music: music, cachedCovers: cachedCovers)
        return item.retainingArtwork(from: container.songLibrary.song(id: item.id))
    }

    private func makeSong(_ value: NeteaseMusicSong, owner: Int64, music: NeteaseMusicStore,
                          cachedCovers: [URL: URL]? = nil) -> LibrarySongItem {
        let artworkURL = value.artworkURL.flatMap { cachedCovers?[$0] ?? music.cachedArtworkURL($0) }
        return OnlineSongProjector.makeSong(
            value,
            id: OnlineSongIdentity.format(owner: owner, song: value.id),
            artwork: artwork(value.artworkURL, music: music, placeholder: .missing, cachedCovers: cachedCovers),
            artworkURL: artworkURL,
            isFavorite: music.likedIDs.contains(value.id),
            favoriteAddedAt: music.likedAt[value.id]
        )
    }

    private func artwork(_ remote: URL?, music: NeteaseMusicStore, placeholder: ArtworkPlaceholder,
                         cachedCovers: [URL: URL]? = nil) -> Artwork {
        guard let remote else { return placeholder == .playlist ? .playlist : .missing }
        if let file = cachedCovers?[remote] ?? music.cachedArtworkURL(remote) { return .file(file) }
        return .deferred(id: DeferredArtworkKey(domain: .music, session: music.sessionRevision, url: remote).rawValue, placeholder: placeholder)
    }
    func requestArtwork(for id: String) {
        guard let music = account.music, let owner = music.userID, owner == account.profile?.userID,
              let url = DeferredArtworkRoute.remote(id, session: music.sessionRevision, domain: .music) else { return }
        music.requestArtwork([url])
    }

    func resolvePlaylistArtworkFile(for id: String, cachedOnly: Bool) async -> URL? {
        guard let music = account.music, let owner = music.userID, let home = account.home else { return nil }
        let revision = music.sessionRevision
        let isCurrent = { self.account.sessionOwnerID == owner && music.sessionRevision == revision }
        return await DeferredArtworkRoute.cachedFile(id, session: revision, domain: .libraryPlaylist,
            isCurrent: isCurrent) { key in
                guard let number = key.playlistID else { return nil }
                if let file = await music.cachedPlaylistCoverFile(id: number) { return file }
                guard isCurrent() else { return nil }
                if cachedOnly { return await home.cachedPlaylistCoverFile(id: number, owner: owner) }
                if home.userID != owner { await account.restoreHomeCachedContent() }
                guard isCurrent(), home.userID == owner else { return nil }
                return try? await home.playlistArtworkFile(id: number)
            }
    }

    func cachedArtworkFile(for id: String) async -> URL? {
        guard let music = account.music, let owner = music.userID else { return nil }
        let revision = music.sessionRevision
        return await DeferredArtworkRoute.cachedFile(id, session: revision, domain: .music,
            isCurrent: { revision == music.sessionRevision && music.userID == owner && account.profile?.userID == owner }) { key in
                guard let url = key.remoteURL else { return nil }
                return await music.cachedArtworkFile(url)
            }
    }

    private func scheduleArtworkPublish(_ urls: Set<URL>) {
        guard let music = account.music else { return }
        let session = music.sessionRevision
        artworkBatcher.enqueue(urls, session: session,
            isCurrent: { [weak self] in self?.account.music === music && music.sessionRevision == session },
            publish: { [weak self] in self?.publishArtwork($0) })
    }

    private func publishArtwork(_ urls: Set<URL>) {
        guard container.runtime.hasRestoredPlayback, let music = account.music, let owner = music.userID,
              owner == account.profile?.userID, published?.owner == owner else { return }
        var songs: [String: LibrarySongItem] = [:]
        for url in urls {
            for value in artworkSongs[url] ?? [] {
                let updated = makeSong(value, owner: owner, music: music)
                songs[updated.id] = updated
                if let previous = projectionCache[value.id] {
                    projectionCache[value.id] = OnlineSongProjectionCache.Entry(
                        owner: String(owner),
                        revision: music.sessionRevision,
                        source: value,
                        isFavorite: previous.isFavorite,
                        favoriteAddedAt: previous.favoriteAddedAt,
                        cachedArtworkURL: updated.artworkURL,
                        item: updated
                    )
                }
            }
        }
        var covers: [String: Artwork] = [:]
        for item in music.playlists {
            let remote = item.creatorID == owner ? item.artworkURL : music.loadedPlaylistCover(id: item.id)
            if let remote, urls.contains(remote) {
                covers[PlaylistRouteIdentity.accountID(owner: owner, playlistID: item.id)] = artwork(remote, music: music, placeholder: .playlist)
            }
        }
        container.player.updateArtwork(songs)
        container.songLibrary.updateOnlineArtwork(songs)
        container.playlistLibrary.updateArtwork(songs: songs, playlists: covers)
    }
}
