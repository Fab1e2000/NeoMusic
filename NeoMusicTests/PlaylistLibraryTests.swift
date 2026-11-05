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

    func testMixedPlaylistRestoresSavedOnlineMetadataOnlyAfterMatchingIdentity() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let cover = root.appendingPathComponent("cover.image")
        let local = song("local.mp3")
        let online = LibrarySongItem(id: "netease:42:7", title: "Saved title", artist: "Saved artist", album: "Album", albumArtist: "Saved artist", trackNumber: 1,
                                    artwork: .file(cover), artworkData: Data([1, 2, 3]), artworkURL: cover, duration: 240, onlineAlbumID: 9,
                                    artistReferences: [.init(id: "catalog:artist:3", name: "Saved artist")])
        let original = library()
        XCTAssertTrue(original.configurePersistence(url: url, songs: [local]))
        original.restoreOnlineIdentity(ownerID: "42")
        original.addSongs([online, local], to: "one")

        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: [local]))
        XCTAssertEqual(restored.songs(in: "one").map(\.id), [online.id, local.id])
        XCTAssertEqual(restored.songs(in: "one").first, .unavailable(online.id))
        XCTAssertEqual(restored.songs(in: "one").last, local)
        restored.restoreOnlineIdentity(ownerID: "42")
        let visible = try XCTUnwrap(restored.songs(in: "one").first)
        XCTAssertEqual(visible.title, online.title)
        XCTAssertEqual(visible.artistReferences, online.artistReferences)
        XCTAssertEqual(visible.onlineAlbumID, online.onlineAlbumID)
        XCTAssertEqual(visible.duration, 240)
        XCTAssertEqual(visible.artwork, .file(cover))
        XCTAssertNil(visible.artworkData)

        restored.restoreOnlineIdentity(ownerID: "43")
        XCTAssertEqual(restored.songs(in: "one").first, .unavailable(online.id))
        restored.reconcileOnlineSongs([online])
        restored.updateArtwork(songs: [online.id: online])
        XCTAssertEqual(restored.songs(in: "one").first, .unavailable(online.id))
        restored.renamePlaylist("one", to: "Edited while another account is active")

        let reopened = PlaylistLibrary(playlists: [])
        XCTAssertTrue(reopened.configurePersistence(url: url, songs: [local]))
        reopened.restoreOnlineIdentity(ownerID: "42")
        XCTAssertEqual(reopened.songs(in: "one").first?.title, online.title)
        reopened.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        XCTAssertEqual(reopened.songs(in: "one").first, .unavailable(online.id))
        XCTAssertEqual(reopened.songs(in: "one").last, local)
        reopened.restoreOnlineIdentity(ownerID: "42")
        XCTAssertEqual(reopened.songs(in: "one").first?.title, online.title)
    }

    func testMixedPlaylistSnapshotIncludesOnlyReferencedOnlineSongsAndFileArtwork() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = library()
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        let remote = URL(string: "https://fixture.test/temporary-cover")!
        let selected = LibrarySongItem(id: "netease:42:7", title: "Selected", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1,
                                       artwork: .missing, artworkData: Data([1, 2, 3]), artworkURL: remote)
        let unrelated = song("netease:42:8")
        let external = LibraryPlaylistItem(id: "netease-playlist:42:1", title: "External", artwork: .playlist, sourceOwnerID: "42")
        library.replaceOnlinePlaylists(items: [external], songs: [external.id: [selected, unrelated]], ownerID: "42")
        library.addSongs([selected, song("local.mp3")], to: "one")

        let snapshot = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(snapshot.onlineSongs?.keys.map { $0 } ?? []), [selected.id])
        XCTAssertNil(snapshot.onlineSongs?[selected.id]?.artworkURL)
        XCTAssertFalse(snapshot.playlists.contains { $0.id == external.id })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let metadata = try XCTUnwrap(object["onlineSongs"] as? [String: [String: Any]])
        XCTAssertNil(metadata[selected.id]?["artworkData"])

        library.removeSong(selected.id, from: "one")
        let removed = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertTrue(removed.onlineSongs?.isEmpty == true)
        XCTAssertEqual(library.songs(in: external.id).count, 2)
    }

    func testMixedPlaylistPersistsLaterOnlineMetadataAndArtworkWithoutCatalogRestore() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = library()
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        library.restoreOnlineIdentity(ownerID: "42")
        library.addSongs([song("netease:42:7")], to: "one")
        let initialBytes = try Data(contentsOf: url)
        let updated = LibrarySongItem(id: "netease:42:7", title: "Updated", artist: "New artist", album: "Album", albumArtist: "New artist", trackNumber: 1, artwork: .missing)
        library.reconcileOnlineSongs([updated])
        let cover = root.appendingPathComponent("later-cover.image")
        var artwork = updated
        artwork.artwork = .file(cover)
        artwork.artworkURL = cover
        library.updateArtwork(songs: [artwork.id: artwork])
        library.restoreOnlineIdentity(ownerID: nil)
        XCTAssertEqual(library.songs(in: "one").first, .unavailable(artwork.id))
        XCTAssertEqual(try Data(contentsOf: url), initialBytes)
        library.persistRestoredMetadata()

        let restored = PlaylistLibrary(playlists: [])
        restored.restoreOnlineIdentity(ownerID: "42")
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        XCTAssertEqual(restored.songs(in: "one").first?.title, "Updated")
        XCTAssertEqual(restored.songs(in: "one").first?.artist, "New artist")
        XCTAssertEqual(restored.songs(in: "one").first?.artwork, .file(cover))
        restored.reconcileSongs([])
        XCTAssertEqual(restored.songs(in: "one").first?.title, "Updated")
    }

    func testLegacyMixedPlaylistWithoutMetadataKeepsReferencesAndAcceptsCurrentOwnerRefresh() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let original = library()
        XCTAssertTrue(original.configurePersistence(url: url, songs: []))
        original.addSongs([song("netease:42:7")], to: "one")
        var legacy = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        legacy.onlineSongs = nil
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: data)
        XCTAssertNil(decoded.onlineSongs)

        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: [], restoredState: .success(decoded)))
        restored.restoreOnlineIdentity(ownerID: "42")
        XCTAssertEqual(restored.songs(in: "one").map(\.id), ["netease:42:7"])
        XCTAssertEqual(restored.songs(in: "one").first, .unavailable("netease:42:7"))
        let refreshed = song("netease:42:7")
        restored.reconcileOnlineSongs([refreshed])
        XCTAssertEqual(restored.songs(in: "one").first?.title, refreshed.title)
    }

    func testPlaylistDetailProjectionUpdatesControlsAndDataWithoutRepeatingWork() {
        let first = LibrarySongItem(id: "a", title: "Alpha", artist: "Zed", album: "Record two",
                                   albumArtist: "Zed", trackNumber: 1, artwork: .missing, duration: 125)
        let second = LibrarySongItem(id: "b", title: "Beta", artist: "Ada", album: "Record one",
                                    albumArtist: "Ada", trackNumber: 2, artwork: .missing, duration: 65)
        let projection = LibraryListProjection<PlaylistDetailView.ProjectionInput, PlaylistDetailView.Projection>()
        var calculations = 0
        func result(_ input: PlaylistDetailView.ProjectionInput) -> PlaylistDetailView.Projection {
            projection.value(for: input) { calculations += 1; return input.calculate() }
        }
        let input = PlaylistDetailView.ProjectionInput(tracks: [second, first], query: "", sort: .order)
        XCTAssertEqual(result(input).tracks.map(\.id), ["b", "a"])
        XCTAssertEqual(result(input).totalDuration, 190)
        XCTAssertEqual(calculations, 1)
        XCTAssertEqual(result(.init(tracks: input.tracks, query: "", sort: .title)).tracks.map(\.id), ["a", "b"])
        XCTAssertEqual(result(.init(tracks: input.tracks, query: "", sort: .artist)).tracks.map(\.id), ["b", "a"])
        XCTAssertEqual(result(.init(tracks: input.tracks, query: "Record one", sort: .album)).tracks.map(\.id), ["b"])
        XCTAssertEqual(result(.init(tracks: input.tracks, query: "zed", sort: .order)).tracks.map(\.id), ["a"])
        let changed = result(.init(tracks: [second], query: "", sort: .order))
        XCTAssertEqual(changed.tracks.map(\.id), ["b"])
        XCTAssertEqual(changed.totalDuration, 65)
        XCTAssertEqual(calculations, 6)
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
    func testToolbarDownloadAndDeletionUseCurrentStateAndCallbacks() throws {
        let route = LibraryRoute.album("album")
        let item = LibraryShelfItem(id: "album", title: "album", artwork: .playlist, route: route)
        var downloaded = false
        var requestedRemoval = false
        var requestedDeletion = false
        var actions = CollectionMenuActions()
        actions.canDelete = { $0 == route }
        actions.isDownloaded = { _ in downloaded }
        actions.canDownload = { $0 == route && !downloaded }
        actions.canRemoveDownload = { $0 == route && downloaded }
        actions.download = { _ in downloaded = true }
        actions.removeDownload = { _ in requestedRemoval = true }
        actions.requestDelete = { _ in requestedDeletion = true }
        let initial = actions.toolbarSections(for: item, route: route)
        XCTAssertEqual(initial.first?.map(\.title), ["下载", "喜爱"])
        XCTAssertFalse(initial.flatMap { $0 }.contains { $0.title == "移除下载" })
        let download = try XCTUnwrap(initial.flatMap { $0 }.first { $0.title == "下载" })
        XCTAssertFalse(download.isDisabled)
        download.perform()
        XCTAssertTrue(downloaded)
        let completed = actions.toolbarSections(for: item, route: route)
        XCTAssertEqual(completed.first?.map(\.title), ["喜爱"])
        let removal = try XCTUnwrap(completed.flatMap { $0 }.first { $0.title == "移除下载" })
        XCTAssertFalse(removal.isDisabled)
        removal.perform()
        XCTAssertTrue(requestedRemoval)
        completed.flatMap { $0 }.first { $0.title == "从资料库删除" }?.perform()
        XCTAssertTrue(requestedDeletion)
    }

    func testImportedAlbumDoesNotOfferManagedDownloadRemoval() {
        let route = LibraryRoute.album("imported")
        let item = LibraryShelfItem(id: "imported", title: "Imported", artwork: .missing, route: route)
        let actions = CollectionMenuActions(isDownloaded: { _ in true }, canRemoveDownload: { _ in false })
        let items = actions.toolbarSections(for: item, route: route).flatMap { $0 }
        XCTAssertFalse(items.contains { $0.title == "移除下载" })
    }

    func testLocalAlbumSongFavoriteAndPinFeedbackFollowsEachAction() throws {
        var song = LibrarySongItem(id: "local", title: "Song", artist: "Artist", album: "Album",
                                  albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        var events: [String] = []
        var actions = SongMenuActions()
        actions.toggleFavorite = { _ in events.append("favorite") }
        actions.togglePin = { _ in events.append("pin") }
        for selected in [false, true] {
            song.isFavorite = selected
            song.isPinned = selected
            let items = actions.albumTrackSections(for: song, isDownloaded: true,
                download: {}, removeDownload: {}, requestDelete: {}, notify: { events.append($0.title) }).flatMap { $0 }
            events.removeAll()
            try XCTUnwrap(items.first { $0.title == (selected ? "撤销" : "喜爱") }).perform()
            try XCTUnwrap(items.first { $0.title == (selected ? "取消置顶" : "置顶歌曲") }).perform()
            XCTAssertEqual(events, ["favorite", (selected ? LibraryToast.unfavorited : .favorited).title,
                                    "pin", (selected ? LibraryToast.unpinned : .pinned).title])
        }
    }

    func testOnlineAlbumSongFeedbackRemainsWithBusinessActions() throws {
        let song = LibrarySongItem(id: "netease:42:7", title: "Song", artist: "Artist", album: "Album",
                                  albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        var events: [String] = []
        var actions = SongMenuActions()
        actions.toggleFavorite = { _ in events.append("favorite") }
        actions.playNext = { _ in events.append("next") }
        actions.playLater = { _ in events.append("later") }
        let items = actions.albumTrackSections(for: song, isDownloaded: false,
            download: {}, removeDownload: {}, requestDelete: {}, notify: { events.append($0.title) }).flatMap { $0 }
        for title in ["喜爱", "插播", "添加到队列"] {
            try XCTUnwrap(items.first { $0.title == title }).perform()
        }
        XCTAssertEqual(events, ["favorite", "next", "later"])
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
