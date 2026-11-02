import AVFoundation
import Foundation
import ImageIO

struct LocalAudioMetadata: Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var trackNumber = 0
    var discNumber = 0
    var duration: Double = 0
    var artworkData: Data?
}

/// Native metadata collection, independent of the library's album grouping and identity rules.
enum LocalAudioMetadataReader {
    static func read(_ url: URL) async throws -> LocalAudioMetadata {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var output = LocalAudioMetadata()
        let seconds = try? await asset.load(.duration).seconds
        if let seconds, seconds.isFinite, seconds > 0 { output.duration = seconds }
        else {
            let audio = try AVAudioFile(forReading: url)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
            output.duration = Double(audio.length) / audio.processingFormat.sampleRate
        }
        // A readable audio stream remains indexable if its optional tags cannot be loaded.
        var entries = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            try Task.checkCancellation()
            entries += (try? await asset.loadMetadata(for: format)) ?? []
        }
        var artists: [String] = []
        var albumArtists: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            let keys = [entry.identifier?.rawValue, entry.key as? String].compactMap { $0 }.map {
                $0.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
            }
            func matches(_ values: Set<String>) -> Bool {
                keys.contains { key in values.contains(key) || values.contains(String(key.split(separator: "/").last ?? "")) }
            }
            let text = ((try? await entry.load(.stringValue)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if output.title.isEmpty && (entry.commonKey == .commonKeyTitle || matches(["title", "tit2", "©nam"])) { output.title = text }
                if output.album.isEmpty && (entry.commonKey == .commonKeyAlbumName || matches(["album", "talb", "©alb"])) { output.album = text }
                if matches(["albumartist", "albumartists", "tpe2", "aart"]) { appendCredits(text, to: &albumArtists) }
                else if entry.commonKey == .commonKeyArtist || matches(["artist", "artists", "tpe1", "©art", "author"]) { appendCredits(text, to: &artists) }
            }
            if output.trackNumber == 0 && matches(["tracknumber", "trck", "trkn"]) {
                output.trackNumber = number(text)
                if output.trackNumber == 0, let bytes = try? await entry.load(.dataValue), bytes.count >= 4 {
                    output.trackNumber = Int(bytes[bytes.startIndex + 2]) * 256 + Int(bytes[bytes.startIndex + 3])
                }
            }
            if output.discNumber == 0 && matches(["discnumber", "disk", "tpos"]) {
                output.discNumber = number(text)
                if output.discNumber == 0, let bytes = try? await entry.load(.dataValue), bytes.count >= 4 {
                    output.discNumber = Int(bytes[bytes.startIndex + 2]) * 256 + Int(bytes[bytes.startIndex + 3])
                }
            }
            if output.artworkData == nil && (entry.commonKey == .commonKeyArtwork || matches(["apic", "covr", "metadatablockpicture"])) {
                if let data = try? await entry.load(.dataValue), validArtwork(data) { output.artworkData = data }
            }
        }
        try Task.checkCancellation()
        let comments = flacComments(url)
        if let values = comments["ARTIST"], !values.isEmpty { artists = []; values.forEach { appendCredits($0, to: &artists) } }
        if let values = comments["ALBUMARTIST"], !values.isEmpty { albumArtists = []; values.forEach { appendCredits($0, to: &albumArtists) } }
        output.artist = artists.joined(separator: " / ")
        output.albumArtist = albumArtists.joined(separator: " / ")
        if output.artworkData == nil, let cover = coverURL(in: url.deletingLastPathComponent()),
           let data = try? Data(contentsOf: cover), validArtwork(data) { output.artworkData = data }
        return output
    }

    static func number(_ value: String) -> Int {
        max(0, Int(value.split(separator: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0)
    }

    static func appendCredits(_ value: String, to credits: inout [String]) {
        for part in value.split(separator: "\0") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !credits.contains(name) { credits.append(name) }
        }
    }

    static func coverURL(in directory: URL) -> URL? {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return candidates.filter { url in
            guard ["cover", "folder"].contains(url.deletingPathExtension().lastPathComponent.lowercased()),
                  ["jpg", "jpeg", "png", "heic", "webp"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.first { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return validArtwork(data)
        }
    }

    // FLAC's Vorbis-comment block stores repeated credits which AVFoundation can collapse.
    // This reader only handles bounded comments; audio decoding remains with the system.
    static func flacComments(_ url: URL) -> [String: [String]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        do {
            guard try handle.read(upToCount: 4) == Data([102, 76, 97, 67]) else { return [:] }
            while let header = try handle.read(upToCount: 4), header.count == 4 {
                let length = Int(header[1]) * 65536 + Int(header[2]) * 256 + Int(header[3])
                if header[0] & 127 == 4 {
                    guard length <= 4_194_304, let payload = try handle.read(upToCount: length), payload.count == length else { return [:] }
                    return parseComments(payload)
                }
                if header[0] & 128 != 0 { break }
                try handle.seek(toOffset: handle.offset() + UInt64(length))
            }
        } catch { return [:] }
        return [:]
    }

    static func parseComments(_ payload: Data) -> [String: [String]] {
        let bytes = [UInt8](payload)
        var cursor = 0
        func readLength() -> Int? {
            guard bytes.count - cursor >= 4 else { return nil }
            let value = Int(bytes[cursor]) + Int(bytes[cursor + 1]) * 256 + Int(bytes[cursor + 2]) * 65536 + Int(bytes[cursor + 3]) * 16777216
            cursor += 4
            return value
        }
        guard let vendorLength = readLength(), vendorLength <= bytes.count - cursor else { return [:] }
        cursor += vendorLength
        guard let count = readLength(), count <= (bytes.count - cursor) / 4 else { return [:] }
        var result: [String: [String]] = [:]
        for _ in 0..<count {
            guard let length = readLength(), length <= bytes.count - cursor else { return [:] }
            let entry = String(bytes: bytes[cursor..<cursor + length], encoding: .utf8)
            cursor += length
            guard let entry, let separator = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<separator].uppercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            if name == "ARTIST" || name == "ALBUMARTIST" {
                let value = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[name, default: []].append(value) }
            }
        }
        return result
    }

    private static func validArtwork(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
