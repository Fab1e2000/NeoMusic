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

    func testStartupSnapshotSharesArtworkAndRestoresEveryTrackField() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.json")
        let original = tracks()
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: directory, store: directory)
        try await cache.write(original, to: url)
        let snapshotDirectory = url.appendingPathExtension("startup")
        let files = try FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "image" }.count, 1)
        let snapshotData = try Data(contentsOf: snapshotDirectory.appendingPathComponent("snapshot.json"))
        XCTAssertLessThan(snapshotData.count, 4_000, "The launch index must not embed the original artwork")
        let restarted = LocalLibraryTrackCache()
        let restored = try await restarted.read(from: url)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url)), original)

        // Changes to the original store invalidate the derived snapshot, including removed artwork.
        let changed = [original[2]]
        try JSONEncoder().encode(changed).write(to: url, options: .atomic)
        let refreshed = try await restarted.read(from: url)
        XCTAssertEqual(refreshed, changed)
        try await restarted.write(changed, to: url)
        let remaining = try FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.filter { $0.pathExtension == "image" }.isEmpty)
        let nextLaunch = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertEqual(nextLaunch, changed)

        try FileManager.default.removeItem(at: url)
        let missing = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertNil(missing, "A derived snapshot cannot revive a missing source store")
    }

    func testDamagedOrUnwritableStartupSnapshotFallsBackToOriginalStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.json")
        let snapshotDirectory = url.appendingPathExtension("startup")
        let original = tracks()
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: directory, store: directory)
        try await cache.write(original, to: url)
        let files = try FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil)
        let artwork = try XCTUnwrap(files.first { $0.pathExtension == "image" })
        try FileManager.default.removeItem(at: artwork)
        let afterMissingArtwork = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertEqual(afterMissingArtwork, original)
        try Data("corrupt index".utf8).write(to: snapshotDirectory.appendingPathComponent("snapshot.json"))
        let afterCorruptIndex = try await LocalLibraryTrackCache().read(from: url)
        XCTAssertEqual(afterCorruptIndex, original)

        try FileManager.default.removeItem(at: snapshotDirectory)
        try Data().write(to: snapshotDirectory)
        let restarted = LocalLibraryTrackCache()
        let restored = try await restarted.read(from: url)
        XCTAssertEqual(restored, original)
        try await restarted.write(original, to: url)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url)), original)
    }

    func testRoundTripPreservesOriginalArtworkAndReportsInvalidFiles() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = documents.appendingPathComponent("state")
        let url = store.appendingPathComponent("tracks.json")
        let cache = LocalLibraryTrackCache()
        try await cache.prepare(documents: documents, store: store)
        let missing = try await cache.read(from: url)
        XCTAssertNil(missing)
        let track = LocalTrack(id: "album/song.flac", title: "Song", artist: "Artist", album: "Album",
            albumArtist: "Artist", trackNumber: 1, duration: 123, artworkData: Data(repeating: 137, count: 2_000_000),
            addedDate: .distantPast, albumDirectory: "album", discNumber: 2)
        try await cache.write([track], to: url)
        let restored = try await cache.read(from: url)
        XCTAssertEqual(restored, [track])
        // Existing readers continue to consume the exact same stored schema.
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url)), [track])
        try Data("broken".utf8).write(to: url)
        do { _ = try await cache.read(from: url); XCTFail("Corrupt cache must report failure") }
        catch is DecodingError {} catch { XCTFail("Unexpected error: \(error)") }
        let invalidDestination = store.appendingPathComponent("missing/tracks.json")
        do { try await cache.write([track], to: invalidDestination); XCTFail("Write failure must propagate") }
        catch {}
        // A failed write does not prevent a subsequent successful refresh.
        try await cache.write([track], to: url)
        let retried = try await cache.read(from: url)
        XCTAssertEqual(retried, [track])
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
