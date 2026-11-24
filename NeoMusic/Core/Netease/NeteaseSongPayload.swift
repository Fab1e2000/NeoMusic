import Foundation

enum NeteaseSongPayload {
    struct Artist: Decodable, Sendable {
        let id: Int64?
        let name: String

        var reference: NeteaseArtistReference? {
            id.map { .init(id: $0, name: name) }
        }
    }

    struct Album: Decodable, Sendable {
        let id: Int64?
        let name: String
        let picUrl: String?
    }

    // The song-detail API supplies the compact keys and optional disc/track metadata.
    struct Music: Decodable, Sendable {
        let id: Int64
        let name: String
        let ar: [Artist]
        let al: Album
        let dt: Double
        let no: Int?
        let cd: String?

        var trackNumber: Int { max(0, no ?? 0) }
        var discNumber: Int { max(1, Int(cd ?? "1") ?? 1) }
        var model: NeteaseMusicSong {
            NeteaseSongPayload.song(id: id, name: name, artistNames: ar.map(\.name),
                album: al, duration: dt, credits: ar.compactMap(\.reference),
                trackNumber: trackNumber, discNumber: discNumber)
        }
    }

    struct Download: Decodable, Sendable {
        private let item: Music
        private let albumID: Int64

        init(from decoder: any Decoder) throws {
            item = try Music(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            albumID = try values.nestedContainer(keyedBy: CodingKeys.self, forKey: .al).decode(Int64.self, forKey: .id)
        }

        private enum CodingKeys: String, CodingKey { case al, id }
        var id: Int64 { item.id }
        var model: NeteaseDownloadSong {
            let names = item.ar.map(\.name)
            let credits = item.ar.compactMap(\.reference).filter { $0.id > 0 }
            let song = NeteaseSongPayload.song(id: id, name: item.name, artistNames: names,
                album: .init(id: albumID, name: item.al.name, picUrl: item.al.picUrl),
                duration: item.dt, credits: credits.isEmpty ? nil : credits)
            return .init(song: song, albumArtist: song.artist, trackNumber: item.trackNumber, discNumber: item.discNumber)
        }
    }

    struct Home: Decodable, Sendable {
        let model: NeteaseMusicSong

        private enum CodingKeys: String, CodingKey { case id, name, artists, ar, album, al, duration, dt }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let artists = try values.decodeIfPresent([Artist].self, forKey: .artists)
                ?? values.decode([Artist].self, forKey: .ar)
            let album = try values.decodeIfPresent(Album.self, forKey: .album)
                ?? values.decode(Album.self, forKey: .al)
            let duration = try values.decodeIfPresent(Double.self, forKey: .duration)
                ?? values.decode(Double.self, forKey: .dt)
            model = try NeteaseSongPayload.song(id: values.decode(Int64.self, forKey: .id),
                name: values.decode(String.self, forKey: .name), artistNames: artists.map(\.name),
                album: album, duration: duration, credits: artists.compactMap(\.reference))
        }
    }

    struct Search: Decodable, Sendable {
        struct Artist: Decodable, Sendable {
            let id: Int64
            let name: String
            let picUrl: String?
            let img1v1Url: String?

            var reference: NeteaseArtistReference {
                .init(id: id, name: name, artworkURL: NeteaseArtworkURL.artist(img1v1Url: img1v1Url, picUrl: picUrl))
            }
        }

        struct Album: Decodable, Sendable {
            let id: Int64
            let name: String
            let picUrl: String?
            let artist: Artist?
            let artists: [Artist]?
        }

        let id: Int64
        let name: String
        let ar: [Artist]?
        let artists: [Artist]?
        let al: Album?
        let album: Album?
        let dt: Double?
        let duration: Double?

        var model: NeteaseMusicSong {
            let performers = ar ?? artists ?? []
            let release = (al ?? album).map { NeteaseSongPayload.Album(id: $0.id, name: $0.name, picUrl: $0.picUrl) }
            return NeteaseSongPayload.song(id: id, name: name, artistNames: performers.map(\.name),
                album: release, duration: dt ?? duration ?? 0, credits: performers.map(\.reference))
        }
    }

    private static func song(id: Int64, name: String, artistNames: [String], album: Album?,
        duration: Double, credits: [NeteaseArtistReference]?, trackNumber: Int? = nil, discNumber: Int? = nil) -> NeteaseMusicSong {
        .init(id: id, title: name, artist: artistNames.joined(separator: " / "), album: album?.name ?? "",
            artworkURL: NeteaseMusicClient.url(album?.picUrl), duration: duration / 1000,
            artists: credits, albumID: album?.id, trackNumber: trackNumber, discNumber: discNumber)
    }
}
