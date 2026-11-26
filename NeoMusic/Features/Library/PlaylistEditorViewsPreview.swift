import SwiftUI
import FrontAMPages

#if DEBUG
#Preview("封面照片读取进度") {
    let selection = PlaylistCoverSelection()
    selection.isLoading = true
    let library = PlaylistLibrary(playlists: [LibraryPlaylistItem(id: "preview:playlist", title: "2", artwork: .playlist)])
    return PlaylistEditor(playlistID: "preview:playlist", library: library, availableSongs: [], coverSelection: selection)
}
#endif
