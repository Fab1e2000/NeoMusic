import XCTest
@testable import NeoMusic

@MainActor final class HomeSongCatalogTests: XCTestCase {
    func testExternalCatalogEnablesActionsWithoutAddingLibrarySongs() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let library = SongLibrary(songs: [], defaults: defaults)
        let song = LibrarySongItem(id: "netease:1:42", title: "Recommended", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 0, artwork: .missing)
        var requested: String?
        library.onlineFavoriteAction = { id, liked in if liked { requested = id } }
        library.replaceExternalSongs([song, song])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.onlineSongs.isEmpty)
        XCTAssertEqual(library.allSongs.count, 1)
        library.toggleFavorite(song.id)
        XCTAssertEqual(requested, song.id)
        library.replaceOnline([song])
        XCTAssertEqual(library.allSongs.count, 1)
        library.replaceExternalSongs([])
        library.replaceOnline([])
        XCTAssertTrue(library.allSongs.isEmpty)
    }
}
