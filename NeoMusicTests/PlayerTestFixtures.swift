import UIKit
@testable import NeoMusic

/// Test inputs use the same model and adapters as the app, with no demo runtime.
@MainActor enum PlayerTestFixtures {
    static func owner(tracks: [ReferenceTrack]) -> NowPlayingModel {
        NowPlayingModel(queue: tracks.map {
            LibrarySongItem(id: $0.id, title: $0.title, artist: $0.artists, album: $0.albumTitle,
                albumArtist: $0.artists, trackNumber: 1, artwork: .missing, duration: Int($0.duration))
        }, currentIndex: 0, isPlaying: false, elapsed: 0)
    }

    static func state(tracks: [ReferenceTrack]) -> ReferencePlayerState {
        ReferencePlayerState(model: owner(tracks: tracks))
    }

    static func actions() -> ReferencePlayerActions {
        ReferencePlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
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
