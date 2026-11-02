import XCTest
@testable import NeoMusic

@MainActor
final class PlaylistLibraryTests: XCTestCase {
    private func library() -> PlaylistLibrary {
        PlaylistLibrary(playlists: [
            LibraryPlaylistItem(id: "one", title: "one", artwork: .playlist),
            LibraryPlaylistItem(id: "two", title: "two", artwork: .playlist),
            LibraryPlaylistItem(id: "favorites", title: "喜爱歌曲", artwork: .favorites, isSystem: true),
        ])
    }

    private func song(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: "艺人", album: "专辑", albumArtist: "艺人",
                        trackNumber: 1, artwork: .missing)
    }

    func testCancelFavoriteKeepsSongInLibraryAndCanBeRestored() {
        var favorite = song("a")
        favorite.isFavorite = true
        let library = SongLibrary(songs: [favorite, song("b")])
        library.setFavorite("a", false)
        library.setFavorite("a", false)
        library.setFavorite("missing", false)
        XCTAssertEqual(library.songs.map(\.id), ["a", "b"])
        XCTAssertTrue(library.songs.filter(\.isFavorite).isEmpty)
        library.toggleFavorite("a")
        XCTAssertEqual(library.songs.filter(\.isFavorite).map(\.id), ["a"])
    }

    func testSavePlaylistCommitsDraftAndRejectsEmptyOrSystemTarget() {
        let library = library()
        library.addSongs([song("a")], to: "one")
        library.savePlaylist("one", title: " changed ", description: "说明", showsOnProfile: false,
                             artwork: .playlist, songs: [song("b"), song("b")])
        XCTAssertEqual(library.playlist("one")?.title, "changed")
        XCTAssertEqual(library.playlist("one")?.description, "说明")
        XCTAssertEqual(library.playlist("one")?.showsOnProfile, false)
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b"])
        library.savePlaylist("one", title: " ", description: "wrong", showsOnProfile: true,
                             artwork: .playlist, songs: [])
        library.savePlaylist("favorites", title: "wrong", description: "", showsOnProfile: true,
                             artwork: .playlist, songs: [])
        XCTAssertEqual(library.playlist("one")?.description, "说明")
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b"])
        XCTAssertEqual(library.playlist("favorites")?.title, "喜爱歌曲")
    }

    func testAddDeduplicatesAndPreservesOrderWithoutChangingOtherPlaylist() {
        let library = library()
        library.addSongs([song("a")], to: "two")
        library.addSongs([song("b"), song("a"), song("b")], to: "one")
        library.addSongs([song("a"), song("c")], to: "one")
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b", "a", "c"])
        XCTAssertEqual(library.songs(in: "two").map(\.id), ["a"])
    }

    func testRemovingSongOnlyChangesItsPlaylist() {
        let library = library()
        for id in ["one", "two"] { library.addSongs([song("a"), song("b")], to: id) }
        library.removeSong("a", from: "one")
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b"])
        XCTAssertEqual(library.songs(in: "two").map(\.id), ["a", "b"])
    }

    func testInvalidTargetsAndSystemPlaylistCannotBeEdited() {
        let library = library()
        for id in ["missing", "favorites"] {
            library.addSongs([song("a")], to: id)
            library.renamePlaylist(id, to: "changed")
            library.deletePlaylist(id)
            XCTAssertTrue(library.songs(in: id).isEmpty)
        }
        XCTAssertEqual(library.playlist("favorites")?.title, "喜爱歌曲")
        library.renamePlaylist("one", to: " \n ")
        XCTAssertEqual(library.playlist("one")?.title, "one")
        library.renamePlaylist("one", to: " renamed ")
        XCTAssertEqual(library.playlist("one")?.title, "renamed")
    }

    func testReorderAndInvalidOffsets() {
        let library = library()
        library.addSongs([song("a"), song("b"), song("c")], to: "one")
        library.reorderSongs(in: "one", fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b", "c", "a"])
        library.reorderSongs(in: "one", fromOffsets: IndexSet(integer: 8), toOffset: 0)
        library.reorderSongs(in: "one", fromOffsets: IndexSet(integer: 0), toOffset: 9)
        XCTAssertEqual(library.songs(in: "one").map(\.id), ["b", "c", "a"])
    }

    func testDeleteFolderCleansOnlyContainedPlaylistRecords() {
        let library = library()
        let folder = library.createFolder(named: "folder", in: nil)
        let child = library.createFolder(named: "child", in: folder.id)
        library.move(playlistID: "one", to: child.id)
        for id in ["one", "two"] { library.addSongs([song("a")], to: id) }
        library.deleteFolder(folder.id)
        XCTAssertNil(library.playlist("one"))
        XCTAssertTrue(library.songs(in: "one").isEmpty)
        XCTAssertEqual(library.songs(in: "two").map(\.id), ["a"])
        XCTAssertTrue(library.folders.isEmpty)
    }
}

