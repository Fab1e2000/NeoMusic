import XCTest
import MetalKit
@testable import FrontAMPlayer

@MainActor final class PlayerResourceAndLyricsTests: XCTestCase {
    func testModuleBundleContainsMetalAndSourceNotices() throws {
        XCTAssertNotEqual(PlayerResources.bundle.bundleURL, Bundle.main.bundleURL)
        XCTAssertNotNil(PlayerResources.bundle.url(forResource: "GPL-3.0", withExtension: "txt"))
        XCTAssertNotNil(PlayerResources.bundle.url(forResource: "PlayerSourceNotices", withExtension: "txt"))
        _ = try XCTUnwrap(PlayerResources.bundle.url(forResource: "default", withExtension: "metallib"))
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let library = try device.makeDefaultLibrary(bundle: PlayerResources.bundle)
        for name in ["lyricsViewportFade", "trackSwipeHorizontalFade"] {
            XCTAssertTrue(library.functionNames.contains(name), name)
        }
    }

    func testLateLyricsCannotReplaceTheNewTrackOrItsFailure() async {
        let model = NowPlayingLyricsModel()
        var resume: CheckedContinuation<PlayerLyrics, Never>?
        let old = Task { await model.load(trackID: "old") { await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        await model.load(trackID: "new") { throw URLError(.notConnectedToInternet) }
        let error = model.error
        resume?.resume(returning: PlayerLyrics(plainText: "old"))
        await old.value
        XCTAssertNil(model.lyrics)
        XCTAssertNotNil(error)
        XCTAssertEqual(model.error, error)
        XCTAssertEqual(model.availability(for: "new"), .failed)
    }

    func testCancelledLyricsDoNotPublishAndImportReloadsOnlyCurrentTrack() async {
        let model = NowPlayingLyricsModel()
        let task = Task {
            await model.load(trackID: "cancelled") {
                withUnsafeCurrentTask { $0?.cancel() }
                return PlayerLyrics(plainText: "cancelled")
            }
        }
        await task.value
        XCTAssertNil(model.lyrics)
        XCTAssertNil(model.error)
        await model.load(trackID: "active") { PlayerLyrics(plainText: "active") }
        let provider = PlayerLyricsSource(load: { _ in PlayerLyrics() }, importFile: { _, _ in })
        await model.importFile(URL(fileURLWithPath: "/lyrics"), trackID: "previous", reader: provider)
        XCTAssertEqual(model.revision, 0)
        await model.importFile(URL(fileURLWithPath: "/lyrics"), trackID: "active", reader: provider)
        XCTAssertEqual(model.revision, 1)
        let failing = PlayerLyricsSource(load: { _ in PlayerLyrics() }, importFile: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        await model.importFile(URL(fileURLWithPath: "/lyrics"), trackID: "active", reader: failing)
        XCTAssertEqual(model.revision, 1)
        XCTAssertNotNil(model.error)
    }
}
