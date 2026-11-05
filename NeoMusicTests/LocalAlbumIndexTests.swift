import XCTest
@testable import NeoMusic

@MainActor
final class LocalAlbumIndexTests: XCTestCase {
    func testRepeatedReadsAndFavoriteChangesReusePreparedAlbumMetadata() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = song("first", track: 1)
        let second = song("second", track: 2)
        let library = SongLibrary(songs: [second, first], defaults: defaults)
        let index = library.albumIndex
        for _ in 0..<10 {
            XCTAssertTrue(library.albumIndex === index)
            XCTAssertEqual(library.albumIndex.songIDsByAlbum[first.albumID], [first.id, second.id])
        }
        library.replace([second, first])
        XCTAssertTrue(library.albumIndex === index)
        library.setFavorite(first.id, true)
        XCTAssertTrue(library.albumIndex === index)
        XCTAssertEqual(library.song(id: first.id)?.isFavorite, true)
        var pinned = library.songs
        pinned[0].isPinned = true
        library.replace(pinned)
        XCTAssertTrue(library.albumIndex === index)
        XCTAssertEqual(library.song(id: second.id)?.isPinned, true)
    }

    func testMetadataArtworkOrderingAndRemovalRebuildIndex() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = song("first", track: 1, artist: "First Artist")
        var second = song("second", track: 2, artist: "Second Artist")
        second.addedOrder = 10
        let library = SongLibrary(songs: [second, first], defaults: defaults)
        let initial = library.albumIndex
        XCTAssertEqual(initial.items.first?.subtitle, "First Artist / Second Artist")
        XCTAssertEqual(initial.items.first?.addedOrder, 10)
        XCTAssertEqual(initial.albumIDsByArtist["Second Artist"], [first.albumID])
        var changed = first
        changed.artwork = .file(URL(fileURLWithPath: "/album-index/changed.png"))
        library.replace([second, changed])
        XCTAssertFalse(library.albumIndex === initial)
        XCTAssertEqual(library.albumIndex.items.first?.artwork, changed.artwork)
        var laterDisc = changed
        laterDisc.discNumber = 2
        library.replace([second, laterDisc])
        XCTAssertEqual(library.albumIndex.songIDsByAlbum[first.albumID], [second.id, first.id])
        XCTAssertEqual(library.albumIndex.items.first?.artwork, second.artwork)
        library.replace([song("renamed", track: 1, album: "Renamed")])
        XCTAssertEqual(library.albumIndex.items.first?.title, "Renamed")
        XCTAssertEqual(library.albumIndex.songIDsByAlbum[first.albumID], ["renamed"])
        library.replace([])
        XCTAssertTrue(library.albumIndex.items.isEmpty)
        XCTAssertTrue(library.albumIndex.songIDsByAlbum.isEmpty)
        XCTAssertTrue(library.albumIndex.albumIDsByArtist.isEmpty)
    }

    func testPresentationOverlaysAlbumPreferencesAndResolvesCurrentSongState() throws {
        let saved = LocalLibrary.songLibrary.songs
        let track = song("album-index-\(UUID().uuidString)", track: 1, directory: UUID().uuidString)
        let id = track.albumID
        defer {
            LocalLibrary.favoriteAlbums.remove(id)
            LocalLibrary.pinnedAlbums.remove(id)
            LocalLibrary.deletedAlbums.remove(id)
            LocalLibrary.songLibrary.replace(saved)
        }
        LocalLibrary.songLibrary.replace([track])
        let index = LocalLibrary.songLibrary.albumIndex
        LocalLibrary.favoriteAlbums.insert(id)
        LocalLibrary.pinnedAlbums.insert(id)
        let item = try XCTUnwrap(LocalLibrary.albums.first { $0.id == id })
        XCTAssertTrue(item.isFavorite)
        XCTAssertTrue(item.isPinned)
        XCTAssertTrue(LocalLibrary.pinned.contains { $0.id == id })
        var favorite = track
        favorite.isFavorite = true
        LocalLibrary.songLibrary.replace([favorite])
        XCTAssertEqual(LocalLibrary.albumDetail(id)?.songs.first?.isFavorite, true)
        XCTAssertTrue(LocalLibrary.songLibrary.albumIndex === index)
        LocalLibrary.deletedAlbums.insert(id)
        XCTAssertFalse(LocalLibrary.albums.contains { $0.id == id })
        XCTAssertNil(LocalLibrary.albumDetail(id))
        XCTAssertNil(LocalLibrary.artistDetail(track.albumArtist))
        LocalLibrary.deletedAlbums.remove(id)
        XCTAssertEqual(LocalLibrary.albumDetail(id)?.songs.first?.id, track.id)
        XCTAssertTrue(LocalLibrary.songLibrary.albumIndex === index)
    }

    private func song(_ id: String, track: Int, album: String = "Album", artist: String = "Artist", directory: String = "index") -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: artist, album: album, albumArtist: artist,
                        trackNumber: track, artwork: .missing, albumDirectory: directory)
    }
}
