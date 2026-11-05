import AVFoundation
import Observation
import Synchronization
import XCTest
import UIKit
@testable import NeoMusic

@MainActor
final class LocalLibraryAlbumProjectionTests: XCTestCase {
    func testAlbumShelfPreservesOrderArtworkCreditsAndVisibility() throws {
        let prefix = UUID().uuidString
        func song(_ name: String, folder: String, artist: String, disc: Int = 1,
                  track: Int, artwork: Artwork = .missing, added: Int) -> LibrarySongItem {
            LibrarySongItem(id: "\(prefix)/\(name)", title: name, artist: artist, album: name,
                            albumArtist: artist, trackNumber: track, artwork: artwork,
                            albumDirectory: "\(prefix)/\(folder)", discNumber: disc, addedOrder: added)
        }
        var first = song("First", folder: "a", artist: "B", track: 1, artwork: .favorites, added: 10)
        first.artworkData = Data([1, 2, 3])
        first.artworkBackdrop = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let second = song("Second", folder: "a", artist: "A", track: 2, added: 90)
        let repeatedArtist = song("Disc 2", folder: "a", artist: "B", disc: 2, track: 1, added: 20)
        let last = song("Other album", folder: "z", artist: "C", track: 1, added: 30)
        let hidden = song("Hidden", folder: "m", artist: "D", track: 1, added: 100)
        let previous = LocalLibrary.songLibrary.songs
        defer {
            LocalLibrary.songLibrary.replace(previous)
            LocalLibrary.favoriteAlbums.remove(first.albumID)
            LocalLibrary.pinnedAlbums.remove(first.albumID)
            LocalLibrary.deletedAlbums.remove(hidden.albumID)
        }
        LocalLibrary.favoriteAlbums.insert(first.albumID)
        LocalLibrary.pinnedAlbums.insert(first.albumID)
        LocalLibrary.deletedAlbums.insert(hidden.albumID)
        LocalLibrary.songLibrary.replace([last, repeatedArtist, hidden, second, first])

        let albums = LocalLibrary.albums
        XCTAssertEqual(albums.map(\.id), [first.albumID, last.albumID])
        let album = try XCTUnwrap(albums.first)
        XCTAssertEqual(album.title, "First")
        XCTAssertEqual(album.subtitle, "B / A")
        XCTAssertEqual(album.addedOrder, 90)
        XCTAssertTrue(album.isFavorite)
        XCTAssertTrue(album.isPinned)
        if case .favorites = album.artwork {} else { XCTFail("The first track's artwork must remain the album cover") }
        let detail = try XCTUnwrap(LocalLibrary.albumDetail(first.albumID))
        XCTAssertEqual(detail.title, album.title)
        XCTAssertEqual(detail.subtitle, album.subtitle)
        XCTAssertEqual(detail.songs.first?.artworkData, first.artworkData)
        XCTAssertEqual(detail.albumBackdrop, first.artworkBackdrop)
        XCTAssertTrue(detail.isFavorite)
        XCTAssertTrue(detail.isPinned)
        if case .favorites = detail.artwork {} else { XCTFail("Album detail must share the shelf cover") }
        XCTAssertEqual(detail.songs.map(\.id), [first.id, second.id, repeatedArtist.id])
        XCTAssertNil(LocalLibrary.albumDetail(hidden.albumID))
        XCTAssertNil(LocalLibrary.albumDetail("missing-\(prefix)"))

        LocalLibrary.deletedAlbums.remove(hidden.albumID)
        XCTAssertEqual(LocalLibrary.albums.map(\.id), [first.albumID, hidden.albumID, last.albumID])
    }

