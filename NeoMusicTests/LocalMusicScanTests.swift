import AVFoundation
import XCTest
@testable import NeoMusic

final class LocalMusicScanTests: XCTestCase, @unchecked Sendable {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeWave(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for index in 0..<4410 { buffer.floatChannelData![0][index] = 0 }
        try file.write(from: buffer)
    }

    func testFLACVorbisTrackNumberUsesTagInsteadOfFilename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Generated 0.1-second silent FLAC, tagged TRACKNUMBER=7/12; contains no user media.
        var bytes = Data(base64Encoded: "ZkxhQwAAACIDIAMgAAANAAANAfQA8AAAAyBq0A9H2K1PEgBbIrLKpI94hAAAQAwAAABMYXZmNjMuMS4xMDICAAAAEAAAAFRSQUNLTlVNQkVSPTcvMTIUAAAAZW5jb2Rlcj1MYXZmNjMuMS4xMDL/+HQIAAMf9wAAAEr4")!
        // Retain normal FLAC padding: AVFoundation rejects an otherwise valid very short stream.
        bytes[42] &= 0x7f
        bytes.insert(contentsOf: [0x81, 0, 0x20, 0] + Array(repeating: UInt8(0), count: 8192), at: 110)
        try bytes.write(to: root.appendingPathComponent("99 unrelated filename.flac"))
        let result = try await LocalMusicScanner().scan(root: root)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.trackNumber, 7)
    }

    func testRecursiveScanStableIdentityFallbackAndRemoval() async throws {
        let documents = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let nested = root.appendingPathComponent("album/disc", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let audio = nested.appendingPathComponent("Song.wav")
        try writeWave(audio)
        try writeWave(root.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.wav"), withDestinationURL: audio)
        let cover = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRz8AAAAASUVORK5CYII=")!
        try cover.write(to: nested.appendingPathComponent("cover.jpg"))
        try Data().write(to: root.appendingPathComponent("unsupported.ogg"))
        for name in ["Song.lrc", "album.json", "booklet.jpg", "readme.txt", ".DS_Store"] {
            try Data("companion".utf8).write(to: root.appendingPathComponent(name))
        }
        let scanner = LocalMusicScanner()
        let result = try await scanner.scan(root: root)
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.id, "album/disc/Song.wav")
        XCTAssertEqual(result.tracks.first?.title, "Song")
        XCTAssertEqual(result.tracks.first?.artist, "未知艺人")
        XCTAssertEqual(result.tracks.first?.artworkData, cover)
        XCTAssertEqual(result.unsupportedCount, 1)
        let repeated = try await scanner.scan(root: root)
        XCTAssertEqual(repeated.tracks, result.tracks)
        try FileManager.default.removeItem(at: audio)
        let removed = try await scanner.scan(root: root)
        XCTAssertTrue(removed.tracks.isEmpty)
    }

    func testRootAliasProducesSameRelativeIdentityAndPlayableURL() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try LocalMusicScanner.prepareDirectory(documents: parent)
        let nested = root.appendingPathComponent("专辑/Disc 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeWave(nested.appendingPathComponent("曲目.wav"))
        let alias = parent.appendingPathComponent("a-much-longer-root-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let scanner = LocalMusicScanner()
        let direct = try await scanner.scan(root: root)
        let aliased = try await scanner.scan(root: alias)
        XCTAssertEqual(aliased.tracks, direct.tracks)
        let id = try XCTUnwrap(aliased.tracks.first?.id)
        XCTAssertEqual(id, "专辑/Disc 1/曲目.wav")
        let playable = try await AVURLAsset(url: alias.appendingPathComponent(id)).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testIncrementalFolderIdentityAndFailedFilePreservation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["a/Album", "b/Album"] {
            let directory = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeWave(directory.appendingPathComponent("song.wav"))
        }
        let scanner = LocalMusicScanner()
        let first = try await scanner.scan(root: root)
        XCTAssertEqual(Set(first.tracks.compactMap(\.albumDirectory)), ["a/Album", "b/Album"])
        XCTAssertTrue(first.tracks.allSatisfy { $0.album == "Album" })
        let second = try await scanner.scan(root: root, previousTracks: first.tracks)
        XCTAssertEqual(second.reusedCount, 2)
        try Data("bad cover".utf8).write(to: root.appendingPathComponent("a/Album/Cover.JPG"))
        let changedCover = try await scanner.scan(root: root, previousTracks: second.tracks)
        XCTAssertEqual(changedCover.reusedCount, 1)
        XCTAssertEqual(changedCover.tracks.count, 2)
        XCTAssertTrue(changedCover.failures.isEmpty)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("a/Album/song.wav"))
        let failed = try await scanner.scan(root: root, previousTracks: second.tracks)
        XCTAssertEqual(failed.failures, ["a/Album/song.wav"])
        XCTAssertEqual(failed.tracks.count, 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/Album/song.wav"))
        let removed = try await scanner.scan(root: root, previousTracks: failed.tracks)
        XCTAssertEqual(removed.tracks.count, 1)
    }

    func testCorruptAudioReportedAndMissingRootThrows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("broken.mp3"))
        let scanner = LocalMusicScanner()
        let result = try await scanner.scan(root: root)
        XCTAssertEqual(result.failures, ["broken.mp3"])
        XCTAssertTrue(result.tracks.isEmpty)
        do {
            _ = try await scanner.scan(root: root.appendingPathComponent("missing"))
            XCTFail("Missing root must not publish an empty successful scan")
        } catch {}
    }

    func testCancelledScanThrows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalMusicScanner().scan(root: root)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

