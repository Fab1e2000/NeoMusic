import Foundation

enum NeteaseDownloadState: Equatable, Sendable {
    case queued, waiting, downloading(Double), processing, downloaded, failed(String)
    var isActive: Bool {
        switch self { case .queued, .waiting, .downloading, .processing: true; default: false }
    }
}

struct NeteaseDownloadSong: Codable, Sendable, Equatable {
    var song: NeteaseMusicSong
    var albumArtist: String
    var trackNumber: Int
    var discNumber: Int
}

struct NeteaseDownloadRecord: Codable, Sendable, Equatable {
    let metadata: NeteaseDownloadSong
    let relativePath: String
    let lyricsRelativePath: String?
    let quality: NeteaseMusicQuality
    let downloadedAt: Date
    var ownerID: Int64? = nil
    var songID: Int64 { metadata.song.id }
    var song: NeteaseMusicSong { metadata.song }
}

struct NeteaseDownloadCollection: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case album, playlist }
    let kind: Kind
    let id: Int64
    let ownerID: Int64
    let title: String
    let artist: String
    let orderedSongIDs: [Int64]
    var key: String { "\(kind.rawValue):\(id)" }
}

struct NeteaseDownloadSource: Sendable {
    let url: URL
    let type: String
    let quality: NeteaseMusicQuality
    let size: Int64?
}

struct NeteaseDownloadJob: Codable, Sendable {
    let id: UUID
    let ownerID: Int64
    let metadata: NeteaseDownloadSong
    let requestedQuality: NeteaseMusicQuality
    var actualQuality: NeteaseMusicQuality?
    var type: String?
    var expectedSize: Int64?
    var stagedFilename: String?
    var destinationRelativePath: String?
    var error: String?
    var cancelled = false
}

enum NeteaseDownloadError: LocalizedError {
    case unavailable, invalidFile, accountChanged, missingMetadata
    var errorDescription: String? {
        switch self {
        case .unavailable: "此歌曲没有可下载的完整音源。"
        case .invalidFile: "下载文件不完整或格式错误，请重试。"
        case .accountChanged: "网易云账号已变化，请重新发起下载。"
        case .missingMetadata: "歌曲信息不完整，请重试。"
        }
    }
}
