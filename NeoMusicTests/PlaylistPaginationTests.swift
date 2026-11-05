import XCTest
@testable import NeoMusic

@MainActor final class PlaylistPaginationTests: XCTestCase {
    func testPreparingCollectionCompletesOnceAndReusesLoadedSongs() async {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "List", artwork: .playlist, sourceOwnerID: "1")
        library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        library.setOnlineHasMore(item.id, true, totalCount: 250)
        var requests = 0
        library.completeOnlinePlaylist = { id in
            requests += 1
            library.setOnlineHasMore(id, false, totalCount: 250)
            return true
        }
        let first = await library.prepareCompleteCollection(item.id)
        let second = await library.prepareCompleteCollection(item.id)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(library.onlineTrackCounts[item.id], 250)
    }

    func testPartialCollectionDoesNotReportSuccessAfterFailedCompletion() async {
        let library = PlaylistLibrary(playlists: [])
        library.setOnlineHasMore("favorites", true)
        library.completeOnlinePlaylist = { _ in false }
        let completed = await library.prepareCompleteCollection("favorites")
        XCTAssertFalse(completed)
        XCTAssertTrue(library.onlineHasMore.contains("favorites"))
    }

    func testAccountSwitchDuringCompletionRejectsOldCollection() async {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "List", artwork: .playlist, sourceOwnerID: "1")
        library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "1")
        library.setOnlineHasMore(item.id, true)
        library.completeOnlinePlaylist = { _ in
            library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "2")
            return true
        }
        let completed = await library.prepareCompleteCollection(item.id)
        XCTAssertFalse(completed)
        XCTAssertTrue(library.onlineHasMore.isEmpty)
    }
}
