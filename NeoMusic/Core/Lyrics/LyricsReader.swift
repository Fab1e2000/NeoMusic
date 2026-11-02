import AVFoundation
import CryptoKit
import Foundation

actor LyricsReader {
    enum Failure: Error { case invalidFile, outsideLibrary }
    private let storageDirectory: URL
    init(storageDirectory: URL) { self.storageDirectory = storageDirectory }

    func load(songID: String, audioURL: URL, root: URL) async throws -> LyricsDocument {
        try Task.checkCancellation()
        let saved = importedURL(songID)
        if FileManager.default.fileExists(atPath: saved.path) {
            var result = try read(saved)
            result.source = "已导入歌词"
            return result
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let canonicalAudio = audioURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalAudio.pathComponents.starts(with: canonicalRoot), canonicalAudio.pathComponents.count > canonicalRoot.count else { throw Failure.outsideLibrary }
        let stem = canonicalAudio.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        let candidates = try FileManager.default.contentsOfDirectory(at: canonicalAudio.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension.lowercased() == "lrc" && $0.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping == stem }
            .sorted { $0.path < $1.path }
        var sidecarFailure: Error?
        for candidate in candidates {
            try Task.checkCancellation()
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            do {
                var result = try read(candidate)
                result.source = "同目录 LRC"
                if !result.isEmpty { return result }
            } catch { sidecarFailure = error }
        }
        let asset = AVURLAsset(url: canonicalAudio)
        if let text = try? await asset.load(.lyrics), !text.isEmpty {
            var result = LyricsDocument.parse(text)
            result.source = "内嵌歌词"
            return result
        }
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            for item in (try? await asset.loadMetadata(for: format)) ?? [] {
                try Task.checkCancellation()
                let key = (item.identifier?.rawValue ?? String(describing: item.key)).lowercased()
                guard ["lyrics", "uslt", "©lyr", "%a9lyr"].contains(where: key.contains) else { continue }
                if let text = try? await item.load(.stringValue), !text.isEmpty {
                    var result = LyricsDocument.parse(text)
                    result.source = "内嵌歌词"
                    return result
                }
            }
        }
        if let sidecarFailure { throw sidecarFailure }
        return LyricsDocument()
    }

    func importFile(_ url: URL, songID: String) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let document = try read(url)
        guard !document.isEmpty else { throw Failure.invalidFile }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        // Keep original text and encoding; never modify the source file.
        let data = try Data(contentsOf: url)
        try data.write(to: importedURL(songID), options: .atomic)
    }

    private func importedURL(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageDirectory.appendingPathComponent(key).appendingPathExtension("lrc")
    }

    private func read(_ url: URL) throws -> LyricsDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw Failure.invalidFile }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw Failure.invalidFile }
        return LyricsDocument.parse(text)
    }
}
