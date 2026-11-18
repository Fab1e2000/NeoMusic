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
        XCTAssertEqual(HomeQuickAction.allCases.filter(\.opensDetail), [.dailySongs, .hotSongs, .privateRadar])
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
        XCTAssertEqual(changes.withLock { $0 }, 0, "Artwork arrival leaves the source list stable")
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
        let pageCache = NeteasePageCache(directory: directory)
        try await pageCache.save([item], scope: "public", key: "recommendations")
        try await pageCache.save(NeteasePlaylistDetail(playlist: item, songs: [track], addedTimes: [:]),
                                 scope: "public", key: "playlist:\(item.id)")
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
        XCTAssertTrue(integration.cachedSongs.isEmpty)
        let changes = Mutex(0)
        withObservationTracking {
            _ = integration.cachedSongs
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        home.onChange?()
        home.onArtworkChange?([URL(string: "https://example.com/unrelated-cover.jpg")!])
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertTrue(integration.cachedSongs.isEmpty)
    }

    func testRetainedHomePlaylistReceivesLateArtworkWithoutReopeningDetail() async throws {
        final class RetainedArtworkProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try XCTUnwrap(URL(string: "https://example.com/retained.jpg"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetainedArtworkProtocol.self]
        let artworkCache = NeteaseArtworkCache(directory: directory.appendingPathComponent("Artwork"),
                                               session: URLSession(configuration: config))
        let file = try await artworkCache.imageURL(for: remote, scope: "42")
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Home list", creator: "Creator", creatorID: 42,
                                            artworkURL: remote, trackCount: 1, isFavorites: false)
        let track = NeteaseMusicSong(id: 9, title: "Song", artist: "Artist", album: "Album", artworkURL: remote, duration: 20)
        try await NeteasePageCache(directory: directory)
            .save(NeteasePlaylistDetail(playlist: playlist, songs: [track], addedTimes: [:]), scope: "42", key: "playlist:12")
        let home = NeteaseHomeStore(directory: directory, artworkCache: artworkCache)
        let session = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test"))
        await home.activate(session, refresh: false)
        _ = try await home.restoreCachedDetail(id: 12)
        let library = PlaylistLibrary(playlists: [])
        let persistence = directory.appendingPathComponent("playlists.json")
        XCTAssertTrue(library.configurePersistence(url: persistence, songs: []))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "42")
        await library.flushPersistence()
        let pending = Artwork.deferred(id: "home:\(home.sessionRevision):\(remote.absoluteString)", placeholder: .playlist)
        let retained = LibraryPlaylistItem(id: "netease-playlist:42:12", title: "Retained title", artwork: pending,
                                           isFavorite: true, isPinned: true, sourceOwnerID: "42")
        var original = song("9", title: "Current title", artwork: pending)
        original.isFavorite = true
        library.retainOnlinePlaylist(retained, songs: [original])
        await library.flushPersistence()
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
        await library.flushPersistence()
        XCTAssertEqual(library.playlist(retained.id)?.artwork, .file(file), "Metadata refresh preserves a cover that arrived after retention")
        XCTAssertEqual(library.songs(in: retained.id), [original.replacingArtwork(from: image)])
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: persistence, songs: []))
        restored.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "42")
        await restored.flushPersistence()
        XCTAssertEqual(restored.playlist(retained.id)?.artwork, .playlist, "The initial retained snapshot predates image delivery")
        HomeMusicIntegration.updateRetainedArtwork(in: restored, home: home, owner: "42")
        XCTAssertEqual(restored.playlist(retained.id)?.artwork, .file(file), "Cold restoration reuses the Home image cache without a download callback")
        XCTAssertEqual(restored.songs(in: retained.id).first?.artwork, .file(file))
        restored.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "other")
        await restored.flushPersistence()
        XCTAssertTrue(restored.playlists.isEmpty)
        XCTAssertTrue(restored.songs(in: retained.id).isEmpty)
        let changes = Mutex(0)
        withObservationTracking { _ = library.playlists; _ = library.songs(in: retained.id) } onChange: {
            changes.withLock { $0 += 1 }
        }
        HomeMusicIntegration.updateRetainedArtwork(in: library, home: home, owner: "other", urls: [remote], songs: [original.id: original])
        XCTAssertEqual(changes.withLock { $0 }, 0)
    }

    func testArtworkBurstOnlyInvalidatesItsImageReaders() throws {
        let tracks = (0..<100).map { song(String($0)) }
        let playlists = PlaylistLibrary(playlists: [])
        let item = LibraryPlaylistItem(id: "home:playlist:burst", title: "List", artwork: .playlist, isReadOnlyContent: true)
        playlists.setExternalCollection(item: item, songs: tracks)
        let catalog = makeSongLibrary()
        catalog.replaceExternalSongs(tracks, source: "home")
        let listChanges = Mutex(0), imageChanges = Mutex(0)
        let projection = LibraryListProjection<PlaylistDetailView.ProjectionInput, PlaylistDetailView.Projection>()
        withObservationTracking {
            let input = PlaylistDetailView.ProjectionInput(tracks: playlists.songs(in: item.id), query: "", sort: .title)
            _ = projection.value(for: input, calculate: input.calculate)
            _ = catalog.allSongs
            _ = catalog.song(id: tracks[0].id)?.title
        } onChange: { listChanges.withLock { $0 += 1 } }
        for track in tracks {
            withObservationTracking { _ = track.artwork } onChange: { imageChanges.withLock { $0 += 1 } }
        }
        for (index, track) in tracks.enumerated() {
            var replacement = track
            replacement.artwork = .file(URL(fileURLWithPath: "/tmp/cover-\(index).jpg"))
            catalog.updateOnlineArtwork([track.id: replacement], source: "home")
            playlists.updateArtwork(songs: [track.id: replacement])
        }
        XCTAssertEqual(imageChanges.withLock { $0 }, 100)
        XCTAssertEqual(listChanges.withLock { $0 }, 0)
        XCTAssertEqual(playlists.songs(in: item.id).map(\.id), tracks.map(\.id))
        // A cache eviction still updates the image, while structural removal updates the list.
        let invalidations = Mutex(0)
        withObservationTracking { _ = tracks[0].artwork } onChange: { invalidations.withLock { $0 += 1 } }
        let missing = song("0", artwork: .deferred(id: "new-session:cover", placeholder: .missing))
        playlists.updateArtwork(songs: [missing.id: missing])
        XCTAssertEqual(invalidations.withLock { $0 }, 1)
        XCTAssertEqual(tracks[0].artwork, missing.artwork)
        catalog.replaceExternalSongs([], source: "home")
        XCTAssertEqual(listChanges.withLock { $0 }, 1)
    }

    func testArtworkPropertyEditsKeepSongValueSemantics() {
        let original = song("1")
        var edited = original
        edited.artwork = .favorites
        edited.artworkURL = URL(fileURLWithPath: "/tmp/edited.jpg")
        XCTAssertEqual(original.artwork, .missing)
        XCTAssertNil(original.artworkURL)
        XCTAssertNotEqual(original, edited)
    }

    func testCardArtworkArrivalPreservesCollectionsAndCopySemantics() {
        let model = HomeContentModel()
        model.sections = [.init(id: "cards", title: "Cards", kind: .covers, items: (0..<100).map {
            .init(id: String($0), title: "Card", subtitle: "Artist", artwork: .missing, action: .playSong)
        })]
        let before = model.sections
        let listChanges = Mutex(0), imageChanges = Mutex(0)
        withObservationTracking { _ = model.sections == before } onChange: { listChanges.withLock { $0 += 1 } }
        for item in model.sections[0].items {
            withObservationTracking { _ = item.artwork } onChange: { imageChanges.withLock { $0 += 1 } }
            item.$artwork.update(.file(URL(fileURLWithPath: "/tmp/card-\(item.id).jpg")))
        }
        XCTAssertEqual(listChanges.withLock { $0 }, 0)
        XCTAssertEqual(imageChanges.withLock { $0 }, 100)
        var edited = model.sections[0].items[0]
        edited.artwork = .favorites
        XCTAssertNotEqual(edited.artwork, model.sections[0].items[0].artwork)
        let image = model.sections[0].items[0]
        let eviction = Mutex(0)
        withObservationTracking { _ = image.artwork } onChange: { eviction.withLock { $0 += 1 } }
        image.$artwork.update(.missing)
        XCTAssertEqual(eviction.withLock { $0 }, 1)
        model.sections = []
        XCTAssertEqual(listChanges.withLock { $0 }, 1)
    }

    private func makeSongLibrary() -> SongLibrary {
        SongLibrary(songs: [], defaults: UserDefaults(suiteName: "IntegrationPublicationTests.\(UUID().uuidString)")!)
    }

    private func song(_ id: String, title: String = "Song", artwork: Artwork = .missing) -> LibrarySongItem {
        .init(id: "netease:42:\(id)", title: title, artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: artwork)
    }
}

