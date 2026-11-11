import Foundation

struct NeteaseMusicSong: Codable, Sendable, Equatable, Identifiable {
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let duration: Double
    var unavailable = false
    var artists: [NeteaseArtistReference]? = nil
    var albumID: Int64? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
}
struct NeteaseMusicPlaylist: Codable, Sendable, Equatable, Identifiable {
    let id: Int64
    let title: String
    let creator: String
    let creatorID: Int64
    let artworkURL: URL?
    let trackCount: Int
    let isFavorites: Bool
    /// 网易云账号收藏的歌单。旧缓存没有这个字段时视为未收藏。
    var isSubscribed: Bool? = nil
    var createTime: Date? = nil
    var updateTime: Date? = nil
}
struct NeteasePlaylistDetail: Codable, Sendable {
    let playlist: NeteaseMusicPlaylist
    let songs: [NeteaseMusicSong]
    let addedTimes: [Int64: Date]
    var trackIDs: [Int64]? = nil
    var loadedTrackCount: Int? = nil

    var orderedTrackIDs: [Int64] { trackIDs ?? songs.map(\.id) }
    var nextOffset: Int { min(loadedTrackCount ?? songs.count, orderedTrackIDs.count) }
    var isComplete: Bool { nextOffset >= orderedTrackIDs.count }
}
enum NeteaseMusicQuality: String, Codable, CaseIterable, Sendable {
    case standard, high = "exhigh", lossless, hiRes = "hires"
    var title: String {
        switch self { case .standard: "标准"; case .high: "高品质"; case .lossless: "无损"; case .hiRes: "Hi-Res" }
    }
    var fallbacks: [Self] {
        switch self { case .standard: [.standard]; case .high: [.high, .standard]; case .lossless: [.lossless, .high, .standard]; case .hiRes: [.hiRes, .lossless, .high, .standard] }
    }
}
struct NeteaseMusicStream: Sendable {
    let url: URL
    let expiresAt: Date
    let quality: NeteaseMusicQuality
}
struct NeteaseMusicLyrics: Codable, Sendable {
    let original: String
    let translation: String
}
enum NeteaseMusicError: LocalizedError {
    case unavailable
    var errorDescription: String? { "此歌曲当前没有可用的完整音源。" }
}
