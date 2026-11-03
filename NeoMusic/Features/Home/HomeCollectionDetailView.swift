import SwiftUI

/// Explicit actions keep browsed collections separate from the user's library.
struct ExternalPlaylistActions {
    var toggleFavorite: (() -> Void)? = nil
    var togglePin: (() -> Void)? = nil
    var addSongs: () -> Void
    var moveToFolder: (() -> Void)? = nil
}

struct HomeCollectionDetailView: View {
    let playlistID: String
    let library: PlaylistLibrary
    let actions: ExternalPlaylistActions
    var artwork: AnyView? = nil
    var onAppear: () -> Void = {}
    var onDisappear: () -> Void = {}

    var body: some View {
        PlaylistDetailView(playlistID: playlistID, library: library, songs: [], externalActions: actions, externalArtwork: artwork)
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
    }
}
