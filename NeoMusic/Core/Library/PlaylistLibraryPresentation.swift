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
    typealias PendingAddition = FrontAMPendingPlaylistAddition
    typealias RecentMove = FrontAMRecentPlaylistMove
}
