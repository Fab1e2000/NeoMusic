import XCTest
import AVFoundation
import MediaPlayer
import UIKit
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
    }

    func testMissingFileFailsFirstPlayWithoutCreatingTransportOrLosingQueue() throws {
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
    }

    func testPlaylistEditsPreserveUnresolvedReferencesAndUnchangedRefreshDoesNotWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let songs = ["a", "b"].map { LibrarySongItem(id: $0, title: $0, artist: "", album: "", albumArtist: "", trackNumber: 1, artwork: .missing) }
        let original = PlaylistLibrary(playlists: [])
        original.configurePersistence(url: url, songs: songs)
        let playlist = try XCTUnwrap(original.createPlaylist(named: "Saved", artwork: .playlist, in: nil))
        original.addSongs(songs, to: playlist.id)
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        restored.renamePlaylist(playlist.id, to: "Renamed")
        let reopened = PlaylistLibrary(playlists: [])
        reopened.configurePersistence(url: url, songs: songs)
        XCTAssertEqual(reopened.songs(in: playlist.id).map(\.id), ["a", "b"])
        XCTAssertEqual(reopened.playlist(playlist.id)?.title, "Renamed")
        let timestamp = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        restored.reconcileSongs(songs)
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
        source.addSongs([.unavailable("broken.mp3")], to: playlist.id)
        let original = try Data(contentsOf: playlistURL)
        let restored = PlaylistLibrary(playlists: [])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback() }
        let runtime = LocalLibraryRuntime(documents: directory, store: store, playlistLibrary: restored, player: player)
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
}
