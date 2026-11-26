import XCTest
@testable import FrontAMPlayer
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

    func testUnrepresentableLyricTimesAndOffsetsLeaveOtherLinesPlayable() {
        let original = """
        [offset:+500]
        [offset:-inf]
        [00:01.500]Original
        [inf:01]Invalid time
        [1e15:02.500]Unrepresentable milliseconds
        """
        let translation = "[00:01.000]译文\n[1e15:02.500]无效时间"
        let stored = LyricsDocument.storedText(original: original, translation: translation)
        let result = LyricsDocument.decodeStored(stored)
        XCTAssertEqual(result.lines.map(\.time), [1])
        XCTAssertEqual(result.lines.map(\.text), ["Original"])
        XCTAssertEqual(result.lines.map(\.translation), ["译文"])

        let offsetOutsideTimeline = LyricsDocument.decodeStored("""
        [offset:-4000000000000000000]
        [00:01]First
        [100000000000000:00]Last
        """)
        XCTAssertEqual(offsetOutsideTimeline.lines.map(\.time), [1, 6e15])
    }

    func testTranslationTimeWindowPreservesExactMatchesTiesAndTolerance() {
        let original = """
        [00:01.000]First
        [00:01.100]Second
        [00:02.000]Boundary
        [00:03.000]Outside
        [00:04.000]Exact
        [00:05.000]Same text
        [00:05.040]Different text
        """
        let translation = """
        [00:01.050]Ambiguous
        [00:02.050]Within tolerance
        [00:03.051]Outside tolerance
        [00:04.000]Exact translation
        [00:04.009]Nearby duplicate
        [00:05.020]Same text
        """
        XCTAssertEqual(
            LyricsDocument.merge(original: original, translation: translation).lines.map(\.translation),
            ["", "", "Within tolerance", "", "Exact translation", "", "Same text"]
        )
    }

    func testPlainAndEmpty() {
        XCTAssertEqual(LyricsDocument.parse("one\ntwo").plainText, "one\ntwo")
        XCTAssertTrue(LyricsDocument.parse("[ar:Artist]\n ").isEmpty)
    }

    func testStoredTranslationStaysSeparateFromTheOriginalLine() {
        let stored = LyricsDocument.storedText(
            original: "[00:01.00]Original",
            translation: "[00:01.00]译文"
        )
        let decoded = LyricsDocument.decodeStored(stored)
        XCTAssertEqual(decoded.lines.map(\.text), ["Original"])
        XCTAssertEqual(decoded.lines.map(\.translation), ["译文"])
        XCTAssertEqual(LyricsDocument.decodeStored("[00:01.00]Original").lines.map(\.translation), [""])
        let crlfStored = "[00:01.00]Original\r\n[neomusic:translation]\r\n[00:01.00]译文"
        let crlfDecoded = LyricsDocument.decodeStored(crlfStored)
        XCTAssertEqual(crlfDecoded.lines.map(\.text), ["Original"])
        XCTAssertEqual(crlfDecoded.lines.map(\.translation), ["译文"])
        let profile = AppleMusicLyricsTypographyProfile.iOS26_6
        XCTAssertEqual(profile.primaryFontSize, 34)
        XCTAssertEqual(profile.translationFontSize, 20)
        XCTAssertEqual(profile.translationOpacity, 0.55)
        XCTAssertEqual(profile.translationTopSpacing, 6)
        XCTAssertEqual(AppleMusicLyricsMotionProfile.iOS26_6.supplementalTextShowSpring.stiffness, 150)
        XCTAssertEqual(AppleMusicLyricsMotionProfile.iOS26_6.supplementalTextHideSpring.stiffness, 130)
    }

    func testDecodeStoredRecognizesStackedAndInterleavedBilingualLRC() {
        let stacked = """
        [00:00.000] 作词 : 藤井健太郎
        [00:01.081] 鮮やかなる色彩の
        [00:05.145] その意味など 君はもう Can’t know
        [00:12.902]
        [00:20.892] 温もりの意味 初めて知れば
        [by:Aki惊蛰]
        [00:01.081]那绚烂夺目的色彩
        [00:05.145]其所蕴藏的真意 你已无从知晓
        [00:12.902]
        [00:20.892]倘若初次领悟温暖的涵义
        """
        let stackedDecoded = LyricsDocument.decodeStored(stacked)
        XCTAssertEqual(stackedDecoded.lines.map(\.text), [
            "作词 : 藤井健太郎",
            "鮮やかなる色彩の",
            "その意味など 君はもう Can’t know",
            "",
            "温もりの意味 初めて知れば"
        ])
        XCTAssertEqual(stackedDecoded.lines.map(\.translation), [
            "",
            "那绚烂夺目的色彩",
            "其所蕴藏的真意 你已无从知晓",
            "",
            "倘若初次领悟温暖的涵义"
        ])

        let interleaved = """
        [00:01.081][01:00.000] 鮮やかなる色彩の
        [00:01.081][01:00.000] 那绚烂夺目的色彩
        [00:05.145] その意味など 君はもう Can’t know
        [00:05.145] 其所蕴藏的真意 你已无从知晓
        [00:12.902]
        [00:12.902]
        [00:20.892] 温もりの意味 初めて知れば
        [00:20.892] 倘若初次领悟温暖的涵义
        """
        let interleavedDecoded = LyricsDocument.decodeStored(interleaved)
        XCTAssertEqual(interleavedDecoded.lines.map(\.time), [1.081, 5.145, 12.902, 20.892, 60.0])
        XCTAssertEqual(interleavedDecoded.lines.map(\.text), [
            "鮮やかなる色彩の",
            "その意味など 君はもう Can’t know",
            "",
            "温もりの意味 初めて知れば",
            "鮮やかなる色彩の"
        ])
        XCTAssertEqual(interleavedDecoded.lines.map(\.translation), [
            "那绚烂夺目的色彩",
            "其所蕴藏的真意 你已无从知晓",
            "",
            "倘若初次领悟温暖的涵义",
            "那绚烂夺目的色彩"
        ])

        let monolingual = """
        [00:00.00] 作词 : A
        [00:00.00] 作曲 : B
        [00:10.00] 第一句歌词
        [00:15.00] 第二句歌词
        """
        let monolingualDecoded = LyricsDocument.decodeStored(monolingual)
        XCTAssertEqual(monolingualDecoded.lines.map(\.text), ["作词 : A", "作曲 : B", "第一句歌词", "第二句歌词"])
        XCTAssertTrue(monolingualDecoded.lines.allSatisfy { $0.translation.isEmpty })
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

    func testDownloadedLyricFilePreservesTranslationWithoutAnAccount() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = LyricsDocument.storedText(
            original: "[00:01.10]Original",
            translation: "[00:01.11]译文"
        )
        try Data(text.utf8).write(to: file)

        let result = try await LyricsReader.loadDownloadedFile(file)

        XCTAssertEqual(result.lines.map(\.text), ["Original"])
        XCTAssertEqual(result.lines.map(\.translation), ["译文"])
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
