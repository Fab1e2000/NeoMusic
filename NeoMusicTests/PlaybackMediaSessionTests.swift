import MediaPlayer
import UIKit
import XCTest
@testable import NeoMusic

@MainActor final class PlaybackMediaSessionTests: XCTestCase {
    func testSystemMetadataFollowsPlayingAndPausedTrack() throws {
        let session = PlaybackMediaSession(play: {}, pause: {}, next: {}, previous: {}, seek: { _ in })
        defer { session.shutdown() }
        session.update(.init(title: "First", artist: "Artist", album: "Album", artwork: nil), elapsed: 12, duration: 60, playing: true)
        let playing = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(playing[MPMediaItemPropertyTitle] as? String, "First")
        XCTAssertEqual(playing[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(playing[MPMediaItemPropertyAlbumTitle] as? String, "Album")
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(playing[MPMediaItemPropertyPlaybackDuration] as? Double, 60)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        session.update(.init(title: "Second", artist: "Other", album: "Next", artwork: nil), elapsed: 3, duration: 90, playing: false)
        let paused = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(paused[MPMediaItemPropertyTitle] as? String, "Second")
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 3)
        XCTAssertEqual(paused[MPMediaItemPropertyPlaybackDuration] as? Double, 90)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        session.shutdown()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testBackgroundArtworkRequestAndTrackWithoutCover() async throws {
        let session = PlaybackMediaSession(play: {}, pause: {}, next: {}, previous: {}, seek: { _ in })
        defer { session.shutdown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        session.update(.init(title: "Covered", artist: "Artist", album: "Album", artwork: try XCTUnwrap(image.pngData())), elapsed: 0, duration: 20, playing: true)
        let artwork = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        let request = MediaSessionArtworkRequest(artwork: artwork)
        let size = await Task.detached { request.artwork.image(at: CGSize(width: 16, height: 16))?.size }.value
        XCTAssertEqual(size, CGSize(width: 16, height: 16))
        session.update(.init(title: "No Cover", artist: "Artist", album: "Album", artwork: nil), elapsed: 0, duration: 30, playing: true)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "No Cover")
    }
}

// Immutable provider is intentionally requested off-main, like MediaPlayer's artwork access queue.
private struct MediaSessionArtworkRequest: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
}
