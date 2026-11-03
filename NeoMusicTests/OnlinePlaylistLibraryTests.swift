import XCTest
@testable import NeoMusic

@MainActor final class OnlinePlaylistLibraryTests: XCTestCase {
    func testOnlineMirrorIsReadOnlyAndLocalReferencesSurviveScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LibraryPlaylistItem(id: "local", title: "Local", artwork: .playlist)
        let library = PlaylistLibrary(playlists: [local])
        let url = root.appendingPathComponent("playlists.json")
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        let online = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "Online", artwork: .playlist, sourceOwnerID: "1")
        let song = LibrarySongItem(id: "netease:1:3", title: "Song", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        library.replaceOnlinePlaylists(items: [online], songs: [online.id: [song]], ownerID: "1")
        XCTAssertFalse(library.canDelete(online.id))
        XCTAssertEqual(library.addSongs([song], to: online.id), 0)
        XCTAssertEqual(library.addSongs([song], to: local.id), 1)
        library.reconcileSongs([])
        XCTAssertEqual(library.songs(in: local.id).map(\.id), [song.id])
        let saved = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.playlists.map(\.id), ["local"])
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        XCTAssertNil(library.playlist(online.id))
        XCTAssertEqual(library.songs(in: local.id).map(\.id), [song.id])
    }

    func testPreferenceRestoreAndOnlineRefreshPreserveLocalEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "Online", artwork: .playlist, sourceOwnerID: "1")
        let first = PlaylistLibrary(playlists: [])
        XCTAssertTrue(first.configurePersistence(url: url, songs: []))
        first.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        first.togglePin(item.id)
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        restored.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        XCTAssertEqual(restored.playlist(item.id)?.isPinned, true)
        restored.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        XCTAssertEqual(restored.playlist(item.id)?.isPinned, true)
        let local = try XCTUnwrap(restored.createPlaylist(named: "Local", artwork: .playlist, in: nil))
        let song = LibrarySongItem(id: "file.mp3", title: "Local", artist: "", album: "", albumArtist: "", trackNumber: 1, artwork: .missing)
        restored.addSongs([song], to: local.id)
        restored.reconcileOnlineSongs([])
        XCTAssertEqual(restored.songs(in: local.id).map(\.id), [song.id])
    }

    func testOnlineDiscoveryAndPlayDatesSurviveRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: root.appendingPathComponent("playlists.json"), songs: []))
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "Online", artwork: .playlist, sourceOwnerID: "1")
        library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        let firstSeen = try XCTUnwrap(library.playlist(item.id)?.addedAt)
        library.markPlayed(item.id)
        let played = try XCTUnwrap(library.playlist(item.id)?.lastPlayedAt)
        library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        XCTAssertEqual(library.playlist(item.id)?.addedAt, firstSeen)
        XCTAssertEqual(library.playlist(item.id)?.lastPlayedAt, played)
        library.updateOnlineSongs(playlistID: item.id, songs: [], error: nil, loading: true)
        XCTAssertFalse(library.loadedOnlinePlaylistIDs.contains(item.id))
        library.updateOnlineSongs(playlistID: item.id, songs: [], error: nil, loading: false)
        XCTAssertTrue(library.loadedOnlinePlaylistIDs.contains(item.id))
        library.updateOnlineSongs(playlistID: item.id, songs: [], error: "Failed", loading: false)
        XCTAssertFalse(library.loadedOnlinePlaylistIDs.contains(item.id))
    }

    func testOnlineFolderDeletionAndAccountPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: root.appendingPathComponent("playlists.json"), songs: []))
        let online = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "Online", artwork: .playlist, sourceOwnerID: "1")
        library.replaceOnlinePlaylists(items: [online], songs: [:], ownerID: "1")
        library.togglePin(online.id)
        let folder = library.createFolder(named: "Folder", in: nil)
        library.move(playlistID: online.id, to: folder.id)
        library.deleteFolder(folder.id)
        XCTAssertNotNil(library.playlist(online.id))
        XCTAssertNil(library.folderID(of: online.id))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        library.replaceOnlinePlaylists(items: [online], songs: [:], ownerID: "1")
        XCTAssertEqual(library.playlist(online.id)?.isPinned, true)
        XCTAssertNil(library.folderID(of: online.id))
    }
}
