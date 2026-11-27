import XCTest
@testable import NeoMusic

@MainActor final class HomeSongCatalogTests: XCTestCase {
    func testGuestArtistSongActionsRequestLogin() {
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})
        let integration = ArtistMusicIntegration(account: account)
        let song = LibrarySongItem(id: "catalog-guest:7", title: "Song", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 0, artwork: .missing)
        integration.songActions(.album("catalog:album:1")).play([song], 0, "Album")
        XCTAssertTrue(integration.showsLogin)
        integration.showsLogin = false
        integration.songActions(.artist("catalog:artist:1")).playNext(song)
        XCTAssertTrue(integration.showsLogin)
    }
    func testGuestArtistCanPlayAndQueueDownloadedTrackWithoutLogin() {
        let app = AppContainer()
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})
        let integration = ArtistMusicIntegration(account: account, container: app)
        let local = LibrarySongItem(id: "Downloads/one.m4a", title: "Song", artist: "Artist", album: "Album",
                                    albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        let guest = LibrarySongItem(id: "catalog-guest:7", title: "Song", artist: "Artist", album: "Album",
                                    albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        app.songLibrary.replace([local])
        XCTAssertEqual(DownloadMusicIntegration.guestDownloadSongID("home-guest:7"), 7)
        XCTAssertNil(DownloadMusicIntegration.guestDownloadSongID("home-guest::7"))
        XCTAssertNil(DownloadMusicIntegration.guestDownloadSongID("local:7"))
        app.songLibrary.downloadedFileID = { DownloadMusicIntegration.guestDownloadSongID($0) == 7 ? local.id : nil }
        LibraryNetworkAccess.$override.withValue(.init(isOffline: { true }, reportOffline: { XCTFail() })) {
            let actions = integration.songActions(.artist("catalog:artist:1"))
            actions.play([guest], 0, "Artist")
            actions.playNext(guest)
            actions.playLater(guest)
            XCTAssertEqual(app.player.queue.map(\.id), [local.id, local.id, local.id])
            XCTAssertFalse(integration.showsLogin)
        }
    }

    func testIndependentExternalSourcesDoNotOverwriteEachOther() {
        let library = SongLibrary(songs: [], defaults: UserDefaults(suiteName: UUID().uuidString)!)
        func song(_ id: Int) -> LibrarySongItem { .init(id: "netease:1:\(id)", title: "Song", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 0, artwork: .missing) }
        library.replaceExternalSongs([song(1)], source: "home")
        library.replaceExternalSongs([song(2)], source: "artists")
        XCTAssertEqual(Set(library.allSongs.map(\.id)), ["netease:1:1", "netease:1:2"])
        library.replaceExternalSongs([], source: "artists")
        XCTAssertEqual(library.allSongs.map(\.id), ["netease:1:1"])
    }
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
