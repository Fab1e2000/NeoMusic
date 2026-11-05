import Foundation
import UIKit
import XCTest
@testable import NeoMusic

@MainActor
final class DownloadedAudioTagsTests: XCTestCase {
    private func directory() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testWritesChineseMetadataCoverAndLyricsWithoutChangingAudioPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cover = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData())
        let metadata = DownloadedAudioTags.Metadata(title: "下载歌曲", artist: "歌手甲 / 歌手乙", album: "测试专辑",
            albumArtist: "专辑艺人", trackNumber: 7, discNumber: 2, artwork: cover,
            lyrics: "[00:00.00]原文\n[00:00.00]译文")
        for format in ["mp3", "flac"] {
            let source = root.appendingPathComponent("download-\(format).ncm")
            try NeteaseDownloadedAudioTests.fixture("audio-ncm-\(format)", extension: "ncm").write(to: source)
            let staged = try await NeteaseDownloadedAudio.prepare(source, declaredType: "ncm", staging: root)
            let originalPayload = try audioPayload(Data(contentsOf: staged), format: format)
            try await DownloadedAudioTags.write(metadata, to: staged)
            let readback = try await DownloadedAudioTags.read(staged)
            XCTAssertEqual(readback, metadata)
            XCTAssertEqual(try audioPayload(Data(contentsOf: staged), format: format), originalPayload)
        }
    }

    func testMissingOptionalMetadataPreservesExistingCoverAndLyrics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for format in ["mp3", "flac"] {
            let staged = root.appendingPathComponent("audio.\(format)")
            try NeteaseDownloadedAudioTests.fixture("audio-local-tags", extension: format).write(to: staged)
            let original = try await DownloadedAudioTags.read(staged)
            let metadata = DownloadedAudioTags.Metadata(title: "新标题", artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1, discNumber: 1)
            try await DownloadedAudioTags.write(metadata, to: staged)
            let updated = try await DownloadedAudioTags.read(staged)
            XCTAssertEqual(updated.title, "新标题")
            XCTAssertEqual(updated.artwork, original.artwork)
            XCTAssertEqual(updated.lyrics, original.lyrics)
        }
    }

    func testInvalidOptionalImageDoesNotDiscardPlayableAudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("audio.flac")
        try NeteaseDownloadedAudioTests.fixture("audio-local-tags", extension: "flac").write(to: staged)
        let before = try await DownloadedAudioTags.read(staged)
        let metadata = DownloadedAudioTags.Metadata(title: "标题", artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1, discNumber: 1, artwork: Data("network error".utf8))
        try await DownloadedAudioTags.write(metadata, to: staged)
        let after = try await DownloadedAudioTags.read(staged)
        XCTAssertEqual(after.artwork, before.artwork)
        XCTAssertEqual(after.title, "标题")
    }

    func testTruncatedAudioCannotBecomeSuccessfulAfterTagWriting() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = DownloadedAudioTags.Metadata(title: "标题", artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1, discNumber: 1)
        for format in ["mp3", "flac"] {
            let staged = root.appendingPathComponent("truncated.\(format)")
            let bytes = try NeteaseDownloadedAudioTests.fixture("audio-local-tags", extension: format).prefix(8)
            try bytes.write(to: staged)
            do { try await DownloadedAudioTags.write(metadata, to: staged); XCTFail("Truncated audio accepted") }
            catch { XCTAssertEqual(try Data(contentsOf: staged), Data(bytes)) }
        }
    }

    func testCancelledTagWriteDoesNotModifyStagedFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("audio.mp3")
        let original = try NeteaseDownloadedAudioTests.fixture("audio-local-tags", extension: "mp3")
        try original.write(to: staged)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await DownloadedAudioTags.write(.init(title: "new", artist: "a", album: "b", albumArtist: "a", trackNumber: 1, discNumber: 1), to: staged)
        }
        do { try await task.value; XCTFail("Cancelled tag write succeeded") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: staged), original)
    }

    /// Compare encoded frames, excluding the format's tag blocks.
    private func audioPayload(_ bytes: Data, format: String) throws -> Data {
        let value = Array(bytes)
        if format == "flac" {
            var offset = 4
            while offset + 4 <= value.count {
                let last = value[offset] & 0x80 != 0
                let size = Int(value[offset + 1]) << 16 | Int(value[offset + 2]) << 8 | Int(value[offset + 3])
                offset += 4 + size
                if last { return Data(value.dropFirst(offset)) }
            }
            XCTFail("Invalid FLAC metadata blocks")
            return Data()
        }
        var start = 0, end = value.count
        if value.starts(with: Array("ID3".utf8)), value.count >= 10 {
            start = 10 + (6..<10).reduce(0) { ($0 << 7) | Int(value[$1] & 0x7f) }
            if value[5] & 0x10 != 0 { start += 10 }
        }
        if end >= 128, Array(value[(end - 128)..<(end - 125)]) == Array("TAG".utf8) { end -= 128 }
        return Data(value[start..<end])
    }
}
