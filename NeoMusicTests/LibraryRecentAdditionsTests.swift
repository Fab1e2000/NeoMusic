import XCTest
@testable import NeoMusic

final class LibraryRecentAdditionsTests: XCTestCase {
    private func song(_ id: String, favorite: Date? = nil, liked: Bool = false) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1,
                        artwork: .missing, isFavorite: liked || favorite != nil, favoriteAddedAt: favorite)
    }

    private func collection(_ id: String, order: Int, route: LibraryRoute) -> LibraryShelfItem {
        LibraryShelfItem(id: id, title: id, artwork: .missing, route: route, addedOrder: order)
    }

    func testNewestDatedItemLeadsAndEveryCollectionRemains() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let albums = (1...7).map { collection("album-\($0)", order: 1_700_000_000 + $0, route: .album("album-\($0)")) }
        let items = LibraryRecentAdditions.ordered(
            collections: albums.map { ($0, LibraryRecentAdditions.date(forAddedOrder: $0.addedOrder)) } + [(collection("playlist", order: 3, route: .playlist("playlist")), newer)],
            songs: [(song("liked", favorite: older), older)]
        )
        XCTAssertEqual(items.map(\.id), ["playlist", "album-7", "album-6", "album-5", "album-4", "album-3", "album-2", "album-1", "recent-song:liked"])
        XCTAssertEqual(items.first { $0.songID == "liked" }?.route, nil)
        XCTAssertEqual(items.first { $0.songID == "liked" }?.subtitle, "艺人")
    }

    func testLikedSongAddedToPlaylistAppearsOnceAtTheLaterTime() {
        let liked = Date(timeIntervalSince1970: 1_700_000_000)
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        let items = LibraryRecentAdditions.ordered(
            collections: [],
            songs: [(song("same", favorite: liked), liked), (song("same"), added)]
        )
        XCTAssertEqual(items.map(\.id), ["recent-song:same"])
        XCTAssertEqual(items[0].addedOrder, Int(added.timeIntervalSince1970))
        XCTAssertTrue(items[0].isFavorite)
        XCTAssertNil(items[0].route)
    }

    func testUndatedAlbumStaysBehindADatedAddition() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = LibraryRecentAdditions.ordered(
            collections: [
                (collection("old-album", order: 0, route: .album("old-album")), nil),
                (collection("new-album", order: Int(now.timeIntervalSince1970), route: .album("new-album")), now)
            ],
            songs: []
        )
        XCTAssertEqual(items.map(\.id), ["new-album", "old-album"])
    }
}

final class AlbumLibraryAdditionsTests: XCTestCase {
    func testExistingAlbumsStayUntimedUntilALaterAlbumAppears() {
        var record = AlbumLibraryAdditions()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        record.observe(previous: [], current: [1, 2], now: first)
        XCTAssertTrue(record.baselineRecorded)
        XCTAssertNil(record.date(1))
        XCTAssertNil(record.date(2))
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        record.stamp(3, at: later)
        record.observe(previous: [1, 2], current: [1, 2, 3], now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(record.date(3), later)
        XCTAssertNil(record.date(1))
        record.observe(previous: [1, 2, 3], current: [1, 2], now: later)
        XCTAssertNil(record.date(3))
    }

    func testFirstSyncDoesNotTreatTheWholeListAsNewWhenOneAlbumWasJustAdded() {
        var record = AlbumLibraryAdditions()
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        record.stamp(9, at: added)
        record.observe(previous: [], current: [1, 9], now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(record.date(9), added)
        XCTAssertNil(record.date(1))
    }
}