@MainActor final class FavoritePublicationTests: XCTestCase {
    func testFavoriteDeltaPreservesMetadataAndRollsBackOrdering() {
        let defaults = UserDefaults(suiteName: "FavoritePublicationTests.\(UUID().uuidString)")!
        let library = SongLibrary(songs: [], defaults: defaults)
        let first = song(1), second = song(2)
        library.replaceOnline([first, second])
        var liked = second
        liked.isFavorite = true
        liked.favoriteAddedAt = Date(timeIntervalSince1970: 10)
        library.updateOnlineFavorites([liked.id: liked], order: [liked.id])
        XCTAssertEqual(library.onlineSongs.map(\.id), [second.id, first.id])
        XCTAssertTrue(library.onlineSongs[0].isFavorite)
        XCTAssertEqual(library.onlineSongs[1], first)
        library.updateOnlineFavorites([second.id: second], order: [])
        XCTAssertEqual(library.onlineSongs, [first, second])
    }

    func testFavoriteOrderUpdatesWithoutReplacementAndAddsKnownMissingSong() {
        let defaults = UserDefaults(suiteName: "FavoritePublicationTests.\(UUID().uuidString)")!
        let library = SongLibrary(songs: [], defaults: defaults)
        let first = song(1), second = song(2)
        library.replaceOnline([first, second])
        library.updateOnlineFavorites([:], order: [second.id])
        XCTAssertEqual(library.onlineSongs.map(\.id), [second.id, first.id])
        library.updateOnlineFavorites([:], order: [])
        XCTAssertEqual(library.onlineSongs, [first, second])
        var third = song(3)
        third.isFavorite = true
        library.updateOnlineFavorites([third.id: third], order: [third.id])
        XCTAssertEqual(library.onlineSongs, [third, first, second])
    }

