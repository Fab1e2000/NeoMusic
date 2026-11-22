import XCTest
@testable import NeoMusic

@MainActor
final class QueuePersistenceTests: XCTestCase {
    private func song(_ id: String, artwork: Artwork = .missing) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: "Artist", album: "Album", albumArtist: "Artist",
                        trackNumber: 0, artwork: artwork)
    }

    func testAutomaticRecommendationsRespectEntryOwnershipAndRepeat() async {
        let seed = song("seed"), original = song("original"), suggestion = song("suggestion")
        let model = NowPlayingModel(queue: [seed, original], currentIndex: 0, isPlaying: false)
        model.recommendationOwner = { $0.id == "local" ? nil : "42" }
        model.fetchRecommendations = { item in
            XCTAssertEqual(item.id, seed.id)
            return [seed, suggestion, original, suggestion]
        }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        XCTAssertEqual(model.repeatMode, .off)
        XCTAssertEqual(model.current.id, seed.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.queue.map(\.id), ["seed", "suggestion", "original"])
        model.insertNext([suggestion])
        let manual = model.entryIDs[1]
        model.cycleRepeat()
        XCTAssertFalse(model.isAutomaticContinuationEnabled)
        XCTAssertEqual(model.repeatMode, .all)
        XCTAssertEqual(model.queue.map(\.id), ["seed", "suggestion", "original"])
        XCTAssertEqual(model.entryIDs[1], manual)
    }

    func testTurningOffKeepsPlayingRecommendationAndDiscardsUnplayedOnes() async {
        let model = NowPlayingModel(queue: [song("seed"), song("original")], currentIndex: 0, isPlaying: false)
        model.recommendationOwner = { _ in "42" }
        model.fetchRecommendations = { _ in ["a", "b", "c"].map { self.song($0) } }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        model.select(1)
        let playing = model.entryIDs[1]
        model.appendLater([song("manual")])
        model.toggleAutomaticContinuation()
        XCTAssertEqual(model.entryIDs[model.currentIndex], playing)
        XCTAssertEqual(model.queue.map(\.id), ["seed", "a", "manual", "original"])
    }

    func testRefillSkipsHistoryAndEmptyResponseRestoresSourceOrder() async {
        let model = NowPlayingModel(queue: ["seed", "b", "d"].map { song($0) }, currentIndex: 0, isPlaying: false)
        model.appendLater([song("manual")])
        model.recommendationOwner = { _ in "42" }
        var batches = [["manual", "b", "a"], ["seed", "b", "a", "c"], []]
        model.fetchRecommendations = { _ in batches.removeFirst().map { self.song($0) } }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        XCTAssertEqual(model.queue.map(\.id), ["seed", "manual", "b", "a"])
        model.select(2)
        await model.recommendationTask?.value
        XCTAssertEqual(model.queue.map(\.id), ["seed", "manual", "b", "a", "c"])
        model.select(3)
        await model.recommendationTask?.value
        XCTAssertFalse(model.isAutomaticContinuationEnabled)
        XCTAssertEqual(model.queue.map(\.id), ["seed", "manual", "b", "a", "d"])
    }

    func testLocalSelectionAndQueueReplacementEndRecommendations() async {
        let seed = song("netease:42:1"), local = song("local")
        let model = NowPlayingModel(queue: [seed], currentIndex: 0, isPlaying: false)
        model.appendLater([local])
        model.recommendationOwner = { $0.onlineOwnerID }
        model.fetchRecommendations = { _ in [self.song("netease:42:2")] }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        model.select(1)
        XCTAssertFalse(model.canAutomaticallyContinue)
        XCTAssertFalse(model.isAutomaticContinuationEnabled)
        XCTAssertEqual(model.queue, [seed, local])
        model.select(0)
        model.toggleAutomaticContinuation()
        let pending = model.recommendationTask
        model.play([local], from: "Local", shuffled: false)
        await pending?.value
        XCTAssertEqual(model.queue, [local])
        XCTAssertFalse(model.queueContinues)
    }

    func testRecommendationRestoreAndAccountChangeOnlyRemoveTaggedFutureEntries() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let seed = song("netease:42:1"), manual = song("netease:42:2")
        let model = NowPlayingModel(queue: [seed, manual], currentIndex: 0, isPlaying: false)
        let restored = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback(); restored.shutdownPlayback() }
        let originalEntries = model.entryIDs
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        model.recommendationOwner = { $0.onlineOwnerID }
        model.fetchRecommendations = { _ in [self.song("netease:42:3")] }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        await model.flushQueuePersistence()
        restored.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(restored.restoreQueue(songs: [seed, manual]))
        restored.restoreOnlineIdentity(ownerID: "42")
        XCTAssertTrue(restored.isAutomaticContinuationEnabled)
        restored.restoreOnlineIdentity(ownerID: "43")
        XCTAssertFalse(restored.isAutomaticContinuationEnabled)
        XCTAssertEqual(restored.entryIDs, originalEntries)
    }

    func testRecommendationFailureAndLateAccountResponsePreserveQueue() async {
        let model = NowPlayingModel(queue: [song("seed"), song("original")], currentIndex: 0, isPlaying: false)
        XCTAssertFalse(model.canAutomaticallyContinue)
        model.recommendationOwner = { _ in "42" }
        model.fetchRecommendations = { _ in throw URLError(.notConnectedToInternet) }
        model.toggleAutomaticContinuation()
        await model.recommendationTask?.value
        XCTAssertFalse(model.isAutomaticContinuationEnabled)
        let started = expectation(description: "fetch started")
        var reply: CheckedContinuation<[LibrarySongItem], Never>?
        model.fetchRecommendations = { _ in
            await withCheckedContinuation { reply = $0; started.fulfill() }
        }
        model.toggleAutomaticContinuation()
        let pending = model.recommendationTask
        await fulfillment(of: [started], timeout: 2)
        model.invalidateOnlinePlayback(ownerID: "43")
        XCTAssertEqual(pending?.isCancelled, true)
        reply?.resume(returning: [song("late")])
        await pending?.value
        XCTAssertFalse(model.isAutomaticContinuationEnabled)
        XCTAssertEqual(model.queue.map(\.id), ["seed", "original"])
    }

    func testArtworkArrivalUpdatesOccurrencesWithoutSavingOrChangingPlaybackState() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let songs = [song("a"), song("b"), song("a"), song("missing")]
        let model = NowPlayingModel(queue: songs, currentIndex: 2, isPlaying: false, elapsed: 37)
        defer { model.shutdownPlayback() }
        model.repeatMode = .one
        model.reconcileAvailability(songs: [song("a"), song("b")])
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        let entries = model.entryIDs
        let staleMetadata = LibrarySongItem(id: "a", title: "Old title", artist: "Old artist", album: "Old album",
                                           albumArtist: "Old artist", trackNumber: 99, artwork: .favorites,
                                           isFavorite: true, favoriteAddedAt: Date(timeIntervalSince1970: 1),
                                           unavailabilityReason: "Old availability error")
        let replacements = ["a": staleMetadata,
                            "b": song("b", artwork: .playlist),
                            "outside": song("outside", artwork: .favorites)]

        let revision = model.queueRevision
        model.updateArtwork(replacements)
        XCTAssertEqual(model.queueRevision, revision)
        await model.flushQueuePersistence()

        XCTAssertEqual(model.queue.map(\.id), songs.map(\.id))
        var expectedA = songs[0]
        expectedA.artwork = .favorites
        XCTAssertEqual(model.queue[0], expectedA)
        XCTAssertEqual(model.queue[1], replacements["b"])
        XCTAssertEqual(model.queue[2], expectedA)
        XCTAssertEqual(model.queue[3], songs[3])
        XCTAssertEqual(model.current.title, "a")
        XCTAssertFalse(model.current.isFavorite)
        XCTAssertNil(model.current.favoriteAddedAt)
        XCTAssertNil(model.current.unavailabilityReason)
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.elapsed, 37)
        XCTAssertEqual(model.repeatMode, .one)
        XCTAssertEqual(model.unavailableIDs, ["missing"])
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Artwork-only updates must not enqueue a playback-state save")
    }

    func testSaveDefersFilesystemWorkAndFlushWaitsForCompleteSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let songs = (0..<512).map { song("track-\($0)") }
        let model = NowPlayingModel(queue: songs, currentIndex: 27, isPlaying: false, elapsed: 12)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)

        model.saveQueue()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "Saving must return before performing filesystem work on the main actor")
        await model.flushQueuePersistence()

        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.ids, songs.map(\.id))
        XCTAssertEqual(saved.index, 27)
        XCTAssertEqual(saved.elapsed, 12)
        XCTAssertEqual(saved.entryIDs, model.entryIDs)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertNil(model.errorMessage)
    }

    func testProgressOnlyWritesSidecarAndRestoresOnlyMatchingSnapshotAndOccurrence() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.json")
        let sidecar = url.appendingPathExtension("progress")
        let model = NowPlayingModel(queue: [song("a"), song("a")], currentIndex: 1, isPlaying: false, elapsed: 3)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        model.saveQueue()
        await model.flushQueuePersistence()
        let base = try Data(contentsOf: url)
        model.elapsed = 17
        await model.flushQueuePersistence()
        XCTAssertEqual(try Data(contentsOf: url), base)
        XCTAssertEqual(try PlaybackQueuePersistence.load(from: url)?.elapsed, 17)
        let progress = try Data(contentsOf: sidecar)
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: progress) as? [String: Any])
        invalid["entryID"] = model.entryIDs[0].uuidString
        try JSONSerialization.data(withJSONObject: invalid).write(to: sidecar)
        XCTAssertEqual(try PlaybackQueuePersistence.load(from: url)?.elapsed, 3)
        try progress.write(to: sidecar)
        model.repeatMode = .one
        model.elapsed = 24
        await model.flushQueuePersistence()
        XCTAssertNotEqual(try Data(contentsOf: url), base)
        XCTAssertEqual(try PlaybackQueuePersistence.load(from: url)?.elapsed, 24)
    }

    func testRapidChangesPersistLatestSnapshotAndRestoreQueueOccurrences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let songs = [song("a"), song("a"), song("b"), song("c")]
        let model = NowPlayingModel(queue: songs, currentIndex: 1, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        let originalEntries = model.entryIDs

        for position in 1...30 { model.elapsed = Double(position) }
        model.repeatMode = .one
        model.isShuffled = true
        model.appendLater([song("a")])
        let manualEntry = try XCTUnwrap(model.entryIDs.last)
        model.toggleCrossfade()
        model.sourceTitle = "Saved collection"
        model.elapsed = 42.5
        model.saveQueue()
        await model.flushQueuePersistence()

        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.ids, model.queue.map(\.id))
        XCTAssertEqual(saved.entryIDs, model.entryIDs)
        XCTAssertEqual(saved.originalOrder, originalEntries + [manualEntry])
        XCTAssertEqual(saved.userQueuedIDs, [manualEntry])
        XCTAssertEqual(saved.index, 1)
        XCTAssertEqual(saved.elapsed, 42.5)
        XCTAssertEqual(saved.repeatMode, .one)
        XCTAssertTrue(saved.shuffled)
        XCTAssertEqual(saved.crossfadeEnabled, true)
        XCTAssertEqual(saved.source, "Saved collection")
        XCTAssertNil(model.errorMessage)

        let restored = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { restored.shutdownPlayback() }
        restored.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(restored.restoreQueue(songs: songs))
        XCTAssertEqual(restored.queue.map(\.id), saved.ids)
        XCTAssertEqual(restored.entryIDs, saved.entryIDs)
        XCTAssertEqual(restored.currentIndex, 1)
        XCTAssertEqual(restored.elapsed, 42.5)
        XCTAssertEqual(restored.repeatMode, .one)
        XCTAssertTrue(restored.isShuffled)
        XCTAssertTrue(restored.isCrossfadeEnabled)
        XCTAssertTrue(restored.hasUserQueuedUpcoming)
        XCTAssertEqual(restored.sourceTitle, "Saved collection")
        XCTAssertFalse(restored.isPlaying)
        XCTAssertFalse(restored.hasAudioEngine)
    }

    func testSnapshotRestoresLocalDisplayBeforeCatalogWithoutStartingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cover = root.appendingPathComponent("artwork.image")
        let song = LibrarySongItem(id: "Album/Track.flac", title: "Saved title", artist: "Saved artist", album: "Saved album",
            albumArtist: "Album artist", trackNumber: 4, artwork: .file(cover), albumDirectory: "Album", discNumber: 2,
            artworkData: Data(repeating: 1, count: 100_000), artworkURL: cover,
            artworkBackdrop: .init(red: 0.1, green: 0.2, blue: 0.3), duration: 321, addedOrder: 9,
            onlineAlbumID: nil, artistReferences: [.init(id: "artist:1", name: "Saved artist")])
        let url = root.appendingPathComponent("queue.json")
        let first = NowPlayingModel(queue: [song, song], currentIndex: 1, isPlaying: false, elapsed: 45)
        defer { first.shutdownPlayback() }
        first.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        first.saveQueue()
        await first.flushQueuePersistence()
        let data = try Data(contentsOf: url)
        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: data)
        XCTAssertEqual(saved.songs?.count, 1, "Duplicate queue occurrences share one metadata record")
        XCTAssertLessThan(data.count, 4_000, "Queue metadata must not embed artwork bytes")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("artworkData"))
        let restored = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { restored.shutdownPlayback() }
        var resolutions = 0
        restored.configurePlayback(resolveURL: { _ in resolutions += 1; return nil }, persistenceURL: url)
        XCTAssertTrue(restored.restoreQueue(songs: [], restoredState: .success(saved)))
        XCTAssertEqual(restored.queue.map(\.title), [song.title, song.title])
        XCTAssertEqual(restored.current.artist, song.artist)
        XCTAssertEqual(restored.current.album, song.album)
        XCTAssertEqual(restored.current.duration, 321)
        XCTAssertEqual(restored.current.artworkURL, cover)
        XCTAssertEqual(restored.current.artwork, .file(cover))
        XCTAssertEqual(restored.current.artworkBackdrop, song.artworkBackdrop)
        XCTAssertEqual(restored.current.artistReferences, song.artistReferences)
        XCTAssertNil(restored.current.artworkData)
        XCTAssertEqual(restored.entryIDs, first.entryIDs)
        XCTAssertEqual(restored.currentIndex, 1)
        XCTAssertEqual(restored.elapsed, 45)
        XCTAssertTrue(restored.unavailableIDs.isEmpty)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertFalse(restored.hasAudioEngine)
        XCTAssertEqual(resolutions, 0)
        restored.reconcileAvailability(songs: [])
        XCTAssertEqual(restored.unavailableIDs, [song.id], "A completed local scan still detects removed files")
    }

    func testSnapshotOmitsRemoteURLsAndOldQueueFormatRemainsReadable() throws {
        var source = song("netease:12:34", artwork: .file(URL(string: "https://example.com/temporary?token=private")!))
        source.artworkURL = URL(string: "https://example.com/temporary?token=private")!
        source.artworkData = Data(repeating: 7, count: 100_000)
        source.onlineAlbumID = 42
        source.artistReferences = [.init(id: "artist:8", name: "Artist")]
        let metadata = PlaybackSongSnapshot(source)
        let encoded = try JSONEncoder().encode(metadata)
        XCTAssertNil(metadata.artworkURL)
        XCTAssertNil(metadata.song.artworkURL)
        XCTAssertEqual(metadata.song.artwork, .missing)
        XCTAssertNil(metadata.song.artworkData)
        XCTAssertEqual(metadata.onlineOwnerID, "12")
        XCTAssertEqual(metadata.song.onlineAlbumID, 42)
        XCTAssertEqual(metadata.song.artistReferences, source.artistReferences)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("https:"))
        let legacy = Data(#"{"ids":["missing.flac","missing.flac"],"index":1,"elapsed":19,"repeatMode":"one","shuffled":true}"#.utf8)
        let state = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: legacy)
        XCTAssertNil(state.songs)
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(state)))
        XCTAssertEqual(model.queue.map(\.id), state.ids)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.elapsed, 19)
        XCTAssertEqual(model.unavailableIDs, ["missing.flac"])
        XCTAssertFalse(model.hasAudioEngine)
    }

    func testContinuationPersistsAndLegacyTitleRestoresAsFiniteQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let original = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let restored = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { original.shutdownPlayback(); restored.shutdownPlayback() }
        let continuation = PlaybackQueueContinuation(ownerID: "42")
        original.play([song("netease:42:1"), song("netease:42:1")], from: "Radio", shuffled: false, continuation: continuation)
        original.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        original.saveQueue()
        await original.flushQueuePersistence()
        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.continuation, continuation)
        restored.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(restored.restoreQueue(songs: [], restoredState: .success(saved)))
        XCTAssertEqual(restored.continuation, continuation)
        XCTAssertEqual(restored.entryIDs, original.entryIDs)
        restored.restoreOnlineIdentity(ownerID: "42")
        XCTAssertEqual(restored.continuation, continuation)
        let legacy = Data(#"{"ids":["local","local"],"index":1,"elapsed":19,"repeatMode":"all","shuffled":false,"source":"私人漫游"}"#.utf8)
        let oldState = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: legacy)
        XCTAssertTrue(restored.restoreQueue(songs: [song("local")], restoredState: .success(oldState)))
        XCTAssertNil(restored.continuation)
        XCTAssertFalse(restored.queueContinues)
        restored.skipForward()
        XCTAssertEqual(restored.currentIndex, 0)
    }

    func testProgressSavesReuseQueueRevisionAndMetadataChangesPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let originalSong = song("a")
        let model = NowPlayingModel(queue: [originalSong, originalSong, song("b")], currentIndex: 1, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        model.saveQueue()
        let revision = model.queueRevision
        for position in 1...10 { model.elapsed = Double(position) }
        await model.flushQueuePersistence()
        XCTAssertEqual(model.queueRevision, revision)
        var saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.elapsed, 10)
        XCTAssertEqual(saved.ids, ["a", "a", "b"])
        XCTAssertEqual(saved.songs?.count, 2)
        XCTAssertEqual(saved.entryIDs, model.entryIDs)
        var changed = originalSong
        changed.isFavorite = true
        changed.favoriteAddedAt = Date(timeIntervalSince1970: 42)
        changed.artworkURL = root.appendingPathComponent("cover.jpg")
        changed.artwork = .file(changed.artworkURL!)
        model.reconcileAvailability(songs: [changed, song("b")])
        XCTAssertGreaterThan(model.queueRevision, revision)
        model.elapsed = 11
        await model.flushQueuePersistence()
        saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        let metadata = try XCTUnwrap(saved.songs?.first { $0.id == "a" })
        XCTAssertTrue(metadata.isFavorite)
        XCTAssertEqual(metadata.favoriteAddedAt, changed.favoriteAddedAt)
        XCTAssertEqual(metadata.artworkURL, changed.artworkURL)
        XCTAssertEqual(saved.entryIDs, model.entryIDs)
    }

    func testWriteFailureStaysQuietAndNextSaveCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state")
        let sentinel = Data("occupied by a file".utf8)
        try sentinel.write(to: directory)
        let url = directory.appendingPathComponent("queue.json")
        let model = NowPlayingModel(queue: [song("a")], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)

        model.elapsed = 5
        await model.flushQueuePersistence()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: directory), sentinel)

        try FileManager.default.removeItem(at: directory)
        model.elapsed = 19
        await model.flushQueuePersistence()
        let saved = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.ids, ["a"])
        XCTAssertEqual(saved.elapsed, 19)
        XCTAssertNil(model.errorMessage)
    }
}
