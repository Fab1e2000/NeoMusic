import XCTest
@testable import FrontAMPages
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

    func testPlaylistTapUsesCompletedFilteredQueueInsteadOfVisiblePartialProjection() async {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "List", artwork: .playlist, sourceOwnerID: "1")
        let tracks = (0..<250).reversed().map { index in
            makeTrack(index, title: index.isMultiple(of: 2) ? "Match \(index)" : "Other \(index)")
        }
        let firstPage = Array(tracks.prefix(150))
        library.replaceOnlinePlaylists(items: [item], songs: [item.id: firstPage], ownerID: "1")
        library.setOnlineHasMore(item.id, true, totalCount: tracks.count)
        library.completeOnlinePlaylist = { _ in
            library.updateOnlineSongs(playlistID: item.id, songs: tracks, error: nil, loading: false)
            library.setOnlineHasMore(item.id, false, totalCount: tracks.count)
            return true
        }
        let selection = PlaylistTrackSelection(playlistID: item.id, ownerID: "1", songID: tracks[1].id,
                                               query: "Match", sort: .title)
        let projection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()
        let partialInput = TrackFilterProjectionInput(tracks: firstPage, query: selection.query, sort: selection.sort)
        await TrackFilterProjection.update(projection, for: partialInput)
        XCTAssertEqual(projection.committedOutput?.tracks.count, 75)

        let result = await selection.prepare(in: library, projection: projection)
        guard case .ready(let queue, let index) = result else { return XCTFail("Expected a complete queue") }
        let expected = tracks.filter { $0.title.hasPrefix("Match") }.sorted(byName: \.title)
        XCTAssertEqual(queue.map(\.id), expected.map(\.id))
        XCTAssertEqual(queue[index].id, selection.songID)
    }

    func testCancelledPlaylistTapDoesNotPlayWhenItsPageLoadReturns() async {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "List", artwork: .playlist, sourceOwnerID: "1")
        let tracks = [makeTrack(1, title: "One"), makeTrack(2, title: "Two")]
        library.replaceOnlinePlaylists(items: [item], songs: [item.id: [tracks[0]]], ownerID: "1")
        library.setOnlineHasMore(item.id, true, totalCount: tracks.count)
        let started = expectation(description: "playlist request started")
        var release: CheckedContinuation<Void, Never>?
        library.completeOnlinePlaylist = { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            library.updateOnlineSongs(playlistID: item.id, songs: tracks, error: nil, loading: false)
            library.setOnlineHasMore(item.id, false)
            return true
        }
        let projection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()
        let first = PlaylistTrackSelection(playlistID: item.id, ownerID: "1", songID: tracks[0].id, query: "", sort: .order)
        let task = Task { @MainActor in
            guard case .cancelled = await first.prepare(in: library, projection: projection) else {
                return XCTFail("The old tap must not play")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        guard let release else { return XCTFail("The request did not reach its page load") }
        release.resume()
        await task.value
        let second = PlaylistTrackSelection(playlistID: item.id, ownerID: "1", songID: tracks[1].id, query: "", sort: .order)
        guard case .ready(let queue, let index) = await second.prepare(in: library, projection: projection) else {
            return XCTFail("The latest tap should play")
        }
        XCTAssertEqual(queue[index].id, second.songID)
    }

    func testPlaylistTapReportsCompletionErrorWithoutQueuingPartialSongs() async {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:1:2", title: "List", artwork: .playlist, sourceOwnerID: "1")
        let track = makeTrack(1, title: "One")
        library.replaceOnlinePlaylists(items: [item], songs: [item.id: [track]], ownerID: "1")
        library.setOnlineHasMore(item.id, true)
        library.completeOnlinePlaylist = { _ in
            library.updateOnlineSongs(playlistID: item.id, songs: [track], error: "连接中断", loading: false)
            return false
        }
        let selection = PlaylistTrackSelection(playlistID: item.id, ownerID: "1", songID: track.id, query: "", sort: .order)
        let projection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()
        guard case .failed(let reason) = await selection.prepare(in: library, projection: projection) else {
            return XCTFail("A failed page should report its error")
        }
        XCTAssertEqual(reason, "连接中断")
    }

    private func makeTrack(_ index: Int, title: String) -> LibrarySongItem {
        LibrarySongItem(id: "netease:1:\(index)", title: title, artist: "Artist", album: "Album",
                        albumArtist: "Artist", trackNumber: index, artwork: .missing)
    }
}
