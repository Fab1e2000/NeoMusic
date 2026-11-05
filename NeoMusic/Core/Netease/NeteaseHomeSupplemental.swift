import Foundation

/// Supplemental sources retain their own identity instead of claiming a homepage block code.
/// Endpoints follow NeteaseCloudMusicApiEnhanced/api-enhanced (GPL-3.0),
/// module/toplist.js and module/artist_new_song.js.
/// Playback and new-song parameters follow MeloX (GPL-3.0),
/// 09713edb847a0f0a3515a34f779cc630d4fe5985, NeteaseAPI+Home / IntelligenceMode.
enum NeteaseHomeSupplemental {
    struct Intelligence: Decodable, Sendable {
        struct Item: Decodable, Sendable { let id: Int64 }
        let data: [Item]
        var songIDs: [Int64] {
            var seen = Set<Int64>()
            return data.map(\.id).filter { $0 > 0 && seen.insert($0).inserted }
        }
    }
    struct SongBatch: Decodable, Sendable {
        let data: [Song]
        var songs: [NeteaseMusicSong] { NeteaseHomeSupplemental.songs(data) }
    }
    struct Similar: Decodable, Sendable {
        let songs: [Song]
        var models: [NeteaseMusicSong] { NeteaseHomeSupplemental.songs(songs) }
    }
    /// These endpoints return either the older artists/album/duration keys or
    /// the song-detail ar/al/dt keys. Both carry the same stable music identities.
    struct Song: Decodable, Sendable {
        let model: NeteaseMusicSong
        private enum CodingKeys: String, CodingKey { case id, name, artists, ar, album, al, duration, dt }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let artists = try values.decodeIfPresent([NeteaseMusicClient.Song.Artist].self, forKey: .artists)
                ?? values.decode([NeteaseMusicClient.Song.Artist].self, forKey: .ar)
            let album = try values.decodeIfPresent(NeteaseMusicClient.Song.Album.self, forKey: .album)
                ?? values.decode(NeteaseMusicClient.Song.Album.self, forKey: .al)
            let duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? values.decode(Double.self, forKey: .dt)
            model = try .init(id: values.decode(Int64.self, forKey: .id), title: values.decode(String.self, forKey: .name),
                artist: artists.map(\.name).joined(separator: " / "), album: album.name,
                artworkURL: NeteaseMusicClient.url(album.picUrl), duration: duration / 1000,
                artists: artists.compactMap { artist in
                    artist.id.map { .init(id: $0, name: artist.name, artworkURL: nil) }
                }, albumID: album.id)
        }
    }
    private static func songs(_ items: [Song]) -> [NeteaseMusicSong] {
        var seen = Set<Int64>()
        return items.map(\.model).filter { $0.id > 0 && !$0.title.isEmpty && seen.insert($0.id).inserted }
    }
    struct Charts: Decodable, Sendable {
        struct Chart: Decodable, Sendable {
            let id: Int64
            let name: String
            let coverImgUrl: String?
        }
        let list: [Chart]
        var block: NeteaseHomeFeed.Block {
            var seen = Set<Int64>()
            let resources = list.filter { $0.id > 0 && !$0.name.isEmpty && seen.insert($0.id).inserted }.map {
                NeteaseHomeFeed.Resource(type: "list", id: $0.id, title: $0.name, artist: "", image: $0.coverImgUrl)
            }
            return NeteaseHomeSupplemental.block(code: "NEOMUSIC_CHARTS", title: "排行榜", resources: resources)
        }
    }
    struct Followed: Decodable, Sendable {
        struct Payload: Decodable, Sendable { let newWorks: [Work] }
        struct Work: Decodable, Sendable {
            struct Title: Decodable, Sendable {
                let resourceId: Int64
                let resourceName: String
                let resourcePicUrl: String?
                let artistName: String
            }
            let blockTitle: Title
            let blockType: String
            let albumId: Int64?
        }
        let data: Payload
        var block: NeteaseHomeFeed.Block {
            var seen = Set<Int64>()
            let resources = data.newWorks.compactMap { work -> NeteaseHomeFeed.Resource? in
                guard ["album", "song"].contains(work.blockType) else { return nil }
                let id = work.albumId ?? (work.blockType == "album" ? work.blockTitle.resourceId : 0)
                guard id > 0, !work.blockTitle.resourceName.isEmpty, seen.insert(id).inserted else { return nil }
                return .init(type: "album", id: id, title: work.blockTitle.resourceName,
                             artist: work.blockTitle.artistName, image: work.blockTitle.resourcePicUrl)
            }
            return NeteaseHomeSupplemental.block(code: "NEOMUSIC_FOLLOWED_RELEASES", title: "你关注的艺人新动向", resources: resources)
        }
    }
    private static func block(code: String, title: String, resources: [NeteaseHomeFeed.Resource]) -> NeteaseHomeFeed.Block {
        .init(blockCode: code, uiElement: .init(mainTitle: nil, subTitle: .init(title: title), image: nil),
              creatives: [.init(creativeId: code, creativeType: nil, uiElement: nil, resources: resources)])
    }
}