    func testBatchCatalogUpdateEmitsSingleRebuildAndIsolatesFavoritesObserver() {
        let defaults = UserDefaults(suiteName: "FavoriteBatchTests.\(UUID().uuidString)")!
        let library = SongLibrary(songs: [], defaults: defaults)
        var liked = song(1)
        liked.isFavorite = true
        let local = LibrarySongItem(id: "local.flac", title: "Local", artist: "Artist", album: "Album",
                                    albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        library.replace([local])
        library.replaceOnline([liked])

        let allChanges = Mutex(0)
        let favoriteChanges = Mutex(0)
        withObservationTracking { _ = library.allSongs } onChange: { allChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = library.favoriteSongs } onChange: { favoriteChanges.withLock { $0 += 1 } }

        var updatedLocal = local
        updatedLocal.duration = 240
        let searchResult = song(2) // not favorite
        library.applyBatch(localMetadata: [local.id: updatedLocal],
                           externalSongs: [searchResult],
                           externalSource: "search",
                           forceCatalogRefresh: true)
        XCTAssertEqual(allChanges.withLock { $0 }, 1)
        XCTAssertEqual(favoriteChanges.withLock { $0 }, 0)
        XCTAssertEqual(library.favoriteSongs.map(\.id), [liked.id])
    }

    func testAsyncListProjectionOffloadsBackgroundWorkAndHonorsCancellation() async {
        let projection = AsyncListProjection<Int, Int>()
        XCTAssertEqual(projection.currentValue(for: 1, fastPath: { _ in nil }, synchronousInitial: { $0 * 10 }), 10)
        await projection.computeIfNeeded(for: 1, fastPath: { _ in nil }, background: { 10 }, finish: { $0 })
        XCTAssertEqual(projection.committedOutput, 10)

        let cancelled = Task {
            await projection.computeIfNeeded(
                for: 2,
                fastPath: { _ in nil },
                background: {
                    Thread.sleep(forTimeInterval: 0.05)
                    return 20
                },
                finish: { $0 }
            )
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(projection.committedOutput, 10)

        await projection.computeIfNeeded(
            for: 3,
            fastPath: { _ in nil },
            background: {
                XCTAssertFalse(Thread.isMainThread)
                return 30
            },
            finish: { $0 }
        )
        XCTAssertEqual(projection.committedOutput, 30)
    }

    func testAsyncListProjectionPlaceholderAvoidsBlockingInitialFrameAndTracksResolution() async {
        let projection = AsyncListProjection<Int, [Int]>()
        XCTAssertFalse(projection.isResolved(for: 1, fastPath: { _ in nil }))
        XCTAssertEqual(projection.currentValue(for: 1, fastPath: { _ in nil }, placeholder: { _ in [] }), [])

        await projection.computeIfNeeded(
            for: 1,
            fastPath: { _ in nil },
            background: {
                XCTAssertFalse(Thread.isMainThread)
                return [1, 2, 3]
            },
            finish: { $0 }
        )
        XCTAssertTrue(projection.isResolved(for: 1, fastPath: { _ in nil }))
        XCTAssertEqual(projection.currentValue(for: 2, fastPath: { _ in nil }, placeholder: { _ in [] }), [1, 2, 3],
                       "Changing controls keeps previous list visible instead of flashing placeholder")
        XCTAssertFalse(projection.isResolved(for: 2, fastPath: { _ in nil }),
                       "A retained result for a previous input must never resolve the new input")

        XCTAssertTrue(projection.isResolved(for: 0, fastPath: { _ in [0] }))
        XCTAssertEqual(projection.currentValue(for: 0, fastPath: { _ in [0] }, placeholder: { _ in [] }), [0])
    }

    func testAsyncListProjectionCancelsSupersededWorkAndNeverPublishesStaleInputs() async {
        let projection = AsyncListProjection<Int, [Int]>()
        await projection.computeIfNeeded(for: 1, fastPath: { _ in nil }, background: { [1, 2, 3] }, finish: { $0 })
        XCTAssertTrue(projection.isResolved(for: 1, fastPath: { _ in nil }))

        let started = expectation(description: "background started")
        let observedCancellation = Mutex(0)
        let stale = Task {
            await projection.computeIfNeeded(
                for: 2,
                fastPath: { _ in nil },
                background: {
                    started.fulfill()
                    while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                    observedCancellation.withLock { $0 += 1 }
                    return [20]
                },
                finish: { $0 }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        stale.cancel()
        await stale.value
        XCTAssertGreaterThan(observedCancellation.withLock { $0 }, 0,
                             "A superseded computation must receive cooperative cancellation")
        XCTAssertEqual(projection.committedOutput, [1, 2, 3], "A cancelled task must not publish its stale result")
        XCTAssertFalse(projection.isResolved(for: 2, fastPath: { _ in nil }))

        // An empty snapshot for the previous input must not surface as the new input's empty state.
        await projection.computeIfNeeded(for: 2, fastPath: { _ in nil }, background: { [Int]() }, finish: { $0 })
        XCTAssertEqual(projection.currentValue(for: 3, fastPath: { _ in nil }, placeholder: { _ in [] }), [],
                       "The previous (empty) snapshot stays visible while the new input computes")
        XCTAssertFalse(projection.isResolved(for: 3, fastPath: { _ in nil }),
                       "The page must not show the empty state before the new input resolves")

        await projection.computeIfNeeded(for: 3, fastPath: { _ in nil }, background: { [30] }, finish: { $0 })
        XCTAssertTrue(projection.isResolved(for: 3, fastPath: { _ in nil }))
        XCTAssertFalse(projection.isResolved(for: 2, fastPath: { _ in nil }))
        XCTAssertEqual(projection.currentValue(for: 3, fastPath: { _ in nil }, placeholder: { _ in [] }), [30])
    }

    func testTitleSectionSortKeyASCIIFastPathAndCJKSorting() {
        XCTAssertEqual(TitleSection<String>.sortKey("Alpha Track 01"), "alpha track 01")
        XCTAssertEqual(TitleSection<String>.sortKey("Artist\u{0001}Album\u{0001}0001"), "artist\u{0001}album\u{0001}0001")
        let grouped = TitleSection.group(["周杰伦", "apple", "123"], by: { $0 })
        XCTAssertEqual(grouped.map(\.letter), ["A", "Z", "#"])
    }

    func testDownloadMetadataPlanClassifiesExistingAndMissingFilesOffMainThread() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("网易云/Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presentPath = "网易云/Artist/Album/1.flac"
        let missingPath = "网易云/Artist/Album/2.flac"
        let traversalPath = "网易云/../escape.flac"
        try Data("audio".utf8).write(to: root.appendingPathComponent(presentPath))

        func makeRecord(id: Int64, path: String, albumID: Int64) -> NeteaseDownloadRecord {
            let song = NeteaseMusicSong(id: id, title: "Song \(id)", artist: "Artist", album: "Album \(albumID)",
                                        artworkURL: nil, duration: 180, albumID: albumID)
            let meta = NeteaseDownloadSong(song: song, albumArtist: "Artist", trackNumber: Int(id), discNumber: 1)
            return NeteaseDownloadRecord(metadata: meta, relativePath: path, lyricsRelativePath: nil,
                                         quality: .lossless, downloadedAt: Date(), ownerID: 42)
        }
        let records: [Int64: NeteaseDownloadRecord] = [
            1: makeRecord(id: 1, path: presentPath, albumID: 20),
            2: makeRecord(id: 2, path: missingPath, albumID: 10),
            3: makeRecord(id: 3, path: traversalPath, albumID: 30),
        ]
        let collection = NeteaseDownloadCollection(kind: .playlist, id: 77, ownerID: 42,
                                                   title: "Offline List", artist: "Me", orderedSongIDs: [1, 2])
        let plan = await Task.detached {
            DownloadMusicIntegration.prepareMetadataPlan(
                records: records,
                collections: [collection.key: collection],
                musicDirectory: root
            )
        }.value

        XCTAssertEqual(plan.availableSongIDs, [1])
        XCTAssertEqual(Set(plan.missingPaths), [missingPath, traversalPath])
        XCTAssertEqual(Set(plan.unavailableRecordIDs), [2, 3])
        XCTAssertEqual(plan.byPath[presentPath], 1)
        XCTAssertEqual(plan.albumGroups.map(\.albumID), [20])
        XCTAssertEqual(plan.collectionPlaylists.map(\.id), ["downloaded:playlist:77"])
    }

    func testSelectiveReconciliationUpdatesCatalogRevisionAndSkipsReadOnlyPlaylists() throws {
        let library = SongLibrary(songs: [], defaults: UserDefaults(suiteName: "SelectiveReconcile.\(UUID().uuidString)")!)
        let revision0 = library.catalogRevision
        let onlineTrack = song(1)
        XCTAssertTrue(library.replaceOnline([onlineTrack]))
        let revision1 = library.catalogRevision
        XCTAssertGreaterThan(revision1, revision0)
        XCTAssertFalse(library.replaceOnline([onlineTrack]))
        XCTAssertEqual(library.catalogRevision, revision1)

        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlists = PlaylistLibrary(playlists: [
            LibraryPlaylistItem(id: "local", title: "Local", artwork: .playlist)
        ])
        XCTAssertTrue(playlists.configurePersistence(url: root.appendingPathComponent("playlists.json"), songs: []))
        playlists.restoreOnlineIdentity(ownerID: "42")
        let placeholderTrack = LibrarySongItem.unavailable(onlineTrack.id)
        playlists.addSongs([placeholderTrack], to: "local")
        let readOnlyItem = LibraryPlaylistItem(id: "netease-playlist:42:99", title: "Online", artwork: .playlist, sourceOwnerID: "42")
        playlists.replaceOnlinePlaylists(items: [readOnlyItem], songs: [readOnlyItem.id: [placeholderTrack]], ownerID: "42")
        playlists.reconcileOnlineSongs([onlineTrack], excludingReadOnly: true)
        XCTAssertEqual(playlists.songs(in: "local").first?.title, onlineTrack.title)
        XCTAssertEqual(playlists.songs(in: readOnlyItem.id).first?.title, placeholderTrack.title)

        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback() }
        player.reconcileAvailability(songs: [onlineTrack])
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertTrue(player.unavailableIDs.isEmpty)

        player.restoreOnlineIdentity(ownerID: "42")
        player.play([placeholderTrack], from: "Local", shuffled: false)
        let catalog = (1...200).map {
            LibrarySongItem(id: "netease:42:\($0)", title: "Catalog \($0)", artist: "Artist", album: "Album",
                            albumArtist: "Artist", trackNumber: $0, artwork: .missing)
        }
        player.reconcileAvailability(songs: catalog)
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertEqual(player.queue.first?.title, "Catalog 1")
    }

    private func song(_ id: Int) -> LibrarySongItem {
        .init(id: "netease:42:\(id)", title: "Song \(id)", artist: "Artist", album: "Album",
              albumArtist: "Artist", trackNumber: id, artwork: .missing)
    }

    func testTypedIdentitiesAndDeferredArtworkKeysRoundTripAndRejectMalformedInputs() throws {
        XCTAssertEqual(OnlineSongIdentity.format(owner: 42, song: 99), "netease:42:99")
        XCTAssertEqual(OnlineSongIdentity.parse("netease:42:99")?.owner, 42)
        XCTAssertEqual(OnlineSongIdentity.parse("netease:42:99")?.song, 99)
        XCTAssertNil(OnlineSongIdentity.parse("netease:search-guest:99"))
        XCTAssertEqual(OnlineSongIdentity.parseOwnerAndSong("netease:search-guest:99")?.ownerID, "search-guest")
        XCTAssertEqual(OnlineSongIdentity.parseOwnerAndSong("netease:search-guest:99")?.songID, 99)
        XCTAssertNil(OnlineSongIdentity.parseOwnerAndSong("local/song.flac"))

        XCTAssertEqual(PlaylistRouteIdentity("favorites"), .favorites)
        XCTAssertEqual(PlaylistRouteIdentity("netease-playlist:42:100"), .account(ownerID: "42", playlistID: 100))
        XCTAssertEqual(PlaylistRouteIdentity("home:playlist:100"), .homePlaylist(playlistID: 100))
        XCTAssertEqual(PlaylistRouteIdentity("home:daily:42:2026-11-18"), .daily(ownerID: "42", date: "2026-11-18"))
        XCTAssertEqual(PlaylistRouteIdentity("downloaded:playlist:100"), .downloaded(playlistID: 100))
        XCTAssertEqual(PlaylistRouteIdentity("my-local-list"), .local(id: "my-local-list"))
        XCTAssertEqual(PlaylistRouteIdentity("home:playlist:100").onlinePlaylistNumber, 100)
        XCTAssertTrue(PlaylistRouteIdentity("home:daily:42:2026-11-18").isHomeRoute)
        XCTAssertFalse(PlaylistRouteIdentity("netease-playlist:42:100").isHomeRoute)

        XCTAssertEqual(CatalogRouteIdentity("catalog:artist:7"), .artist(7))
        XCTAssertEqual(CatalogRouteIdentity("catalog:album:8"), .album(8))
        XCTAssertNil(CatalogRouteIdentity("local-album"))

        let session = UUID()
        let url = try XCTUnwrap(URL(string: "https://p1.music.126.net/cover.jpg?param=200y200"))
        let artworkKey = DeferredArtworkKey(domain: .home, session: session, url: url)
        let parsedKey = try XCTUnwrap(DeferredArtworkKey(rawValue: artworkKey.rawValue))
        XCTAssertTrue(parsedKey.matches(domain: .home, session: session))
        XCTAssertEqual(parsedKey.remoteURL, url)

        let playlistKey = DeferredArtworkKey(domain: .homePlaylist, session: session, playlistID: 88)
        let parsedPlaylistKey = try XCTUnwrap(DeferredArtworkKey(rawValue: playlistKey.rawValue))
        XCTAssertTrue(parsedPlaylistKey.matches(domain: .homePlaylist, session: session))
        XCTAssertEqual(parsedPlaylistKey.playlistID, 88)

        let registry = AppTabNavigationRegistry()
        let playlistBridge = registry.navigation(for: .playlist("p1"))
        XCTAssertTrue(registry.bridge(for: "p1") === playlistBridge)
        registry.prunePlaylists(keeping: [])
        XCTAssertNil(registry.items["p1"])
    }
}
