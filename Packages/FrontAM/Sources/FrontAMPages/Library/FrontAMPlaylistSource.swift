import FrontAMCore
import Foundation

public struct PlaylistFolder: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var parentID: String?
    public var addedOrder = 0

    public init(id: String,
                name: String,
                parentID: String? = nil,
                addedOrder: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.addedOrder = addedOrder
    }
}


public struct FrontAMPendingPlaylistAddition: Identifiable {
    public let songs: [LibrarySongItem]
    public let id = UUID()

    public init(songs: [LibrarySongItem]) {
        self.songs = songs
    }
}

public struct FrontAMRecentPlaylistMove: Equatable {
    public let folderID: String
    public let id = UUID()

    public init(folderID: String) {
        self.folderID = folderID
    }
}

@MainActor public protocol FrontAMPlaylistSource: AnyObject {
    var playlists: [LibraryPlaylistItem] { get }
    var folders: [PlaylistFolder] { get }
    var placement: [String: String] { get }
    var recentMove: FrontAMRecentPlaylistMove? { get }
    var pendingDeletion: LibraryPlaylistItem? { get set }
    var pendingMove: LibraryPlaylistItem? { get set }
    var pendingEdit: LibraryPlaylistItem? { get set }
    var pendingAddition: FrontAMPendingPlaylistAddition? { get set }
    var onlineHasMore: Set<String> { get }
    var onlineTrackCounts: [String: Int] { get }
    var onlineErrors: [String: String] { get }
    var onlineStatus: String? { get }
    var isRefreshingOnline: Bool { get }
    var loadOnlinePlaylist: (@MainActor (String) async -> Void)? { get }
    var loadMoreOnlinePlaylist: (@MainActor (String) async -> Void)? { get }
    var retryOnline: (@MainActor () async -> Void)? { get }
    func isAwaitingInitialOnlineDetail(for item: LibraryPlaylistItem) -> Bool
    func prepareCompleteCollection(_ id: String) async -> Bool
    func playlist(_ id: String) -> LibraryPlaylistItem?
    func songs(in id: String) -> [LibrarySongItem]
    @discardableResult func addSongs(_ songs: [LibrarySongItem], to id: String) -> Int
    func displayArtwork(of playlist: LibraryPlaylistItem) -> Artwork
    func removeSong(_ songID: String, from id: String)
    func savePlaylist(_ id: String, title: String, description: String, showsOnProfile: Bool, artwork: Artwork, songs: [LibrarySongItem])
    func toggleFavorite(_ id: String)
    func togglePin(_ id: String)
    func folder(_ id: String) -> PlaylistFolder?
    func folders(in parentID: String?) -> [PlaylistFolder]
    func playlists(in folderID: String?) -> [LibraryPlaylistItem]
    func folderID(of playlistID: String) -> String?
    func createPlaylist(named name: String, artwork: Artwork, in folderID: String?) -> LibraryPlaylistItem?
    @discardableResult func createFolder(named name: String, in parentID: String?) -> PlaylistFolder
    func move(playlistID: String, to folderID: String?)
    func move(folderID: String, to parentID: String?)
    func consumeRecentMove(_ move: FrontAMRecentPlaylistMove) -> PlaylistFolder?
    func canDelete(_ playlistID: String) -> Bool
    func canCollectPreview(_ item: LibraryPlaylistItem) -> Bool
    func canUnsubscribe(_ playlistID: String) -> Bool
    func deletePlaylist(_ id: String)
    func deleteFolder(_ id: String)
    func renameFolder(_ id: String, to name: String)
    func isDescendant(_ id: String, of ancestorID: String) -> Bool
}
