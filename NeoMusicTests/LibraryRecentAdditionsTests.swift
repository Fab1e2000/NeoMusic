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
        let collections = albums.map { ($0, LibraryRecentAdditions.date(forAddedOrder: $0.addedOrder)) }
            + [(collection("playlist", order: 3, route: .playlist("playlist")), newer)]
        let songs: [(LibrarySongItem, Date?)] = [(song("liked", favorite: older), older)]
        let items = LibraryRecentAdditions.ordered(collections: collections, songs: songs)
        XCTAssertEqual(items.map(\.id), ["playlist", "album-7", "album-6", "album-5", "album-4", "album-3", "album-2", "album-1", "recent-song:liked"])
        XCTAssertEqual(items.first { $0.songID == "liked" }?.route, nil)
        XCTAssertEqual(items.first { $0.songID == "liked" }?.subtitle, "艺人")
        XCTAssertEqual(LibraryRecentAdditions.ordered(collections: collections, songs: songs, limit: 6), Array(items.prefix(6)))
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

@MainActor final class SongRowMenuTests: XCTestCase {
    func testSameNamedArtistsKeepIndependentMenuIdentityAndActions() throws {
        var song = LibrarySongItem(id: "netease:7:9", title: "歌", artist: "同名艺人", album: "辑", albumArtist: "同名艺人",
                                   trackNumber: 1, artwork: .missing,
                                   artistReferences: [.init(id: "catalog:artist:1", name: "同名艺人"),
                                                      .init(id: "catalog:artist:2", name: "同名艺人")])
        var opened: [LibraryRoute] = []
        let artists = try XCTUnwrap(SongMenuActions().rowMenuSections(for: song) { opened.append($0) }.last)
        XCTAssertEqual(artists.map(\.title), ["同名艺人", "同名艺人"])
        XCTAssertEqual(Set(artists.map(\.id)).count, 2)
        artists.forEach { $0.perform() }
        XCTAssertEqual(opened, [.artist("catalog:artist:1"), .artist("catalog:artist:2")])

        song.artistReferences = [.init(id: "catalog:artist:2", name: "新名称"),
                                 .init(id: "catalog:artist:1", name: "同名艺人")]
        let updated = try XCTUnwrap(SongMenuActions().rowMenuSections(for: song) { _ in }.last)
        XCTAssertEqual(updated.map(\.id), artists.reversed().map(\.id))
    }

    func testLocalSongMenuMatchesTheRowEllipsis() {
        var song = LibrarySongItem(id: "local", title: "歌", artist: "艺人", album: "专辑", albumArtist: "艺人", trackNumber: 1, artwork: .missing)
        song.isFavorite = true
        var actions = SongMenuActions()
        actions.playbackSource = { "喜爱歌曲" }
        var opened: [LibraryRoute] = []
        let items = actions.rowMenuSections(for: song) { opened.append($0) }.flatMap { $0 }
        XCTAssertEqual(items.map(\.title), ["撤销", "添加到播放列表", "插播", "随后播放", "前往专辑"])
        XCTAssertEqual(items.first { $0.title == "随后播放" }?.subtitle, "喜爱歌曲")
        XCTAssertFalse(items.contains {
            ["下载", "置顶歌曲", "取消置顶", "前往艺人", "查看完整歌词", "从资料库删除"].contains($0.title)
        })
        items.first { $0.title == "前往专辑" }?.perform()
        XCTAssertEqual(opened, [.album(song.albumID)])
    }

    func testDownloadedNeteaseSongMenuOpensOnlineAlbumAndArtists() {
        let downloads = LibraryDownloads()
        downloads.isRemovable = { $0.id == "netease/song.flac" }
        let song = LibrarySongItem(id: "netease/song.flac", title: "歌", artist: "甲", album: "辑", albumArtist: "甲",
                                   trackNumber: 1, artwork: .missing, albumDirectory: "netease",
                                   onlineAlbumID: 3, artistReferences: [.init(id: "catalog:artist:1", name: "甲")])
        downloads.update(states: [song.id: .downloaded], collections: [:])
        var actions = SongMenuActions(downloads: downloads)
        var opened: [LibraryRoute] = []
        actions.openAlbum = { item, open in open(.album(item.albumID)) }
        let items = actions.rowMenuSections(for: song) { opened.append($0) }.flatMap { $0 }
        XCTAssertEqual(items.map(\.title), ["喜爱", "添加到播放列表", "插播", "添加到队列", "移除下载", "前往专辑", "甲"])
        items.first { $0.title == "前往专辑" }?.perform()
        items.first { $0.title == "甲" }?.perform()
        XCTAssertEqual(opened, [.album("catalog:album:3"), .artist("catalog:artist:1")])
    }

    func testOnlineSongMenuAddsAlbumAndArtists() {
        let song = LibrarySongItem(id: "netease:7:9", title: "歌", artist: "甲", album: "辑", albumArtist: "甲", trackNumber: 1,
                                    artwork: .missing, onlineAlbumID: 3,
                                    artistReferences: [.init(id: "catalog:artist:1", name: "甲"), .init(id: "catalog:artist:2", name: "乙")])
        var opened: [LibraryRoute] = []
        let items = SongMenuActions().rowMenuSections(for: song) { opened.append($0) }.flatMap { $0 }
        XCTAssertEqual(items.map(\.title), ["下载", "喜爱", "添加到播放列表", "插播", "添加到队列", "前往专辑", "甲", "乙"])
        items.first { $0.title == "甲" }?.perform()
        XCTAssertEqual(opened, [.artist("catalog:artist:1")])
    }
}
