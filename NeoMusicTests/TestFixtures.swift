import AVFoundation
import UIKit
import XCTest
@testable import NeoMusic
@testable import FullScreenPlayer

/// Test inputs use the same model and adapters as the app, with no demo runtime.
@MainActor enum PlayerTestFixtures {
    /// A fresh file per caller keeps playback and persistence tests isolated.
    @discardableResult nonisolated static func silentAudio(
        at url: URL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav"),
        seconds: Int = 1
    ) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * seconds)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func owner(tracks: [PlayerTrack]) -> NowPlayingModel {
        NowPlayingModel(queue: tracks.map {
            LibrarySongItem(id: $0.id, title: $0.title, artist: $0.artists, album: $0.albumTitle,
                albumArtist: $0.artists, trackNumber: 1, artwork: .missing, duration: Int($0.duration))
        }, currentIndex: 0, isPlaying: false, elapsed: 0)
    }

    static func state(tracks: [PlayerTrack]) -> PlayerState {
        PlayerState(model: owner(tracks: tracks))
    }

    static func actions() -> PlayerActions {
        PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in })
    }

    static func library() -> ReferenceLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ReferenceLibrary(reader: ReferenceLyricsReader(storageDirectory: root.appendingPathComponent("lyrics"),
            root: root, resolveAudioURL: { _ in nil }))
    }

    static func artwork() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 120))
        }
    }
}

actor SessionActivation {
    enum RequestError: Error { case missingRequest }
    private var requests: [CheckedContinuation<Bool, Error>?] = []
    var count: Int { requests.count }

    func activate(started: @Sendable () -> Void = {}) async throws -> Bool {
        try await withCheckedThrowingContinuation {
            requests.append($0)
            started()
        }
    }

    func complete(_ index: Int = 0, with result: Result<Bool, Error> = .success(true)) throws {
        guard requests.indices.contains(index), let request = requests[index] else { throw RequestError.missingRequest }
        request.resume(with: result)
        requests[index] = nil
    }
}

@MainActor extension XCTestCase {
    /// Hosted tests can begin before UIKit connects the application's first scene.
    func applicationWindowScene() async throws -> UIWindowScene {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return scene
        }
        let activation = expectation(forNotification: UIScene.didActivateNotification, object: nil)
        await fulfillment(of: [activation], timeout: 10)
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }
}
