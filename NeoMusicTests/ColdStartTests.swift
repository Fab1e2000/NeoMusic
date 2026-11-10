import XCTest
import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI
@testable import NeoMusic

@MainActor final class ColdStartTests: XCTestCase {
    func testRestoredPlayerStaysLightweightAndFirstPlaySeeksToSavedPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        let stateURL = directory.appendingPathComponent("queue.json")
        let saved = NowPlayingModel.SavedQueue(ids: ["tone.wav"], index: 0, elapsed: 4, repeatMode: .off, shuffled: false)
        let data = try JSONEncoder().encode(saved)
        try data.write(to: stateURL)
        let song = LibrarySongItem(id: "tone.wav", title: "Tone", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing, duration: 10)
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in audioURL }, persistenceURL: stateURL)
        XCTAssertTrue(model.restoreQueue(songs: [song]))
        let adapter = ReferencePlayerState(model: model)
        XCTAssertEqual(adapter.currentTrack?.title, "Tone")
        XCTAssertEqual(adapter.duration, 10)
        XCTAssertEqual(adapter.progress, 4)
        XCTAssertFalse(adapter.isLoading)
        XCTAssertEqual(model.spectrumLevels(), Array(repeating: 0, count: 5))
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertEqual(try Data(contentsOf: stateURL), data)
        model.togglePlayback()
        XCTAssertTrue(model.hasAudioEngine)
        for _ in 0..<40 where model.elapsed <= 4.1 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPlaying)
        XCTAssertGreaterThan(model.elapsed, 4.1)
        XCTAssertLessThan(model.elapsed, 7)
        await model.flushQueuePersistence()
    }

    func testRestoredOnlineSongResolvesOnlyOnFirstTapAndSeeksSavedProgress() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        let track = LibrarySongItem(id: "netease:12:34", title: "Saved online song", artist: "Artist",
            album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing, duration: 10)
        let saved = NowPlayingModel.SavedQueue(ids: [track.id], index: 0, elapsed: 4,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(track)])
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        var requests = 0
        model.configurePlayback(resolveResource: { _ in
            requests += 1
            return PlaybackResource(url: audioURL)
        }, persistenceURL: directory.appendingPathComponent("queue.json"))
        XCTAssertTrue(model.restoreQueue(songs: [], restoredState: .success(saved)))
        model.restoreOnlineIdentity(ownerID: "12")
        let presentation = ReferencePlayerState(model: model)
        XCTAssertEqual(presentation.currentTrack?.title, track.title)
        XCTAssertEqual(presentation.progress, 4)
        XCTAssertFalse(presentation.isPlaying)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertEqual(requests, 0)

        presentation.togglePlayback()
        await model.waitForResourceResolution()
        for _ in 0..<40 where model.elapsed <= 4.1 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(requests, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(presentation.isPlaying)
        XCTAssertGreaterThan(presentation.progress, 4.1)
        XCTAssertLessThan(presentation.progress, 7)
        XCTAssertEqual(presentation.currentTrack?.title, track.title)
        await model.flushQueuePersistence()
    }

    func testMissingFileFailsFirstPlayWithoutCreatingTransportOrLosingQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = NowPlayingModel.SavedQueue(ids: ["missing.wav"], index: 0, elapsed: 4, repeatMode: .off, shuffled: false)
        try JSONEncoder().encode(saved).write(to: url)
        let model = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { model.shutdownPlayback() }
        model.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(model.restoreQueue(songs: []))
        model.togglePlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasAudioEngine)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.queue.map(\.id), saved.ids)
        XCTAssertEqual(model.elapsed, 4)
        await model.flushQueuePersistence()
    }

    func testPlaylistEditsPreserveUnresolvedReferencesAndUnchangedRefreshDoesNotWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let songs = ["a", "b"].map { LibrarySongItem(id: $0, title: $0, artist: "", album: "", albumArtist: "", trackNumber: 1, artwork: .missing) }
        let original = PlaylistLibrary(playlists: [])
        original.configurePersistence(url: url, songs: songs)
        let playlist = try XCTUnwrap(original.createPlaylist(named: "Saved", artwork: .playlist, in: nil))
        await original.flushPersistence()
        original.addSongs(songs, to: playlist.id)
        await original.flushPersistence()
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        restored.renamePlaylist(playlist.id, to: "Renamed")
        await restored.flushPersistence()
        let reopened = PlaylistLibrary(playlists: [])
        reopened.configurePersistence(url: url, songs: songs)
        XCTAssertEqual(reopened.songs(in: playlist.id).map(\.id), ["a", "b"])
        XCTAssertEqual(reopened.playlist(playlist.id)?.title, "Renamed")
        let timestamp = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        restored.reconcileSongs(songs)
        await restored.flushPersistence()
        let actual = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(actual, timestamp)
    }

    func testThumbnailDownsamplingAndPlayerReuseTheSameArtworkFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 512), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        }
        try XCTUnwrap(source.pngData()).write(to: url)
        let loaded = await LocalArtworkImages.load(url, pixels: 128)
        let thumbnail = try XCTUnwrap(loaded)
        XCTAssertEqual(thumbnail.size, CGSize(width: 128, height: 64))
        XCTAssertTrue(LocalArtworkImages.cached(url, pixels: 128) === thumbnail)
        let song = LibrarySongItem(id: "song", title: "Song", artist: "", album: "", albumArtist: "", trackNumber: 1, artwork: .file(url), artworkURL: url)
        let model = NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false)
        let adapter = ReferencePlayerState(model: model)
        XCTAssertEqual(adapter.currentTrack?.coverURL, url)
        XCTAssertEqual(adapter.tracks.first?.coverURL, url)
        XCTAssertFalse(model.hasAudioEngine)
    }

    func testUnreadableSongKeepsPlaylistReferenceWhenMetadataCacheIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        defer { try? FileManager.default.removeItem(at: directory); LocalLibrary.songLibrary.replace(previous) }
        let root = try LocalMusicScanner.prepareDirectory(documents: directory)
        try Data("broken audio".utf8).write(to: root.appendingPathComponent("broken.mp3"))
        let store = directory.appendingPathComponent("state")
        let playlistURL = store.appendingPathComponent("playlists.json")
        let source = PlaylistLibrary(playlists: [])
        source.configurePersistence(url: playlistURL, songs: [])
        let playlist = try XCTUnwrap(source.createPlaylist(named: "Saved", artwork: .playlist, in: nil))
        await source.flushPersistence()
        source.addSongs([.unavailable("broken.mp3")], to: playlist.id)
        await source.flushPersistence()
        let original = try Data(contentsOf: playlistURL)
        let restored = PlaylistLibrary(playlists: [])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback() }
        let runtime = LocalLibraryRuntime(
            documents: directory,
            store: store,
            songLibrary: LocalLibrary.songLibrary,
            playlistLibrary: restored,
            player: player,
            favoriteAlbums: LocalLibrary.favoriteAlbums,
            pinnedAlbums: LocalLibrary.pinnedAlbums,
            deletedAlbums: LocalLibrary.deletedAlbums,
            onLocalSongsApplied: { LocalLibrary.downloads.setLocalSongs($0) })
        await runtime.refresh()
        XCTAssertTrue(runtime.isInitialLibraryReady)
        XCTAssertNotNil(runtime.status)
        XCTAssertEqual(restored.songs(in: playlist.id).map(\.id), ["broken.mp3"])
        XCTAssertEqual(try Data(contentsOf: playlistURL), original)
    }

    func testCancelledSystemArtworkLoadCannotRestorePreviousTrackCover() async throws {
        // The test host also restores its real player; finish that owner before testing MediaPlayer's process-wide center.
        await LocalLibrary.runtime.refresh()
        for _ in 0..<500 where LocalLibrary.runtime.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(LocalLibrary.runtime.isScanning)
        LocalLibrary.player.shutdownPlayback()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(PlayerTestFixtures.artwork().pngData()).write(to: url)
        let session = PlaybackMediaSession(play: {}, pause: {}, next: {}, previous: {}, seek: { _ in })
        defer { session.shutdown() }
        session.update(.init(title: "First", artist: "", album: "", artwork: nil, artworkURL: url), elapsed: 0, duration: 10, playing: false)
        session.update(.init(title: "Second", artist: "", album: "", artwork: nil), elapsed: 0, duration: 10, playing: false)
        _ = await LocalArtworkImages.load(url, pixels: 512)
        await Task.yield()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Second")
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
    }
    func testConcurrentArtworkConsumersSharePreparedImage() async throws {
        let url = try artworkFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let results = await withTaskGroup(of: UIImage?.self, returning: [UIImage?].self) { group in
            for _ in 0..<24 { group.addTask { await LocalArtworkImages.load(url, pixels: 512) } }
            var values: [UIImage?] = []
            for await value in group { values.append(value) }
            return values
        }
        let first = try XCTUnwrap(results.first ?? nil)
        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0 === first }, "Rows sharing a cover reuse one prepared bitmap")
        let smaller = await LocalArtworkImages.load(url, pixels: 128)
        XCTAssertTrue(smaller === first, "An adequate decoded image is reused without another decode")
    }

    func testArtworkRetainsDecodedFallbackDuringSizeUpgradeAndFailure() async throws {
        let url = try artworkFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let preparedSmall = await LocalArtworkImages.load(url, pixels: 128)
        let small = try XCTUnwrap(preparedSmall)
        XCTAssertTrue(LocalArtworkImages.cached(url, pixels: 512) === small)
        let preparedLarge = await LocalArtworkImages.load(url, pixels: 512)
        let large = try XCTUnwrap(preparedLarge)
        XCTAssertEqual(large.size, CGSize(width: 512, height: 256))
        XCTAssertTrue(LocalArtworkImages.cached(url, pixels: 1024) === large)
        try FileManager.default.removeItem(at: url)
        let unavailable = await LocalArtworkImages.load(url, pixels: 1024)
        XCTAssertNil(unavailable)
        XCTAssertTrue(LocalArtworkImages.cached(url, pixels: 1024) === large, "A failed upgrade must not blank an existing image")
    }

    func testFailedArtworkPreparationCanRetryAfterFileArrives() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        let failed = await LocalArtworkImages.load(url, pixels: 128)
        XCTAssertNil(failed)
        try XCTUnwrap(PlayerTestFixtures.artwork().pngData()).write(to: url)
        let retried = await LocalArtworkImages.load(url, pixels: 128)
        XCTAssertNotNil(retried)
    }

    func testFirstShelfPreparationIsBoundedAndUsesFolderThumbnailSize() async throws {
        let first = try artworkFile(), second = try artworkFile(), later = try artworkFile()
        defer { [first, second, later].forEach { try? FileManager.default.removeItem(at: $0) } }
        await LocalArtworkImages.prepare([
            .folder([.file(first), .file(first)]), .file(second), .file(later)
        ], pixels: 512, limit: 2)
        let small = try XCTUnwrap(LocalArtworkImages.cached(first, pixels: 192))
        XCTAssertEqual(small.size.width, 192)
        XCTAssertEqual(LocalArtworkImages.cached(second, pixels: 512)?.size.width, 512)
        XCTAssertNil(LocalArtworkImages.cached(later, pixels: 512))
    }

    func testCancelledFirstShelfPreparationDoesNotDecodeNewFiles() async throws {
        let url = try artworkFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { await LocalArtworkImages.prepare([.file(url)]) }
        task.cancel()
        await task.value
        XCTAssertNil(LocalArtworkImages.cached(url, pixels: 512))
    }

    func testPlaylistThumbnailKeepsOnlyHeaderZoomSurface() async throws {
        let appeared = expectation(description: "Artwork views appeared")
        let song = LibrarySongItem(id: "image", title: "Song", artist: "Artist", album: "Album",
                                  albumArtist: "Artist", trackNumber: 1, artwork: .favorites)
        let window = UIWindow(windowScene: try await applicationWindowScene())
        let controller = UIHostingController(rootView: VStack {
            ArtworkView(artwork: .favorites).frame(width: 96, height: 96)
            PlaylistSongArtwork(song: song).frame(width: 48, height: 48)
        }.environment(\.nativeArtworkSurfaceEnabled, true).onAppear { appeared.fulfill() })
        window.rootViewController = controller
        defer { window.isHidden = true }
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 2)
        controller.view.layoutIfNeeded()
        func surfaces(in view: UIView) -> [LibraryArtworkSurfaceView] {
            (view as? LibraryArtworkSurfaceView).map { [$0] } ?? view.subviews.flatMap { surfaces(in: $0) }
        }
        let covers = surfaces(in: controller.view)
        XCTAssertEqual(covers.count, 1, "The header remains a zoom source; track thumbnails render directly")
        XCTAssertEqual(try XCTUnwrap(covers.first).bounds.width, 96, accuracy: 0.5)
    }

    func testFullCatalogProviderIsReadOnlyWhenEditorOpens() async throws {
        let appeared = expectation(description: "Playlist appeared")
        let opened = expectation(description: "Editor requested catalog")
        let item = LibraryPlaylistItem(id: "lazy-catalog", title: "Playlist", artwork: .playlist)
        let library = PlaylistLibrary(playlists: [item])
        var reads = 0
        let catalog: @MainActor () -> [LibrarySongItem] = {
            reads += 1
            if reads == 1 { opened.fulfill() }
            return []
        }
        let window = UIWindow(windowScene: try await applicationWindowScene())
        let controller = UIHostingController(rootView:
            PlaylistDetailView(playlistID: item.id, library: library, songs: [], availableSongs: catalog)
                .playlistEditSheet(library, songs: catalog)
                .onAppear { appeared.fulfill() })
        window.rootViewController = controller
        defer { window.isHidden = true }
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 2)
        XCTAssertEqual(reads, 0, "Browsing a playlist must not observe the whole song catalog")
        library.pendingEdit = item
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertGreaterThan(reads, 0)
    }

    private func artworkFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 512), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

}
