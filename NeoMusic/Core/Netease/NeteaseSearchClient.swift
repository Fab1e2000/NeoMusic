import Foundation

enum NeteaseSearchKind: Int, Codable, CaseIterable, Sendable {
    case combined = 1018, song = 1, artist = 100, album = 10, playlist = 1000
}

struct NeteaseSearchResource: Codable, Sendable, Identifiable {
    let kind: NeteaseSearchKind
    let resourceID: Int64
    let title: String
    let subtitle: String
    let artworkURL: URL?
    var song: NeteaseMusicSong?
    var id: String { "\(kind.rawValue):\(resourceID)" }
}

struct NeteaseSearchGroup: Codable, Sendable {
    let kind: NeteaseSearchKind
    var items: [NeteaseSearchResource]
    var hasMore: Bool
}

struct NeteaseSearchPage: Codable, Sendable {
    var groups: [NeteaseSearchGroup]
    let nextOffset: Int
    var hasMore: Bool
}

struct NeteaseSearchCategory: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let group: Int
    let isHot: Bool
    var id: String { name }
}

struct NeteaseSearchSuggestions: Sendable {
    var keywords: [String]
    var resources: [NeteaseSearchResource]
}

/// Endpoint selection follows MeloX 09713ed (GPL-3.0), Features/Search and
/// NeteaseAPI+SearchSuggestions. Composite order comes from the service response.
final class NeteaseSearchClient: Sendable {
    let transport: NeteaseAccountClient
    init(transport: NeteaseAccountClient = .init()) { self.transport = transport }

    @concurrent func categories(credential: NeteaseCredential?) async throws -> [NeteaseSearchCategory] {
        struct Response: Decodable {
            struct Category: Decodable { let name: String; let category: Int; let hot: Bool? }
            let sub: [Category]
        }
        let response: Response = try await transport.decoded(path: "/api/playlist/catalogue", fields: [:], credential: credential, profile: .search, retryTLS: true)
        var seen = Set<String>()
        return response.sub.enumerated().filter { !$0.element.name.isEmpty && seen.insert($0.element.name).inserted }
            .sorted { a, b in
                if (a.element.hot == true) != (b.element.hot == true) { return a.element.hot == true }
                if a.element.category != b.element.category { return a.element.category < b.element.category }
                return a.offset < b.offset
            }.map { .init(name: $0.element.name, group: $0.element.category, isHot: $0.element.hot == true) }
    }

    @concurrent func playlists(category: String, offset: Int = 0, limit: Int = 50,
                               credential: NeteaseCredential?) async throws -> NeteaseSearchPage {
        struct Response: Decodable { let playlists: [Playlist]; let more: Bool }
        let response: Response = try await transport.decoded(path: "/api/playlist/list",
            fields: ["cat": category, "order": "hot", "offset": offset, "limit": limit, "total": true],
            credential: credential, profile: .search, retryTLS: true)
        let items = Self.unique(response.playlists.map(\.resource))
        let more = response.more && !items.isEmpty
        return .init(groups: [.init(kind: .playlist, items: items, hasMore: more)],
                     nextOffset: offset + response.playlists.count, hasMore: more)
    }

