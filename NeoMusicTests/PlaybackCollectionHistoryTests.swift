import XCTest
import AVFoundation
@testable import NeoMusic

@MainActor final class PlaybackCollectionHistoryTests: XCTestCase {
    private func silentAudio(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("activation.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5))
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
        return url
    }

    func testHistoryRestoresDeduplicatesAndIsolatesAccounts() async throws {
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
        await history.flush()
        let restored = PlaybackCollectionHistory(url: url)
        await restored.restore()
        XCTAssertEqual(restored.recent(for: "first"), [local, first])
        XCTAssertEqual(restored.recent(for: "second"), [local, second])
        XCTAssertEqual(restored.recent(for: nil), [local])
    }

    func testConcurrentRestoreMergesPlaybackRecordedDuringRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let original = PlaybackCollectionReference(kind: .localAlbum, id: "album", ownerID: nil, title: "Original")
        let other = PlaybackCollectionReference(kind: .onlinePlaylist, id: "online", ownerID: "42", title: "Online")
        let seed = PlaybackCollectionHistory(url: url)
        seed.record(original, at: Date(timeIntervalSince1970: 1))
        seed.record(other, at: Date(timeIntervalSince1970: 2))
        await seed.flush()
        let gate = HistoryReadGate(data: try Data(contentsOf: url))
        let history = PlaybackCollectionHistory(url: url, loadData: { _ in await gate.load() })
        let readsBeforeRestore = await gate.loadCount
        XCTAssertEqual(readsBeforeRestore, 0, "Constructing the home model must not read history on the launch path")
        let firstRestore = Task { await history.restore() }
        await gate.waitUntilStarted()
        let secondRestore = Task { await history.restore() }
        let renamed = PlaybackCollectionReference(kind: .localAlbum, id: "album", ownerID: nil, title: "Renamed")
        history.record(renamed, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(history.recent(for: "42"), [renamed])
        await gate.finish()
        await firstRestore.value
        await secondRestore.value
        await history.flush()
        let readCount = await gate.loadCount
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(history.recent(for: "42"), [renamed, other])
        XCTAssertEqual(history.recent(for: nil), [renamed])
        let restored = PlaybackCollectionHistory(url: url)
        await restored.restore()
        XCTAssertEqual(restored.recent(for: "42"), [renamed, other])
    }

    func testPlaybackBeforeRestorePreservesExistingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let previous = PlaybackCollectionReference(kind: .localAlbum, id: "previous", ownerID: nil, title: "Previous")
        let current = PlaybackCollectionReference(kind: .localAlbum, id: "current", ownerID: nil, title: "Current")
        let seed = PlaybackCollectionHistory(url: url)
        seed.record(previous, at: Date(timeIntervalSince1970: 1))
        await seed.flush()
        let history = PlaybackCollectionHistory(url: url)
        history.record(current, at: Date(timeIntervalSince1970: 2))
        await history.flush()
        let restored = PlaybackCollectionHistory(url: url)
        await restored.restore()
        XCTAssertEqual(restored.recent(for: nil), [current, previous])
    }

    func testFlushPersistsLatestOfOrderedSnapshots() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let history = PlaybackCollectionHistory(url: url)
        await history.restore()
        for index in 0..<25 {
            history.record(.init(kind: .localPlaylist, id: String(index), ownerID: nil, title: String(index)),
                           at: Date(timeIntervalSince1970: Double(index)))
        }
        await history.flush()
        let restored = PlaybackCollectionHistory(url: url)
        await restored.restore()
        XCTAssertEqual(restored.recent(for: nil).map(\.id), (5..<25).reversed().map(String.init))
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
        await player.flushQueuePersistence()
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
        await player.flushQueuePersistence()
    }

    func testCollectionHistoryWaitsForSuccessfulSessionActivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try silentAudio(in: directory)
        let activation = SessionActivation()
        let started = expectation(description: "Native session activation started")
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate { started.fulfill() } })
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, makeAudioEngine: { engine })
        defer { player.shutdownPlayback() }
        player.configurePlayback(resolveURL: { _ in url }, persistenceURL: directory.appendingPathComponent("queue.json"))
        let song = LibrarySongItem(id: "tone", title: "Tone", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let reference = PlaybackCollectionReference(kind: .localAlbum, id: "album", ownerID: nil, title: "Album")
        var recorded: [PlaybackCollectionReference] = []
        player.onCollectionPlaybackStarted = { recorded.append($0) }
        player.play([song], from: "Album", shuffled: false, collection: reference)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isLoading)
        XCTAssertTrue(recorded.isEmpty)
        let pending = engine.activation
        try await activation.complete()
        await pending?.value
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(recorded, [reference])
        await player.flushQueuePersistence()
    }

    func testDeclinedAndFailedSessionActivationLeaveCollectionHistoryEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try silentAudio(in: directory)
        let results: [Result<Bool, Error>] = [.success(false), .failure(URLError(.cannotConnectToHost))]
        for result in results {
            let activation = SessionActivation()
            let started = expectation(description: "Native session activation started")
            let engine = LocalPlaybackEngine(activateSession: { try await activation.activate { started.fulfill() } })
            let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, makeAudioEngine: { engine })
            defer { player.shutdownPlayback() }
            player.configurePlayback(resolveURL: { _ in url }, persistenceURL: directory.appendingPathComponent(UUID().uuidString))
            var recorded = false
            player.onCollectionPlaybackStarted = { _ in recorded = true }
            let song = LibrarySongItem(id: "tone", title: "Tone", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
            player.play([song], from: "Album", shuffled: false,
                        collection: .init(kind: .localAlbum, id: "album", ownerID: nil, title: "Album"))
            await fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(recorded)
            let pending = engine.activation
            try await activation.complete(with: result)
            await pending?.value
            XCTAssertFalse(player.isPlaying)
            XCTAssertNotNil(player.errorMessage)
            XCTAssertFalse(recorded)
            await player.flushQueuePersistence()
        }
    }

    func testPausingPendingSessionActivationLeavesCollectionHistoryEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try silentAudio(in: directory)
        let activation = SessionActivation()
        let started = expectation(description: "Native session activation started")
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate { started.fulfill() } })
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false, makeAudioEngine: { engine })
        defer { player.shutdownPlayback() }
        player.configurePlayback(resolveURL: { _ in url }, persistenceURL: directory.appendingPathComponent("queue.json"))
        var recorded = false
        player.onCollectionPlaybackStarted = { _ in recorded = true }
        let song = LibrarySongItem(id: "tone", title: "Tone", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        player.play([song], from: "Album", shuffled: false,
                    collection: .init(kind: .localAlbum, id: "album", ownerID: nil, title: "Album"))
        await fulfillment(of: [started], timeout: 2)
        let pending = engine.activation
        player.togglePlayback()
        try await activation.complete()
        await pending?.value
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(recorded)
        await player.flushQueuePersistence()
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

private actor HistoryReadGate {
    let data: Data
    private(set) var loadCount = 0
    private var pending: CheckedContinuation<Data, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }

    func load() async -> Data {
        loadCount += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { pending = $0 }
    }

    func waitUntilStarted() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        pending?.resume(returning: data)
        pending = nil
    }
}
