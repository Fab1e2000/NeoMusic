import AudioTagBridge
import AVFoundation
import Foundation
import ImageIO

/// Tags only newly prepared download files. Source audio bytes are not re-encoded.
nonisolated enum DownloadedAudioTags {
    struct Metadata: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let albumArtist: String
        let trackNumber: Int
        let discNumber: Int
        var artwork: Data? = nil
        var lyrics: String? = nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `url` belongs to the caller's staging area. Publish it only after this succeeds.
    @concurrent static func write(_ metadata: Metadata, to url: URL) async throws {
        try Task.checkCancellation()
        try await validate(url)
        var values = ["TITLE": [metadata.title], "ARTIST": [metadata.artist],
                      "ALBUM": [metadata.album], "ALBUMARTIST": [metadata.albumArtist]]
        if metadata.trackNumber > 0 { values["TRACKNUMBER"] = [String(metadata.trackNumber)] }
        if metadata.discNumber > 0 { values["DISCNUMBER"] = [String(metadata.discNumber)] }
        if let lyrics = metadata.lyrics, !lyrics.isEmpty { values["LYRICS"] = [lyrics] }
        var document: [String: Any] = ["values": values]
        if let image = metadata.artwork, image.count <= 20 * 1024 * 1024,
           let source = CGImageSourceCreateWithData(image as CFData, nil),
           CGImageSourceGetCount(source) > 0 {
            document["cover"] = image.base64EncodedString()
            let type = CGImageSourceGetType(source) as String?
            document["mime"] = type == "public.png" ? "image/png" : "image/jpeg"
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        try Task.checkCancellation()
        _ = try url.path.withCString { path in
            try json.withCString { data in try response(NMTagWrite(path, data)) }
        }
        try Task.checkCancellation()
        try await validate(url)
    }

    @concurrent static func read(_ url: URL) async throws -> Metadata {
        try Task.checkCancellation()
        let result = try url.path.withCString { try response(NMTagRead($0)) }
        guard let values = result["values"] as? [String: [String]] else {
            throw Failure(message: "音频标签数据无效。")
        }
        func value(_ key: String) -> String { values[key]?.first ?? "" }
        let cover = (result["cover"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
        let lyrics = value("LYRICS")
        return Metadata(title: value("TITLE"), artist: value("ARTIST"), album: value("ALBUM"),
                        albumArtist: value("ALBUMARTIST"), trackNumber: Int(value("TRACKNUMBER")) ?? 0,
                        discNumber: Int(value("DISCNUMBER")) ?? 0, artwork: cover,
                        lyrics: lyrics.isEmpty ? nil : lyrics)
    }

    private static func response(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let pointer else { throw Failure(message: "读取音频标签失败。") }
        defer { NMTagFree(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "音频标签数据无效。")
        }
        if let error = value["error"] as? String { throw Failure(message: error) }
        return value
    }

    private static func validate(_ url: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw Failure(message: "下载的音频文件损坏或无法播放。")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw Failure(message: "下载的音频文件不完整。")
        }
        try Task.checkCancellation()
    }
}