    @concurrent func search(_ query: String, kind: NeteaseSearchKind, offset: Int = 0,
                            credential: NeteaseCredential?) async throws -> NeteaseSearchPage {
        let data = try await transport.request(path: "/api/search/get",
            fields: ["s": query, "type": kind.rawValue, "limit": 30, "offset": offset],
            credential: credential, profile: .search, retryTLS: true)
        var page = try Self.parse(data, kind: kind, offset: offset)
        let songs = page.groups.flatMap(\.items).compactMap(\.song)
        let missing = songs.filter { $0.artworkURL == nil || $0.duration <= 0 }.map(\.id)
        if !missing.isEmpty {
            do {
                let details = try await NeteaseMusicClient(transport: transport).songs(ids: Array(Set(missing)).sorted(), credential: credential)
                let lookup = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for group in page.groups.indices {
                    for index in page.groups[group].items.indices {
                        let old = page.groups[group].items[index]
                        if old.kind == .song, let song = lookup[old.resourceID] {
                            page.groups[group].items[index] = Self.resource(song)
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        return page
    }

    @concurrent func suggestions(_ query: String, credential: NeteaseCredential?) async throws -> NeteaseSearchSuggestions {
        async let words = keywords(query, credential: credential)
        async let matches = entities(query, credential: credential)
        return try await .init(keywords: words, resources: matches)
    }

    @concurrent private func keywords(_ query: String, credential: NeteaseCredential?) async throws -> [String] {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Match: Decodable { let keyword: String }
                let allMatch: [Match]?
            }
            let result: Result?
        }
        let data = try await transport.requestWeb(path: "/api/search/suggest/keyword", fields: ["s": query], credential: credential, retryTLS: true)
        let response = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<String>()
        return Array((response.result?.allMatch ?? []).map(\.keyword).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8))
    }

    @concurrent private func entities(_ query: String, credential: NeteaseCredential?) async throws -> [NeteaseSearchResource] {
        struct Response: Decodable {
            struct Result: Decodable { let artist: [Artist]?; let album: [Album]?; let orders: [String]? }
            let result: Result?
        }
        do {
            let response: Response = try await transport.decoded(path: "/api/search/suggest/multimatch",
                fields: ["s": query, "type": 1], credential: credential, profile: .search, retryTLS: true)
            guard let result = response.result else { return [] }
            return Self.unique((result.orders ?? ["artist", "album"]).flatMap { key -> [NeteaseSearchResource] in
                return switch key { case "artist": (result.artist ?? []).map(\.resource)
                case "album": (result.album ?? []).map(\.resource)
                default: [] }
            }).prefix(3).map { $0 }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return [] }
    }

    static func parse(_ data: Data, kind: NeteaseSearchKind, offset: Int) throws -> NeteaseSearchPage {
        struct Response: Decodable { let code: Int; let result: Result? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == 200 else { throw NeteaseAccountError.server(response.code) }
        guard let result = response.result else { return .init(groups: [], nextOffset: offset, hasMore: false) }
        if kind == .combined {
            var seen = Set<NeteaseSearchKind>()
            let groups = (result.order ?? []).compactMap { key -> NeteaseSearchGroup? in
                let group: NeteaseSearchGroup?
                switch key {
                case "song": group = result.song.map { .init(kind: .song, items: unique(($0.songs ?? []).map(\.resource)), hasMore: $0.more == true) }
                case "artist": group = result.artist.map { .init(kind: .artist, items: unique(($0.artists ?? []).map(\.resource)), hasMore: $0.more == true) }
                case "album": group = result.album.map { .init(kind: .album, items: unique(($0.albums ?? []).map(\.resource)), hasMore: $0.more == true) }
                case "playList": group = result.playList.map { .init(kind: .playlist, items: unique(($0.playLists ?? []).map(\.resource)), hasMore: $0.more == true) }
                default: group = nil
                }
                guard let group, !group.items.isEmpty, seen.insert(group.kind).inserted else { return nil }
                return group
            }
            return .init(groups: groups, nextOffset: 0, hasMore: false)
        }
        let raw: [NeteaseSearchResource]
        let count: Int?
        switch kind {
        case .song: raw = (result.songs ?? []).map(\.resource); count = result.songCount
        case .artist: raw = (result.artists ?? []).map(\.resource); count = result.artistCount
        case .album: raw = (result.albums ?? []).map(\.resource); count = result.albumCount
        case .playlist: raw = (result.playlists ?? []).map(\.resource); count = result.playlistCount
        case .combined: raw = []; count = nil
        }
        let next = offset + raw.count
        let more = !raw.isEmpty && (result.hasMore ?? count.map { next < $0 } ?? (raw.count == 30))
        return .init(groups: [.init(kind: kind, items: unique(raw), hasMore: more)], nextOffset: next, hasMore: more)
    }

    static func resource(_ song: NeteaseMusicSong) -> NeteaseSearchResource {
        .init(kind: .song, resourceID: song.id, title: song.title, subtitle: song.artist, artworkURL: song.artworkURL, song: song)
    }
    private static func unique(_ values: [NeteaseSearchResource]) -> [NeteaseSearchResource] {
        var seen = Set<String>(); return values.filter { $0.resourceID > 0 && seen.insert($0.id).inserted }
    }
    private struct Result: Decodable {
        struct Group: Decodable {
            let songs: [Song]?; let artists: [Artist]?; let albums: [Album]?; let playLists: [Playlist]?; let more: Bool?
        }
        let order: [String]?
        let song: Group?; let artist: Group?; let album: Group?; let playList: Group?
        let songs: [Song]?; let artists: [Artist]?; let albums: [Album]?; let playlists: [Playlist]?
        let songCount: Int?; let artistCount: Int?; let albumCount: Int?; let playlistCount: Int?; let hasMore: Bool?
    }
    private struct Artist: Decodable {
        let id: Int64; let name: String; let picUrl: String?; let img1v1Url: String?
        var resource: NeteaseSearchResource { .init(kind: .artist, resourceID: id, title: name, subtitle: "艺人", artworkURL: NeteaseMusicClient.url(picUrl ?? img1v1Url)) }
    }
    private struct Album: Decodable {
        let id: Int64; let name: String; let picUrl: String?; let artist: Artist?; let artists: [Artist]?
        var resource: NeteaseSearchResource { .init(kind: .album, resourceID: id, title: name, subtitle: artists?.map(\.name).joined(separator: " / ") ?? artist?.name ?? "", artworkURL: NeteaseMusicClient.url(picUrl)) }
    }
    private struct Playlist: Decodable {
        struct Creator: Decodable { let nickname: String }
        let id: Int64; let name: String; let coverImgUrl: String?; let creator: Creator?
        var resource: NeteaseSearchResource { .init(kind: .playlist, resourceID: id, title: name, subtitle: creator?.nickname ?? "", artworkURL: NeteaseMusicClient.url(coverImgUrl)) }
    }
    private struct Song: Decodable {
        let id: Int64; let name: String; let ar: [Artist]?; let artists: [Artist]?; let al: Album?; let album: Album?; let dt: Double?; let duration: Double?
        var resource: NeteaseSearchResource {
            let performers = ar ?? artists ?? []
            let release = al ?? album
            let song = NeteaseMusicSong(id: id, title: name, artist: performers.map(\.name).joined(separator: " / "), album: release?.name ?? "",
                artworkURL: NeteaseMusicClient.url(release?.picUrl), duration: (dt ?? duration ?? 0) / 1000,
                artists: performers.map { .init(id: $0.id, name: $0.name, artworkURL: NeteaseMusicClient.url($0.picUrl ?? $0.img1v1Url)) }, albumID: release?.id)
            return NeteaseSearchClient.resource(song)
        }
    }
}