extension NeteaseHomeFeed.Resource {
    init(type: String, id: Int64, title: String, artist: String, image: String?) {
        resourceType = type
        resourceID = String(id)
        uiElement = .init(mainTitle: .init(title: title), subTitle: .init(title: artist),
                          image: .init(imageUrl: NeteaseMusicClient.url(image)?.absoluteString))
        song = nil
    }
}

extension NeteaseMusicClient {
    @concurrent func intelligenceModeSongs(playlistID: Int64, seedSongID: Int64,
                                           credential: NeteaseCredential) async throws -> [NeteaseMusicSong] {
        let response: NeteaseHomeSupplemental.Intelligence = try await read("/api/playmode/intelligence/list",
            ["songId": seedSongID, "type": "fromPlayOne", "playlistId": playlistID,
             "startMusicId": seedSongID, "count": 1], credential)
        let ids = response.songIDs
        guard !ids.isEmpty else { return [] }
        let details = try await songs(ids: ids, credential: credential)
        let lookup = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return ids.compactMap { lookup[$0] }
    }
    @concurrent func personalFM(credential: NeteaseCredential, mode: String = "EXPLORE",
                               limit: Int = 30) async throws -> [NeteaseMusicSong] {
        let response: NeteaseHomeSupplemental.SongBatch = try await read("/api/v1/radio/get",
            ["mode": mode, "limit": min(max(limit, 1), 50)], credential)
        return response.songs
    }
    @concurrent func similarSongs(id: Int64, credential: NeteaseCredential?, limit: Int = 50) async throws -> [NeteaseMusicSong] {
        let response: NeteaseHomeSupplemental.Similar = try await read("/api/v1/discovery/simiSong",
            ["songid": id, "limit": min(max(limit, 1), 50), "offset": 0], credential)
        return response.models
    }
    @concurrent func newSongs(credential: NeteaseCredential?, limit: Int = 12) async throws -> [NeteaseMusicSong] {
        let response: NeteaseHomeSupplemental.SongBatch = try await read("/api/v1/discovery/new/songs",
            ["areaId": 0, "total": true], credential)
        return Array(response.songs.prefix(min(max(limit, 1), 100)))
    }
    @concurrent func homeCharts(credential: NeteaseCredential?) async throws -> NeteaseHomeFeed.Block {
        let response: NeteaseHomeSupplemental.Charts = try await read("/api/toplist", [:], credential)
        return response.block
    }
    @concurrent func followedArtistReleases(credential: NeteaseCredential) async throws -> NeteaseHomeFeed.Block {
        let response: NeteaseHomeSupplemental.Followed = try await read("/api/sub/artist/new/works/song/list",
            ["limit": 20, "startTimestamp": Int64(Date().timeIntervalSince1970 * 1000)], credential)
        return response.block
    }
}
