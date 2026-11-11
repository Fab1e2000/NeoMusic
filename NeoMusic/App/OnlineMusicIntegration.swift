import SwiftUI

/// Converts account-owned content into the existing library and playback contracts.
@MainActor
final class OnlineMusicIntegration {
    private let account: NeteaseAccount
    var onPublication: (() -> Void)?
    private struct Content: Equatable {
        let owner: Int64
        let revision: UUID
        let playlists: [NeteaseMusicPlaylist]
        let songs: [Int64: NeteaseMusicSong]
        let tracks: [Int64: [Int64]]
        let liked: Set<Int64>
        let likedAt: [Int64: Date]
    }
    private var published: Content?
    private var artworkSongs: [URL: [Int64]] = [:]
    init(account: NeteaseAccount) { self.account = account }

    func connect() {
        guard let music = account.music else { return }
        music.onChange = { [weak self] in self?.publish() }
        music.onArtworkChange = { [weak self] in self?.publishArtwork($0) }
        music.onSessionInvalidated = { [weak self] in
            LocalLibrary.player.invalidateOnlinePlayback(ownerID: nil)
            LocalLibrary.songLibrary.replaceOnline([])
            LocalLibrary.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
            self?.onPublication?()
        }
        music.onQualityChange = { LocalLibrary.player.reloadCurrentResource() }
        LocalLibrary.runtime.onLibraryRestored = { [weak self] in
            self?.publish()
        }
        LocalLibrary.runtime.configureOnlineResolver { [weak music] id in
            guard let music, let parts = Self.songIdentity(id), music.userID == parts.owner else {
                throw NeteaseAccountError.authenticationRequired
            }
            let stream = try await music.stream(songID: parts.song)
            return PlaybackResource(url: stream.url, expiresAt: stream.expiresAt, quality: stream.quality.rawValue)
        }
        LocalLibrary.songLibrary.onlineFavoriteAction = { [weak music] id, liked in
            guard let music, let parts = Self.songIdentity(id), music.userID == parts.owner else {
                LocalLibrary.toasts.show(.error("请登录原网易云账号后重试"))
                return
            }
            Task {
                do { try await music.setLiked(songID: parts.song, liked: liked) }
                catch is CancellationError { }
                catch { LocalLibrary.toasts.show(.error(error.localizedDescription)) }
            }
        }
        LocalLibrary.playlistLibrary.loadOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music, let playlistID = Self.playlistID(id, music: music) else { return }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return }
            await music.loadPlaylist(id: playlistID)
            guard revision == music.sessionRevision else { return }
            self.publish()
        }
        LocalLibrary.playlistLibrary.loadMoreOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music, let playlistID = Self.playlistID(id, music: music) else { return }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return }
            await music.loadMorePlaylist(id: playlistID)
            guard revision == music.sessionRevision else { return }
            self.publish()
        }
        LocalLibrary.playlistLibrary.completeOnlinePlaylist = { [weak self, weak music] id in
            guard let self, let music else { return false }
            guard let playlistID = Self.playlistID(id, music: music) else { return id == "favorites" }
            let revision = music.sessionRevision
            await self.restoreHomePlaylist(playlistID, music: music, revision: revision)
            guard revision == music.sessionRevision, !Task.isCancelled else { return false }
            let complete = await music.completePlaylist(id: playlistID)
            guard revision == music.sessionRevision, !Task.isCancelled else { return false }
            self.publish()
            return complete
        }
        LocalLibrary.playlistLibrary.retryOnline = { [weak music] in await music?.refresh(force: true) }
        LocalLibrary.playlistLibrary.unsubscribeOnlinePlaylist = { [weak self] id in self?.changePlaylistCollection(id, subscribed: false) }
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

    func restoreReferencedMetadata(player: NowPlayingModel = LocalLibrary.player,
                                   playlistLibrary: PlaylistLibrary = LocalLibrary.playlistLibrary) async {
        guard let music = account.music, let owner = music.userID, account.profile?.userID == owner,
              !Task.isCancelled else { return }
        let home = account.home, artists = account.artists
        guard home == nil || home?.userID == owner, artists == nil || artists?.userID == owner else { return }
        let localSongs = playlistLibrary.playlists.filter { !$0.isReadOnly && !$0.isSystem }
            .flatMap { playlistLibrary.songs(in: $0.id) }
        let ids = Set((player.queue + localSongs).compactMap { item -> Int64? in
            guard item.unavailabilityReason != nil, let identity = Self.songIdentity(item.id), identity.owner == owner else { return nil }
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
        let values = recovered.0 + (recovered.1 ?? []) + (recovered.2 ?? [])
        guard !values.isEmpty else { return }
        var merged = Dictionary(LocalLibrary.allSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for value in values {
            let id = "netease:\(owner):\(value.id)"
            if merged[id] == nil || merged[id]?.unavailabilityReason != nil {
                merged[id] = song(value, owner: owner, music: music)
            }
        }
        let songs = Array(merged.values)
        player.reconcileAvailability(songs: songs)
        playlistLibrary.reconcileOnlineSongs(songs)
        player.saveQueue()
    }

    func connectLyrics() async {
        guard let music = account.music else { return }
        let downloads = account.downloads
        await LocalLibrary.referenceLibrary.reader.configureRemoteLyrics { [weak music, weak downloads] id in
            if let parts = Self.songIdentity(id), let file = downloads?.lyricsURL(songID: parts.song),
               let lyrics = try? String(contentsOf: file, encoding: .utf8) {
                return LyricsDocument.parse(lyrics)
            }
            guard let music, let parts = Self.songIdentity(id), music.userID == parts.owner else {
                throw NeteaseAccountError.authenticationRequired
            }
            let lyrics = try await music.lyrics(songID: parts.song)
            return LyricsDocument.onlineLyrics(original: lyrics.original, translation: lyrics.translation)
        }
    }

    private func changePlaylistCollection(_ id: String, subscribed: Bool) {
        guard let music = account.music, let owner = music.userID, account.profile?.userID == owner,
              let playlistID = Self.playlistNumber(id), id.hasPrefix("netease-playlist:\(owner):") || id.hasPrefix("home:playlist:") else {
            return
        }
        let revision = music.sessionRevision
        Task { [weak self] in
            do {
                try await music.setPlaylistSubscribed(id: playlistID, subscribed: subscribed)
                guard let self, revision == music.sessionRevision, music.userID == owner,
                      self.account.profile?.userID == owner else { return }
                if !subscribed, music.playlists.contains(where: { $0.id == playlistID && $0.isSubscribed == true }) == false {
                    LocalLibrary.playlistLibrary.releaseRetainedOnlinePlaylist("netease-playlist:\(owner):\(playlistID)")
                }
            } catch is CancellationError { }
            catch {
                guard revision == music.sessionRevision, music.userID == owner else { return }
                LocalLibrary.toasts.show(.error(error.localizedDescription))
            }
        }
    }

    private static func playlistNumber(_ id: String) -> Int64? {
        let parts = id.split(separator: ":")
        if id.hasPrefix("home:playlist:"), let number = parts.last { return Int64(number) }
        guard parts.count == 3, parts[0] == "netease-playlist" else { return nil }
        return Int64(parts[2])
    }

    private static func playlistID(_ id: String, music: NeteaseMusicStore) -> Int64? {
        if id == "favorites" { return music.playlists.first(where: \.isFavorites)?.id }
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "netease-playlist", let owner = Int64(parts[1]),
              owner == music.userID else { return nil }
        return Int64(parts[2])
    }

    private static func songIdentity(_ id: String) -> (owner: Int64, song: Int64)? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "netease", let owner = Int64(parts[1]), let song = Int64(parts[2]) else { return nil }
        return (owner, song)
    }

    private func publish() {
        guard LocalLibrary.runtime.hasRestoredPlayback else { return }
        defer { onPublication?() }
        guard let music = account.music else { return }
        if LocalLibrary.playlistLibrary.onlineStatus != music.error { LocalLibrary.playlistLibrary.onlineStatus = music.error }
        if LocalLibrary.playlistLibrary.isRefreshingOnline != music.isLoading { LocalLibrary.playlistLibrary.isRefreshingOnline = music.isLoading }
        guard let owner = music.userID else {
            published = nil
            artworkSongs = [:]
            LocalLibrary.songLibrary.replaceOnline([])
            LocalLibrary.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
            return
        }
        let ownerID = String(owner)
        LocalLibrary.player.restoreOnlineIdentity(ownerID: ownerID)
        let content = Content(owner: owner, revision: music.sessionRevision, playlists: music.playlists, songs: music.songs,
                              tracks: music.playlistTracks, liked: music.likedIDs, likedAt: music.likedAt)
        if published != content {
            let ownerChanged = published?.owner != owner
            published = content
            artworkSongs = Dictionary(grouping: music.songs.values.compactMap { value in
                value.artworkURL.map { ($0, value.id) }
            }, by: { $0.0 }).mapValues { $0.map(\.1) }
            let favoritesID = music.playlists.first(where: \.isFavorites)?.id
            let favoritesOrder = favoritesID.flatMap { music.playlistTracks[$0] } ?? []
            var seen = Set<Int64>()
            let order = (favoritesOrder + music.songs.keys.sorted()).filter { seen.insert($0).inserted }
            let songs = order.compactMap { music.songs[$0].map { song($0, owner: owner, music: music) } }
            let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            let songsChanged = LocalLibrary.songLibrary.replaceOnline(songs)
            let playlists = music.playlists.filter { !$0.isFavorites }.enumerated().map { index, value in
                var item = LibraryPlaylistItem(id: "netease-playlist:\(owner):\(value.id)", title: value.title,
                    artwork: artwork(value.artworkURL, music: music, placeholder: .playlist), addedOrder: music.playlists.count - index,
                    sourceOwnerID: ownerID, subtitle: value.creator)
                item.addedAt = value.createTime
                item.updatedAt = value.updateTime
                item.isSubscribed = value.isSubscribed == true
                return item
            }
            var contents: [String: [LibrarySongItem]] = [:]
            for (id, tracks) in music.playlistTracks {
                contents["netease-playlist:\(owner):\(id)"] = tracks.map {
                    let stableID = "netease:\(owner):\($0)"
                    return byID[stableID] ?? .unavailable(stableID)
                }
            }
            LocalLibrary.playlistLibrary.replaceOnlinePlaylists(items: playlists, songs: contents, ownerID: ownerID)
            if songsChanged || ownerChanged {
                LocalLibrary.playlistLibrary.reconcileOnlineSongs(LocalLibrary.allSongs)
                LocalLibrary.player.reconcileAvailability(songs: LocalLibrary.allSongs)
            }
        }
        for item in LocalLibrary.playlistLibrary.playlists where item.sourceOwnerID == ownerID || item.id == "favorites" {
            guard let id = Self.playlistID(item.id, music: music) else {
                LocalLibrary.playlistLibrary.setOnlineHasMore(item.id, false)
                continue
            }
            let localCount = item.id == "favorites" ? LocalLibrary.songLibrary.songs.filter(\.isFavorite).count : 0
            LocalLibrary.playlistLibrary.setOnlineHasMore(item.id, music.hasMorePlaylist(id: id), totalCount: music.playlistTotalCount(id: id) + localCount)
            LocalLibrary.playlistLibrary.updateOnlineSongs(playlistID: item.id, songs: LocalLibrary.playlistLibrary.songs(in: item.id),
                error: music.playlistErrors[id], loading: music.loadingPlaylists.contains(id))
        }
    }

    private func song(_ value: NeteaseMusicSong, owner: Int64, music: NeteaseMusicStore) -> LibrarySongItem {
        let artworkURL = value.artworkURL.flatMap { music.cachedArtworkURL($0) }
        return LibrarySongItem(id: "netease:\(owner):\(value.id)", title: value.title, artist: value.artist,
            album: value.album, albumArtist: value.artist, trackNumber: 0,
            artwork: artwork(value.artworkURL, music: music, placeholder: .missing), artworkURL: artworkURL,
            duration: Int(value.duration), isFavorite: music.likedIDs.contains(value.id),
            favoriteAddedAt: music.likedAt[value.id], unavailabilityReason: value.unavailable ? "暂无完整音源" : nil, onlineAlbumID: value.albumID,
            artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
    }

    private func artwork(_ remote: URL?, music: NeteaseMusicStore, placeholder: ArtworkPlaceholder) -> Artwork {
        guard let remote else { return placeholder == .playlist ? .playlist : .missing }
        if let file = music.cachedArtworkURL(remote) { return .file(file) }
        return .deferred(id: "music:\(music.sessionRevision.uuidString):\(remote.absoluteString)", placeholder: placeholder)
    }
    func requestArtwork(for id: String) {
        guard let music = account.music, let owner = music.userID, owner == account.profile?.userID else { return }
        let prefix = "music:\(music.sessionRevision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return }
        music.requestArtwork([url])
    }
    func cachedArtworkFile(for id: String) async -> URL? {
        guard let music = account.music, let owner = music.userID,
              owner == account.profile?.userID, !Task.isCancelled else { return nil }
        let revision = music.sessionRevision, prefix = "music:\(music.sessionRevision.uuidString):"
        guard id.hasPrefix(prefix), let url = URL(string: String(id.dropFirst(prefix.count))) else { return nil }
        let file = await music.cachedArtworkFile(url)
        guard revision == music.sessionRevision, music.userID == owner,
              account.profile?.userID == owner, !Task.isCancelled else { return nil }
        return file
    }

    private func publishArtwork(_ urls: Set<URL>) {
        guard LocalLibrary.runtime.hasRestoredPlayback, let music = account.music, let owner = music.userID,
              owner == account.profile?.userID, published?.owner == owner else { return }
        var songs: [String: LibrarySongItem] = [:]
        for url in urls {
            for id in artworkSongs[url] ?? [] {
                if let value = music.songs[id] {
                    let updated = song(value, owner: owner, music: music)
                    songs[updated.id] = updated
                }
            }
        }
        var covers: [String: Artwork] = [:]
        for item in music.playlists {
            if let remote = item.artworkURL, urls.contains(remote) {
                covers["netease-playlist:\(owner):\(item.id)"] = artwork(remote, music: music, placeholder: .playlist)
            }
        }
        LocalLibrary.songLibrary.updateOnlineArtwork(songs)
        LocalLibrary.playlistLibrary.updateArtwork(songs: songs, playlists: covers)
        LocalLibrary.player.updateArtwork(songs)
    }
}
