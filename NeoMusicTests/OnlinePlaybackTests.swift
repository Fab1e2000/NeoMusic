import XCTest
import AVFoundation
@testable import NeoMusic

@MainActor
final class OnlinePlaybackTests: XCTestCase {
    func testRestoredPausedOnlineQueueRemainsQuietWhileAccountRestores() async {
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { model.shutdownPlayback(); try? FileManager.default.removeItem(at: file) }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: file)
        let saved = NowPlayingModel.SavedQueue(ids: ["netease:12:34"], index: 0, elapsed: 42,
                                               repeatMode: .off, shuffled: false)
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        model.invalidateOnlinePlayback(ownerID: nil)
        model.reconcileAvailability(songs: [])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.elapsed, 42)
        XCTAssertEqual(model.unavailableIDs, ["netease:12:34"])
        model.restoreOnlineIdentity(ownerID: "12")
        model.reconcileAvailability(songs: [song("netease:12:34")])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        await model.flushQueuePersistence()
    }

    func testSnapshotWaitsOnlyForOwnerAndPlaysByStableIdentityWithoutCatalog() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var track = song("netease:12:34")
        track.duration = 215
        track.artworkURL = URL(fileURLWithPath: "/tmp/saved-cover.image")
        track.artwork = .file(track.artworkURL!)
        let entries = [UUID(), UUID()]
        let state = NowPlayingModel.SavedQueue(ids: [track.id, track.id], index: 1, elapsed: 42,
            repeatMode: .one, shuffled: true, entryIDs: entries, songs: [PlaybackSongSnapshot(track)])
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        var requested: [String] = []
        model.configurePlayback(resolveResource: { id in
            requested.append(id)
            throw URLError(.notConnectedToInternet)
        }, persistenceURL: url)
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(state)))
        XCTAssertNotEqual(model.current.title, track.title)
        XCTAssertNil(model.current.artworkURL)
        XCTAssertEqual(model.unavailableIDs, [track.id])
        model.invalidateOnlinePlayback(ownerID: nil)
        await model.flushQueuePersistence()
        let whileRestoring = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(whileRestoring.songs?.first?.title, track.title, "Initial content activation must preserve pending snapshots")
        model.restoreOnlineIdentity(ownerID: "12")
        XCTAssertEqual(model.current.title, track.title)
        XCTAssertEqual(model.current.artworkURL, track.artworkURL)
        XCTAssertEqual(model.duration, 215)
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.elapsed, 42)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertTrue(requested.isEmpty)
        model.reconcileAvailability(songs: [])
        XCTAssertEqual(model.current.title, track.title)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        model.togglePlayback()
        await model.waitForResourceResolution()
        XCTAssertEqual(requested, [track.id])
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.elapsed, 42)
        await model.flushQueuePersistence()
    }

    func testPendingAccountRecoveryDoesNotInterruptNewLocalQueueOrRestoreOldOnlineSong() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("local.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        let requested = expectation(description: "Local resolution started")
        var resolution: CheckedContinuation<PlaybackResource, Error>?
        model.configurePlayback(resolveResource: { _ in
            try await withCheckedThrowingContinuation { continuation in
                resolution = continuation
                requested.fulfill()
            }
        }, persistenceURL: directory.appendingPathComponent("queue.json"))
        let online = song("netease:12:34")
        let saved = NowPlayingModel.SavedQueue(ids: [online.id], index: 0, elapsed: 42,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(online)])
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        let local = song("local.wav")
        model.play([local], from: "Local album", shuffled: false)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(model.isLoading)
        model.restoreOnlineIdentity(ownerID: "12")
        resolution?.resume(returning: PlaybackResource(url: audioURL))
        await model.waitForResourceResolution()
        // Resolving a URL starts AVPlayerItem preparation; transport readiness
        // arrives through its status observation after the resource task ends.
        for _ in 0..<40 where model.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.queue.map(\.id), [local.id])
        XCTAssertEqual(model.current.title, local.title)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.hasAudioEngine)
        XCTAssertNil(model.errorMessage)
        await model.flushQueuePersistence()
    }

    func testResolvedOwnerRejectsOtherAccountSnapshotsAndLateMetadata() async throws {
        for owner in [nil, "99"] as [String?] {
            let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let local = song("local.flac")
            let online = song("netease:12:34")
            let state = NowPlayingModel.SavedQueue(ids: [local.id, online.id], index: 1, elapsed: 10,
                repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(local), PlaybackSongSnapshot(online)])
            let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
            defer { model.shutdownPlayback() }
            var requested = false
            model.configurePlayback(resolveResource: { _ in requested = true; throw URLError(.badURL) }, persistenceURL: url)
            XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(state)))
            model.restoreOnlineIdentity(ownerID: owner)
            model.reconcileAvailability(songs: [local, online])
            model.updateArtwork([online.id: .init(id: online.id, title: online.title, artist: online.artist,
                album: online.album, albumArtist: online.albumArtist, trackNumber: 1, artwork: .favorites)])
            XCTAssertEqual(model.queue[0].title, local.title)
            XCTAssertEqual(model.current.title, "在线歌曲不可用")
            XCTAssertEqual(model.current.artwork, .missing)
            XCTAssertEqual(model.unavailableIDs, [online.id])
            model.togglePlayback()
            await model.waitForResourceResolution()
            XCTAssertFalse(requested)
            XCTAssertFalse(model.hasAudioEngine)
            await model.flushQueuePersistence()
            let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved.songs?.first { $0.id == online.id }?.title, "在线歌曲不可用")
            model.restoreOnlineIdentity(ownerID: "12")
            XCTAssertEqual(model.current.title, "在线歌曲不可用", "Switching back must not resurrect cleared private metadata")
            await model.flushQueuePersistence()
        }
    }

    func testIdentityResolvedBeforeQueueRestoreUsesMatchingSnapshot() {
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.restoreOnlineIdentity(ownerID: "12")
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let track = song("netease:12:34")
        let saved = NowPlayingModel.SavedQueue(ids: [track.id], index: 0, elapsed: 14,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(track)])
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        XCTAssertEqual(model.current.title, track.title)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        XCTAssertFalse(model.hasAudioEngine)
    }

    func testLogoutInterruptingOnlinePlaybackReportsReason() {
        let model = NowPlayingModel(queue: [song("netease:12:34")], currentIndex: 0, isPlaying: true)
        model.invalidateOnlinePlayback(ownerID: nil)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.errorMessage, "请登录原账号后重试")
        XCTAssertEqual(model.unavailableIDs, ["netease:12:34"])
    }

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
        await model.flushQueuePersistence()
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
        await model.flushQueuePersistence()
    }

    func testMissingSourceDetailDoesNotStopPlaybackOrAlert() {
        var track = song("netease:12:34")
        track.unavailabilityReason = "暂无完整音源"
        let model = NowPlayingModel(queue: [track], currentIndex: 0, isPlaying: true)
        defer { model.shutdownPlayback() }
        model.restoreOnlineIdentity(ownerID: "12")
        model.reconcileAvailability(songs: [track])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.unavailableIDs.contains(track.id))
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
        await model.flushQueuePersistence()
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
        await model.flushQueuePersistence()
    }
}
