import XCTest
import AVFoundation
import MediaPlayer
import UIKit
@testable import NeoMusic

@MainActor
final class PlaybackTests: XCTestCase {
    func song(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
    }
    func testCrossfadePreferencePersistsAndOldRecordsDefaultOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let model = NowPlayingModel(queue: [song("a")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertFalse(model.isCrossfadeEnabled)
        model.toggleCrossfade()
        await model.flushQueuePersistence()
        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.crossfadeEnabled, true)
        let old = NowPlayingModel.SavedQueue(ids: ["a"], index: 0, elapsed: 0, repeatMode: .all, shuffled: false)
        try JSONEncoder().encode(old).write(to: url)
        model.restoreQueue(songs: [song("a")])
        XCTAssertFalse(model.isCrossfadeEnabled)
        XCTAssertFalse(model.isPlaying)
    }

    func testCircularUpcomingReorderPreservesCurrentOccurrence() {
        let model = NowPlayingModel(queue: [song("a"), song("b"), song("a"), song("d")], currentIndex: 2, isPlaying: false)
        let current = model.entryIDs[2]
        model.reorderUpcoming(indices: [3, 0, 1], fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.entryIDs[2], current)
        XCTAssertEqual(model.queue.map(\.id), ["b", "d", "a", "a"])
        model.removeQueueEntry(at: 0)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.entryIDs[1], current)
    }

    func testEmptyQueueAndInsertion() {
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        XCTAssertFalse(model.hasCurrent)
        XCTAssertTrue(model.upcoming.isEmpty)
        model.insertNext([song("a")])
        XCTAssertEqual(model.current.id, "a")
        model.moveUpcoming(from: 10, to: 0)
        XCTAssertEqual(model.queue.count, 1)
    }
    func testRepeatAndManualQueueConfirmation() {
        let model = NowPlayingModel(queue: [song("a"), song("b")], currentIndex: 1)
        model.skipForward()
        XCTAssertEqual(model.currentIndex, 0)
        model.appendLater([song("c")])
        model.requestPlay([song("d")], from: "new", shuffled: false)
        XCTAssertNotNil(model.pendingPlay)
        XCTAssertEqual(model.current.id, "a")
        model.confirmPendingPlay()
        XCTAssertEqual(model.current.id, "d")
    }
    func testSavedQueueRoundTrip() throws {
        let state = NowPlayingModel.SavedQueue(ids: ["a", "missing", "a"], index: 1, elapsed: 42, repeatMode: .one, shuffled: true, source: "album")
        let result = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(result.ids, state.ids)
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.elapsed, 42)
        XCTAssertEqual(result.repeatMode, .one)
    }
    func testRefreshReplacesMetadataWithoutChangingQueueOccurrencesOrPosition() {
        let model = NowPlayingModel(queue: [song("a"), song("a")], currentIndex: 1, isPlaying: false, elapsed: 12)
        let occurrences = model.entryIDs
        let fresh = LibrarySongItem(id: "a", title: "Updated title", artist: "Artist", album: "Folder", albumArtist: "Artist", trackNumber: 2, artwork: .missing)
        model.reconcileAvailability(songs: [fresh])
        XCTAssertEqual(model.current.title, "Updated title")
        XCTAssertEqual(model.entryIDs, occurrences)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.elapsed, 12)
    }

    func testRemovedCurrentStopsPlayback() {
        let model = NowPlayingModel(queue: [song("a"), song("b")], currentIndex: 0)
        model.reconcileAvailability(songs: [song("b")])
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.unavailableIDs, ["a"])
        XCTAssertEqual(model.queue.count, 2)
    }
    func testDuplicateOccurrencesAndShuffleRoundTrip() {
        let model = NowPlayingModel(queue: [song("a"), song("b"), song("a"), song("c")], currentIndex: 0)
        let order = model.entryIDs
        XCTAssertEqual(Set(order).count, 4)
        model.isShuffled = true
        XCTAssertEqual(model.entryIDs.first, order.first)
        model.isShuffled = false
        XCTAssertEqual(model.entryIDs, order)
        model.appendLater([song("a")])
        XCTAssertEqual(Set(model.entryIDs).count, 5)
        model.moveUpcoming(from: 3, to: 0)
        XCTAssertEqual(model.queue.map(\.id), ["a", "a", "b", "a", "c"])
    }

    func testRealAudioPlaybackSeekAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 10)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 44100)) * 0.01 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let state = root.appendingPathComponent("queue.json")
        let track = song("tone.wav")
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: state)
        model.play([track], from: "test", shuffled: false)
        for _ in 0..<50 where model.elapsed < 0.5 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertGreaterThan(model.elapsed, 0.5, "Real AVPlayer must advance")
        model.elapsed = 4
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertGreaterThanOrEqual(model.elapsed, 4)
        model.togglePlayback()
        let savedElapsed = model.elapsed
        await model.flushQueuePersistence()
        let restored = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        restored.configurePlayback(resolveURL: { _ in url }, persistenceURL: state)
        restored.restoreQueue(songs: [track])
        XCTAssertEqual(restored.current.id, track.id)
        XCTAssertEqual(restored.elapsed, savedElapsed, accuracy: 0.1)
        XCTAssertFalse(restored.isPlaying)
        restored.reconcileAvailability(songs: [])
        XCTAssertEqual(restored.unavailableIDs, [track.id])
    }

    func testCorruptAudioAndCorruptRestorationReportFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("broken.wav")
        try Data("broken".utf8).write(to: url)
        let state = root.appendingPathComponent("queue.json")
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: state)
        model.play([song("broken")], from: "test", shuffled: false)
        for _ in 0..<50 where model.errorMessage == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
        await model.flushQueuePersistence()
        try Data("broken".utf8).write(to: state)
        model.restoreQueue(songs: [])
        XCTAssertTrue(model.errorMessage?.contains("恢复失败") == true)
    }

    func testPlaybackAcceptanceCallbackWaitsForConfirmationAndSurvivesCancellation() {
        let model = NowPlayingModel(queue: [song("original")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.appendLater([song("manual")])
        var starts = 0
        model.requestPlay([song("batch")], from: "Roaming", shuffled: false, onStarted: { starts += 1 })
        XCTAssertEqual(starts, 0)
        model.pendingPlay = nil
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(model.current.id, "original")
        model.requestPlay([song("batch")], from: "Roaming", shuffled: false, onStarted: { starts += 1 })
        model.confirmPendingPlay()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(model.current.id, "batch")
        model.confirmPendingPlay()
        XCTAssertEqual(starts, 1)
        model.requestPlay([song("next")], startingAt: 0, from: "Next", onStarted: { starts += 1 })
        XCTAssertEqual(starts, 2)
        model.requestPlay([], from: "Empty", shuffled: false, onStarted: { starts += 1 })
        XCTAssertEqual(starts, 2)
    }

    func testSelectedSongWaitsForConfirmationAndKeepsIndex() {
        let model = NowPlayingModel(queue: [song("original")], currentIndex: 0)
        model.appendLater([song("manual")])
        model.requestPlay([song("first"), song("selected")], startingAt: 1, from: "album")
        XCTAssertEqual(model.current.id, "original")
        XCTAssertEqual(model.pendingPlay?.startingIndex, 1)
        model.confirmPendingPlay()
        XCTAssertEqual(model.current.id, "selected")
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.sourceTitle, "album")
        XCTAssertFalse(model.hasUserQueuedUpcoming)
        model.requestPlay([song("direct")], startingAt: 0, from: "direct")
        XCTAssertEqual(model.current.id, "direct")
        XCTAssertNil(model.pendingPlay)
    }

    private func temporaryAudio(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4)!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func queuePlayer(in model: NowPlayingModel) throws -> AVQueuePlayer {
        let engine = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "_audio" }?.value as? LocalPlaybackEngine)
        return try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "player" }?.value as? AVQueuePlayer)
    }

    func testClockKeepsUIProgressWithoutRepublishingNowPlayingUntilPlaybackChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try temporaryAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = song("first")
        first.duration = 99 // The resolved asset duration must still reach Now Playing.
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        model.configurePlayback(resolveURL: { $0 == "missing" ? nil : url }, persistenceURL: root.appendingPathComponent("queue.json"))
        defer { model.shutdownPlayback() }
        model.play([first, song("second"), song("missing")], from: "test", shuffled: false)
        for _ in 0..<100 where model.elapsed < 0.4 || model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertGreaterThanOrEqual(model.elapsed, 0.4)
        let center = MPNowPlayingInfoCenter.default()
        let initial = try XCTUnwrap(center.nowPlayingInfo)
        XCTAssertEqual(initial[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 4, accuracy: 0.1)
        XCTAssertEqual(initial[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        let publishedTime = try XCTUnwrap(initial[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double)
        let progress = model.elapsed
        for _ in 0..<100 where model.elapsed < progress + 0.4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(model.elapsed, progress + 0.4)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, publishedTime,
                       "The system extrapolates elapsed time between semantic playback changes")

        model.togglePlayback()
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, model.elapsed)
        model.elapsed = 2
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 2)
        model.togglePlayback()
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        model.select(1)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "second")
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        model.select(2)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "missing")
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        await model.flushQueuePersistence()
    }

    func testManualNextReusesPreparedOccurrencesAndPreservesPauseAndLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try temporaryAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NowPlayingModel(queue: [song("a"), song("b"), song("a")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        let state = root.appendingPathComponent("queue.json")
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: state)
        model.startCurrent()
        let player = try queuePlayer(in: model)
        let ids = model.entryIDs
        for index in [1, 2, 0] {
            let prepared = try XCTUnwrap(player.items().dropFirst().first)
            model.select(index)
            XCTAssertTrue(player.currentItem === prepared, "Manual next should keep the enqueued AVPlayerItem")
            XCTAssertEqual(model.currentIndex, index)
            XCTAssertEqual(model.entryIDs, ids)
            XCTAssertFalse(model.isPlaying)
            XCTAssertEqual(model.elapsed, 0, accuracy: 0.01)
            await model.flushQueuePersistence()
            let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: state))
            XCTAssertEqual(saved.index, index)
        }
    }

    func testManualNextReusesPreparedItemWhilePlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try temporaryAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NowPlayingModel(queue: [song("a"), song("b")], currentIndex: 0, isPlaying: true)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent()
        let player = try queuePlayer(in: model)
        let prepared = try XCTUnwrap(player.items().dropFirst().first)
        model.select(1)
        XCTAssertTrue(player.currentItem === prepared)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.current.id, "b")
        await model.flushQueuePersistence()
    }

    func testManualSelectionFallsBackForDifferentOrMissingPreparedItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try temporaryAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NowPlayingModel(queue: [song("a"), song("b")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { id in id == "a" ? url : root.appendingPathComponent("missing.wav") },
                                persistenceURL: root.appendingPathComponent("queue.json"))
        model.repeatMode = .one
        model.startCurrent()
        let player = try queuePlayer(in: model)
        let repeated = try XCTUnwrap(player.items().dropFirst().first)
        model.select(1)
        XCTAssertFalse(player.currentItem === repeated)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(model.current.id, "b")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
        await model.flushQueuePersistence()
    }

    func testManualPreviousLoadsRequestedItemRatherThanPreparedNext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try temporaryAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NowPlayingModel(queue: [song("a"), song("b"), song("c")], currentIndex: 1, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in url }, persistenceURL: root.appendingPathComponent("queue.json"))
        model.startCurrent()
        let player = try queuePlayer(in: model)
        let preparedNext = try XCTUnwrap(player.items().dropFirst().first)
        model.select(0)
        XCTAssertNotNil(player.currentItem)
        XCTAssertFalse(player.currentItem === preparedNext)
        XCTAssertEqual(model.current.id, "a")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.errorMessage)
        await model.flushQueuePersistence()
    }

    func testSystemArtworkFollowsCurrentSongAndClearsMissingCover() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        var covered = song("covered")
        covered.artworkData = try XCTUnwrap(image.pngData())
        var corrupt = song("corrupt-cover")
        corrupt.artworkData = Data("not an image".utf8)
        let model = NowPlayingModel(queue: [covered, song("no-cover"), corrupt], currentIndex: 0, isPlaying: false)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: stateURL)
        defer { model.shutdownPlayback(); try? FileManager.default.removeItem(at: stateURL) }
        model.elapsed = 1
        let first = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(first.bounds.size, CGSize(width: 12, height: 12))
        let shared = ArtworkRequestBox(first)
        let backgroundSize = await Task.detached { shared.artwork.image(at: CGSize(width: 12, height: 12))?.size }.value
        XCTAssertEqual(backgroundSize, CGSize(width: 12, height: 12))
        XCTAssertNotNil(first.image(at: CGSize(width: 12, height: 12)))
        model.elapsed = 2
        XCTAssertTrue(first === (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork))
        model.select(1)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        model.select(2)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        model.select(0)
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        await model.flushQueuePersistence()
    }

}

// MediaPlayer invokes this immutable artwork provider from its background access queue.
private final class ArtworkRequestBox: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
    init(_ artwork: MPMediaItemArtwork) { self.artwork = artwork }
}
