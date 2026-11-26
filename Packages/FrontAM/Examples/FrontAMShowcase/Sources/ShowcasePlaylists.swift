import Foundation
import FrontAM
import Observation

@MainActor @Observable
final class ShowcasePlaylists: FrontAMPlaylistSource {
    private(set) var playlists: [LibraryPlaylistItem]
    private(set) var folders: [PlaylistFolder] = []
    private(set) var placement: [String: String] = [:]
    private(set) var recentMove: FrontAMRecentPlaylistMove?
    var pendingDeletion: LibraryPlaylistItem?
    var pendingMove: LibraryPlaylistItem?
    var pendingEdit: LibraryPlaylistItem?
    var pendingAddition: FrontAMPendingPlaylistAddition?
    private var contents: [String: [LibrarySongItem]]

    let onlineHasMore: Set<String> = []
    let onlineTrackCounts: [String: Int] = [:]
    let onlineErrors: [String: String] = [:]
    let onlineStatus: String? = nil
    let isRefreshingOnline = false
    let loadOnlinePlaylist: (@MainActor (String) async -> Void)? = nil
    let loadMoreOnlinePlaylist: (@MainActor (String) async -> Void)? = nil
    let retryOnline: (@MainActor () async -> Void)? = nil

    init(catalog: ShowcaseCatalog) {
        playlists = [
            .init(id: "night-post", title: "夜间邮路", artwork: catalog.playlistCover.artwork,
                  description: "在虚构的城市之间穿行。", isPinned: true, addedOrder: 40),
            .init(id: "paper-light", title: "纸上的微光", artwork: catalog.albums[2].cover.artwork, addedOrder: 39)
        ]
        contents = ["night-post": catalog.songs, "paper-light": catalog.albums[2].songs]
    }

    func isAwaitingInitialOnlineDetail(for item: LibraryPlaylistItem) -> Bool { false }
    func prepareCompleteCollection(_ id: String) async -> Bool { playlist(id) != nil }
    func playlist(_ id: String) -> LibraryPlaylistItem? { playlists.first { $0.id == id } }
    func songs(in id: String) -> [LibrarySongItem] { contents[id, default: []] }

    @discardableResult
    func addSongs(_ songs: [LibrarySongItem], to id: String) -> Int {
        guard canDelete(id) else { return 0 }
        var known = Set(contents[id, default: []].map(\.id))
        let additions = songs.filter { known.insert($0.id).inserted }
        contents[id, default: []].append(contentsOf: additions)
        return additions.count
    }

    func displayArtwork(of playlist: LibraryPlaylistItem) -> Artwork {
        if case .playlist = playlist.artwork, let first = songs(in: playlist.id).first { return first.artwork }
        return playlist.artwork
    }

    func removeSong(_ songID: String, from id: String) {
        contents[id]?.removeAll { $0.id == songID }
    }

    func updateFavorite(_ favorite: Bool, songID: String) {
        for id in Array(contents.keys) {
            guard let index = contents[id]?.firstIndex(where: { $0.id == songID }) else { continue }
            contents[id]?[index].isFavorite = favorite
        }
    }

    func savePlaylist(_ id: String, title: String, description: String, showsOnProfile: Bool,
                      artwork: Artwork, songs: [LibrarySongItem]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = title
        playlists[index].description = description
        playlists[index].showsOnProfile = showsOnProfile
        playlists[index].artwork = artwork
        contents[id] = songs
    }

    func toggleFavorite(_ id: String) {
        if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].isFavorite.toggle() }
    }

    func togglePin(_ id: String) {
        if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].isPinned.toggle() }
    }

    func folder(_ id: String) -> PlaylistFolder? { folders.first { $0.id == id } }
    func folders(in parentID: String?) -> [PlaylistFolder] { folders.filter { $0.parentID == parentID } }
    func playlists(in folderID: String?) -> [LibraryPlaylistItem] { playlists.filter { placement[$0.id] == folderID } }
    func folderID(of playlistID: String) -> String? { placement[playlistID] }

    func createPlaylist(named name: String, artwork: Artwork, in folderID: String?) -> LibraryPlaylistItem? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let item = LibraryPlaylistItem(id: UUID().uuidString, title: name, artwork: artwork, addedOrder: Int(Date().timeIntervalSince1970))
        playlists.insert(item, at: 0)
        placement[item.id] = folderID
        return item
    }

    @discardableResult
    func createFolder(named name: String, in parentID: String?) -> PlaylistFolder {
        let item = PlaylistFolder(id: UUID().uuidString, name: name, parentID: parentID, addedOrder: folders.count)
        folders.append(item)
        return item
    }

    func move(playlistID: String, to folderID: String?) {
        guard playlist(playlistID) != nil, folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        placement[playlistID] = folderID
        recentMove = folderID.map(FrontAMRecentPlaylistMove.init)
    }

    func move(folderID: String, to parentID: String?) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              parentID != folderID, parentID.map({ !isDescendant($0, of: folderID) }) ?? true else { return }
        folders[index].parentID = parentID
    }

    func consumeRecentMove(_ move: FrontAMRecentPlaylistMove) -> PlaylistFolder? {
        guard recentMove == move else { return nil }
        recentMove = nil
        return folder(move.folderID)
    }

    func canDelete(_ playlistID: String) -> Bool { playlist(playlistID) != nil }
    func canCollectPreview(_ item: LibraryPlaylistItem) -> Bool { false }
    func canUnsubscribe(_ playlistID: String) -> Bool { false }

    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        placement[id] = nil
        contents[id] = nil
    }

    func deleteFolder(_ id: String) {
        guard let item = folder(id) else { return }
        for playlist in playlists(in: id) { placement[playlist.id] = item.parentID }
        for index in folders.indices where folders[index].parentID == id { folders[index].parentID = item.parentID }
        folders.removeAll { $0.id == id }
    }

    func renameFolder(_ id: String, to name: String) {
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].name = name }
    }

    func isDescendant(_ id: String, of ancestorID: String) -> Bool {
        var parent = folder(id)?.parentID
        while let current = parent {
            if current == ancestorID { return true }
            parent = folder(current)?.parentID
        }
        return false
    }
}