    func testArtistDetailKeepsWholeSharedAlbumsInShelfOrder() throws {
        let prefix = UUID().uuidString
        let artist = "\(prefix)-Artist"
        let hiddenArtist = "\(prefix)-Hidden artist"
        func song(_ name: String, folder: String, artist: String, track: Int,
                  artwork: Artwork = .missing) -> LibrarySongItem {
            LibrarySongItem(id: "\(prefix)/\(name)", title: name, artist: artist, album: name,
                            albumArtist: artist, trackNumber: track, artwork: artwork,
                            albumDirectory: "\(prefix)/\(folder)")
        }
        let first = song("Shared first", folder: "a", artist: "Other credit", track: 1, artwork: .favorites)
        let matching = song("Shared second", folder: "a", artist: artist, track: 2)
        let last = song("Solo", folder: "z", artist: artist, track: 1)
        let unrelated = song("Unrelated", folder: "b", artist: "Unrelated credit", track: 1)
        let hidden = song("Hidden", folder: "m", artist: hiddenArtist, track: 1)
        let previous = LocalLibrary.songLibrary.songs
        defer {
            LocalLibrary.songLibrary.replace(previous)
            LocalLibrary.favoriteArtists.remove(artist)
            LocalLibrary.deletedAlbums.remove(hidden.albumID)
        }
        LocalLibrary.favoriteArtists.insert(artist)
        LocalLibrary.deletedAlbums.insert(hidden.albumID)
        LocalLibrary.songLibrary.replace([last, hidden, matching, unrelated, first])

        let detail = try XCTUnwrap(LocalLibrary.artistDetail(artist))
        XCTAssertEqual(detail.name, artist)
        XCTAssertTrue(detail.isFavorite)
        XCTAssertEqual(detail.albums.map(\.id), [first.albumID, last.albumID])
        let shared = try XCTUnwrap(detail.albums.first)
        XCTAssertEqual(shared.title, first.album)
        XCTAssertEqual(shared.subtitle, "Other credit / \(artist)")
        if case .favorites = shared.artwork {} else { XCTFail("Keep the whole album's first cover, including other artists") }
        XCTAssertNil(LocalLibrary.artistDetail(hiddenArtist))
        XCTAssertNil(LocalLibrary.artistDetail("missing-\(prefix)"))

        LocalLibrary.deletedAlbums.remove(hidden.albumID)
        XCTAssertEqual(LocalLibrary.artistDetail(hiddenArtist)?.albums.map(\.id), [hidden.albumID])
    }
}

