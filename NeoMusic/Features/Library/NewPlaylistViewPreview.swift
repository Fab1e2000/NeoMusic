import SwiftUI
import FrontAMPages

#if DEBUG
#Preview("新建播放列表") {
    NewPlaylistView(library: PlaylistLibrary(playlists: []))
}
#endif
