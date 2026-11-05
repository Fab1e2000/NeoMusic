import Foundation

struct NeteaseDailySnapshot: Codable, Sendable, Identifiable {
    let id: String
    let date: String
    let songs: [NeteaseMusicSong]

    init(date: String, songs: [NeteaseMusicSong], id: String = UUID().uuidString) {
        self.id = id; self.date = date; self.songs = songs
    }
    private enum CodingKeys: String, CodingKey { case id, date, songs }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        songs = try values.decode([NeteaseMusicSong].self, forKey: .songs)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? date
    }
}

enum NeteaseHomeCategory: String, CaseIterable, Codable, Sendable {
    case likedSongs, songRecommendations, recommendedPlaylists, radarPlaylists
    case charts, followedArtists, scenePlaylists, newSongs
}

enum NeteaseHomeQuickAction: String, CaseIterable, Sendable {
    case dailySongs, hotSongs, heartMode, privateRadar, privateRoaming, similarSongs
}

enum NeteaseHomeQuickActionState: Equatable, Sendable {
    case loading
    case failed(String)
}

enum NeteaseHomeQuickActionResult: Sendable {
    case daily(NeteaseDailySnapshot)
    case playlist(NeteaseMusicPlaylist)
    case songs([NeteaseMusicSong])
    case roaming(id: UUID, songs: [NeteaseMusicSong])
}

enum NeteaseHomeActionError: LocalizedError {
    case loginRequired, noLikedSongs, noFavoritePlaylist, noCurrentOnlineSong, noRadar, noHotChart, emptySongs
    case requestFailed(String)
    var errorDescription: String? {
        switch self {
        case .loginRequired: "请先登录网易云音乐。"
        case .noLikedSongs: "喜欢歌曲后，就可以从你喜欢的音乐开始。"
        case .noFavoritePlaylist: "暂未读取到你的喜欢歌单，请刷新后重试。"
        case .noCurrentOnlineSong: "请先播放一首网易云歌曲，再查找相似歌曲。"
        case .noRadar: "你的首页暂时没有可用的雷达歌单。"
        case .noHotChart: "排行榜目录中暂时没有热歌榜。"
        case .emptySongs: "暂时没有可播放的歌曲，请稍后重试。"
        case .requestFailed(let message): message
        }
    }
}

/// Homepage resources follow the existing NeoDizzy/MeloX GPL-3.0 resource mapping.
/// Preserve server titles and resources; the store arranges supported categories.
struct NeteaseHomeFeed: Codable, Sendable, Equatable {
    var blocks: [Block]
    let hasMore: Bool?
    let cursor: String?

    /// Categories verified in the captured authenticated feed. Other codes remain
    /// available for diagnostics without being assigned a guessed category.
    enum BlockKind: String, Codable, Sendable {
        case charts = "NEOMUSIC_CHARTS"
        case followedArtists = "NEOMUSIC_FOLLOWED_RELEASES"
        case recommendedPlaylists = "HOMEPAGE_BLOCK_PLAYLIST_RCMD"
        case recommendedSongs = "HOMEPAGE_BLOCK_STYLE_RCMD"
        case radarPlaylists = "HOMEPAGE_BLOCK_MGC_PLAYLIST"
        case vipSongs = "HOMPAGE_BLOCK_VIP_RCMD"
        case newReleases = "HOMEPAGE_BLOCK_NEW_ALBUM_NEW_SONG"
        case officialPlaylists = "HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST"
    }