@MainActor
final class LocalLibraryRuntimeTests: XCTestCase {
    func testUnreadablePlaybackDoesNotPublishOrOverwriteAndCanRestoreOnRetry() async throws {
        let documents = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let url = store.appendingPathComponent("playback.json")
        let unreadable = Data("incomplete snapshot".utf8)
        try unreadable.write(to: url)
        let runtime = LocalLibraryRuntime(documents: documents, store: store,
            playlistLibrary: PlaylistLibrary(playlists: []), player: player)
        await runtime.restoreCachedState()
        XCTAssertFalse(runtime.hasRestoredPlayback)
        runtime.completeInitialPlaybackRestoration(ownerID: "42", songs: [])
        XCTAssertFalse(runtime.isInitialPlaybackReady)
        player.saveQueueForBackground()
        await player.flushQueuePersistence()
        XCTAssertEqual(try Data(contentsOf: url), unreadable)

        let song = LibrarySongItem(id: "netease:42:9", title: "Saved song", artist: "Artist",
            album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let saved = NowPlayingModel.SavedQueue(ids: [song.id], index: 0, elapsed: 28,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(song)])
        try JSONEncoder().encode(saved).write(to: url)
        await runtime.refresh()
        XCTAssertTrue(runtime.hasRestoredPlayback)
        runtime.completeInitialPlaybackRestoration(ownerID: "42", songs: [])
        XCTAssertTrue(runtime.isInitialPlaybackReady)
        XCTAssertEqual(player.current.title, song.title)
        XCTAssertEqual(player.elapsed, 28)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudioEngine)
        await player.flushQueuePersistence()
    }

    func testLocalPlaybackRemainsUsableAfterUnreadableQueueAndRetryKeepsChosenSong() async throws {
        let documents = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        try writeWave(root.appendingPathComponent("chosen.wav"))
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let url = store.appendingPathComponent("playback.json")
        let broken = Data("unreadable queue".utf8)
        try broken.write(to: url)
        let runtime = LocalLibraryRuntime(documents: documents, store: store,
            playlistLibrary: PlaylistLibrary(playlists: []), player: player)
        await runtime.restoreCachedState()
        player.saveQueueForBackground()
        await player.flushQueuePersistence()
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertFalse(runtime.hasRestoredPlayback)

        let chosen = LibrarySongItem(id: "chosen.wav", title: "Chosen song", artist: "Artist",
            album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        player.repeatMode = .off
        player.play([chosen], from: "Local album", shuffled: false)
        XCTAssertTrue(player.hasAudioEngine)
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(player.current.id, chosen.id)
        await player.flushQueuePersistence()
        let selected = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(selected.ids, [chosen.id])
        let occurrence = player.entryIDs
        await runtime.refresh()
        XCTAssertTrue(runtime.hasRestoredPlayback)
        XCTAssertEqual(player.current.id, chosen.id)
        XCTAssertEqual(player.entryIDs, occurrence)
        await player.flushQueuePersistence()
    }

    func testCachedStateRestoresBeforeScanAndPresentationIsReleasedExplicitly() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        try writeWave(root.appendingPathComponent("new.wav"))
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let cached = LocalTrack(id: "cached.wav", title: "Cached", artist: "A", album: "B", albumArtist: "A",
                                trackNumber: 1, duration: 1, artworkData: nil, addedDate: .distantPast)
        try JSONEncoder().encode([cached]).write(to: store.appendingPathComponent("tracks.json"))
        let saved = NowPlayingModel.SavedQueue(ids: [cached.id], index: 0, elapsed: 0, repeatMode: .off, shuffled: false)
        try JSONEncoder().encode(saved).write(to: store.appendingPathComponent("playback.json"))
        let runtime = LocalLibraryRuntime(documents: documents, store: store,
                                          playlistLibrary: PlaylistLibrary(playlists: []), player: player)
        await runtime.restoreCachedState()
        XCTAssertEqual(LocalLibrary.songs.map(\.id), [cached.id])
        XCTAssertEqual(player.queue.map(\.title), [cached.title])
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertFalse(runtime.isInitialPresentationReady)
        XCTAssertFalse(player.hasAudioEngine)
        runtime.completeInitialPresentation(songs: LocalLibrary.songs)
        XCTAssertTrue(runtime.isInitialPresentationReady)
        XCTAssertFalse(runtime.isInitialPlaybackReady)
        runtime.completeInitialPlaybackRestoration(ownerID: nil, songs: LocalLibrary.songs)
        XCTAssertTrue(runtime.isInitialPlaybackReady)
        await runtime.refresh()
        XCTAssertEqual(LocalLibrary.songs.map(\.id), ["new.wav"])
        XCTAssertTrue(runtime.isInitialPresentationReady)
    }

    func testLibraryPresentationDoesNotWaitForOnlineQueueMetadata() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let song = LibrarySongItem(id: "netease:42:9", title: "Cached recommendation", artist: "Artist",
                                  album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        let original = PlaylistLibrary(playlists: [])
        original.configurePersistence(url: store.appendingPathComponent("playlists.json"), songs: [song])
        let playlistID = try XCTUnwrap(original.createPlaylist(named: "Saved", artwork: .playlist, in: nil)).id
        XCTAssertEqual(original.addSongs([song], to: playlistID), 1)
        let saved = NowPlayingModel.SavedQueue(ids: [song.id], index: 0, elapsed: 4, repeatMode: .all, shuffled: false)
        try JSONEncoder().encode(saved).write(to: store.appendingPathComponent("playback.json"))
        let restored = PlaylistLibrary(playlists: [])
        let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)

        await runtime.restoreCachedState()
        XCTAssertEqual(player.unavailableIDs, [song.id])
        XCTAssertNotEqual(player.current.title, song.title)
        XCTAssertNotEqual(restored.songs(in: playlistID).first?.title, song.title)
        XCTAssertFalse(runtime.isInitialPresentationReady)

        runtime.completeInitialPresentation(songs: LocalLibrary.songs)
        XCTAssertTrue(runtime.isInitialPresentationReady)
        XCTAssertFalse(runtime.isInitialPlaybackReady)

        let titlesAtReady = Mutex<[String]?>(nil)
        _ = withObservationTracking { runtime.isInitialPlaybackReady } onChange: {
            MainActor.assumeIsolated {
                titlesAtReady.withLock {
                    $0 = [player.current.title] + restored.songs(in: playlistID).map(\.title)
                }
            }
        }
        runtime.completeInitialPlaybackRestoration(ownerID: "42", songs: [song])

        XCTAssertEqual(titlesAtReady.withLock { $0 }, [song.title, song.title])
        XCTAssertTrue(runtime.isInitialPresentationReady)
        XCTAssertTrue(runtime.isInitialPlaybackReady)
        XCTAssertTrue(player.unavailableIDs.isEmpty)
        XCTAssertEqual(player.elapsed, 4)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertFalse(player.hasAudioEngine)
    }

    private func writeWave(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for index in 0..<4410 { buffer.floatChannelData![0][index] = 0 }
        try file.write(from: buffer)
    }

    func testIncompleteCacheRestoresSavedReferencesBeforeScan() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeWave(root.appendingPathComponent("song.wav"))
        let stale = LocalTrack(id: "removed.wav", title: "Removed", artist: "A", album: "B", albumArtist: "A",
                               trackNumber: 1, duration: 10, artworkData: nil, addedDate: .distantPast)
        let cacheURL = store.appendingPathComponent("tracks.json")
        try JSONEncoder().encode([stale]).write(to: cacheURL)
        let song = LibrarySongItem(id: "song.wav", title: "Song", artist: "A", album: "B", albumArtist: "A",
                                   trackNumber: 1, artwork: .missing)
        let original = PlaylistLibrary(playlists: [])
        original.configurePersistence(url: store.appendingPathComponent("playlists.json"), songs: [song])
        let playlistID = try XCTUnwrap(original.createPlaylist(named: "Saved", artwork: .playlist, in: nil)).id
        _ = original.addSongs([song], to: playlistID)
        let queue = NowPlayingModel.SavedQueue(ids: [song.id], index: 0, elapsed: 0, repeatMode: .off, shuffled: false)
        try JSONEncoder().encode(queue).write(to: store.appendingPathComponent("playback.json"))
        let restored = PlaylistLibrary(playlists: [])
        let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)

        // Missing metadata retains saved identities while the background scan resolves them.
        let snapshotAtReady = Mutex<[[String]]?>(nil)
        _ = withObservationTracking { runtime.isInitialLibraryReady } onChange: {
            MainActor.assumeIsolated {
                let snapshot = [LocalLibrary.songs.map(\.id), restored.songs(in: playlistID).map(\.id), player.queue.map(\.id)]
                snapshotAtReady.withLock { $0 = snapshot }
            }
        }
        await runtime.refresh()
        XCTAssertEqual(snapshotAtReady.withLock { $0 }, [[stale.id], [song.id], [song.id]])
        XCTAssertEqual(LocalLibrary.songs.map(\.id), [song.id])
        XCTAssertEqual(restored.songs(in: playlistID).map(\.id), [song.id])
        XCTAssertTrue(runtime.isInitialLibraryReady)
    }

    func testCompleteCacheReleasesShelfBeforeScanAndRetainsStoresOnFailure() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeWave(root.appendingPathComponent("song.wav"))
        let cached = LocalTrack(id: "song.wav", title: "Cached title", artist: "A", album: "B", albumArtist: "A",
                               trackNumber: 1, duration: 10, artworkData: nil, addedDate: .distantPast)
        let cacheURL = store.appendingPathComponent("tracks.json")
        let cacheData = try JSONEncoder().encode([cached])
        try cacheData.write(to: cacheURL)
        let song = LibrarySongItem(id: cached.id, title: cached.title, artist: "A", album: "B", albumArtist: "A",
                                   trackNumber: 1, artwork: .missing)
        let playlistURL = store.appendingPathComponent("playlists.json")
        let playbackURL = store.appendingPathComponent("playback.json")
        let original = PlaylistLibrary(playlists: [])
        original.configurePersistence(url: playlistURL, songs: [song])
        let id = try XCTUnwrap(original.createPlaylist(named: "Saved", artwork: .playlist, in: nil)).id
        original.addSongs([song], to: id)
        let playlistData = try Data(contentsOf: playlistURL)
        let playbackData = try JSONEncoder().encode(NowPlayingModel.SavedQueue(
            ids: [song.id], index: 0, elapsed: 0, repeatMode: .off, shuffled: false))
        try playbackData.write(to: playbackURL)
        let restored = PlaylistLibrary(playlists: [])
        let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)
        let snapshot = Mutex<[[String]]?>(nil)
        _ = withObservationTracking { runtime.isInitialLibraryReady } onChange: {
            MainActor.assumeIsolated {
                snapshot.withLock { $0 = [LocalLibrary.songs.map(\.title), restored.songs(in: id).map(\.id), player.queue.map(\.id)] }
                // If the shelf really appears before scanning, this makes that later scan fail.
                try? FileManager.default.removeItem(at: root)
            }
        }
        await runtime.refresh()
        XCTAssertEqual(snapshot.withLock { $0 }, [[cached.title], [song.id], [song.id]])
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertNotNil(runtime.status)
        XCTAssertEqual(LocalLibrary.songs.map(\.title), [cached.title])
        XCTAssertEqual(try Data(contentsOf: cacheURL), cacheData)
        XCTAssertEqual(try Data(contentsOf: playlistURL), playlistData)
        // The audio engine may persist generated occurrence IDs after restoration;
        // a failed scan must preserve the restored queue and playback preferences.
        await player.flushQueuePersistence()
        let savedQueue = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: playbackURL))
        XCTAssertEqual(savedQueue.ids, [song.id])
        XCTAssertEqual(savedQueue.index, 0)
        XCTAssertEqual(savedQueue.elapsed, 0)
        XCTAssertEqual(savedQueue.repeatMode, .off)
        XCTAssertFalse(savedQueue.shuffled)
        XCTAssertEqual(player.queue.map(\.id), [song.id])
    }

    func testCancellationAfterCacheRestoreKeepsReadyShelfAndRetriesScan() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let cached = LocalTrack(id: "removed.wav", title: "Cached", artist: "A", album: "B", albumArtist: "A",
                               trackNumber: 1, duration: 1, artworkData: nil, addedDate: .distantPast)
        let cacheURL = store.appendingPathComponent("tracks.json")
        let cacheData = try JSONEncoder().encode([cached])
        try cacheData.write(to: cacheURL)
        try writeWave(root.appendingPathComponent("new.wav"))
        let runtime = LocalLibraryRuntime(documents: documents, store: store,
                                          playlistLibrary: PlaylistLibrary(playlists: []), player: player)
        _ = withObservationTracking { runtime.isInitialLibraryReady } onChange: {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        await Task { await runtime.refresh() }.value
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertEqual(LocalLibrary.songs.map(\.id), [cached.id])
        XCTAssertEqual(try Data(contentsOf: cacheURL), cacheData)
        await runtime.refresh()
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertEqual(LocalLibrary.songs.map(\.id), ["new.wav"])
    }

    func testIncompleteQueueRestoresReferencesWithoutPreparingAudioOrRewritingState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback(); try? FileManager.default.removeItem(at: url) }
        let saved = try JSONEncoder().encode(NowPlayingModel.SavedQueue(
            ids: ["new.wav"], index: 0, elapsed: 2, repeatMode: .all, shuffled: false))
        try saved.write(to: url)
        player.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(player.restoreQueue(songs: []))
        XCTAssertEqual(player.queue.map(\.id), ["new.wav"])
        XCTAssertEqual(player.unavailableIDs, ["new.wav"])
        XCTAssertNil(player.errorMessage, "Missing cached metadata is resolved by the scan before reporting a missing file")
        XCTAssertFalse(player.hasAudioEngine)
        await player.flushQueuePersistence()
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let song = LibrarySongItem(id: "new.wav", title: "New", artist: "A", album: "B", albumArtist: "A",
                                   trackNumber: 1, artwork: .missing)
        player.reconcileAvailability(songs: [song])
        XCTAssertEqual(player.current.title, "New")
        XCTAssertTrue(player.unavailableIDs.isEmpty)
        XCTAssertFalse(player.hasAudioEngine)
        XCTAssertEqual(player.queue.map(\.id), [song.id])
        XCTAssertEqual(player.repeatMode, .all)
        await player.flushQueuePersistence()
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testUnchangedTrackCacheDoesNotRewriteAndChangedCachePersists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("startup"))
        }
        let track = LocalTrack(id: "song.wav", title: "Song", artist: "A", album: "B", albumArtist: "A",
                              trackNumber: 1, duration: 1, artworkData: nil, addedDate: .distantPast)
        try JSONEncoder().encode([track]).write(to: url)
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
        let cache = LocalLibraryTrackCache()
        _ = try await cache.read(from: url)
        try await cache.write([track], to: url)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, sentinel)
        try await cache.write([], to: url)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: url)), [])
    }

    func testInitialRestoreFailurePublishesCachedAppearanceWithoutRestoringStores() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        defer {
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeWave(root.appendingPathComponent("song.wav"))
        let artwork = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
        let cached = LocalTrack(id: "ents/音乐/song.wav", title: "Cached", artist: "A", album: "B", albumArtist: "A",
                               trackNumber: 1, duration: 10, artworkData: artwork, addedDate: .distantPast)
        let cacheURL = store.appendingPathComponent("tracks.json")
        let cacheData = try JSONEncoder().encode([cached])
        try cacheData.write(to: cacheURL)
        // A known legacy identity requires repair; an unreadable playlist aborts
        // restoration before either persistent document may be changed.
        let playlistURL = store.appendingPathComponent("playlists.json")
        let playbackURL = store.appendingPathComponent("playback.json")
        let playlistData = Data("unreadable playlist".utf8)
        let playbackData = try JSONEncoder().encode(NowPlayingModel.SavedQueue(
            ids: [cached.id], index: 0, elapsed: 0, repeatMode: .off, shuffled: false))
        try playlistData.write(to: playlistURL)
        try playbackData.write(to: playbackURL)
        let restored = PlaylistLibrary(playlists: [])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)
        await runtime.refresh()

        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertNotNil(runtime.status)
        XCTAssertEqual(LocalLibrary.songs.map(\.id), [cached.id])
        XCTAssertEqual(LocalLibrary.songs.first?.artworkBackdrop, AlbumArtworkBackdrop.extract(from: artwork))
        XCTAssertTrue(restored.playlists.isEmpty)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cacheURL), cacheData)
        XCTAssertEqual(try Data(contentsOf: playlistURL), playlistData)
        XCTAssertEqual(try Data(contentsOf: playbackURL), playbackData)
    }

    func testCancelledInitialRestoreDoesNotPublishCacheOrReady() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        defer {
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: documents)
        }
        _ = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let cached = LocalTrack(id: "cached.wav", title: "Cached", artist: "A", album: "B", albumArtist: "A",
                               trackNumber: 1, duration: 10, artworkData: nil, addedDate: .distantPast)
        let cacheURL = store.appendingPathComponent("tracks.json")
        let cacheData = try JSONEncoder().encode([cached])
        try cacheData.write(to: cacheURL)
        let restored = PlaylistLibrary(playlists: [])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await runtime.refresh()
        }
        await cancelled.value
        XCTAssertFalse(runtime.isInitialLibraryReady)
        XCTAssertNil(runtime.status)
        XCTAssertEqual(LocalLibrary.songLibrary.songs.map(\.id), previous.map(\.id))
        XCTAssertTrue(restored.playlists.isEmpty)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cacheURL), cacheData)
    }

    func testFolderIdentityAndDiscTrackNaturalOrder() {
        func song(_ id: String, artist: String, folder: String, disc: Int, track: Int) -> LibrarySongItem {
            LibrarySongItem(id: id, title: id, artist: artist, album: "同名目录", albumArtist: artist,
                            trackNumber: track, artwork: .missing, albumDirectory: folder, discNumber: disc)
        }
        let a = song("one/10.wav", artist: "A", folder: "one", disc: 1, track: 0)
        let b = song("one/2.wav", artist: "B", folder: "one", disc: 1, track: 0)
        let c = song("two/1.wav", artist: "A", folder: "two", disc: 1, track: 1)
        let d = song("one/disc2.wav", artist: "A", folder: "one", disc: 2, track: 1)
        XCTAssertEqual(a.albumID, b.albumID)
        XCTAssertNotEqual(a.albumID, c.albumID)
        XCTAssertEqual([d, a, b].sorted(by: LibrarySongItem.albumOrder).map(\.id), [b.id, a.id, d.id])
        let previous = LocalLibrary.songLibrary.songs
        defer { LocalLibrary.songLibrary.replace(previous) }
        LocalLibrary.songLibrary.replace([a, b, c])
        XCTAssertEqual(LocalLibrary.albums.count, 2)
        XCTAssertEqual(LocalLibrary.albumDetail(a.albumID)?.songs.count, 2)
        XCTAssertEqual(LocalLibrary.artistDetail("B")?.albums.count, 1)
    }

    func testFolderMigrationPreservesFavoriteAndPinWithoutHidingOtherSongs() {
        let old = LocalTrack(id: "migration-test/song.wav", title: "Song", artist: "Artist", album: "Old migration album", albumArtist: "Artist", trackNumber: 1, duration: 1, artworkData: nil, addedDate: .distantPast)
        var new = old
        new.albumDirectory = "migration-test"
        let oldID = "Artist\u{001F}Old migration album"
        let newID = "folder:migration-test"
        let previousHidden = UserDefaults.standard.object(forKey: "hiddenSongs")
        LocalLibrary.favoriteAlbums.insert(oldID)
        LocalLibrary.pinnedAlbums.insert(oldID)
        LocalLibrary.deletedAlbums.insert(oldID)
        defer {
            for id in [oldID, newID] {
                LocalLibrary.favoriteAlbums.remove(id)
                LocalLibrary.pinnedAlbums.remove(id)
                LocalLibrary.deletedAlbums.remove(id)
            }
            UserDefaults.standard.set(previousHidden, forKey: "hiddenSongs")
        }
        LocalLibraryRuntime().migrateAlbumSelections(from: [old], to: [new])
        XCTAssertTrue(LocalLibrary.favoriteAlbums.ids.contains(newID))
        XCTAssertTrue(LocalLibrary.pinnedAlbums.ids.contains(newID))
        XCTAssertFalse(LocalLibrary.deletedAlbums.ids.contains(newID))
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: "hiddenSongs")?.contains(old.id) == true)
    }

    func testFailedDecodeRetainsCachedIdentityAndCancelledRefreshDoesNotWrite() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents); LocalLibrary.songLibrary.replace([]) }
        let root = try LocalMusicScanner.prepareDirectory(documents: documents)
        let store = documents.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let artworkData = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
        let expectedBackdrop = try XCTUnwrap(AlbumArtworkBackdrop.extract(from: artworkData))
        let track = LocalTrack(id: "broken.mp3", title: "Cached", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, duration: 10, artworkData: artworkData, addedDate: .distantPast)
        let cache = store.appendingPathComponent("tracks.json")
        try JSONEncoder().encode([track]).write(to: cache)
        try Data("invalid audio".utf8).write(to: root.appendingPathComponent(track.id))
        let runtime = LocalLibraryRuntime(documents: documents, store: store)
        await runtime.refresh()
        XCTAssertEqual(LocalLibrary.songs.map(\.id), [track.id])
        let song = try XCTUnwrap(LocalLibrary.songs.first)
        XCTAssertNil(song.artworkData)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(song.artworkURL)), artworkData)
        XCTAssertEqual(song.artworkBackdrop, expectedBackdrop, "Published covers must already have their matching page color")
        XCTAssertEqual(LocalLibrary.albumDetail(song.albumID)?.albumBackdrop, expectedBackdrop)
        var expected = track
        expected.artworkData = nil
        expected.artworkKey = song.artworkURL?.deletingPathExtension().lastPathComponent
        expected.artworkBackdrop = expectedBackdrop
        let saved = try Data(contentsOf: cache)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: saved), [expected])
        XCTAssertTrue(runtime.status?.contains("broken.mp3") == true)
        try FileManager.default.removeItem(at: root.appendingPathComponent(track.id))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await runtime.refresh()
        }
        await cancelled.value
        XCTAssertEqual(LocalLibrary.songs.first?.artworkBackdrop, expectedBackdrop)
        XCTAssertEqual(try Data(contentsOf: cache), saved)
        await runtime.refresh()
        XCTAssertTrue(LocalLibrary.songs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: cache)), [])
    }

    func testInitialFailureReleasesShelfAndReportsError() async throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: documents)
        defer { try? FileManager.default.removeItem(at: documents) }
        let runtime = LocalLibraryRuntime(documents: documents)
        await runtime.refresh()
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertNotNil(runtime.status)
    }

    func testMissingOrCorruptCacheDoesNotErasePlaylistReferences() async throws {
        for corrupt in [false, true] {
            let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: documents); LocalLibrary.songLibrary.replace([]) }
            let root = try LocalMusicScanner.prepareDirectory(documents: documents)
            let store = documents.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            let song = LibrarySongItem(id: "song.wav", title: "song", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
            let playlistURL = store.appendingPathComponent("playlists.json")
            let original = PlaylistLibrary(playlists: [])
            original.configurePersistence(url: playlistURL, songs: [song])
            let playlist = try XCTUnwrap(original.createPlaylist(named: "saved", artwork: .playlist, in: nil))
            _ = original.addSongs([song], to: playlist.id)
            let before = try Data(contentsOf: playlistURL)
            if corrupt { try Data("bad cache".utf8).write(to: store.appendingPathComponent("tracks.json")) }
            let restored = PlaylistLibrary(playlists: [])
            let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
            let runtime = LocalLibraryRuntime(documents: documents, store: store, playlistLibrary: restored, player: player)
            XCTAssertFalse(runtime.isInitialLibraryReady)
            // An aborted scan must not resolve identities against an empty library or touch the store.
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                await runtime.refresh()
            }
            await cancelled.value
            XCTAssertFalse(runtime.isInitialLibraryReady)
            XCTAssertEqual(try Data(contentsOf: playlistURL), before)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            do {
                let file = try AVAudioFile(forWriting: root.appendingPathComponent(song.id), settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
                buffer.frameLength = 4410
                for i in 0..<4410 { buffer.floatChannelData![0][i] = 0 }
                try file.write(from: buffer)
            }
            await runtime.refresh()
            XCTAssertTrue(runtime.isInitialLibraryReady)
            XCTAssertEqual(restored.songs(in: playlist.id).map(\.id), [song.id])
            let reloaded = PlaylistLibrary(playlists: [])
            reloaded.configurePersistence(url: playlistURL, songs: LocalLibrary.songs)
            XCTAssertEqual(reloaded.songs(in: playlist.id).map(\.id), [song.id])
        }
    }
    func testLegacyIdentityRepairPreservesQueuePlaylistAndFlags() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func track(_ id: String) -> LocalTrack {
            LocalTrack(id: id, title: "Song", artist: "A", album: "B", albumArtist: "A", trackNumber: 1, duration: 12, artworkData: nil, addedDate: .distantPast)
        }
        let legacy = "ents/音乐/album/track.flac"
        let id = "album/track.flac"
        let playlist = store.appendingPathComponent("playlists.json")
        let playback = store.appendingPathComponent("playback.json")
        try JSONSerialization.data(withJSONObject: ["playlists": [["id": "list", "songs": [legacy, "other"]]], "nextOrder": 9]).write(to: playlist)
        try JSONSerialization.data(withJSONObject: ["ids": [legacy, legacy, "other"], "index": 1, "elapsed": 42]).write(to: playback)
        for key in ["favoriteSongs", "pinnedSongs", "hiddenSongs"] { defaults.set([legacy, "other"], forKey: key) }
        try LocalLibraryRuntime.repairLegacyIdentities(cached: [track(legacy)], scanned: [track(id)], store: store, defaults: defaults)
        let p = try JSONSerialization.jsonObject(with: Data(contentsOf: playlist)) as! [String: Any]
        XCTAssertEqual((p["playlists"] as! [[String: Any]])[0]["songs"] as? [String], [id, "other"])
        XCTAssertEqual(p["nextOrder"] as? Int, 9)
        let q = try JSONSerialization.jsonObject(with: Data(contentsOf: playback)) as! [String: Any]
        XCTAssertEqual(q["ids"] as? [String], [id, id, "other"])
        XCTAssertEqual(q["index"] as? Int, 1)
        XCTAssertEqual(q["elapsed"] as? Int, 42)
        for key in ["favoriteSongs", "pinnedSongs", "hiddenSongs"] { XCTAssertEqual(defaults.stringArray(forKey: key), [id, "other"]) }
        // Invalid second store aborts before the valid first document is changed.
        try JSONSerialization.data(withJSONObject: ["playlists": [["songs": [legacy]]]]).write(to: playlist)
        let before = try Data(contentsOf: playlist)
        try Data("broken".utf8).write(to: playback)
        XCTAssertThrowsError(try LocalLibraryRuntime.repairLegacyIdentities(cached: [track(legacy)], scanned: [track(id)], store: store, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: playlist), before)
        // Ambiguous or unrelated suffixes never qualify.
        XCTAssertNoThrow(try LocalLibraryRuntime.repairLegacyIdentities(cached: [track(legacy), track(id)], scanned: [track(id)], store: store, defaults: defaults))
        XCTAssertNoThrow(try LocalLibraryRuntime.repairLegacyIdentities(cached: [track("other/" + id)], scanned: [track(id)], store: store, defaults: defaults))
    }
}

