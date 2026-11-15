import XCTest
@testable import NeoMusic

final class LocalLyricsTests: XCTestCase, @unchecked Sendable {
    func testOffsetsMultipleTimestampsAndStableTies() {
        let cases: [(offset: String, times: [Double])] = [
            ("+500", [0.5, 0.5, 2]),
            ("-500", [1.5, 1.5, 3])
        ]
        for testCase in cases {
            let result = LyricsDocument.parse("[ti:Title]\n[00:02.50][00:01]hello\n[00:01]second\n[offset:\(testCase.offset)]")
            XCTAssertEqual(result.lines.map(\.time), testCase.times)
            XCTAssertEqual(result.lines.map(\.text), ["hello", "second", "hello"])
            XCTAssertNil(result.activeLine(at: testCase.times[0] - 0.001))
            XCTAssertEqual(result.activeLine(at: testCase.times[0]), 1)
        }
    }

    func testPositiveOffsetClampsAdvancedTimestampsAtZero() {
        let result = LyricsDocument.parse("[offset:+500]\n[00:00.75]later\n[00:00.25]early\n[00:00.00]start\n[00:00.50]boundary")
        XCTAssertEqual(result.lines.map(\.time), [0, 0, 0, 0.25])
        XCTAssertEqual(result.lines.map(\.text), ["start", "early", "boundary", "later"])
        XCTAssertEqual(result.activeLine(at: 0), 2)
        XCTAssertEqual(result.activeLine(at: 0.25), 3)
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
