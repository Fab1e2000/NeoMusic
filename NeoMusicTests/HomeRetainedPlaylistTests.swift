import XCTest
@testable import NeoMusic

@MainActor final class HomeRetainedPlaylistTests: XCTestCase {
    func testExplicitRetentionRestoresOnlyForOwnerAndDeduplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "1")
        let item = LibraryPlaylistItem(id: "netease-playlist:1:42", title: "Recommended", artwork: .playlist, sourceOwnerID: "1", subtitle: "Author")
        XCTAssertTrue(library.playlists.isEmpty)
        library.retainOnlinePlaylist(item, songs: [])
        library.togglePin(item.id)
        library.replaceOnlinePlaylists(items: [item, item], songs: [:], ownerID: "1")
        XCTAssertEqual(library.playlists.count, 1)
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        XCTAssertTrue(library.playlists.isEmpty)
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "2")
        XCTAssertTrue(library.playlists.isEmpty)
        library.retainOnlinePlaylist(item, songs: [])
        XCTAssertTrue(library.playlists.isEmpty)
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "1")
        XCTAssertEqual(library.playlists.map(\.id), [item.id])
        XCTAssertTrue(try XCTUnwrap(library.playlists.first).isPinned)
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        restored.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "1")
        XCTAssertEqual(restored.playlists.map(\.id), [item.id])
    }

    func testExternalDetailsStayInTheirMemoryLibrary() {
        let details = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "home:playlist:42", title: "Detail", artwork: .playlist, isReadOnlyContent: true)
        details.setExternalCollection(item: item, songs: [], error: "Retry")
        XCTAssertEqual(details.onlineErrors[item.id], "Retry")
        details.setExternalCollection(item: item, songs: [])
        XCTAssertNil(details.onlineErrors[item.id])
        XCTAssertEqual(details.playlists.count, 1)
    }
}