@MainActor
final class PinnedOrderStoreTests: XCTestCase {
    private let key = "pinned-order-test"
    private var playlist: PinnedOrderID { .init(kind: .playlist, id: "same/id") }
    private var album: PinnedOrderID { .init(kind: .album, id: "same/id") }
    private var added: PinnedOrderID { .init(kind: .playlist, id: "new") }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PinnedOrderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testLegacyPinsKeepTheirOrderAndDifferentTypesDoNotCollide() throws {
        try withDefaults { defaults in
            defaults.set(["same/id"], forKey: "pinnedAlbums")
            let store = PinnedOrderStore(defaults: defaults, key: key)
            let existing = [playlist, album]
            XCTAssertEqual(store.ordered(existing, id: { $0 }), existing)
            XCTAssertNotEqual(playlist, album)
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(defaults.stringArray(forKey: "pinnedAlbums"), ["same/id"])
            XCTAssertEqual(PinnedOrderID(route: .playlist("same/id")), playlist)
            XCTAssertEqual(PinnedOrderID(route: .album("same/id")), album)
            XCTAssertNil(PinnedOrderID(route: .category(.albums)))
        }
    }

    func testMixedReorderPersistsAndNewPinsAppend() throws {
        try withDefaults { defaults in
            let store = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertTrue(store.reorder(visible: [playlist, album], to: [album, playlist]))
            let restored = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertEqual(restored.ordered([playlist, album, added], id: { $0 }), [album, playlist, added])
            // Removing a pin hides it; re-pinning restores its position without losing it.
            XCTAssertEqual(restored.ordered([playlist, added], id: { $0 }), [playlist, added])
            XCTAssertEqual(restored.ordered([playlist, album, added], id: { $0 }), [album, playlist, added])
        }
    }

