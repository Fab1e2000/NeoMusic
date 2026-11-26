#if DEBUG
import SwiftUI
import FrontAMPlayer
private struct NowPlayingControlsFeedbackPreview: View {
    @State private var player: PlayerState
    private let song: PlayerTrack
    private let actions: PlayerActions

    init() {
        let item = LibrarySongItem(
            id: "controls-preview",
            title: "STYX HELIX",
            artist: "MYTH & ROID",
            album: "STYX HELIX",
            albumArtist: "MYTH & ROID",
            trackNumber: 1,
            artwork: .missing,
            duration: 290
        )
        let model = NowPlayingModel(queue: [item], currentIndex: 0, isPlaying: true, elapsed: 48)
        _player = State(initialValue: PlayerState(model: model))
        self.song = PlayerTrack(
            id: "controls-preview",
            title: "STYX HELIX",
            artists: "MYTH & ROID",
            albumTitle: "STYX HELIX",
            coverURL: nil,
            duration: 290
        )
        self.actions = PlayerActions(
            isFavorite: { _ in false },
            toggleFavorite: { _ in },
            addToPlaylist: { _ in },
            openAlbum: { _ in },
            openArtist: { _ in },
            audioQuality: { _ in PlayerAudioQuality(title: "无损") }
        )
    }

    var body: some View { PlayerControlsPreview(player: player, song: song, actions: actions) }
}
#Preview("进度条与音量条") { NowPlayingControlsFeedbackPreview() }
#endif