@MainActor
final class AlbumMenuTests: XCTestCase {
    func testToolbarDownloadAndDeletionUseCurrentStateAndCallbacks() {
        let route = LibraryRoute.album("album")
        let item = LibraryShelfItem(id: "album", title: "album", artwork: .playlist, route: route)
        var downloaded = false
        var requestedDeletion = false
        var actions = CollectionMenuActions()
        actions.canDelete = { $0 == route }
        actions.isDownloaded = { _ in downloaded }
        actions.download = { _ in downloaded = true }
        actions.requestDelete = { _ in requestedDeletion = true }
        let initial = actions.toolbarSections(for: item, route: route)
        XCTAssertEqual(initial.first?.map(\.title), ["下载", "喜爱"])
        initial.flatMap { $0 }.first { $0.title == "下载" }?.perform()
        XCTAssertTrue(downloaded)
        let completed = actions.toolbarSections(for: item, route: route)
        XCTAssertEqual(completed.first?.map(\.title), ["喜爱"])
        XCTAssertTrue(completed.flatMap { $0 }.contains { $0.title == "移除下载" })
        completed.flatMap { $0 }.first { $0.title == "从资料库删除" }?.perform()
        XCTAssertTrue(requestedDeletion)
    }
}

@MainActor
final class QueueMenuTests: XCTestCase {
    func testQueueMenusShareCurrentSourceNamesAndPreserveActionsAndNotifications() throws {
        let song = LibrarySongItem(id: "song", title: "song", artist: "艺人", album: "专辑",
                                   albumArtist: "艺人", trackNumber: 1, artwork: .missing)
        var source: String?
        var events: [String] = []
        let notify: (LibraryToast) -> Void = { events.append($0.title) }
        var songActions = SongMenuActions()
        songActions.playbackSource = { source }
        songActions.playNext = { XCTAssertEqual($0.id, song.id); events.append("next") }
        songActions.playLater = { XCTAssertEqual($0.id, song.id); events.append("later") }

        func check(_ sections: LibraryMenuSections, notifies: Bool) throws {
            let items = try XCTUnwrap(sections.first { $0.contains { $0.title == "插播" } })
            XCTAssertEqual(items.map(\.title), ["插播", source == nil ? "添加到队列" : "随后播放"])
            XCTAssertEqual(items.map(\.subtitle), [nil, source])
            XCTAssertEqual(items.map(\.systemImage), ["text.line.first.and.arrowtriangle.forward",
                                                       "text.line.last.and.arrowtriangle.forward"])
            XCTAssertTrue(items.allSatisfy { !$0.isDisabled })
            events.removeAll()
            for item in items { item.perform() }
            XCTAssertEqual(events, notifies ? ["next", "下个播放", "later", "已添加到队列"] : ["next", "later"])
        }

        // Rebuild after source changes, including returning to a paused/no-source state.
        let sources: [String?] = [nil, "喜爱歌曲", nil]
        for currentSource in sources {
            source = currentSource
            for route in [LibraryRoute.album("album"), .playlist("playlist")] {
                let item = LibraryShelfItem(id: "item", title: "item", artwork: .missing, route: route)
                var actions = CollectionMenuActions()
                actions.playbackSource = { source }
                actions.playNext = { XCTAssertEqual($0, route); events.append("next") }
                actions.playLater = { XCTAssertEqual($0, route); events.append("later") }
                actions.notify = notify
                try check(actions.sections(for: item, route: route), notifies: true)
                try check(actions.toolbarSections(for: item, route: route), notifies: true)
                try check(actions.pinnedSections(for: item, route: route, tapAction: .open,
                                                setTapAction: { _ in }), notifies: true)
            }
            for downloaded in [false, true] {
                try check(songActions.albumTrackSections(for: song, isDownloaded: downloaded,
                    download: {}, removeDownload: {}, requestDelete: {}, notify: notify), notifies: true)
            }
            // Ordinary song menus previously exposed only play-next; both actions must reach the same song.
            try check(songActions.sections(for: song, goToAlbum: {}), notifies: false)
        }
    }

    func testDisabledQueueMenuKeepsBothItemsWithoutPerformingActionsOrNotifying() {
        var calls = 0
        let items = libraryQueueMenuItems(playbackSource: "喜爱歌曲", isDisabled: true,
                                         playNext: { calls += 1 }, playLater: { calls += 1 },
                                         notify: { _ in calls += 1 })
        XCTAssertEqual(items.map(\.title), ["插播", "随后播放"])
        XCTAssertEqual(items.map(\.subtitle), [nil, "喜爱歌曲"])
        XCTAssertTrue(items.allSatisfy(\.isDisabled))
        for item in items { item.perform() }
        XCTAssertEqual(calls, 0)
    }
}