    func testReorderingDuringPartialLoadPreservesUnavailablePins() throws {
        try withDefaults { defaults in
            let store = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertTrue(store.reorder(visible: [playlist, album, added], to: [playlist, album, added]))
            XCTAssertEqual(store.ordered([], id: { (id: PinnedOrderID) in id }), [])
            XCTAssertTrue(store.reorder(visible: [playlist, added], to: [added, playlist]))
            let restored = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertEqual(restored.ordered([playlist, album, added], id: { $0 }), [added, album, playlist])
        }
    }

    func testInvalidRequestsAndCorruptStorageNeverOverwriteSavedOrder() throws {
        try withDefaults { defaults in
            let store = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertTrue(store.reorder(visible: [playlist, album], to: [album, playlist]))
            let saved = try XCTUnwrap(defaults.data(forKey: key))
            XCTAssertFalse(store.reorder(visible: [playlist, album], to: [playlist, playlist]))
            XCTAssertFalse(store.reorder(visible: [playlist, album], to: [playlist]))
            XCTAssertFalse(store.reorder(visible: [playlist, playlist], to: [playlist, playlist]))
            XCTAssertFalse(store.reorder(visible: [playlist, album], to: [playlist, added]))
            XCTAssertEqual(defaults.data(forKey: key), saved)
            let corrupt = Data("invalid order".utf8)
            defaults.set(corrupt, forKey: key)
            let invalid = PinnedOrderStore(defaults: defaults, key: key)
            XCTAssertEqual(invalid.ordered([playlist, album], id: { $0 }), [playlist, album])
            XCTAssertFalse(invalid.reorder(visible: [playlist, album], to: [album, playlist]))
            XCTAssertEqual(defaults.data(forKey: key), corrupt)
        }
    }
}
