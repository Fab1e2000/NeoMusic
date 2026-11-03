// Endpoint parameters follow MeloX (GPL-3.0), 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import Foundation

@MainActor final class NeteaseMusicClient {
    let transport: NeteaseAccountClient
    init(transport: NeteaseAccountClient = NeteaseAccountClient()) { self.transport = transport }
    func read<T: Decodable>(_ path: String, _ fields: [String: Any], _ credential: NeteaseCredential?) async throws -> T {
        try await JSONDecoder().decode(T.self, from: transport.request(path: path, fields: fields, credential: credential))
    }
    func playlists(userID: Int64, credential: NeteaseCredential) async throws -> [NeteaseMusicPlaylist] {
        struct Response: Decodable { let playlist: [Playlist]; let more: Bool }
        var offset = 0, seen = Set<Int64>(), result: [NeteaseMusicPlaylist] = []
        while true {
            let page: Response = try await read("/api/user/playlist", ["uid": userID, "limit": 200, "offset": offset], credential)
            result += page.playlist.filter { seen.insert($0.id).inserted }.map { item in
                let value = item.model
                return NeteaseMusicPlaylist(id: value.id, title: value.title, creator: value.creator, creatorID: value.creatorID, artworkURL: value.artworkURL, trackCount: value.trackCount, isFavorites: value.isFavorites && value.creatorID == userID, createTime: value.createTime, updateTime: value.updateTime)
            }
            if !page.more { return result }
            offset += 200
        }
    }
    func detail(id: Int64, credential: NeteaseCredential?) async throws -> NeteasePlaylistDetail {
        struct Response: Decodable { let playlist: Playlist }
        struct Songs: Decodable { let songs: [Song] }
        let response: Response = try await read("/api/v6/playlist/detail", ["id": id, "n": 0, "s": 0], credential)
        guard let ids = response.playlist.trackIds else { throw NeteaseAccountError.invalidResponse }
        var lookup: [Int64: NeteaseMusicSong] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let batch = ids[start..<min(start + 400, ids.count)].map { ["id": $0.id] }
            let data = try JSONSerialization.data(withJSONObject: batch)
            let songs: Songs = try await read("/api/v3/song/detail", ["c": String(decoding: data, as: UTF8.self)], credential)
            for song in songs.songs { lookup[song.id] = song.model }
        }
        var dates: [Int64: Date] = [:]
        for item in ids { if let at = item.at, at > 0 { dates[item.id] = Date(timeIntervalSince1970: at / 1000) } }
        return .init(playlist: response.playlist.model, songs: ids.map { lookup[$0.id] ?? .init(id: $0.id, title: "歌曲不可用", artist: "网易云音乐", album: "", artworkURL: nil, duration: 0, unavailable: true) }, addedTimes: dates)
    }
    func homeRecommendations(credential: NeteaseCredential?) async throws -> [NeteaseMusicPlaylist] {
        struct Item: Decodable {
            let id: Int64; let name: String; let picUrl: String?; let trackCount: Int?
            struct Creator: Decodable { let userId: Int64; let nickname: String }
            let creator: Creator?
        }
        struct Response: Decodable { let result: [Item]?; let recommend: [Item]? }
        let response: Response = try await read(credential == nil ? "/api/personalized/playlist" : "/api/v1/discovery/recommend/resource", ["limit": 30, "total": true, "n": 1000], credential)
        guard let items = response.result ?? response.recommend else { throw NeteaseAccountError.invalidResponse }
        var seen = Set<Int64>()
        return items.filter { seen.insert($0.id).inserted }.map {
            .init(id: $0.id, title: $0.name, creator: $0.creator?.nickname ?? "", creatorID: $0.creator?.userId ?? 0,
                  artworkURL: Self.url($0.picUrl), trackCount: $0.trackCount ?? 0, isFavorites: false)
        }
    }
    func dailyRecommendations(credential: NeteaseCredential) async throws -> [NeteaseMusicSong] {
        struct Payload: Decodable { let dailySongs: [Song] }
        struct Response: Decodable { let data: Payload }
        let response: Response = try await read("/api/v3/discovery/recommend/songs", [:], credential)
        var seen = Set<Int64>()
        return response.data.dailySongs.filter { seen.insert($0.id).inserted }.map(\.model)
    }
    func likedIDs(userID: Int64, credential: NeteaseCredential) async throws -> Set<Int64> {
        struct Response: Decodable { let ids: [Int64] }
        let response: Response = try await read("/api/song/like/get", ["uid": userID], credential)
        return Set(response.ids)
    }
    func setLiked(id: Int64, liked: Bool, credential: NeteaseCredential) async throws {
        _ = try await transport.request(path: "/api/radio/like", fields: ["alg": "itembased", "trackId": id, "like": liked, "time": "3"], credential: credential)
    }
    func stream(id: Int64, quality: NeteaseMusicQuality, credential: NeteaseCredential) async throws -> NeteaseMusicStream {
        struct Trial: Decodable {}
        struct Item: Decodable { let id: Int64; let url: String?; let expi: Double?; let freeTrialInfo: Trial?; let level: String? }
        struct Response: Decodable { let data: [Item] }
        for candidate in quality.fallbacks {
            let response: Response = try await read("/api/song/enhance/player/url/v1", ["ids": "[\(id)]", "level": candidate.rawValue, "encodeType": "flac"], credential)
            guard let item = response.data.first(where: { $0.id == id }), item.freeTrialInfo == nil,
                  let value = item.url, let url = Self.url(value) else { continue }
            return .init(url: url, expiresAt: Date().addingTimeInterval(max(0, (item.expi ?? 300) - 30)), quality: NeteaseMusicQuality(rawValue: item.level ?? "") ?? candidate)
        }
        throw NeteaseMusicError.unavailable
    }
    func lyrics(id: Int64, credential: NeteaseCredential) async throws -> NeteaseMusicLyrics {
        struct Text: Decodable { let lyric: String? }
        struct Response: Decodable { let lrc: Text?; let tlyric: Text? }
        let response: Response = try await read("/api/song/lyric", ["id": id, "lv": -1, "tv": -1], credential)
        return .init(original: response.lrc?.lyric ?? "", translation: response.tlyric?.lyric ?? "")
    }
    nonisolated static func url(_ value: String?) -> URL? {
        guard let value, var parts = URLComponents(string: value), ["https", "http"].contains(parts.scheme) else { return nil }
        parts.scheme = "https"
        return parts.url
    }
    private struct Playlist: Decodable {
        struct Creator: Decodable { let userId: Int64; let nickname: String }
        struct Track: Decodable { let id: Int64; let at: Double? }
        let id: Int64; let name: String; let creator: Creator; let coverImgUrl: String?; let trackCount: Int; let specialType: Int?; let trackIds: [Track]?; let createTime: Double?; let updateTime: Double?
        var model: NeteaseMusicPlaylist { .init(id: id, title: name, creator: creator.nickname, creatorID: creator.userId, artworkURL: NeteaseMusicClient.url(coverImgUrl), trackCount: trackCount, isFavorites: specialType == 5, createTime: createTime.map { Date(timeIntervalSince1970: $0 / 1000) }, updateTime: updateTime.map { Date(timeIntervalSince1970: $0 / 1000) }) }
    }
    struct Song: Decodable {
        struct Artist: Decodable { let id: Int64?; let name: String }
        struct Album: Decodable { let id: Int64?; let name: String; let picUrl: String? }
        let id: Int64; let name: String; let ar: [Artist]; let al: Album; let dt: Double
        var model: NeteaseMusicSong { .init(id: id, title: name, artist: ar.map(\.name).joined(separator: " / "), album: al.name, artworkURL: NeteaseMusicClient.url(al.picUrl), duration: dt / 1000, artists: ar.compactMap { artist in artist.id.map { NeteaseArtistReference(id: $0, name: artist.name, artworkURL: nil) } }, albumID: al.id) }
    }
}
