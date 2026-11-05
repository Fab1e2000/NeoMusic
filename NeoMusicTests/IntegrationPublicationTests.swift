import Observation
import Synchronization
import XCTest
@testable import NeoMusic

@MainActor final class IntegrationPublicationTests: XCTestCase {
    func testHomeFeedPlaybackSelectsOnlyTappedCreativeAndPreservesOrder() throws {
        func resource(_ id: Int) -> [String: Any] {
            ["resourceType": "song", "resourceId": String(id), "song": ["id": id, "title": "Song \(id)", "artist": "Artist", "album": "Album", "duration": 100, "unavailable": false]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["blocks": [[
            "blockCode": "HOMEPAGE_BLOCK_STYLE_RCMD", "uiElement": ["subTitle": ["title": "根据《Song》推荐"]],
            "creatives": [["resources": [resource(1), resource(2), resource(3)]],
                          ["resources": [resource(4), resource(5), resource(6)]]]
        ]]])
        let feed = try JSONDecoder().decode(NeteaseHomeFeed.self, from: data)
        let selected = try XCTUnwrap(HomeMusicIntegration.feedPlayback(feed, section: feed.blocks[0].id, item: "song/5"))
        XCTAssertEqual(selected.songs.map(\.id), [4, 5, 6])
        XCTAssertEqual(selected.index, 1)
        XCTAssertEqual(selected.title, "根据《Song》推荐")
        XCTAssertNil(HomeMusicIntegration.feedPlayback(feed, section: feed.blocks[0].id, item: "song/99"))
        let sections = HomeMusicIntegration.feedSections(feed, artwork: { _ in .missing })
        XCTAssertEqual(sections[0].items.map(\.groupID), ["song/1", "song/1", "song/1", "song/4", "song/4", "song/4"])
        XCTAssertEqual(sections[0].items.map(\.action), Array(repeating: .playSong, count: 6))
    }

    func testHomeFeedProjectionKeepsServerTitlesAndFiltersUnapprovedBlocks() throws {
        let data = Data(#"{"blocks":[{"blockCode":"HOMEPAGE_BLOCK_MGC_PLAYLIST","uiElement":{"subTitle":{"title":"Account radar"}},"creatives":[{"resources":[{"resourceType":"list","resourceId":"42","uiElement":{"mainTitle":{"title":"Radar"}}},{"resourceType":"voice","resourceId":"9"}]}]},{"blockCode":"HOMPAGE_BLOCK_VIP_RCMD","uiElement":{"subTitle":{"title":"VIP"}}},{"blockCode":"HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST","uiElement":{"subTitle":{"title":"Scenes"}},"creatives":[{"resources":[{"resourceType":"list","resourceId":"43","uiElement":{"mainTitle":{"title":"Relax"}}}]}]}]}"#.utf8)
        let feed = try JSONDecoder().decode(NeteaseHomeFeed.self, from: data)
        let sections = HomeMusicIntegration.feedSections(feed, artwork: { _ in .missing })
        XCTAssertEqual(sections.map(\.title), ["Account radar", "Scenes"])
        XCTAssertEqual(sections.flatMap(\.items).map(\.action), [.navigate(.playlist("home:playlist:42")), .navigate(.playlist("home:playlist:43"))])
        XCTAssertEqual(sections.flatMap(\.items).map(\.id), ["list/42", "list/43"])
        XCTAssertTrue(HomeMusicIntegration.feedSections(nil, artwork: { _ in .missing }).isEmpty)
    }

    func testHomeCategoriesHaveStableFixedOrderAndExplicitResourceActions() throws {
        let song: [String: Any] = ["resourceType": "song", "resourceId": "9",
            "song": ["id": 9, "title": "Song", "artist": "Artist", "album": "Album", "duration": 20, "unavailable": false]]
        func resource(_ type: String, _ id: Int) -> [String: Any] {
            ["resourceType": type, "resourceId": String(id), "uiElement": ["mainTitle": ["title": "Item \(id)"]]]
        }
        func block(_ code: String, _ title: String, _ resources: [[String: Any]]) -> [String: Any] {
            ["blockCode": code, "uiElement": ["subTitle": ["title": title]],
             "creatives": [["creativeId": UUID().uuidString, "resources": resources]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["blocks": [
            block("NEOMUSIC_NEW_SONGS", "新歌速递", [song]),
            block("HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST", "午后的音乐", [resource("list", 8)]),
            block("NEOMUSIC_FOLLOWED_RELEASES", "艺人新作", [resource("album", 7), resource("artist", 17)]),
            block("NEOMUSIC_CHARTS", "排行榜", [resource("list", 6)]),
            block("HOMEPAGE_BLOCK_MGC_PLAYLIST", "Test 的雷达歌单", [resource("list", 5)]),
            block("HOMEPAGE_BLOCK_PLAYLIST_RCMD", "为你推荐的歌单", [resource("list", 4)]),
            block("HOMEPAGE_BLOCK_STYLE_RCMD", "根据《Seed》推荐", [song, song]),
            block("HOMEPAGE_BLOCK_STYLE_RCMD", "根据你喜欢的歌曲推荐", [song]),
            block("NEOMUSIC_LIKED_SONGS", "根据你喜欢的《Fallback》推荐", [song]),
            block("UNKNOWN", "未知内容", [resource("list", 99)])
        ]])
        let feed = try JSONDecoder().decode(NeteaseHomeFeed.self, from: data)
        let sections = HomeMusicIntegration.feedSections(feed, artwork: { _ in .missing })
        XCTAssertEqual(sections.map(\.id), NeteaseHomeCategory.allCases.map(\.rawValue))
        XCTAssertEqual(sections.first?.title, "根据你喜欢的歌曲推荐")
        XCTAssertEqual(sections[1].items.count, 1)
        XCTAssertEqual(sections[5].items.map(\.action), [.navigate(.album("catalog:album:7")), .navigate(.artist("catalog:artist:17"))])
        XCTAssertEqual(sections.last?.items.first?.action, .playSong)
        let reordered = NeteaseHomeFeed(blocks: Array(feed.blocks.reversed()), hasMore: nil, cursor: nil)
        XCTAssertEqual(HomeMusicIntegration.feedSections(reordered, artwork: { _ in .missing }).map(\.id), sections.map(\.id))
    }

    func testSimilarActionAcceptsOnlyCurrentAccountsPlayableOnlineIdentity() {
        func item(_ id: String, unavailable: Bool = false) -> LibrarySongItem {
            .init(id: id, title: "Song", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1,
                  artwork: .missing, unavailabilityReason: unavailable ? "Unavailable" : nil)
        }
        XCTAssertEqual(HomeMusicIntegration.currentOnlineSongID(item("netease:42:9"), owner: "42"), 9)
        for song in [item("local:9"), item("netease:41:9"), item("netease:42:0"), item("netease:42:9", unavailable: true)] {
            XCTAssertNil(HomeMusicIntegration.currentOnlineSongID(song, owner: "42"))
        }
        XCTAssertNil(HomeMusicIntegration.currentOnlineSongID(item("netease:42:9"), owner: nil))
        XCTAssertEqual(HomeQuickAction.allCases.map(\.rawValue), NeteaseHomeQuickAction.allCases.map(\.rawValue))
    }

    func testUnchangedSongCatalogDoesNotInvalidateObservers() {
        let library = makeSongLibrary()
        let online = song("1")
        let external = song("2")
        XCTAssertTrue(library.replaceOnline([online]))
        library.replaceExternalSongs([external], source: "home")
        let changes = Mutex(0)
        withObservationTracking {
            _ = library.allSongs
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        XCTAssertFalse(library.replaceOnline([online, online]), "Duplicate inputs still describe the same catalog")
        library.replaceExternalSongs([external], source: "home")
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertEqual(library.allSongs.map(\.id), [online.id, external.id])
        XCTAssertTrue(library.replaceOnline([song("3")]))
        XCTAssertEqual(changes.withLock { $0 }, 1, "Real content changes must still reach the view")
    }

    func testSongLookupTracksCatalogPrecedenceArtworkAndRemoval() {
        let library = makeSongLibrary()
        let external = song("1", title: "External")
        library.replaceExternalSongs([external])
        XCTAssertEqual(library.song(id: external.id), external)
        let online = song("1", title: "Library")
        library.replaceOnline([online])
        XCTAssertEqual(library.song(id: online.id), online)
        let cover = song("1", artwork: .file(URL(fileURLWithPath: "/tmp/lookup-cover.jpg")))
        library.updateOnlineArtwork([cover.id: cover])
        XCTAssertEqual(library.song(id: online.id), online.replacingArtwork(from: cover))
        library.replaceOnline([])
        XCTAssertEqual(library.song(id: external.id), external)
        library.replaceExternalSongs([])
        XCTAssertNil(library.song(id: external.id))
        XCTAssertTrue(library.allSongs.isEmpty)
    }

    func testSongLookupTracksLocalFavoriteAndRemoval() {
        let library = makeSongLibrary()
        let local = LibrarySongItem(id: "local:lookup", title: "Local", artist: "Artist", album: "Album",
                                    albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        library.replace([local])
        XCTAssertEqual(library.song(id: local.id), local)
        library.setFavorite(local.id, true)
        XCTAssertEqual(library.song(id: local.id)?.isFavorite, true)
        XCTAssertNotNil(library.song(id: local.id)?.favoriteAddedAt)
        library.replace([])
        XCTAssertNil(library.song(id: local.id))
    }

    func testLowerPriorityCatalogUpdateDoesNotInvalidateMergedCatalog() {
        let library = makeSongLibrary()
        let online = song("1", title: "Library")
        library.replaceOnline([online])
        let changes = Mutex(0)
        withObservationTracking { _ = library.allSongs; _ = library.song(id: online.id) } onChange: {
            changes.withLock { $0 += 1 }
        }
        library.replaceExternalSongs([song("1", title: "External")])
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertEqual(library.song(id: online.id), online)
    }

    func testIdenticalPlaylistRefreshPreservesFirstSeenDateAndDoesNotRepublish() throws {
        let library = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:42:10", title: "List", artwork: .playlist, sourceOwnerID: "42")
        let track = song("1")
        let contents = [item.id: [track]]
        library.replaceOnlinePlaylists(items: [item], songs: contents, ownerID: "42")
        let firstSeen = try XCTUnwrap(library.playlist(item.id)?.addedAt)
        let changes = Mutex(0)
        withObservationTracking {
            _ = library.playlists
            _ = library.songs(in: item.id)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        for _ in 0..<3 {
            library.replaceOnlinePlaylists(items: [item], songs: contents, ownerID: "42")
        }
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertEqual(library.playlist(item.id)?.addedAt, firstSeen)
        XCTAssertEqual(library.songs(in: item.id), [track])
        var renamed = item
        renamed.title = "Renamed"
        library.replaceOnlinePlaylists(items: [renamed], songs: contents, ownerID: "42")
        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(library.playlist(item.id)?.title, renamed.title)
        XCTAssertEqual(library.playlist(item.id)?.addedAt, firstSeen)
    }

    func testArtworkPublicationPreservesSongAndPlaylistState() throws {
        let songs = makeSongLibrary()
        var original = song("1", title: "Current title")
        original.isFavorite = true
        original.favoriteAddedAt = Date(timeIntervalSince1970: 123)
        original.isPinned = true
        original.duration = 200
        original.unavailabilityReason = "Unavailable"
        let untouched = song("2")
        songs.replaceOnline([original, untouched])
        let playlists = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "netease-playlist:42:10", title: "Saved list", artwork: .playlist,
                                       isFavorite: true, isPinned: true, sourceOwnerID: "42")
        let other = LibraryPlaylistItem(id: "netease-playlist:42:11", title: "Other list", artwork: .playlist, sourceOwnerID: "42")
        playlists.replaceOnlinePlaylists(items: [item, other], songs: [item.id: [original, untouched], other.id: [untouched]], ownerID: "42")
        playlists.updateOnlineSongs(playlistID: item.id, songs: [original, untouched], error: "Offline", loading: true)
        playlists.updateOnlineSongs(playlistID: other.id, songs: [untouched], error: nil, loading: false)
        let loaded = playlists.loadedOnlinePlaylistIDs
        let loading = playlists.loadingPlaylistIDs
        let errors = playlists.onlineErrors
        let firstSeen = playlists.playlist(item.id)?.addedAt
        let coverURL = URL(fileURLWithPath: "/tmp/updated-playlist-cover.jpg")
        var imageResult = song("1", title: "Stale title", artwork: .file(coverURL))
        imageResult.artworkURL = coverURL
        imageResult.artworkData = Data([1, 2, 3])
        imageResult.artworkBackdrop = .init(red: 0.1, green: 0.2, blue: 0.3)
        let replacements = [imageResult.id: imageResult, "netease:42:999": song("999")]
        songs.updateOnlineArtwork(replacements)
        playlists.updateArtwork(songs: replacements, playlists: [item.id: .file(coverURL)])
        let expected = original.replacingArtwork(from: imageResult)
        XCTAssertEqual(songs.onlineSongs, [expected, untouched])
        XCTAssertEqual(playlists.songs(in: item.id), [expected, untouched])
        XCTAssertEqual(playlists.songs(in: other.id), [untouched])
        let updated = try XCTUnwrap(playlists.playlist(item.id))
        XCTAssertEqual(updated.title, item.title)
        XCTAssertEqual(updated.artwork, .file(coverURL))
        XCTAssertEqual(updated.addedAt, firstSeen)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(playlists.playlists.map(\.id), [item.id, other.id])
        XCTAssertEqual(playlists.loadedOnlinePlaylistIDs, loaded)
        XCTAssertEqual(playlists.loadingPlaylistIDs, loading)
        XCTAssertEqual(playlists.onlineErrors, errors)
    }

    func testRepeatedArtworkPublicationDoesNotInvalidateObservers() {
        let library = makeSongLibrary()
        let track = song("1", artwork: .file(URL(fileURLWithPath: "/tmp/existing-cover.jpg")))
        library.replaceOnline([track])
        let playlists = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "home:playlist:1", title: "List", artwork: track.artwork, isReadOnlyContent: true)
        playlists.setExternalCollection(item: item, songs: [track])
        let changes = Mutex(0)
        withObservationTracking {
            _ = library.onlineSongs
            _ = playlists.playlists
            _ = playlists.songs(in: item.id)
            _ = playlists.loadedOnlinePlaylistIDs
            _ = playlists.onlineErrors
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        library.updateOnlineArtwork([track.id: track])
        playlists.updateArtwork(songs: [track.id: track], playlists: [item.id: track.artwork])
        playlists.setExternalCollection(item: item, songs: [track])
        XCTAssertEqual(changes.withLock { $0 }, 0)
    }

    func testExternalArtworkUpdatesRespectSourcePrecedence() throws {
        let library = makeSongLibrary()
        let home = song("1", title: "Home metadata")
        let artist = song("1", title: "Artist metadata", artwork: .favorites)
        library.replaceExternalSongs([home], source: "home")
        library.replaceExternalSongs([artist], source: "artists")
        XCTAssertEqual(library.externalSongs, [artist])
        let changes = Mutex(0)
        withObservationTracking {
            _ = library.externalSongs
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        let homeCover = song("1", title: "Stale home metadata", artwork: .file(URL(fileURLWithPath: "/tmp/home-cover.jpg")))
        library.updateOnlineArtwork([homeCover.id: homeCover], source: "home")
        XCTAssertEqual(library.externalSongs, [artist], "An image from a lower-priority source must not replace the active source")
        XCTAssertEqual(changes.withLock { $0 }, 0)
        let artistCover = song("1", title: "Stale artist metadata", artwork: .file(URL(fileURLWithPath: "/tmp/artist-cover.jpg")))
        library.updateOnlineArtwork([artistCover.id: artistCover], source: "artists")
        XCTAssertEqual(library.externalSongs, [artist.replacingArtwork(from: artistCover)])
        XCTAssertEqual(changes.withLock { $0 }, 1)
        library.replaceExternalSongs([], source: "artists")
        XCTAssertEqual(library.externalSongs, [home.replacingArtwork(from: homeCover)])
        let online = song("1", title: "Library metadata")
        library.replaceOnline([online])
        XCTAssertEqual(library.allSongs, [online], "The retained library catalog keeps priority over external browsing catalogs")
        XCTAssertEqual(try XCTUnwrap(library.externalSongs.first).title, home.title)
    }

    func testUnchangedHomeStoreCallbacksDoNotRepublishVisibleContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = NeteaseMusicPlaylist(id: 12, title: "Public list", creator: "Creator", creatorID: 42,
                                        artworkURL: nil, trackCount: 1, isFavorites: false)
        let track = NeteaseMusicSong(id: 9, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 20)
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist]
            let snapshots: [String: NeteaseDailySnapshot]
            let details: [Int64: NeteasePlaylistDetail]
        }
        let cache = Cache(recommendations: [item], snapshots: [:],
                          details: [item.id: .init(playlist: item, songs: [track], addedTimes: [:])])
        try JSONEncoder().encode(cache).write(to: directory.appendingPathComponent("public.json"))
        let home = NeteaseHomeStore(directory: directory)
        await home.activate(nil, refresh: false)
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, home: home)
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let previousOwner = LocalLibrary.playbackAccountID
        let previousExternal = LocalLibrary.songLibrary.externalSongs
        let integration = HomeMusicIntegration(account: account, player: player)
        defer {
            home.onChange = nil
            home.onArtworkChange = nil
            player.shutdownPlayback()
            LocalLibrary.playbackAccountID = previousOwner
            LocalLibrary.songLibrary.replaceExternalSongs(previousExternal)
        }
        integration.connect()
        XCTAssertEqual(integration.model.recommendations.map(\.id), [String(item.id)])
        XCTAssertEqual(integration.model.featured.map(\.id), ["favorites"])
        XCTAssertTrue(integration.cachedSongs.isEmpty)
        let changes = Mutex(0)
        withObservationTracking {
            _ = integration.model.featured
            _ = integration.model.recommendations
            _ = integration.model.recent
            _ = integration.cachedSongs
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        home.onChange?()
        home.onArtworkChange?([URL(string: "https://example.com/unrelated-cover.jpg")!])
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertEqual(integration.model.recommendations.first?.title, item.title)
        XCTAssertTrue(integration.cachedSongs.isEmpty)
    }

    func testRetainedHomePlaylistReceivesLateArtworkWithoutReopeningDetail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artworkDirectory = directory.appendingPathComponent("42", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try XCTUnwrap(URL(string: "https://example.com/retained.jpg"))
        let file = artworkDirectory.appendingPathComponent("cover")
        try Data([1, 2, 3]).write(to: file)
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Home list", creator: "Creator", creatorID: 42,
                                            artworkURL: remote, trackCount: 1, isFavorites: false)
        let track = NeteaseMusicSong(id: 9, title: "Song", artist: "Artist", album: "Album", artworkURL: remote, duration: 20)
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist] = []
            let snapshots: [String: NeteaseDailySnapshot] = [:]
            let details: [Int64: NeteasePlaylistDetail]
            let artworkFiles: [String: String]
        }
        let cache = Cache(details: [12: .init(playlist: playlist, songs: [track], addedTimes: [:])],
                          artworkFiles: [remote.absoluteString: file.lastPathComponent])
        try JSONEncoder().encode(cache).write(to: directory.appendingPathComponent("42.json"))
        let home = NeteaseHomeStore(directory: directory)
        let session = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test"))
        await home.activate(session, refresh: false)
        _ = try await home.restoreCachedDetail(id: 12)
        let library = PlaylistLibrary(playlists: [])
        let persistence = directory.appendingPathComponent("playlists.json")
        XCTAssertTrue(library.configurePersistence(url: persistence, songs: []))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "42")
        let pending = Artwork.deferred(id: "home:\(home.sessionRevision):\(remote.absoluteString)", placeholder: .playlist)
        let retained = LibraryPlaylistItem(id: "netease-playlist:42:12", title: "Retained title", artwork: pending,
                                           isFavorite: true, isPinned: true, sourceOwnerID: "42")
        var original = song("9", title: "Current title", artwork: pending)
        original.isFavorite = true
        library.retainOnlinePlaylist(retained, songs: [original])
        library.updateOnlineSongs(playlistID: retained.id, songs: [original], error: "Offline", loading: true)
        var image = song("9", title: "Stale title", artwork: .file(file))
        image.artworkURL = file
        HomeMusicIntegration.updateRetainedArtwork(in: library, home: home, owner: "42", urls: [remote], songs: [image.id: image])
        let updated = try XCTUnwrap(library.playlist(retained.id))
        XCTAssertEqual(updated.id, retained.id)
        XCTAssertEqual(updated.title, retained.title)
        XCTAssertEqual(updated.artwork, .file(file))
        XCTAssertTrue(updated.isFavorite)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(library.songs(in: retained.id), [original.replacingArtwork(from: image)])
        XCTAssertEqual(library.onlineErrors[retained.id], "Offline")
        XCTAssertTrue(library.loadingPlaylistIDs.contains(retained.id))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "42")
        XCTAssertEqual(library.playlist(retained.id)?.artwork, .file(file), "Metadata refresh preserves a cover that arrived after retention")
        XCTAssertEqual(library.songs(in: retained.id), [original.replacingArtwork(from: image)])
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: persistence, songs: []))
        restored.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "42")
        XCTAssertEqual(restored.playlist(retained.id)?.artwork, .playlist, "The initial retained snapshot predates image delivery")
        HomeMusicIntegration.updateRetainedArtwork(in: restored, home: home, owner: "42")
        XCTAssertEqual(restored.playlist(retained.id)?.artwork, .file(file), "Cold restoration reuses the Home image cache without a download callback")
        XCTAssertEqual(restored.songs(in: retained.id).first?.artwork, .file(file))
        restored.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "other")
        XCTAssertTrue(restored.playlists.isEmpty)
        XCTAssertTrue(restored.songs(in: retained.id).isEmpty)
        let changes = Mutex(0)
        withObservationTracking { _ = library.playlists; _ = library.songs(in: retained.id) } onChange: {
            changes.withLock { $0 += 1 }
        }
        HomeMusicIntegration.updateRetainedArtwork(in: library, home: home, owner: "other", urls: [remote], songs: [original.id: original])
        XCTAssertEqual(changes.withLock { $0 }, 0)
    }

    private func makeSongLibrary() -> SongLibrary {
        SongLibrary(songs: [], defaults: UserDefaults(suiteName: "IntegrationPublicationTests.\(UUID().uuidString)")!)
    }

    private func song(_ id: String, title: String = "Song", artwork: Artwork = .missing) -> LibrarySongItem {
        .init(id: "netease:42:\(id)", title: title, artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: artwork)
    }
}