final class LocalLibraryTrackCacheTests: XCTestCase, @unchecked Sendable {
    private func tracks() -> [LocalTrack] {
        let artwork = Data(repeating: 137, count: 32_000)
        return (0..<3).map { index in
            LocalTrack(id: "album/\(index).flac", title: "Song \(index)", artist: "Artist", album: "Album",
                       albumArtist: "Album artist", trackNumber: index + 1, duration: 123,
                       artworkData: index == 2 ? nil : artwork, addedDate: Date(timeIntervalSince1970: 100),
                       albumDirectory: "album", discNumber: 2,
                       fingerprint: LocalFileFingerprint(version: 1, size: 200, modified: .distantPast, covers: ["cover.jpg|100"]))
        }
    }

    func testMetadataIndexSharesArtworkWithoutEmbeddingImageBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.json")
        let original = tracks()
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: directory, store: directory)
        let saved = try await cache.write(original, to: url)
        let artworkDirectory = url.appendingPathExtension("startup")
        let files = try FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "image" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkDirectory.appendingPathComponent("snapshot.json").path))
        let index = try Data(contentsOf: url)
        XCTAssertLessThan(index.count, 4_000)
        XCTAssertTrue(saved.allSatisfy { $0.artworkData == nil })
        XCTAssertEqual(saved[0].artworkKey, saved[1].artworkKey)
        for (input, output) in zip(original, saved) {
            var expected = input
            expected.artworkData = nil
            expected.artworkKey = output.artworkKey
            XCTAssertEqual(output, expected)
            if let key = output.artworkKey {
                XCTAssertEqual(try Data(contentsOf: artworkDirectory.appendingPathComponent(key + ".image")), input.artworkData)
            }
        }
        let restored = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: index), saved)
        try FileManager.default.removeItem(at: url)
        let missing = try await cache.read(from: url)
        XCTAssertNil(missing)
    }

    func testMissingImageDoesNotBlockMetadataRestoreAndIsRepairedByScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.json")
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: directory, store: directory)
        let saved = try await cache.write(tracks(), to: url)
        let key = try XCTUnwrap(saved[0].artworkKey)
        try FileManager.default.removeItem(at: url.appendingPathExtension("startup").appendingPathComponent(key + ".image"))
        let restored = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertEqual(restored, saved, "Startup must read metadata independently of image availability")
        let reusable = await cache.reusableTracks(saved, at: url)
        XCTAssertNil(reusable[0].fingerprint)
        XCTAssertNil(reusable[1].fingerprint)
        XCTAssertEqual(reusable[2].fingerprint, saved[2].fingerprint)
        let repaired = try await cache.write(tracks(), to: url)
        XCTAssertEqual(repaired, saved)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("startup").appendingPathComponent(key + ".image")), tracks()[0].artworkData)
    }

    func testLegacySnapshotImportsColorsAndImageReferencesWithoutReadingImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tracks.json")
        let original = tracks()
        let source = try JSONEncoder().encode(original)
        try source.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let artworkDirectory = url.appendingPathExtension("startup")
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for track in original {
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
            metadata.removeValue(forKey: "artworkData")
            var entry: [String: Any] = ["metadata": metadata]
            if track.artworkData != nil { entry["artworkKey"] = "shared-cover" }
            entries.append(entry)
        }
        let snapshot: [String: Any] = ["version": 1, "source": ["size": source.count, "modified": modified.timeIntervalSinceReferenceDate], "tracks": entries]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: artworkDirectory.appendingPathComponent("snapshot.json"))
        let color = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let colors: [String: Any] = ["version": AlbumArtworkBackdropPreparer.cacheVersion, "colors": ["shared-cover": ["red": color.red, "green": color.green, "blue": color.blue]]]
        try JSONSerialization.data(withJSONObject: colors).write(to: directory.appendingPathComponent("artwork-backdrops.json"))
        let cache = LocalLibraryTrackCache()
        let read = try await cache.read(from: url)
        let restored = try XCTUnwrap(read)
        XCTAssertEqual(restored.map(\.id), original.map(\.id))
        XCTAssertEqual(restored[0].artworkBackdrop, color)
        XCTAssertEqual(restored[0].artworkKey, "shared-cover")
        XCTAssertTrue(restored.allSatisfy { $0.artworkData == nil })
        XCTAssertEqual(try Data(contentsOf: url), source, "Reading must leave the previous store intact")
        try await cache.write(restored, to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkDirectory.appendingPathComponent("snapshot.json").path))
        XCTAssertLessThan(try Data(contentsOf: url).count, 4_000)
    }

    func testCorruptIndexAndUnwritableArtworkReportFailureWithoutReplacingMetadata() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let url = documents.appendingPathComponent("tracks.json")
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: documents, store: documents)
        let original = Data("broken index".utf8)
        try original.write(to: url)
        do { _ = try await cache.read(from: url); XCTFail("Corrupt index must report failure") }
        catch is DecodingError {} catch { XCTFail("Unexpected error: \(error)") }
        try Data().write(to: url.appendingPathExtension("startup"))
        do { try await cache.write(tracks(), to: url); XCTFail("Artwork failure must propagate") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        try FileManager.default.removeItem(at: url.appendingPathExtension("startup"))
        let written = try await cache.write(tracks(), to: url)
        let restored = try await cache.read(from: url)
        XCTAssertEqual(restored, written)
    }

    func testCancelledCacheWorkLeavesExistingFileUntouched() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: documents, store: documents)
        let url = documents.appendingPathComponent("tracks.json")
        let original = Data("original bytes".utf8)
        try original.write(to: url)
        let write = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.write([], to: url)
        }
        do { try await write.value; XCTFail("Cancellation must propagate before write") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.read(from: url)
        }
        do { _ = try await read.value; XCTFail("Cancellation must propagate before decode") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
