import AVFoundation
import XCTest
@testable import NeoMusic

@MainActor
final class DownloadedPlaybackTests: XCTestCase {
    func testRemapPreservesDuplicateEntriesManualQueueProgressAndPendingRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = song("网易云/Album/song.flac"), online = song("netease:12:34")
        let model = NowPlayingModel(queue: [local, online, local], currentIndex: 2, isPlaying: false, elapsed: 17)
        defer { model.shutdownPlayback() }
        let file = directory.appendingPathComponent("queue.json")
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: file)
        model.insertNext([local])
        let entries = model.entryIDs
        let collection = PlaybackCollectionReference(kind: .localPlaylist, id: "saved-playlist", ownerID: nil, title: "Saved playlist")
        var started = false
        model.requestPlay([local, online, local], startingAt: 1, from: "Pending", collection: collection, onStarted: { started = true })
        let pendingID = try XCTUnwrap(model.pendingPlay?.id)

        model.remapSongReferences([local.id: online])
        XCTAssertEqual(model.queue.map(\.id), Array(repeating: online.id, count: 4))
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.elapsed, 17)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.hasUserQueuedUpcoming)
        XCTAssertEqual(model.pendingPlay?.id, pendingID)
        XCTAssertEqual(model.pendingPlay?.songs.map(\.id), Array(repeating: online.id, count: 3))
        XCTAssertEqual(model.pendingPlay?.startingIndex, 1)
        XCTAssertEqual(model.pendingPlay?.collection, collection)
        XCTAssertEqual(model.pendingPlay?.source, "Pending")
        XCTAssertFalse(started)
        let revision = model.queueRevision
        model.remapSongReferences([local.id: online, online.id: song(online.id)])
        XCTAssertEqual(model.queueRevision, revision)
        await model.flushQueuePersistence()
        let persisted = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.ids, model.queue.map(\.id))
        XCTAssertEqual(persisted.entryIDs, entries)
        XCTAssertEqual(persisted.elapsed, 17)
        XCTAssertEqual(persisted.userQueuedIDs, [entries[3]])

        model.confirmPendingPlay()
        XCTAssertTrue(started)
        XCTAssertEqual(model.queue.map(\.id), Array(repeating: online.id, count: 3))
        XCTAssertEqual(model.currentIndex, 1)
        await model.flushQueuePersistence()
    }

    func testRemapRetainsLoadedAudioWithoutResolvingAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("download.wav")
        try writeAudio(to: file)
        let local = song("网易云/Album/song.flac"), online = song("netease:12:34")
        let model = NowPlayingModel(queue: [local], currentIndex: 0, isPlaying: false, elapsed: 2)
        defer { model.shutdownPlayback() }
        model.repeatMode = .off
        var requests = 0
        model.configurePlayback(resolveResource: { _ in
            requests += 1
            return PlaybackResource(url: file)
        }, persistenceURL: directory.appendingPathComponent("queue.json"))
        model.startCurrent(at: 2)
        await model.waitForResourceResolution()
        for _ in 0..<40 where model.elapsed < 1.9 { try await Task.sleep(for: .milliseconds(50)) }
        let elapsed = model.elapsed, entries = model.entryIDs
        XCTAssertTrue(model.hasAudioEngine)

        model.remapSongReferences([local.id: online])
        XCTAssertEqual(model.elapsed, elapsed)
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertTrue(model.hasAudioEngine)
        XCTAssertEqual(requests, 1)
        model.togglePlayback()
        for _ in 0..<40 where model.elapsed <= elapsed + 0.1 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.errorMessage)
        await model.flushQueuePersistence()
    }

    func testOfflineMetadataRestoresBeforeAccountWithoutChangingQueueIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let track = song("netease:12:34")
        let entries = [UUID(), UUID()]
        let saved = NowPlayingModel.SavedQueue(ids: [track.id, track.id], index: 1, elapsed: 24,
            repeatMode: .one, shuffled: true, entryIDs: entries)
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: file)
        model.configureOfflineSongs { $0 == track.id ? track : nil }

        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        XCTAssertEqual(model.current.title, track.title)
        XCTAssertEqual(model.current.artwork, track.artwork)
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.elapsed, 24)
        XCTAssertTrue(model.hasOfflineCurrentSong)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertFalse(model.isPlaying)

        model.restoreOnlineIdentity(ownerID: nil)
        model.reconcileAvailability(songs: [])
        XCTAssertEqual(model.queue.map(\.id), saved.ids)
        XCTAssertEqual(model.current.title, track.title)
        XCTAssertTrue(model.hasOfflineCurrentSong)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        await model.flushQueuePersistence()
        let persisted = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.songs?.first?.title, track.title)
        XCTAssertEqual(persisted.elapsed, 24)
    }

    func testAccountSwitchPreservesDownloadedSongAndInvalidatesOnlyRemoteSong() {
        let downloaded = song("netease:12:34"), remote = song("netease:12:35")
        let model = NowPlayingModel(queue: [downloaded, remote, downloaded], currentIndex: 0, isPlaying: true, elapsed: 8)
        defer { model.shutdownPlayback() }
        model.configureOfflineSongs { $0 == downloaded.id ? downloaded : nil }
        let entries = model.entryIDs
        model.restoreOnlineIdentity(ownerID: "99")
        model.reconcileAvailability(songs: [])

        XCTAssertEqual(model.current, downloaded)
        XCTAssertEqual(model.queue[2], downloaded)
        XCTAssertEqual(model.entryIDs, entries)
        XCTAssertEqual(model.elapsed, 8)
        XCTAssertEqual(model.unavailableIDs, [remote.id])
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.errorMessage)
    }

    func testRemovedOfflineFileReturnsToAccountAvailabilityRules() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = song("netease:12:34")
        let model = NowPlayingModel(queue: [track], currentIndex: 0, isPlaying: false, elapsed: 9)
        defer { model.shutdownPlayback() }
        var available = true
        var resourceCalls = 0
        model.configurePlayback(resolveResource: { _ in
            resourceCalls += 1
            throw URLError(.notConnectedToInternet)
        }, persistenceURL: directory.appendingPathComponent("queue.json"))
        model.configureOfflineSongs { $0 == track.id && available ? track : nil }
        model.restoreOnlineIdentity(ownerID: nil)
        XCTAssertTrue(model.hasOfflineCurrentSong)

        available = false
        model.reconcileOfflineAvailability()
        XCTAssertFalse(model.hasOfflineCurrentSong)
        XCTAssertEqual(model.unavailableIDs, [track.id])
        XCTAssertEqual(model.elapsed, 9)
        model.togglePlayback()
        await model.waitForResourceResolution()
        XCTAssertEqual(resourceCalls, 0)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.errorMessage, "请登录原账号后重试")

        model.restoreOnlineIdentity(ownerID: "12")
        model.reconcileAvailability(songs: [track])
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        XCTAssertEqual(model.current.title, track.title)
        await model.flushQueuePersistence()
    }

    func testLateOfflineIndexHydratesPendingSnapshotAndPersistsUsableMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = song("netease:12:34")
        let file = directory.appendingPathComponent("queue.json")
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: file)
        let saved = NowPlayingModel.SavedQueue(ids: [track.id], index: 0, elapsed: 13,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(track)])
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        XCTAssertFalse(model.unavailableIDs.isEmpty)
        model.configureOfflineSongs { $0 == track.id ? track : nil }
        XCTAssertTrue(model.hasOfflineCurrentSong)
        XCTAssertEqual(model.current, track)
        XCTAssertTrue(model.unavailableIDs.isEmpty)
        XCTAssertEqual(model.elapsed, 13)
        await model.flushQueuePersistence()
        let persisted = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.songs?.first?.title, track.title)
        XCTAssertNil(persisted.songs?.first?.unavailabilityReason)
    }

    func testRuntimeUsesOfflineFileBeforeOnlineResolverAndResumesSavedProgress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("download.wav")
        try writeAudio(to: audioURL)
        let track = song("netease:12:34")
        let store = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let saved = NowPlayingModel.SavedQueue(ids: [track.id], index: 0, elapsed: 3,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(track)])
        try JSONEncoder().encode(saved).write(to: store.appendingPathComponent("playback.json"))
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let previousSongs = LocalLibrary.songLibrary.songs
        defer {
            model.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previousSongs)
            LocalLibrary.downloads.setLocalSongs(previousSongs)
        }
        let runtime = LocalLibraryRuntime(
            documents: directory,
            store: store,
            songLibrary: LocalLibrary.songLibrary,
            playlistLibrary: PlaylistLibrary(playlists: []),
            player: model,
            favoriteAlbums: LocalLibrary.favoriteAlbums,
            pinnedAlbums: LocalLibrary.pinnedAlbums,
            deletedAlbums: LocalLibrary.deletedAlbums,
            onLocalSongsApplied: { LocalLibrary.downloads.setLocalSongs($0) })
        var onlineCalls = 0, publications = 0
        runtime.onLibraryPublished = { publications += 1 }
        runtime.configureOnlineResolver { _ in
            onlineCalls += 1
            throw URLError(.userAuthenticationRequired)
        }
        runtime.configureOfflineResolver { id in
            id == track.id ? PlaybackResource(url: audioURL, quality: "lossless") : nil
        }
        model.configureOfflineSongs { $0 == track.id ? track : nil }
        await runtime.restoreCachedState()
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(model.hasOfflineCurrentSong)
        XCTAssertEqual(model.elapsed, 3)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasAudioEngine)

        model.togglePlayback()
        await model.waitForResourceResolution()
        for _ in 0..<40 where model.elapsed <= 3.1 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(onlineCalls, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPlaying)
        XCTAssertGreaterThan(model.elapsed, 3.1)
        XCTAssertLessThan(model.elapsed, 6)
        XCTAssertEqual(model.actualQuality, "lossless")
        model.restoreOnlineIdentity(ownerID: nil)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.hasOfflineCurrentSong)
        await model.flushQueuePersistence()
    }

    private func song(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: "Downloaded song", artist: "Artist", album: "Album",
            albumArtist: "Artist", trackNumber: 1, artwork: .favorites, duration: 10)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
