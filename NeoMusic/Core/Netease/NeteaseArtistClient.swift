import Foundation

struct NeteaseArtistReference: Codable, Sendable, Equatable, Identifiable {
    let id: Int64
    let name: String
    var artworkURL: URL?
    var shareURL: URL? { URL(string: "https://music.163.com/#/artist?id=\(id)") }
}
struct NeteaseArtistAlbum: Codable, Sendable, Identifiable {
    let id: Int64
    let title: String
    let artist: String
    let artworkURL: URL?
    let publishTime: Date?
    let type: String
    let trackCount: Int
}
struct NeteaseArtistDetail: Codable, Sendable {
    let artist: NeteaseArtistReference
    let biography: String
    let songs: [NeteaseMusicSong]
}
struct NeteaseArtistAlbumDetail: Codable, Sendable {
    let album: NeteaseArtistAlbum
    let songs: [NeteaseMusicSong]
}

extension NeteaseMusicClient {
    @concurrent func songDetail(id: Int64, credential: NeteaseCredential?) async throws -> NeteaseMusicSong {
        struct Response: Decodable { let songs: [Song] }
        let response: Response = try await read("/api/v3/song/detail", ["c": "[{\"id\":\(id)}]"], credential)
        guard let song = response.songs.first(where: { $0.id == id }) else { throw NeteaseAccountError.invalidResponse }
        return song.model
    }
    @concurrent func artistDetail(id: Int64, credential: NeteaseCredential?) async throws -> NeteaseArtistDetail {
        struct Response: Decodable { let artist: ArtistDTO; let hotSongs: [Song] }
        let response: Response = try await read("/api/v1/artist/\(id)", [:], credential)
        return .init(artist: response.artist.model, biography: response.artist.briefDesc ?? "", songs: response.hotSongs.map(\.model))
    }
    @concurrent func artistBiography(id: Int64, credential: NeteaseCredential?) async throws -> String {
        struct Section: Decodable { let ti: String; let txt: String }
        struct Response: Decodable { let briefDesc: String?; let introduction: [Section]? }
        let response: Response = try await read("/api/artist/introduction", ["id": id], credential)
        return ([response.briefDesc ?? ""] + (response.introduction ?? []).map { $0.ti + "\n" + $0.txt }).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    @concurrent func artistAlbums(id: Int64, credential: NeteaseCredential?) async throws -> [NeteaseArtistAlbum] {
        struct Response: Decodable { let hotAlbums: [AlbumDTO]; let more: Bool }
        var result: [NeteaseArtistAlbum] = [], offset = 0, seen = Set<Int64>()
        while true {
            let response: Response = try await read("/api/artist/albums/\(id)", ["limit": 100, "offset": offset, "total": true], credential)
            result += response.hotAlbums.filter { seen.insert($0.id).inserted }.map(\.model)
            if !response.more { return result }
            guard !response.hotAlbums.isEmpty else { throw NeteaseAccountError.invalidResponse }
            offset += response.hotAlbums.count
        }
    }
    @concurrent func similarArtists(id: Int64, credential: NeteaseCredential?) async throws -> [NeteaseArtistReference] {
        struct Response: Decodable { let artists: [ArtistDTO] }
        let response: Response = try await read("/api/discovery/simiArtist", ["artistid": id], credential)
        return response.artists.map(\.model)
    }
    @concurrent func albumDetail(id: Int64, credential: NeteaseCredential?) async throws -> NeteaseArtistAlbumDetail {
        struct Response: Decodable { let album: AlbumDTO; let songs: [Song] }
        let response: Response = try await read("/api/v1/album/\(id)", [:], credential)
        guard response.album.size.map({ $0 == response.songs.count }) ?? true else { throw NeteaseAccountError.invalidResponse }
        return .init(album: response.album.model, songs: response.songs.map(\.model))
    }
    @concurrent func subscribedArtists(credential: NeteaseCredential) async throws -> [NeteaseArtistReference] {
        struct Response: Decodable { let data: [ArtistDTO]; let hasMore: Bool }
        var result: [NeteaseArtistReference] = [], offset = 0, seen = Set<Int64>()
        while true {
            let page: Response = try await read("/api/artist/sublist", ["limit": 100, "offset": offset, "total": true], credential)
            result += page.data.filter { seen.insert($0.id).inserted }.map(\.model)
            if !page.hasMore { return result }
            guard !page.data.isEmpty else { throw NeteaseAccountError.invalidResponse }
            offset += page.data.count
        }
    }
    @concurrent func subscribedAlbums(credential: NeteaseCredential) async throws -> [NeteaseArtistAlbum] {
        struct Response: Decodable { let data: [AlbumDTO]; let hasMore: Bool }
        var result: [NeteaseArtistAlbum] = [], offset = 0, seen = Set<Int64>()
        while true {
            let page: Response = try await read("/api/album/sublist", ["limit": 100, "offset": offset, "total": true], credential)
            result += page.data.filter { seen.insert($0.id).inserted }.map(\.model)
            if !page.hasMore { return result }
            guard !page.data.isEmpty else { throw NeteaseAccountError.invalidResponse }
            offset += page.data.count
        }
    }
    @concurrent func setArtistSubscribed(id: Int64, subscribed: Bool, credential: NeteaseCredential) async throws {
        _ = try await transport.requestWeb(path: subscribed ? "/api/artist/sub" : "/api/artist/unsub", fields: ["artistId": id, "artistIds": "[\(id)]"], credential: credential)
    }
    @concurrent func setAlbumSubscribed(id: Int64, subscribed: Bool, credential: NeteaseCredential) async throws {
        _ = try await transport.requestWeb(path: subscribed ? "/api/album/sub" : "/api/album/unsub", fields: ["id": id], credential: credential)
    }
    private struct ArtistDTO: Decodable {
        let id: Int64; let name: String; let picUrl: String?; let img1v1Url: String?; let briefDesc: String?
        var model: NeteaseArtistReference { .init(id: id, name: name, artworkURL: NeteaseArtworkURL.artist(img1v1Url: img1v1Url, picUrl: picUrl)) }
    }
    private struct AlbumDTO: Decodable {
        let id: Int64; let name: String; let picUrl: String?; let publishTime: Double?; let type: String?; let size: Int?; let artist: ArtistDTO?; let artists: [ArtistDTO]?
        var model: NeteaseArtistAlbum {
            .init(id: id, title: name, artist: artists?.map(\.name).joined(separator: " / ") ?? artist?.name ?? "", artworkURL: NeteaseMusicClient.url(picUrl), publishTime: publishTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }, type: type ?? "", trackCount: size ?? 0)
        }
    }
}
