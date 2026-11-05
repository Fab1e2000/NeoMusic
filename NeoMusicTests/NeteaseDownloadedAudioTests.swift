import Foundation
import XCTest
@testable import NeoMusic

final class NeteaseDownloadedAudioTests: XCTestCase {
    private func directory() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func fixture(_ name: String, extension ext: String) throws -> Data {
        let bundle = Bundle(for: NeteaseDownloadedAudioTests.self)
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Downloads")
            ?? bundle.url(forResource: name, withExtension: ext)
        return try Data(contentsOf: XCTUnwrap(url, "Missing synthetic download fixture: \(name).\(ext)"))
    }

    func testDecodesBothFormatsAndAcrossChunkBoundariesWithoutChangingSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in ["flac", "mp3", "long"] {
            let source = root.appendingPathComponent("source-\(kind)")
            let encrypted = try Self.fixture("audio-ncm-\(kind)", extension: "ncm")
            try encrypted.write(to: source)
            let output = try await NeteaseDownloadedAudio.prepare(source, declaredType: "flac", staging: root)
            let format = kind == "mp3" ? "mp3" : "flac"
            var expected = try Self.fixture("audio-local-tags", extension: format)
            if kind == "long" { expected.append(contentsOf: (0..<150_003).map { UInt8($0 % 251) }) }
            XCTAssertEqual(output.pathExtension, format)
            XCTAssertEqual(try Data(contentsOf: output), expected)
            XCTAssertEqual(try Data(contentsOf: source), encrypted)
        }
    }

    func testOrdinaryAudioUsesDetectedFormatAndPreservesBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for format in ["mp3", "flac"] {
            let source = root.appendingPathComponent("source")
            let bytes = try Self.fixture("audio-local-tags", extension: format)
            try bytes.write(to: source)
            let output = try await NeteaseDownloadedAudio.prepare(source, declaredType: "flac", staging: root)
            XCTAssertEqual(output.pathExtension, format)
            XCTAssertEqual(try Data(contentsOf: output), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testTruncatedOrCorruptContainerDoesNotLeaveOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let encrypted = try Self.fixture("audio-ncm-flac", extension: "ncm")
        var cases = [0, 8, 12, 30, 64, 90, 114].map { Data(encrypted.prefix($0)) }
        for offset in [10, 14, 114] {
            var corrupt = encrypted
            corrupt[offset] ^= 0xff
            cases.append(corrupt)
        }
        for bytes in cases {
            try bytes.write(to: source)
            do {
                _ = try await NeteaseDownloadedAudio.prepare(source, declaredType: "ncm", staging: root)
                XCTFail("Corrupt container was accepted")
            } catch is NeteaseDownloadedAudio.Failure { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testRejectsServerErrorBodyAndUsesHeaderInsteadOfDeclaration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        for format in ["mp3", "flac", "ncm"] {
            try Data("{\"code\":403}".utf8).write(to: source)
            do {
                _ = try await NeteaseDownloadedAudio.prepare(source, declaredType: format, staging: root)
                XCTFail("Error body was accepted")
            } catch is NeteaseDownloadedAudio.Failure { }
        }
        try Self.fixture("audio-local-tags", extension: "mp3").write(to: source)
        let actual = try await NeteaseDownloadedAudio.prepare(source, declaredType: "ncm", staging: root)
        XCTAssertEqual(actual.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: actual), try Data(contentsOf: source))
    }

    func testCancelledPreparationCreatesNoFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NeteaseDownloadedAudio.prepare(root.appendingPathComponent("missing"), declaredType: "ncm", staging: root)
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch is CancellationError { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
