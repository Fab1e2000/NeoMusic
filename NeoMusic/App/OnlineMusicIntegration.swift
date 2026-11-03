import SwiftUI

/// Converts account-owned content into the existing library and playback contracts.
@MainActor
final class OnlineMusicIntegration {
    private let account: NeteaseAccount
    private var libraryRestored = false
    init(account: NeteaseAccount) { self.account = account }

    func connect() {
        guard let music = account.music else { return }
        music.onChange = { [weak self] in self?.publish() }
        music.onSessionInvalidated = {
            LocalLibrary.player.invalidateOnlinePlayback(ownerID: nil)
            LocalLibrary.songLibrary.replaceExternalSongs([])
            LocalLibrary.songLibrary.replaceOnline([])
            LocalLibrary.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        }
        music.onQualityChange = { LocalLibrary.player.reloadCurrentResource() }
        LocalLibrary.runtime.onLibraryRestored = { [weak self] in
            self?.libraryRestored = true
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
            let parts = id.split(separator: ":")
            guard let music, parts.count == 3, let owner = Int64(parts[1]), let playlistID = Int64(parts[2]),
                  owner == music.userID else { return }
            LocalLibrary.playlistLibrary.updateOnlineSongs(playlistID: id,
                songs: LocalLibrary.playlistLibrary.songs(in: id), error: nil, loading: true)
            await music.loadPlaylist(id: playlistID)
            self?.publish()
            guard owner == music.userID else { return }
            LocalLibrary.playlistLibrary.updateOnlineSongs(playlistID: id,
                songs: LocalLibrary.playlistLibrary.songs(in: id), error: music.playlistErrors[playlistID], loading: false)
        }
        LocalLibrary.playlistLibrary.retryOnline = { [weak music] in await music?.refresh() }
        publish()
    }

    func connectLyrics() async {
        guard let music = account.music else { return }
        await LocalLibrary.referenceLibrary.reader.configureRemoteLyrics { [weak music] id in
            guard let music, let parts = Self.songIdentity(id), music.userID == parts.owner else {
                throw NeteaseAccountError.authenticationRequired
            }
            let lyrics = try await music.lyrics(songID: parts.song)
            return LyricsDocument.onlineLyrics(original: lyrics.original, translation: lyrics.translation)
        }
    }

    private static func songIdentity(_ id: String) -> (owner: Int64, song: Int64)? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "netease", let owner = Int64(parts[1]), let song = Int64(parts[2]) else { return nil }
        return (owner, song)
    }

    private func publish() {
        guard libraryRestored else { return }
        guard let music = account.music else { return }
        LocalLibrary.playlistLibrary.onlineStatus = music.error
        LocalLibrary.playlistLibrary.isRefreshingOnline = music.isLoading
        guard let owner = music.userID else {
            LocalLibrary.songLibrary.replaceExternalSongs([])
            LocalLibrary.songLibrary.replaceOnline([])
            LocalLibrary.playlistLibrary.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
            return
        }
        let ownerID = String(owner)
        func song(_ value: NeteaseMusicSong) -> LibrarySongItem {
            let artworkURL = value.artworkURL.flatMap { music.cachedArtworkURL($0) }
            return LibrarySongItem(id: "netease:\(owner):\(value.id)", title: value.title, artist: value.artist,
                album: value.album, albumArtist: value.artist, trackNumber: 0,
                artwork: artworkURL.map(Artwork.file) ?? .missing, artworkURL: artworkURL,
                duration: Int(value.duration), isFavorite: music.likedIDs.contains(value.id),
                favoriteAddedAt: music.likedAt[value.id], unavailabilityReason: value.unavailable ? "暂无完整音源" : nil, onlineAlbumID: value.albumID,
                artistReferences: (value.artists ?? []).map { .init(id: "catalog:artist:\($0.id)", name: $0.name) })
        }
        let favoritesID = music.playlists.first(where: \.isFavorites)?.id
        let favoritesOrder = favoritesID.flatMap { music.playlistTracks[$0] } ?? []
        var seen = Set<Int64>()
        let order = (favoritesOrder + music.songs.keys.sorted()).filter { seen.insert($0).inserted }
        let songs = order.compactMap { music.songs[$0].map(song) }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        LocalLibrary.songLibrary.replaceOnline(songs)
        let playlists = music.playlists.filter { !$0.isFavorites }.enumerated().map { index, value in
            let artworkURL = value.artworkURL.flatMap { music.cachedArtworkURL($0) }
            var item = LibraryPlaylistItem(id: "netease-playlist:\(owner):\(value.id)", title: value.title,
                artwork: artworkURL.map(Artwork.file) ?? .playlist, addedOrder: music.playlists.count - index,
                sourceOwnerID: ownerID, subtitle: value.creator)
            item.updatedAt = value.updateTime
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
        LocalLibrary.playlistLibrary.reconcileOnlineSongs(LocalLibrary.allSongs)
        for item in playlists {
            if let id = item.id.split(separator: ":").last.flatMap({ Int64($0) }) {
                LocalLibrary.playlistLibrary.updateOnlineSongs(playlistID: item.id, songs: contents[item.id] ?? [],
                    error: music.playlistErrors[id], loading: music.loadingPlaylists.contains(id))
            }
        }
        LocalLibrary.player.reconcileAvailability(songs: LocalLibrary.allSongs)
    }
}
