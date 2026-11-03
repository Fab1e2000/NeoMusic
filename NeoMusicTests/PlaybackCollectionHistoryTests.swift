import XCTest
import AVFoundation
@testable import NeoMusic

@MainActor final class PlaybackCollectionHistoryTests: XCTestCase {
    func testHistoryRestoresDeduplicatesAndIsolatesAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let history = PlaybackCollectionHistory(url: url)
        let local = PlaybackCollectionReference(kind: .localAlbum, id: "a", ownerID: nil, title: "Album")
        let first = PlaybackCollectionReference(kind: .onlinePlaylist, id: "1", ownerID: "first", title: "First")
        let second = PlaybackCollectionReference(kind: .onlinePlaylist, id: "1", ownerID: "second", title: "Second")
        history.record(local, at: Date(timeIntervalSince1970: 1))
        history.record(first, at: Date(timeIntervalSince1970: 2))
        history.record(second, at: Date(timeIntervalSince1970: 3))
        history.record(local, at: Date(timeIntervalSince1970: 4))
        let restored = PlaybackCollectionHistory(url: url)
        XCTAssertEqual(restored.recent(for: "first"), [local, first])
        XCTAssertEqual(restored.recent(for: "second"), [local, second])
        XCTAssertEqual(restored.recent(for: nil), [local])
    }

    func testHistoryKeepsTwentyMostRecentCollections() {
        let history = PlaybackCollectionHistory()
        for index in 0..<25 {
            history.record(.init(kind: .localPlaylist, id: String(index), ownerID: nil, title: String(index)), at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(history.recent(for: nil).count, 20)
        XCTAssertEqual(history.recent(for: nil).first?.id, "24")
        XCTAssertEqual(history.recent(for: nil).last?.id, "5")
    }

    func testSuccessfulAudioRecordsOnceAndResumeDoesNotRecordAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5))
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 44100)) * 0.01 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback() }
        player.configurePlayback(resolveURL: { _ in url }, persistenceURL: directory.appendingPathComponent("queue.json"))
        let song = LibrarySongItem(id: "tone", title: "Tone", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let reference = PlaybackCollectionReference(kind: .localAlbum, id: "album", ownerID: nil, title: "Album")
        var recorded: [PlaybackCollectionReference] = []
        player.onCollectionPlaybackStarted = { recorded.append($0) }
        player.play([song], from: "Album", shuffled: false, collection: reference)
        for _ in 0..<50 where recorded.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(recorded, [reference])
        player.togglePlayback()
        player.togglePlayback()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorded, [reference])
    }

    func testFailedResolutionDoesNotRecordPlayback() async throws {
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        player.configurePlayback(resolveResource: { _ in throw CocoaError(.fileReadNoSuchFile) }, persistenceURL: directory.appendingPathComponent("queue.json"))
        var recorded = false
        player.onCollectionPlaybackStarted = { _ in recorded = true }
        let song = LibrarySongItem(id: "missing", title: "Missing", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        player.play([song], from: "Album", shuffled: false, collection: .init(kind: .localAlbum, id: "album", ownerID: nil, title: "Album"))
        for _ in 0..<20 where player.errorMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(player.errorMessage)
        XCTAssertFalse(recorded)
    }

    func testPendingQueueReplacementPreservesCollectionAndDoesNotRecordBeforePlayback() {
        let song = LibrarySongItem(id: "song", title: "Song", artist: "Artist", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let player = NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false)
        let reference = PlaybackCollectionReference(kind: .localPlaylist, id: "list", ownerID: nil, title: "List")
        var recorded: [PlaybackCollectionReference] = []
        player.onCollectionPlaybackStarted = { recorded.append($0) }
        player.appendLater([song])
        player.requestPlay([song], from: "List", shuffled: false, collection: reference)
        XCTAssertEqual(player.pendingPlay?.collection, reference)
        XCTAssertTrue(recorded.isEmpty)
        player.pendingPlay = nil
        XCTAssertTrue(recorded.isEmpty)
        player.requestPlay([], from: "Empty", shuffled: false, collection: reference)
        XCTAssertTrue(recorded.isEmpty)
    }
}