    struct Block: Codable, Sendable, Equatable, Identifiable {
        var kind: BlockKind? {
            switch blockCode {
            case "HOMEPAGE_BLOCK_TOPLIST": .charts
            case "HOMEPAGE_BLOCK_OLD_SUBSCRIBE_ARTIST_NEW": .followedArtists
            default: BlockKind(rawValue: blockCode)
            }
        }
        let blockCode: String
        let uiElement: Element?
        let creatives: [Creative]?
        var category: NeteaseHomeCategory? {
            let normalizedTitle = title.filter { !$0.isWhitespace }
            switch blockCode {
            case "NEOMUSIC_LIKED_SONGS": return .likedSongs
            case "NEOMUSIC_NEW_SONGS": return .newSongs
            case "NEOMUSIC_RECOMMENDED_PLAYLISTS": return .recommendedPlaylists
            default: break
            }
            switch kind {
            case .charts: return .charts
            case .followedArtists: return .followedArtists
            case .recommendedPlaylists: return .recommendedPlaylists
            case .radarPlaylists: return .radarPlaylists
            case .officialPlaylists: return .scenePlaylists
            case .newReleases: return normalizedTitle.contains("每周新热趋势") ? .newSongs : nil
            case .recommendedSongs, .vipSongs:
                if normalizedTitle.contains("根据你喜欢") || normalizedTitle.contains("根据你喜爱") { return .likedSongs }
                if normalizedTitle.hasPrefix("根据") { return .songRecommendations }
                return nil
            case nil: return nil
            }
        }
        var contentIdentity: String { blockCode + "/" + (title.isEmpty ? creatives?.first?.creativeId ?? "" : title) }
        var id: String { category?.rawValue ?? blockCode + "/" + (creatives?.first?.creativeId ?? "") }
        var title: String { uiElement?.subTitle?.title ?? uiElement?.mainTitle?.title ?? "" }
        var hasDisplayableResources: Bool {
            resources.contains { resource in
                if category == .likedSongs || category == .songRecommendations {
                    return resource.song != nil && !resource.title.isEmpty
                }
                if resource.resourceType?.lowercased() == "song" { return resource.song != nil && !resource.title.isEmpty }
                return !resource.title.isEmpty
            }
        }
        var resources: [Resource] {
            var result: [Resource] = []
            var indices: [String: Int] = [:]
            for resource in (creatives ?? []).flatMap({ $0.resources ?? [] }) where resource.isSupportedMusicResource {
                if let index = indices[resource.id] {
                    if !result[index].isDisplayable, resource.isDisplayable { result[index] = resource }
                } else { indices[resource.id] = result.count; result.append(resource) }
            }
            return result
        }
    }
    struct Creative: Codable, Sendable, Equatable {
        let creativeId: String?
        let creativeType: String?
        let uiElement: Element?
        let resources: [Resource]?
    }
    struct Element: Codable, Sendable, Equatable {
        struct Title: Codable, Sendable, Equatable { let title: String? }
        struct Image: Codable, Sendable, Equatable { let imageUrl: String? }
        let mainTitle: Title?
        let subTitle: Title?
        let image: Image?
    }
    struct Resource: Codable, Sendable, Equatable, Identifiable {
        let resourceType: String?
        let resourceID: String?
        let uiElement: Element?
        let song: NeteaseMusicSong?
        var id: String {
            let type = resourceType?.lowercased() ?? ""
            return (type == "playlist" ? "list" : type) + "/" + (resourceID ?? song.map { String($0.id) } ?? "")
        }
        var isDisplayable: Bool { !title.isEmpty && (resourceType?.lowercased() != "song" || song != nil) }
        var numericID: Int64? { resourceID.flatMap(Int64.init) }
        var isSupportedMusicResource: Bool {
            guard let numericID, numericID > 0 else { return false }
            return ["song", "list", "playlist", "album", "artist"].contains(resourceType?.lowercased() ?? "")
        }
        var title: String { uiElement?.mainTitle?.title ?? song?.title ?? "" }
        var artworkURL: URL? { NeteaseMusicClient.url(uiElement?.image?.imageUrl) ?? song?.artworkURL }
        enum CodingKeys: String, CodingKey { case resourceType, resourceId, uiElement, resourceExtInfo, song }
        private struct FeedSong: Decodable {
            let model: NeteaseMusicSong
            enum CodingKeys: String, CodingKey { case id, name, artists, ar, album, al, duration, dt }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let artists = try c.decodeIfPresent([NeteaseMusicClient.Song.Artist].self, forKey: .artists)
                    ?? c.decode([NeteaseMusicClient.Song.Artist].self, forKey: .ar)
                let album = try c.decodeIfPresent(NeteaseMusicClient.Song.Album.self, forKey: .album)
                    ?? c.decode(NeteaseMusicClient.Song.Album.self, forKey: .al)
                let duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? c.decode(Double.self, forKey: .dt)
                model = try .init(id: c.decode(Int64.self, forKey: .id), title: c.decode(String.self, forKey: .name),
                    artist: artists.map(\.name).joined(separator: " / "), album: album.name,
                    artworkURL: NeteaseMusicClient.url(album.picUrl), duration: duration / 1000,
                    artists: artists.compactMap { a in a.id.map { .init(id: $0, name: a.name, artworkURL: nil) } }, albumID: album.id)
            }
        }
        private struct Extra: Decodable {
            let songData: FeedSong?
            let song: FeedSong?
        }
        init(song: NeteaseMusicSong) {
            resourceType = "song"; resourceID = String(song.id); uiElement = nil; self.song = song
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            resourceType = try c.decodeIfPresent(String.self, forKey: .resourceType)
            resourceID = (try? c.decode(String.self, forKey: .resourceId)) ?? (try? c.decode(Int64.self, forKey: .resourceId)).map(String.init)
            uiElement = try c.decodeIfPresent(Element.self, forKey: .uiElement)
            let extra = try? c.decode(Extra.self, forKey: .resourceExtInfo)
            song = (try? c.decode(NeteaseMusicSong.self, forKey: .song)) ?? extra?.songData?.model ?? extra?.song?.model
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(resourceType, forKey: .resourceType)
            try c.encodeIfPresent(resourceID, forKey: .resourceId)
            try c.encodeIfPresent(uiElement, forKey: .uiElement)
            try c.encodeIfPresent(song, forKey: .song)
        }
    }
    func merging(_ page: Self) -> Self {
        var result = blocks
        for block in page.blocks {
            if let index = result.firstIndex(where: { $0.contentIdentity == block.contentIdentity }) {
                let previous = result[index]
                let creatives = (previous.creatives ?? []) + (block.creatives ?? [])
                result[index] = Block(blockCode: previous.blockCode, uiElement: previous.uiElement ?? block.uiElement, creatives: creatives)
            }
            else { result.append(block) }
        }
        return .init(blocks: result, hasMore: page.hasMore, cursor: page.cursor)
    }
}

extension NeteaseMusicClient {
    @concurrent func homeFeed(credential: NeteaseCredential?, refresh: Bool = false, cursor: String? = nil) async throws -> NeteaseHomeFeed {
        struct Response: Decodable { let data: NeteaseHomeFeed }
        var fields: [String: any Sendable] = ["refresh": refresh]
        if let cursor, !cursor.isEmpty { fields["cursor"] = cursor }
        let response: Response = try await read("/api/homepage/block/page", fields, credential)
        return response.data
    }
}
