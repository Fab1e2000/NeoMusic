// Endpoint parameters follow MeloX (GPL-3.0), 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import Foundation

final class NeteaseMusicClient: Sendable {
    let transport: NeteaseAccountClient
    init(transport: NeteaseAccountClient = NeteaseAccountClient()) { self.transport = transport }
    @concurrent func read<T: Decodable & Sendable>(_ path: String, _ fields: [String: any Sendable], _ credential: NeteaseCredential?) async throws -> T {
        try await transport.decoded(path: path, fields: fields, credential: credential, retryTLS: true)
    }
    @concurrent func playlists(userID: Int64, credential: NeteaseCredential) async throws -> [NeteaseMusicPlaylist] {
        struct Response: Decodable { let playlist: [Playlist]; let more: Bool }
        var offset = 0, seen = Set<Int64>(), result: [NeteaseMusicPlaylist] = []
        while true {
            let page: Response = try await read("/api/user/playlist", ["uid": userID, "limit": 200, "offset": offset], credential)
            result += page.playlist.filter { seen.insert($0.id).inserted }.map { item in
                let value = item.model
                return NeteaseMusicPlaylist(id: value.id, title: value.title, creator: value.creator, creatorID: value.creatorID, artworkURL: value.artworkURL, trackCount: value.trackCount, isFavorites: value.isFavorites && value.creatorID == userID, isSubscribed: item.subscribed == true && item.creator.userId != userID && item.specialType != 5, createTime: value.createTime, updateTime: value.updateTime)
            }
            if !page.more { return result }
            offset += 200
        }
    }
    @concurrent func detail(id: Int64, credential: NeteaseCredential?, trackLimit: Int? = nil,
                            prefetched: [NeteaseMusicSong] = []) async throws -> NeteasePlaylistDetail {
        struct Response: Decodable { let playlist: Playlist }
        let response: Response = try await read("/api/v6/playlist/detail", ["id": id, "n": min(max(trackLimit ?? 100, 0), 100), "s": 0], credential)
        guard let ids = response.playlist.trackIds else { throw NeteaseAccountError.invalidResponse }
        var dates: [Int64: Date] = [:]
        for item in ids { if let at = item.at, at > 0 { dates[item.id] = Date(timeIntervalSince1970: at / 1000) } }
        let detail = NeteasePlaylistDetail(playlist: response.playlist.model, songs: [], addedTimes: dates,
                                           trackIDs: ids.map(\.id), loadedTrackCount: 0)
        return try await load(detail, through: min(max(trackLimit ?? ids.count, 0), ids.count),
                              prefetched: prefetched.filter { !$0.unavailable } + (response.playlist.tracks ?? []).map(\.model),
                              credential: credential)
    }
    @concurrent func loadMore(_ detail: NeteasePlaylistDetail, credential: NeteaseCredential?, limit: Int = 100) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        guard !detail.isComplete else { return detail }
        return try await load(detail, through: min(detail.nextOffset + max(1, limit), detail.orderedTrackIDs.count),
                              credential: credential)
    }

    @concurrent func complete(_ detail: NeteasePlaylistDetail, credential: NeteaseCredential?) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        guard !detail.isComplete else { return detail }
        return try await load(detail, through: detail.orderedTrackIDs.count, credential: credential)
    }

    private func load(_ detail: NeteasePlaylistDetail, through end: Int, prefetched: [NeteaseMusicSong] = [],
                      credential: NeteaseCredential?) async throws -> NeteasePlaylistDetail {
        try Task.checkCancellation()
        let ids = Array(detail.orderedTrackIDs.prefix(end))
        var lookup = Dictionary((detail.songs + prefetched).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<Int64>()
        let missing = ids.filter { lookup[$0] == nil && seen.insert($0).inserted }
        let batches = stride(from: 0, to: missing.count, by: 100).map { Array(missing[$0..<min($0 + 100, missing.count)]) }
        try await withThrowingTaskGroup(of: [NeteaseMusicSong].self) { group in
            var next = 0
            for _ in 0..<min(3, batches.count) {
                let batch = batches[next]
                next += 1
                group.addTask { try await self.songs(ids: batch, credential: credential) }
            }
            while let songs = try await group.next() {
                for song in songs { lookup[song.id] = song }
                if next < batches.count {
                    let batch = batches[next]
                    next += 1
                    group.addTask { try await self.songs(ids: batch, credential: credential) }
                }
            }
        }
        try Task.checkCancellation()
        // 详情接口没返回的编号先不放进曲目。不能写成「暂无完整音源」，否则正在播放的歌会被停掉。
        return .init(playlist: detail.playlist, songs: ids.compactMap { lookup[$0] }, addedTimes: detail.addedTimes, trackIDs: detail.orderedTrackIDs, loadedTrackCount: end)
    }

    @concurrent func songs(ids: [Int64], credential: NeteaseCredential?) async throws -> [NeteaseMusicSong] {
        struct Response: Decodable { let songs: [Song] }
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] })
        let response: Response = try await read("/api/v3/song/detail", ["c": String(decoding: data, as: UTF8.self)], credential)
        return response.songs.map(\.model)
    }

    @concurrent func homeRecommendations(credential: NeteaseCredential?) async throws -> [NeteaseMusicPlaylist] {
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
    @concurrent func dailyRecommendations(credential: NeteaseCredential) async throws -> [NeteaseMusicSong] {
        struct Payload: Decodable { let dailySongs: [Song] }
        struct Response: Decodable { let data: Payload }
        let response: Response = try await read("/api/v3/discovery/recommend/songs", [:], credential)
        var seen = Set<Int64>()
        return response.data.dailySongs.filter { seen.insert($0.id).inserted }.map(\.model)
    }
    @concurrent func likedIDs(userID: Int64, credential: NeteaseCredential) async throws -> Set<Int64> {
        struct Response: Decodable { let ids: [Int64] }
        let response: Response = try await read("/api/song/like/get", ["uid": userID], credential)
        return Set(response.ids)
    }
    /// 收藏或取消收藏歌单。与网页一样分别请求 subscribe / unsubscribe，只带歌单编号。
    @concurrent func setPlaylistSubscribed(id: Int64, subscribed: Bool, credential: NeteaseCredential) async throws {
        _ = try await transport.requestWeb(path: subscribed ? "/api/playlist/subscribe" : "/api/playlist/unsubscribe", fields: ["id": id], credential: credential)
    }
    @concurrent func setLiked(id: Int64, liked: Bool, credential: NeteaseCredential) async throws {
        _ = try await transport.request(path: "/api/radio/like", fields: ["alg": "itembased", "trackId": id, "like": liked, "time": "3"], credential: credential)
    }
    @concurrent func stream(id: Int64, quality: NeteaseMusicQuality, credential: NeteaseCredential) async throws -> NeteaseMusicStream {
        struct Trial: Decodable {}
        struct Item: Decodable { let id: Int64; let url: String?; let expi: Double?; let freeTrialInfo: Trial?; let level: String? }
        struct Response: Decodable { let data: [Item] }
        for candidate in quality.fallbacks {
            let response: Response = try await transport.decoded(path: "/api/song/enhance/player/url/v1",
                fields: ["ids": "[\(id)]", "level": candidate.rawValue, "encodeType": "flac"],
                credential: credential, profile: .playback)
            guard let item = response.data.first(where: { $0.id == id }), item.freeTrialInfo == nil,
                  let value = item.url, let url = Self.url(value) else { continue }
            return .init(url: url, expiresAt: Date().addingTimeInterval(max(0, (item.expi ?? 300) - 30)), quality: NeteaseMusicQuality(rawValue: item.level ?? "") ?? candidate)
        }
        throw NeteaseMusicError.unavailable
    }
    @concurrent func lyrics(id: Int64, credential: NeteaseCredential) async throws -> NeteaseMusicLyrics {
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
        let id: Int64; let name: String; let creator: Creator; let coverImgUrl: String?; let trackCount: Int; let specialType: Int?; let subscribed: Bool?; let trackIds: [Track]?; let tracks: [Song]?; let createTime: Double?; let updateTime: Double?
        var model: NeteaseMusicPlaylist { .init(id: id, title: name, creator: creator.nickname, creatorID: creator.userId, artworkURL: NeteaseMusicClient.url(coverImgUrl), trackCount: trackCount, isFavorites: specialType == 5, createTime: createTime.map { Date(timeIntervalSince1970: $0 / 1000) }, updateTime: updateTime.map { Date(timeIntervalSince1970: $0 / 1000) }) }
    }
    struct Song: Decodable {
        struct Artist: Decodable { let id: Int64?; let name: String }
        struct Album: Decodable { let id: Int64?; let name: String; let picUrl: String? }
        let id: Int64; let name: String; let ar: [Artist]; let al: Album; let dt: Double
        var model: NeteaseMusicSong { .init(id: id, title: name, artist: ar.map(\.name).joined(separator: " / "), album: al.name, artworkURL: NeteaseMusicClient.url(al.picUrl), duration: dt / 1000, artists: ar.compactMap { artist in artist.id.map { NeteaseArtistReference(id: $0, name: artist.name, artworkURL: nil) } }, albumID: al.id) }
    }
}
