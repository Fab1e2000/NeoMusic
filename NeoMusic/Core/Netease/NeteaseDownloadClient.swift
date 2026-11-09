// Download endpoint and NCM handling reference: NeoDizzy (GPL-3.0).
import Foundation

extension NeteaseMusicClient {
    @concurrent func downloadSource(id: Int64, quality: NeteaseMusicQuality,
                                    credential: NeteaseCredential) async throws -> NeteaseDownloadSource {
        struct Trial: Decodable {}
        struct Item: Decodable {
            let id: Int64; let url: String?; let type: String?; let level: String?
            let size: Int64?; let freeTrialInfo: Trial?
        }
        struct Response: Decodable { let data: Item? }
        for candidate in quality.fallbacks {
            try Task.checkCancellation()
            let response: Response = try await read("/api/song/enhance/download/url/v1",
                ["id": id, "level": candidate.rawValue], credential)
            guard let item = response.data, item.id == id, item.freeTrialInfo == nil,
                  let text = item.url, let url = Self.url(text), url.host != nil,
                  url.user == nil, url.password == nil,
                  let type = item.type?.lowercased(), ["ncm", "mp3", "flac"].contains(type),
                  let quality = item.level.flatMap(NeteaseMusicQuality.init(rawValue:)) else { continue }
            return .init(url: url, type: type, quality: quality, size: item.size.flatMap { $0 > 0 ? $0 : nil })
        }
        throw NeteaseDownloadError.unavailable
    }

    @concurrent func downloadSongs(ids: [Int64], credential: NeteaseCredential) async throws -> [NeteaseDownloadSong] {
        struct Artist: Decodable { let name: String }
        struct Item: Decodable {
            let id: Int64; let name: String; let ar: [Artist]
            struct Album: Decodable { let id: Int64; let name: String; let picUrl: String? }
            let al: Album; let dt: Double; let no: Int?; let cd: String?
            var model: NeteaseDownloadSong {
                .init(song: .init(id: id, title: name, artist: ar.map(\.name).joined(separator: " / "),
                    album: al.name, artworkURL: NeteaseMusicClient.url(al.picUrl), duration: dt / 1000, albumID: al.id),
                    albumArtist: ar.map(\.name).joined(separator: " / "), trackNumber: max(0, no ?? 0),
                    discNumber: max(1, Int(cd ?? "1") ?? 1))
            }
        }
        struct Response: Decodable { let songs: [Item] }
        var unique = Set<Int64>(), ordered: [Int64] = []
        for id in ids where unique.insert(id).inserted { ordered.append(id) }
        var songs: [Int64: NeteaseDownloadSong] = [:]
        for start in stride(from: 0, to: ordered.count, by: 100) {
            try Task.checkCancellation()
            let batch = ordered[start..<min(start + 100, ordered.count)]
            let data = try JSONSerialization.data(withJSONObject: batch.map { ["id": $0] })
            let response: Response = try await read("/api/v3/song/detail", ["c": String(decoding: data, as: UTF8.self)], credential)
            for item in response.songs where unique.contains(item.id) { songs[item.id] = item.model }
        }
        let albumIDs = Array(Set(songs.values.compactMap { $0.song.albumID })).sorted()
        let albums = try await withThrowingTaskGroup(of: (Int64, NeteaseArtistAlbumDetail?).self) { group in
            var next = 0, result: [Int64: NeteaseArtistAlbumDetail] = [:]
            func add(_ id: Int64) {
                group.addTask {
                    do { return (id, try await self.albumDetail(id: id, credential: credential)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (id, nil) }
                }
            }
            for _ in 0..<min(3, albumIDs.count) { add(albumIDs[next]); next += 1 }
            while let (id, album) = try await group.next() {
                if let album { result[id] = album }
                if next < albumIDs.count { add(albumIDs[next]); next += 1 }
            }
            return result
        }
        for id in songs.keys {
            guard var value = songs[id], let albumID = value.song.albumID, let album = albums[albumID] else { continue }
            if !album.album.artist.isEmpty { value.albumArtist = album.album.artist }
            if value.trackNumber == 0, let position = album.songs.firstIndex(where: { $0.id == id }) { value.trackNumber = position + 1 }
            songs[id] = value
        }
        return ordered.compactMap { songs[$0] }
    }
}
