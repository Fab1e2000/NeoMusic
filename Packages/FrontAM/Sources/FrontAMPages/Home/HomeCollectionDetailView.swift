import FrontAMCore
import SwiftUI

public struct ExternalPlaylistActions {
    public var toggleFavorite: (() -> Void)? = nil
    public var togglePin: (() -> Void)? = nil
    public var addSongs: () -> Void
    public var moveToFolder: (() -> Void)? = nil
    public var collect: (() -> Void)? = nil

    public init(toggleFavorite: (() -> Void)? = nil,
                togglePin: (() -> Void)? = nil,
                addSongs: @escaping () -> Void,
                moveToFolder: (() -> Void)? = nil,
                collect: (() -> Void)? = nil) {
        self.toggleFavorite = toggleFavorite
        self.togglePin = togglePin
        self.addSongs = addSongs
        self.moveToFolder = moveToFolder
        self.collect = collect
    }
}

public struct HomeCollectionDetailView: View {
    public let playlistID: String
    public let library: any FrontAMPlaylistSource
    public let actions: ExternalPlaylistActions
    public var artwork: AnyView? = nil
    public var onAppear: () -> Void = {}
    public var onDisappear: () -> Void = {}

    public var body: some View {
        PlaylistDetailView(playlistID: playlistID, library: library, songs: [], externalActions: actions, externalArtwork: artwork)
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
    }

    public init(playlistID: String,
                library: any FrontAMPlaylistSource,
                actions: ExternalPlaylistActions,
                artwork: AnyView? = nil,
                onAppear: @escaping () -> Void = {},
                onDisappear: @escaping () -> Void = {}) {
        self.playlistID = playlistID
        self.library = library
        self.actions = actions
        self.artwork = artwork
        self.onAppear = onAppear
        self.onDisappear = onDisappear
    }
}
