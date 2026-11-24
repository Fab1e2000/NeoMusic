import Foundation
import Observation

@MainActor @Observable
final class PlaylistLibraryPresentation {
    var recentMove: PlaylistLibrary.RecentMove?
    var pendingDeletion: LibraryPlaylistItem?
    var pendingMove: LibraryPlaylistItem?
    var pendingEdit: LibraryPlaylistItem?
    var pendingAddition: PlaylistLibrary.PendingAddition?
}

extension PlaylistLibrary {
    struct PendingAddition: Identifiable {
        let songs: [LibrarySongItem]
        let id = UUID()
    }

    struct RecentMove: Equatable {
        let folderID: String
        let id = UUID()
    }
}
