import XCTest
@testable import NeoMusic

final class LocalLyricsTests: XCTestCase, @unchecked Sendable {
    func testOffsetsMultipleTimestampsAndStableTies() {
        let result = LyricsDocument.parse("[ti:Title]\n[00:02.50][00:01]hello\n[00:01]second\n[offset:-500]")
        XCTAssertEqual(result.lines.map(\.time), [0.5, 0.5, 2])
        XCTAssertEqual(result.lines.map(\.text), ["hello", "second", "hello"])
        XCTAssertEqual(result.activeLine(at: 0.5), 1)
        XCTAssertNil(result.activeLine(at: 0))
    }

    func testPlainAndEmpty() {
        XCTAssertEqual(LyricsDocument.parse("one\ntwo").plainText, "one\ntwo")
        XCTAssertTrue(LyricsDocument.parse("[ar:Artist]\n ").isEmpty)
    }

    func testImportOverridesSidecarAndFailedImportPreservesPrevious() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("song.wav")
        let sidecar = root.appendingPathComponent("song.LRC")
        try Data("[00:01]sidecar".utf8).write(to: sidecar)
        let reader = LyricsReader(storageDirectory: root.appendingPathComponent("imports"))
        let local = try await reader.load(songID: "song", audioURL: audio, root: root)
        XCTAssertEqual(local.lines.first?.text, "sidecar")
        let input = root.appendingPathComponent("import.txt")
        try Data("[00:02]imported".utf8).write(to: input)
        try await reader.importFile(input, songID: "song")
        try Data().write(to: input)
        do { try await reader.importFile(input, songID: "song"); XCTFail("Empty import accepted") } catch { }
        let imported = try await reader.load(songID: "song", audioURL: audio, root: root)
        XCTAssertEqual(imported.lines.first?.text, "imported")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "[00:01]sidecar")
    }

    @MainActor func testLateResultCannotOverwriteNewSong() async {
        let model = LyricsPresentationModel()
        var resume: CheckedContinuation<LyricsDocument, Never>?
        let first = Task {
            await model.load(songID: "old") { await withCheckedContinuation { resume = $0 } }
        }
        while resume == nil { await Task.yield() }
        await model.load(songID: "new") { LyricsDocument.parse("new lyrics") }
        resume?.resume(returning: LyricsDocument.parse("old lyrics"))
        await first.value
        XCTAssertEqual(model.songID, "new")
        XCTAssertEqual(model.document?.plainText, "new lyrics")
        XCTAssertFalse(model.isLoading)
    }

    @MainActor func testCancelledLoadDoesNotPublish() async {
        let model = LyricsPresentationModel()
        let task = Task {
            await model.load(songID: "song") {
                try await Task.sleep(for: .seconds(10))
                return LyricsDocument.parse("late")
            }
        }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertNil(model.document)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }
}
