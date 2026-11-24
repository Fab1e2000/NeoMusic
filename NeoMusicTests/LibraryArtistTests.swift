import XCTest
@testable import NeoMusic

@MainActor
final class LibraryArtistTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults, LibraryArtistPreferences) throws -> Void) throws {
        let suite = "LibraryArtistTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, LibraryArtistPreferences(defaults: defaults))
    }

    private func track(_ id: String, artist: String, album: String = "Album", directory: String? = nil,
                       providerArtist: String? = nil, providerAlbum: Int64? = nil, year: Int? = nil) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: artist, album: album, albumArtist: artist,
                        trackNumber: 1, artwork: .missing, albumDirectory: directory,
                        onlineAlbumID: providerAlbum, artistReferences: providerArtist.map {
                            [.init(id: $0, name: artist)]
                        } ?? [], year: year)
    }

    func testFiltersAndPinyinSearchUseLibraryMembership() throws {
        try withPreferences { _, preferences in
            let imported = track("local/track.mp3", artist: "北极圈", directory: "local", year: 2023)
            let downloaded = track("downloads/track.flac", artist: "CIEL",
                                   providerArtist: "catalog:artist:2", providerAlbum: 20)
            let duplicate = track("netease:42:11", artist: "CIEL",
                                  providerArtist: "catalog:artist:2", providerAlbum: 20)
            let online = track("netease:42:12", artist: "Albemuth",
                               providerArtist: "catalog:artist:3", providerAlbum: 30)
            let oldAccount = track("netease:43:12", artist: "Old account",
                                   providerArtist: "catalog:artist:4", providerAlbum: 40)
            preferences.registerLocalCredits(in: [imported, downloaded])
            let localID = try XCTUnwrap(preferences.localIdentity(for: imported.artist))
            preferences.toggleFavorite(localID, owner: "42")

            let result = LibraryArtistCatalog.make(local: [imported, downloaded], online: [duplicate, online, oldAccount],
                subscribed: [], albums: LocalAlbumIndex(songs: [imported]).items, owner: "42",
                preferences: preferences, downloadedID: { $0 == downloaded.id ? 11 : nil })

            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .all, query: "").map(\.name), ["Albemuth", "北极圈", "CIEL"])
            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .favorites, query: "").map(\.name), ["北极圈"])
            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .downloaded, query: "").map(\.name), ["北极圈", "CIEL"])
            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .all, query: " bei ji ").map(\.name), ["北极圈"])
            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .all, query: "beiji").map(\.name), ["北极圈"])
            XCTAssertEqual(LibraryArtistEntry.visible(result, filter: .all, query: "ciel").first?.songs.map(\.id), [downloaded.id])
            XCTAssertEqual(result.first { $0.id == localID }?.albums.first?.year, 2023)
            XCTAssertTrue(LibraryArtistEntry.visible(result, filter: .downloaded, query: "Albemuth").isEmpty)
        }
    }

    func testAlbumIdentityAndIndependentPortraitTakePriority() throws {
        try withPreferences { _, preferences in
            let id = "catalog:artist:7"
            let portrait = Artwork.file(URL(fileURLWithPath: "/artist.jpg"))
            let cover = Artwork.file(URL(fileURLWithPath: "/cover.jpg"))
            let album = LibraryShelfItem(id: "catalog:album:9", title: "Release", artwork: cover,
                route: .album("catalog:album:9"), isFavorite: true, year: 2024, sourceOwnerID: "42",
                artistReferences: [.init(id: id, name: "相同名称")])
            var artists = LibraryArtistCatalog.make(local: [], online: [],
                subscribed: [.init(id: id, name: "新名称", artwork: portrait, isFavorite: true),
                             .init(id: "catalog:artist:8", name: "相同名称", artwork: nil, isFavorite: true)],
                albums: [album], owner: "42", preferences: preferences, downloadedID: { _ in nil })

            let first = try XCTUnwrap(artists.firstIndex { $0.id.itemID == id })
            let second = try XCTUnwrap(artists.first { $0.id.itemID == "catalog:artist:8" })
            XCTAssertEqual(artists[first].albums.map(\.id), [album.id])
            XCTAssertTrue(artists[first].isFavorite)
            XCTAssertEqual(artists[first].avatar, .portrait(portrait))
            XCTAssertTrue(second.albums.isEmpty)
            XCTAssertEqual(second.avatar, .missing)
            artists[first].portrait = .missing
            XCTAssertEqual(artists[first].avatar, .album(cover, nil))
        }
    }

    func testLocalArtistRetainsTracksWithoutDisplayingAnUnnamedAlbum() throws {
        try withPreferences { _, preferences in
            let track = track("loose.mp3", artist: "Solo", album: "")
            preferences.registerLocalCredits(in: [track])
            let artists = LibraryArtistCatalog.make(local: [track], online: [], subscribed: [],
                albums: LocalAlbumIndex(songs: [track]).items, owner: nil, preferences: preferences,
                downloadedID: { _ in nil })
            let artist = try XCTUnwrap(artists.first)
            XCTAssertTrue(artist.albums.isEmpty)
            XCTAssertEqual(artist.songs.map(\.id), [track.id])
            XCTAssertNil(artist.id.onlineRoute)
            XCTAssertEqual(LibraryArtistIdentity.catalog(id: "catalog:artist:7", ownerID: nil).onlineRoute,
                           .artist("catalog:artist:7"))
            XCTAssertNil(LibraryArtistIdentity.catalog(id: "catalog:album:8", ownerID: "42").onlineRoute)
        }
    }

    func testFavoriteAndPinsSurviveReloadAndRespectAccountBoundaries() throws {
        try withPreferences { defaults, preferences in
            let song = track("track.mp3", artist: "Local Artist")
            preferences.registerLocalCredits(in: [song])
            let local = try XCTUnwrap(preferences.localIdentity(for: "Local Artist"))
            let a = LibraryArtistIdentity.catalog(id: "catalog:artist:7", ownerID: "42")
            let b = LibraryArtistIdentity.catalog(id: a.itemID, ownerID: "43")
            let offline = LibraryArtistIdentity.catalog(id: a.itemID, ownerID: nil)

            preferences.toggleFavorite(local, owner: nil)
            preferences.togglePin(local, name: "Local Artist", owner: nil)
            preferences.toggleFavorite(offline, owner: nil)
            preferences.togglePin(offline, name: "Offline Artist", owner: nil)
            preferences.togglePin(a, name: "A", owner: "42")
            preferences.togglePin(a, name: "Stale action", owner: "43")
            preferences.toggleFavorite(a, owner: "42")

            let restored = LibraryArtistPreferences(defaults: defaults)
            XCTAssertEqual(restored.localIdentity(for: "LOCAL ARTIST"), local)
            XCTAssertTrue(restored.isFavorite(local, owner: "43"))
            XCTAssertTrue(restored.isFavorite(offline, owner: nil))
            XCTAssertFalse(restored.isFavorite(offline, owner: "43"))
            XCTAssertFalse(restored.isFavorite(a, owner: "42"), "Signed-in favorites are provided by the account service.")
            XCTAssertEqual(restored.pins(for: "42"), [local: "Local Artist", a: "A"])
            XCTAssertEqual(restored.pins(for: "43"), [local: "Local Artist"])
            XCTAssertEqual(restored.pins(for: nil), [local: "Local Artist", offline: "Offline Artist"])
            XCTAssertNotEqual(PinnedOrderID(route: .libraryArtist(a)), PinnedOrderID(route: .libraryArtist(b)))

            let shownToB = LibraryArtistCatalog.make(local: [song], online: [], subscribed: [], albums: [],
                owner: "43", preferences: restored, downloadedID: { _ in nil })
            XCTAssertEqual(shownToB.map(\.id), [local])
            restored.togglePin(a, name: "A", owner: "42")
            restored.toggleFavorite(local, owner: nil)
            let reloaded = LibraryArtistPreferences(defaults: defaults)
            XCTAssertEqual(reloaded.pins(for: "42"), [local: "Local Artist"])
            XCTAssertFalse(reloaded.isFavorite(local, owner: "42"))
        }
    }

    func testArtistParticipatesInLegacyMixedPinnedOrder() throws {
        try withPreferences { defaults, _ in
            let key = "pinned"
            defaults.set(Data(#"[{"kind":"playlist","id":"favorites"},{"kind":"album","id":"folder:album"}]"#.utf8), forKey: key)
            let store = PinnedOrderStore(defaults: defaults, key: key)
            let playlist = try XCTUnwrap(PinnedOrderID(route: .playlist("favorites")))
            let album = try XCTUnwrap(PinnedOrderID(route: .album("folder:album")))
            let artist = try XCTUnwrap(PinnedOrderID(route: .libraryArtist(.catalog(id: "catalog:artist:7", ownerID: "42"))))
            XCTAssertEqual(store.order, [playlist, album])
            XCTAssertTrue(store.reorder(visible: [playlist, album, artist], to: [artist, playlist, album]))
            XCTAssertEqual(PinnedOrderStore(defaults: defaults, key: key).order, [artist, playlist, album])
        }
    }

    func testOnlineFavoriteRestoresOnlyForItsOwner() async throws {
        struct Subscriptions: Encodable {
            let artists: [NeteaseArtistReference]
            let albums: [NeteaseArtistAlbum] = []
            let refreshedAt: [String: Date] = [:]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        try await cache.save(Subscriptions(artists: [.init(id: 7, name: "Artist", artworkURL: nil)]),
                             scope: "42", key: "subscriptions")
        let credential = try NeteaseCredential(musicU: "fixture")
        let a = NeteaseSavedSession(profile: .init(userID: 42, nickname: "A", avatarURL: nil), credential: credential)
        let b = NeteaseSavedSession(profile: .init(userID: 43, nickname: "B", avatarURL: nil), credential: credential)
        let store = NeteaseArtistStore(directory: directory)
        await store.activate(a, refresh: false)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
        await store.activate(b, refresh: false)
        XCTAssertTrue(store.subscribedArtists.isEmpty)
        await store.activate(nil, refresh: false)
        XCTAssertTrue(store.subscribedArtists.isEmpty)
        await store.activate(a, refresh: false)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
        await store.invalidate()
    }

    func testReleaseYearFromCommonTagFormats() {
        XCTAssertEqual(LocalAudioMetadataReader.releaseYear("2023-09-20"), 2023)
        XCTAssertEqual(LocalAudioMetadataReader.releaseYear(" 2024 "), 2024)
        XCTAssertNil(LocalAudioMetadataReader.releaseYear("unknown"))
    }
}
