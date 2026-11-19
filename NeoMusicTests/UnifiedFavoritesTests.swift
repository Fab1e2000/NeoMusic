import XCTest
import FullScreenPlayer
@testable import NeoMusic

@MainActor
final class UnifiedFavoritesTests: XCTestCase {
    private func song(_ id: String, date: Date? = nil) -> LibrarySongItem {
        var result = LibrarySongItem(id: id, title: id, artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        result.isFavorite = true
        result.favoriteAddedAt = date
        return result
    }

    func testKnownDatesPrecedeStableHistory() {
        let local = song("local")
        let online = song("netease:1:1")
        let older = song("netease:1:2", date: Date(timeIntervalSince1970: 10))
        let newer = song("new", date: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(SongLibrary.orderedFavorites([local, newer, online, older]).map(\.id), ["new", "netease:1:2", "local", "netease:1:1"])
    }

    func testOnlineLikeDelegatesWithoutPublishingSuccess() {
        let library = SongLibrary(songs: [song("local")])
        library.replaceOnline([song("netease:1:1"), song("netease:1:1")])
        var request: (String, Bool, Bool)?
        library.onlineFavoriteAction = { request = ($0, $1, $2) }
        library.toggleFavorite("netease:1:1")
        XCTAssertEqual(request?.0, "netease:1:1")
        XCTAssertEqual(request?.1, false)
        XCTAssertEqual(request?.2, true)
        library.setFavorite("netease:1:1", false, playsSuccessHaptic: false)
        XCTAssertEqual(request?.2, false)
        XCTAssertTrue(library.onlineSongs[0].isFavorite)
        XCTAssertEqual(library.onlineSongs.count, 1)
        library.replaceOnline([])
        XCTAssertEqual(library.allSongs.map(\.id), ["local"])
    }

    func testLocalFavoriteTimePersistsWithoutInventingHistoricalTime() throws {
        let name = "UnifiedFavoritesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let library = SongLibrary(songs: [song("old")], defaults: defaults)
        XCTAssertNil(library.songs[0].favoriteAddedAt)
        library.setFavorite("old", false)
        library.setFavorite("old", true)
        let time = try XCTUnwrap(library.songs[0].favoriteAddedAt)
        let restored = SongLibrary(songs: [song("old")], defaults: defaults)
        let restoredTime = try XCTUnwrap(restored.songs[0].favoriteAddedAt)
        XCTAssertEqual(restoredTime.timeIntervalSince1970, time.timeIntervalSince1970)
        restored.setFavorite("old", false)
        XCTAssertNil(restored.songs[0].favoriteAddedAt)
    }

    func testPlayerActionsDefersFavoriteFeedbackForAsynchronousTracks() {
        var feedbackCount = 0
        var notices: [PlayerNotice] = []
        var toggled: [String] = []
        let actions = PlayerActions(
            isFavorite: { _ in false },
            toggleFavorite: { toggled.append($0) },
            addToPlaylist: { _ in },
            openAlbum: { _ in },
            openArtist: { _ in },
            feedback: { feedbackCount += 1 },
            notify: { notices.append($0) },
            completesFavoriteSynchronously: { $0 == "local" }
        )
        let onlineTrack = PlayerTrack(id: "netease:1:1", title: "Online", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 100)
        let localTrack = PlayerTrack(id: "local", title: "Local", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 100)

        actions.toggleFavorite(onlineTrack)
        XCTAssertEqual(toggled, ["netease:1:1"])
        XCTAssertEqual(feedbackCount, 0)
        XCTAssertTrue(notices.isEmpty)

        actions.toggleFavorite(localTrack)
        XCTAssertEqual(toggled, ["netease:1:1", "local"])
        XCTAssertEqual(feedbackCount, 1)
        XCTAssertEqual(notices, [.favorited])
    }
}
