import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct LocalTrack: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int
    let duration: Double
    var artworkData: Data?
    let addedDate: Date
    var albumDirectory: String? = nil
    var discNumber: Int? = nil
    var fingerprint: LocalFileFingerprint? = nil
    var artworkKey: String? = nil
    var artworkBackdrop: AlbumArtworkBackdrop? = nil
    var year: Int? = nil
}

struct LocalFileFingerprint: Codable, Sendable, Equatable {
    let version: Int
    let size: Int
    let modified: Date?
    let covers: [String]
}

struct LocalScanResult: Sendable {
    var tracks: [LocalTrack] = []
    var unsupportedCount = 0
    var failures: [String] = []
    var failedDirectoryPaths: [String] = []
    var issues: [String] = []
    var reusedCount = 0
}

actor LocalMusicScanner {
    static let supportedExtensions: Set<String> = ["mp3", "aac", "m4a", "alac", "flac", "wav", "aiff", "aif"]

    private var generation = 0

    static func prepareDirectory(documents: URL) throws -> URL {
        let root = AppStoragePaths.musicDirectory(in: documents)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instructions = root.appendingPathComponent("如何添加音乐.txt")
        let oldInstructions = """
            将音乐文件放入此文件夹或任意层级子文件夹。
            支持 MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF；不支持的文件会跳过并提示数量。
            优先使用内嵌标签和封面，也可在同目录放置 cover.jpg 或 folder.jpg。
            应用启动、回到前台或资料库下拉刷新时扫描。隐藏文件不会读取。
            文件移动或改名视为删除后新增；移除文件后，资料库会移除相应记录。
            """
        let albumInstructions = oldInstructions.replacingOccurrences(of: "优先使用内嵌标签和封面，也可在同目录放置 cover.jpg 或 folder.jpg。", with: "每个直接包含歌曲的文件夹为一张专辑，以文件夹名显示。歌曲信息优先读取内嵌标签；封面优先内嵌图片，也支持同目录 cover/folder 的 JPG、PNG 等图片（不区分大小写）。")
        let updatedInstructions = albumInstructions.replacingOccurrences(of: "应用启动、回到前台或资料库下拉刷新时扫描。", with: "应用启动或回到前台时自动扫描。")
        let existingInstructions = try? String(contentsOf: instructions, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: instructions.path) || existingInstructions == oldInstructions || existingInstructions == albumInstructions {
            try updatedInstructions.write(to: instructions, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func folderDisc(_ name: String) -> Int {
        let lower = name.lowercased()
        for prefix in ["disc", "disk", "cd"] where lower.hasPrefix(prefix) {
            let number = lower.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: " _.-"))
            if !number.isEmpty, number.allSatisfy(\.isNumber), let value = Int(number), value > 0 { return value }
        }
        return 1
    }

    func scan(root: URL, previousTracks: [LocalTrack] = [], files selectedFiles: [URL]? = nil) async throws -> LocalScanResult {
        generation += 1
        let scanGeneration = generation
        let previous = Dictionary(previousTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = LocalScanResult()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            AppLogger.library.error("library.scan.root_unavailable")
            throw CocoaError(.fileReadNoSuchFile)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .isPackageKey]
        var unreadableDirectories: [URL] = []
        var directoryIssues: [String] = []
        var listingFailures: [String] = []
        func files(in directory: URL) throws -> [URL] {
            var result: [URL] = []
            let children: [URL]
            do { children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys + [.isDirectoryKey], options: [.skipsHiddenFiles]) }
            catch {
                if directory == root {
                    AppLogger.failure(AppLogger.library, "library.scan.list_root", error: error)
                    throw error
                }
                throw DirectoryReadFailure(url: directory, underlying: error)
            }
            for url in children {
                try Task.checkCancellation()
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: Set(keys + [.isDirectoryKey])) }
                catch {
                    let path = url.pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
                    listingFailures.append(path)
                    unreadableDirectories.append(url)
                    directoryIssues.append("\(path)：\(error.localizedDescription)")
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if url.lastPathComponent == "__MACOSX" || values.isPackage == true { continue }
                    do { result += try files(in: url) }
                    catch is CancellationError { throw CancellationError() }
                    catch { unreadableDirectories.append(url); directoryIssues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
                else if values.isRegularFile == true { result.append(url) }
            }
            return result
        }
        let listed: [URL]
        if let selectedFiles { listed = selectedFiles.sorted { $0.path < $1.path } }
        else { listed = try files(in: root).sorted { $0.path < $1.path } }
        result.failedDirectoryPaths = unreadableDirectories.map { $0.pathComponents.dropFirst(rootComponents.count).joined(separator: "/") }
        result.issues = directoryIssues
        result.failures = listingFailures
        var directoryCovers: [String: (candidates: [URL], signature: [String])] = [:]
        var checkedCoverArtwork: [String: Data?] = [:]
        for url in listed {
            try Task.checkCancellation()
            let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                let ext = url.pathExtension.lowercased()
                let knownAudio: Set<String> = ["ogg", "oga", "opus", "wma", "ape", "dsf", "dff", "wv", "mka", "mp2", "aifc", "caf", "ac3", "dts"]
                if knownAudio.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .audio) == true {
                    result.unsupportedCount += 1
                }
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                let directory = url.deletingLastPathComponent()
                let directoryID = components.dropFirst(rootComponents.count).dropLast().joined(separator: "/")
                let cover: (candidates: [URL], signature: [String])
                if let cached = directoryCovers[directoryID] { cover = cached }
                else {
                    let coverFiles: [URL]
                    var coverLookupFailed = false
                    do {
                        coverFiles = try manager.contentsOfDirectory(at: directory,
                            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey])
                            .filter(LocalAudioMetadataReader.isCoverCandidate)
                    }
                    catch {
                        coverFiles = []
                        coverLookupFailed = true
                        result.issues.append("\(directoryID)：封面目录暂不可读（\(error.localizedDescription)）")
                    }
                    let signature = (coverLookupFailed ? ["unavailable"] : []) + coverFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> String? in
                        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]), attributes.isSymbolicLink != true else { return nil }
                        return "\(url.lastPathComponent)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes.isSymbolicLink == true)"
                    }
                    cover = (coverFiles, signature)
                    directoryCovers[directoryID] = cover
                }
                let fingerprint = LocalFileFingerprint(version: 2, size: values.fileSize ?? 0, modified: values.contentModificationDate, covers: cover.signature)
                if let old = previous[relative], old.fingerprint == fingerprint {
                    result.tracks.append(old)
                    result.reusedCount += 1
                    continue
                }
                var metadata = try await LocalAudioMetadataReader.read(url)
                try Task.checkCancellation()
                guard generation == scanGeneration else { throw CancellationError() }
                if metadata.artworkData == nil {
                    if let checked = checkedCoverArtwork[directoryID] {
                        metadata.artworkData = checked
                    } else {
                        metadata.artworkData = LocalAudioMetadataReader.coverArtwork(from: cover.candidates)
                        checkedCoverArtwork.updateValue(metadata.artworkData, forKey: directoryID)
                    }
                }
                result.tracks.append(LocalTrack(id: relative, title: metadata.title.isEmpty ? url.deletingPathExtension().lastPathComponent : metadata.title,
                    artist: metadata.artist.isEmpty ? "未知艺人" : metadata.artist, album: directory.lastPathComponent,
                    albumArtist: metadata.albumArtist.isEmpty ? (metadata.artist.isEmpty ? "未知艺人" : metadata.artist) : metadata.albumArtist,
                    trackNumber: metadata.trackNumber, duration: metadata.duration, artworkData: metadata.artworkData,
                    addedDate: previous[relative]?.addedDate ?? values.creationDate ?? .distantPast,
                    albumDirectory: directoryID, discNumber: metadata.discNumber > 0 ? metadata.discNumber : Self.folderDisc(directory.lastPathComponent),
                    fingerprint: fingerprint, year: metadata.year))
            } catch is CancellationError { throw CancellationError() }
            catch { result.failures.append(relative); result.issues.append("\(relative)：\(error.localizedDescription)") }
        }
        let emitted = Set(result.tracks.map(\.id))
        let failures = Set(result.failures)
        result.tracks += previousTracks.filter { old in
            !emitted.contains(old.id) && (failures.contains(old.id) || result.failedDirectoryPaths.contains { old.id.hasPrefix($0 + "/") })
        }
        try Task.checkCancellation()
        guard generation == scanGeneration else { throw CancellationError() }
        if !result.failures.isEmpty || !result.failedDirectoryPaths.isEmpty {
            AppLogger.library.notice("library.scan.partial files_failed=\(result.failures.count) directories_failed=\(result.failedDirectoryPaths.count)")
        }
        return result
    }
}

private struct DirectoryReadFailure: Error {
    let url: URL
    let underlying: Error
}

