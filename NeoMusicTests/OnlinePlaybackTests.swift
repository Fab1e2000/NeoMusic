import XCTest
import AVFoundation
@testable import NeoMusic

@MainActor
final class OnlinePlaybackTests: XCTestCase {
    func testSuccessfulQualityReloadPreservesProgressAndPlaybackIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("quality.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 12)!
        buffer.frameLength = buffer.frameCapacity
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let model = NowPlayingModel(queue: [song("netease:12:34")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveResource: { _ in PlaybackResource(url: url, quality: "lossless") },
                                persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent(at: 2)
        await model.waitForResourceResolution()
        for playing in [true, false, true] {
            if model.isPlaying != playing { model.togglePlayback() }
            let position = model.elapsed
            model.reloadCurrentResource()
            await model.waitForResourceResolution()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.isPlaying, playing)
            XCTAssertEqual(model.elapsed, position, accuracy: 0.6)
            XCTAssertEqual(model.actualQuality, "lossless")
        }
    }

    private func song(_ id: String) -> LibrarySongItem {
        .init(id: id, title: "Private title", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
    }

    func testLogoutRetainsQueueReferencesAndClearsOnlineMetadata() {
        let model = NowPlayingModel(queue: [song("local.flac"), song("netease:12:34")], currentIndex: 0, isPlaying: false)
        let entries = model.entryIDs
        model.invalidateOnlinePlayback(ownerID: nil)
        XCTAssertEqual(model.queue.map(\.id), ["local.flac", "netease:12:34"])
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.queue[0].title, "Private title")
        XCTAssertEqual(model.queue[1].title, "在线歌曲不可用")
        XCTAssertTrue(model.unavailableIDs.contains("netease:12:34"))
    }

    func testTranslationSharesOriginalLineAndRespectsIndependentOffsets() {
        let value = LyricsDocument.onlineLyrics(original: "[offset:1000]\n[00:01.00]Original", translation: "[00:02.00]译文")
        XCTAssertEqual(value.lines.count, 1)
        XCTAssertEqual(value.lines.first?.time, 2)
        XCTAssertEqual(value.lines.first?.text, "Original\n译文")
    }

    func testLateResolutionAfterLogoutCannotStartAudio() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "resolver started")
        var reply: CheckedContinuation<PlaybackResource, Never>?
        let model = NowPlayingModel(queue: [song("netease:12:34")], currentIndex: 0)
        model.configurePlayback(resolveResource: { _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }, persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent()
        await fulfillment(of: [started], timeout: 2)
        let completion = Task { await model.waitForResourceResolution() }
        await Task.yield()
        model.invalidateOnlinePlayback(ownerID: nil)
        reply?.resume(returning: PlaybackResource(url: URL(fileURLWithPath: "/missing.wav"), quality: "lossless"))
        await completion.value
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.actualQuality)
        XCTAssertEqual(model.current.title, "在线歌曲不可用")
        model.shutdownPlayback()
    }

    func testReloadFailureKeepsLoadedItemAndProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4)!
        buffer.frameLength = buffer.frameCapacity
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        var fail = false
        let model = NowPlayingModel(queue: [song("netease:12:34")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveResource: { _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return PlaybackResource(url: url, quality: "lossless")
        }, persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent(at: 1)
        await model.waitForResourceResolution()
        let progress = model.elapsed
        fail = true
        model.reloadCurrentResource()
        await model.waitForResourceResolution()
        XCTAssertTrue(model.hasAudioEngine)
        XCTAssertEqual(model.actualQuality, "lossless")
        XCTAssertEqual(model.elapsed, progress, accuracy: 0.1)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
    }

    func testResolutionFailureStopsAtCurrentSong() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NowPlayingModel(queue: [song("netease:12:34"), song("local.flac")], currentIndex: 0)
        model.configurePlayback(resolveResource: { _ in throw URLError(.notConnectedToInternet) }, persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent()
        await model.waitForResourceResolution()
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
        model.shutdownPlayback()
    }
}
