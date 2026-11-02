import MediaPlayer
import UIKit

/// Opt-in system integration: create only for the application's active playback owner.
@MainActor final class PlaybackMediaSession {
    struct Metadata {
        var title: String
        var artist: String
        var album: String
        var artwork: Data?
    }
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkData: Data?
    private var artwork: MPMediaItemArtwork?

    init(play: @escaping @MainActor () -> Void, pause: @escaping @MainActor () -> Void,
         next: @escaping @MainActor () -> Void, previous: @escaping @MainActor () -> Void,
         seek: @escaping @MainActor (Double) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, play), (center.pauseCommand, pause),
                                  (center.nextTrackCommand, next), (center.previousTrackCommand, previous)] {
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            targets.append((command, target))
        }
        let target = center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in seek(position) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
    }

    func update(_ metadata: Metadata, elapsed: Double, duration: Double, playing: Bool) {
        if artworkData != metadata.artwork {
            artworkData = metadata.artwork
            artwork = metadata.artwork.flatMap(UIImage.init(data:)).map { image in
                MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            }
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: metadata.artist, MPMediaItemPropertyAlbumTitle: metadata.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPMediaItemPropertyPlaybackDuration: duration.isFinite ? duration : 0,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    func shutdown() {
        targets.forEach { $0.0.removeTarget($0.1) }; targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artwork = nil; artworkData = nil
    }
}
