import XCTest
import Synchronization
@testable import NeoMusic

@MainActor final class NeteaseLoadingPerformanceTests: XCTestCase {
    private func session(_ id: Int64 = 42) throws -> NeteaseSavedSession {
        .init(profile: .init(userID: id, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "session-\(id)"))
    }
    private func network(_ responses: [String: String], blocked: Set<String> = [], statuses: [String: Int] = [:],
                         started: @escaping @Sendable (String) -> Void = { _ in },
                         stopped: @escaping @Sendable (String) -> Void = { _ in },
                         completed: @escaping @Sendable (String) -> Void = { _ in }) -> URLSession {
        LoadingProtocol.state.withLock { $0 = .init(responses: responses, blocked: blocked, statuses: statuses, started: started, stopped: stopped, completed: completed) }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [LoadingProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func client(_ network: URLSession) -> NeteaseMusicClient {
        NeteaseMusicClient(transport: NeteaseAccountClient(session: network))
    }

    private func playlistFixtures(count: Int, favorites: Bool = false) throws -> [String: String] {
        let ids = (1...count).map(Int64.init)
        func encoded(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func song(_ id: Int64) -> [String: Any] {
            ["id": id, "name": "Song \(id)", "ar": [["id": 1, "name": "Artist"]], "al": ["name": "Album"], "dt": 60_000]
        }
        var playlist: [String: Any] = ["id": 7, "name": "Library", "creator": ["userId": 42, "nickname": "Test"], "trackCount": count]
        if favorites { playlist["specialType"] = 5 }
        let summary = try encoded(["code": 200, "playlist": [playlist], "more": false])
        playlist["trackIds"] = ids.map { ["id": $0, "at": 1_000] }
        playlist["tracks"] = ids.prefix(100).map(song)
        return [
            "/eapi/user/playlist": summary,
            "/eapi/song/like/get": try encoded(["code": 200, "ids": favorites ? ids : []]),
            "/eapi/v6/playlist/detail": try encoded(["code": 200, "playlist": playlist]),
            "/eapi/v3/song/detail": try encoded(["code": 200, "songs": ids.map(song)]),
            "/eapi/radio/like": #"{"code":200}"#
        ]
    }

    func testLibraryPlaylistPagesAndPlaybackReuseAlreadyLoadedSongs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = network(try playlistFixtures(count: 205))
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session())
        await store.loadPlaylist(id: 7)
        XCTAssertEqual(store.playlistTracks[7], Array(1...100).map(Int64.init))
        XCTAssertTrue(store.hasMorePlaylist(id: 7))
        XCTAssertEqual(store.playlistTotalCount(id: 7), 205)
        await store.loadPlaylist(id: 7)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.filter { $0 == "/eapi/v6/playlist/detail" }.count }, 1)
        await store.loadMorePlaylist(id: 7)
        XCTAssertEqual(store.playlistTracks[7]?.count, 200)
        let completed = await store.completePlaylist(id: 7)
        XCTAssertTrue(completed)
        XCTAssertEqual(store.playlistTracks[7], Array(1...205).map(Int64.init))
        XCTAssertFalse(store.hasMorePlaylist(id: 7))
        let requests = LoadingProtocol.state.withLock { $0.startedPaths }
        XCTAssertEqual(requests.filter { $0 == "/eapi/v3/song/detail" }.count, 2)
        let reused = await store.completePlaylist(id: 7)
        XCTAssertTrue(reused)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths }, requests)
        await store.waitForCacheWrites()
        await store.invalidate()

        let restored = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await restored.activate(try session(), refresh: false)
        XCTAssertEqual(restored.playlists.map(\.id), [7])
        XCTAssertNil(restored.playlistTracks[7])
        XCTAssertTrue(restored.songs.isEmpty)
        let restoredComplete = await restored.completePlaylist(id: 7)
        XCTAssertTrue(restoredComplete)
        XCTAssertEqual(restored.playlistTracks[7], Array(1...205).map(Int64.init))
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths }, requests)
        await restored.invalidate()
    }

    func testFavoritesRestoreOnlyPreviewAndReuseFullDiskCacheForLikeMutation() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = network(try playlistFixtures(count: 205, favorites: true))
        defer { network.invalidateAndCancel() }
        let original = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await original.activate(try session())
        let complete = await original.completePlaylist(id: 7)
        XCTAssertTrue(complete)
        await original.waitForCacheWrites()
        await original.invalidate()
        let requests = LoadingProtocol.state.withLock { $0.startedPaths }

        let restored = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await restored.activate(try session(), refresh: false)
        XCTAssertEqual(restored.playlistTracks[7], Array(1...100).map(Int64.init))
        XCTAssertEqual(restored.songs.count, 100)
        XCTAssertEqual(restored.playlistTotalCount(id: 7), 205)
        XCTAssertTrue(restored.hasMorePlaylist(id: 7))
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths }, requests)

        try await restored.setLiked(songID: 1, liked: false)
        XCTAssertEqual(restored.playlistTracks[7], Array(2...205).map(Int64.init))
        let reused = await restored.completePlaylist(id: 7)
        XCTAssertTrue(reused)
        XCTAssertEqual(Array(LoadingProtocol.state.withLock { $0.startedPaths }.dropFirst(requests.count)), ["/eapi/radio/like"])
        await restored.invalidate()
    }

    func testCachedPlaylistPublishesBeforeRefreshAndSurvivesRefreshFailure() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/eapi/v6/playlist/detail"
        let waiting = expectation(description: "Refresh waits after cache publication")
        let network = network(try playlistFixtures(count: 205), blocked: [path], statuses: [path: 503],
                              started: { if $0 == path { waiting.fulfill() } })
        defer { network.invalidateAndCancel() }
        let playlist = NeteaseMusicPlaylist(id: 7, title: "Saved", creator: "Test", creatorID: 42, artworkURL: nil, trackCount: 1, isFavorites: false)
        let song = NeteaseMusicSong(id: 1, title: "Cached song", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, unavailable: false)
        let cache = NeteasePageCache(directory: root)
        try await cache.save(NeteasePlaylistDetail(playlist: playlist, songs: [song], addedTimes: [:]), scope: "42", key: "playlist:7")
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session(), refresh: false)
        XCTAssertTrue(store.songs.isEmpty)

        let refresh = Task { await store.loadPlaylist(id: 7) }
        await fulfillment(of: [waiting], timeout: 3)
        XCTAssertEqual(store.playlistTracks[7], [1])
        XCTAssertEqual(store.songs[1]?.title, "Cached song")
        let completeWithoutRefresh = expectation(description: "Cached playback does not wait for refresh")
        let completion = Task {
            let result = await store.completePlaylist(id: 7)
            completeWithoutRefresh.fulfill()
            return result
        }
        await fulfillment(of: [completeWithoutRefresh], timeout: 3)
        LoadingProtocol.release(path)
        await refresh.value
        XCTAssertNotNil(store.playlistErrors[7])
        XCTAssertEqual(store.playlistTracks[7], [1])
        let completed = await completion.value
        XCTAssertTrue(completed)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths }, [path])
        await store.invalidate()
    }

    func testNextPageJoiningCachedPageRefreshStillLoadsNextPage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = network(try playlistFixtures(count: 205))
        defer { network.invalidateAndCancel() }
        let initial = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await initial.activate(try session())
        await initial.loadPlaylist(id: 7)
        await initial.waitForCacheWrites()
        await initial.invalidate()

        let path = "/eapi/v6/playlist/detail"
        let waiting = expectation(description: "Cached first page refresh is pending")
        LoadingProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { waiting.fulfill() } }
        }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session(), refresh: false)
        let refresh = Task { await store.loadPlaylist(id: 7) }
        await fulfillment(of: [waiting], timeout: 3)
        XCTAssertEqual(store.playlistTracks[7]?.count, 100)
        let joined = expectation(description: "Pagination joins refresh")
        let nextPage = Task { joined.fulfill(); await store.loadMorePlaylist(id: 7) }
        await fulfillment(of: [joined], timeout: 3)
        LoadingProtocol.release(path)
        await refresh.value
        await nextPage.value
        XCTAssertEqual(store.playlistTracks[7]?.count, 200)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.filter { $0 == "/eapi/v3/song/detail" }.count }, 1)
        await store.invalidate()
    }

    func testCompletionJoiningFirstPageFinishesEntirePlaylist() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/eapi/v6/playlist/detail"
        let started = expectation(description: "First page waiting")
        let network = network(try playlistFixtures(count: 205), blocked: [path], started: { if $0 == path { started.fulfill() } })
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session())
        let firstPage = Task { await store.loadPlaylist(id: 7) }
        await fulfillment(of: [started], timeout: 3)
        let complete = Task { await store.completePlaylist(id: 7) }
        await Task.yield()
        LoadingProtocol.release(path)
        await firstPage.value
        let success = await complete.value
        XCTAssertTrue(success)
        XCTAssertFalse(store.hasMorePlaylist(id: 7))
        XCTAssertEqual(store.playlistTracks[7], Array(1...205).map(Int64.init))
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.filter { $0 == path }.count }, 1)
        await store.invalidate()
    }

    func testLibraryFailedNextPageRetainsFirstPageAndCanRetry() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = network(try playlistFixtures(count: 205), statuses: ["/eapi/v3/song/detail": 503])
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session())
        await store.loadPlaylist(id: 7)
        await store.loadMorePlaylist(id: 7)
        XCTAssertEqual(store.playlistTracks[7]?.count, 100)
        XCTAssertNotNil(store.playlistErrors[7])
        XCTAssertTrue(store.hasMorePlaylist(id: 7))
        LoadingProtocol.state.withLock { $0.statuses["/eapi/v3/song/detail"] = 200 }
        await store.loadMorePlaylist(id: 7)
        XCTAssertEqual(store.playlistTracks[7]?.count, 200)
        XCTAssertNil(store.playlistErrors[7])
        await store.invalidate()
    }

    func testLibraryListsPublishBeforeLikedIDsAndRefreshHonorsFreshness() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let likedPath = "/eapi/song/like/get"
        let listsReady = expectation(description: "Lists ready before likes")
        let likesStarted = expectation(description: "Likes requested concurrently")
        let network = network(try playlistFixtures(count: 1), blocked: [likedPath], started: { if $0 == likedPath { likesStarted.fulfill() } })
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        var published = false
        store.onChange = { if !published, store.playlists.first?.id == 7 { published = true; listsReady.fulfill() } }
        let saved = try session()
        let activation = Task { await store.activate(saved) }
        await fulfillment(of: [listsReady, likesStarted], timeout: 3)
        XCTAssertTrue(store.isLoading)
        LoadingProtocol.state.withLock { $0.started = { _ in } }
        LoadingProtocol.release(likedPath)
        await activation.value
        let requests = LoadingProtocol.state.withLock { $0.startedPaths.count }
        await store.refresh()
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.count }, requests)
        await store.refresh(force: true)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.count }, requests + 2)
        await store.invalidate()
    }

    func testUnlikingSongUpdatesFavoritesWithoutReloadingWholePlaylist() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = network(try playlistFixtures(count: 205, favorites: true))
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session())
        let before = LoadingProtocol.state.withLock { $0.startedPaths }
        try await store.setLiked(songID: 1, liked: false)
        XCTAssertFalse(store.likedIDs.contains(1))
        XCTAssertEqual(store.playlistTracks[7], Array(2...100).map(Int64.init))
        XCTAssertEqual(store.playlistTotalCount(id: 7), 204)
        XCTAssertTrue(store.hasMorePlaylist(id: 7))
        let after = LoadingProtocol.state.withLock { $0.startedPaths }
        XCTAssertEqual(Array(after.dropFirst(before.count)), ["/eapi/radio/like"])
        await store.invalidate()
    }

    func testAccountSwitchCancelsPlaylistCompletionAndRetainsNoOldPage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/eapi/v3/song/detail"
        let started = expectation(description: "Completion started")
        let stopped = expectation(description: "Completion cancelled")
        started.expectedFulfillmentCount = 2
        stopped.expectedFulfillmentCount = 2
        let network = network(try playlistFixtures(count: 205), blocked: [path],
            started: { if $0 == path { started.fulfill() } }, stopped: { if $0 == path { stopped.fulfill() } })
        defer { network.invalidateAndCancel() }
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session())
        await store.loadPlaylist(id: 7)
        let completion = Task { await store.completePlaylist(id: 7) }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try session(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        let result = await completion.value
        XCTAssertFalse(result)
        XCTAssertEqual(store.userID, 99)
        XCTAssertTrue(store.songs.isEmpty)
        XCTAssertNil(store.playlistTracks[7])
        await store.invalidate()
    }

    func testLibraryArtworkEvictionPublishesInvalidationAndReloadsOnDemand() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = URL(string: "https://fixture.test/first")!
        let second = URL(string: "https://fixture.test/second")!
        let network = network([first.path: "image", second.path: "image"])
        defer { network.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: root.appendingPathComponent("Artwork"), session: network, countLimit: 1)
        let store = NeteaseMusicStore(client: client(network), directory: root, artworkCache: cache)
        await store.activate(try session(), refresh: false)
        var invalidated: Set<URL> = []
        store.onArtworkChange = { urls in
            invalidated.formUnion(urls.filter { store.cachedArtworkURL($0) == nil })
        }
        _ = try await store.artwork(first)
        _ = try await store.artwork(second)
        XCTAssertEqual(invalidated, [first])
        XCTAssertNil(store.cachedArtworkURL(first))
        XCTAssertNotNil(store.cachedArtworkURL(second))
        _ = try await store.artwork(first)
        XCTAssertNotNil(store.cachedArtworkURL(first))
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.filter { $0 == first.path }.count }, 2)
        await store.invalidate()
    }

    func testAccountStoresAndDailyRecommendationsProgressWhileOtherEndpointsWait() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recommendationsPath = "/eapi/v1/discovery/recommend/resource"
        let artistsPath = "/eapi/artist/sublist"
        let recommendationsStarted = expectation(description: "Recommendations started")
        let artistsStarted = expectation(description: "Subscriptions started")
        let libraryReady = expectation(description: "Library loaded independently")
        let dailyReady = expectation(description: "Daily songs loaded independently")
        let network = network([
            recommendationsPath: #"{"code":200,"recommend":[]}"#,
            artistsPath: #"{"code":200,"data":[],"hasMore":false}"#,
            "/eapi/album/sublist": #"{"code":200,"data":[],"hasMore":false}"#,
            "/eapi/v3/discovery/recommend/songs": #"{"code":200,"data":{"dailySongs":[{"id":9,"name":"Daily","ar":[],"al":{"name":"Album"},"dt":1000}]}}"#,
            "/eapi/user/playlist": #"{"code":200,"playlist":[{"id":7,"name":"Library","creator":{"userId":42,"nickname":"Test"},"trackCount":0}],"more":false}"#,
            "/eapi/song/like/get": #"{"code":200,"ids":[]}"#
        ], blocked: [recommendationsPath, artistsPath], started: { path in
            if path == recommendationsPath { recommendationsStarted.fulfill() }
            if path == artistsPath { artistsStarted.fulfill() }
        })
        let home = NeteaseHomeStore(client: client(network), directory: root.appendingPathComponent("home"), artworkSession: network)
        let artists = NeteaseArtistStore(client: client(network), directory: root.appendingPathComponent("artists"), artworkSession: network)
        let music = NeteaseMusicStore(client: client(network), directory: root.appendingPathComponent("music"), artworkSession: network)
        var sawLibrary = false, sawDaily = false
        music.onChange = {
            if !sawLibrary, music.playlists.first?.id == 7 { sawLibrary = true; libraryReady.fulfill() }
        }
        home.onChange = {
            if !sawDaily, home.daily?.songs.first?.id == 9 { sawDaily = true; dailyReady.fulfill() }
        }
        let saved = try session()
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, music: music, home: home, artists: artists)
        let restore = Task { await account.restore() }
        await fulfillment(of: [recommendationsStarted, artistsStarted, libraryReady, dailyReady], timeout: 3)
        XCTAssertTrue(home.recommendations.isEmpty)
        XCTAssertTrue(sawLibrary)
        XCTAssertTrue(sawDaily)
        LoadingProtocol.release(recommendationsPath)
        LoadingProtocol.release(artistsPath)
        await restore.value
        try await account.logout()
        network.invalidateAndCancel()
    }

    func testAlbumMetadataReturnsBeforeArtworkAndImageUsesOnlyArtworkNotification() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = URL(string: "https://fixture.test/cover")!
        let imageStarted = expectation(description: "Artwork started")
        let metadataReturned = expectation(description: "Metadata returned before artwork")
        let imageReady = expectation(description: "Artwork ready")
        let network = network([
            "/eapi/v1/album/7": #"{"code":200,"album":{"id":7,"name":"Album","size":0,"picUrl":"https://fixture.test/cover"},"songs":[]}"#,
            image.path: "image"
        ], blocked: [image.path], started: { if $0 == image.path { imageStarted.fulfill() } })
        let store = NeteaseArtistStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session(), refresh: false)
        var contentChanges = 0
        store.onChange = { contentChanges += 1 }
        store.onArtworkChange = { urls in
            XCTAssertEqual(urls, [image])
            XCTAssertNotNil(store.cachedArtworkURL(image))
            imageReady.fulfill()
        }
        let load = Task { await store.loadAlbum(id: 7); metadataReturned.fulfill() }
        await fulfillment(of: [imageStarted, metadataReturned], timeout: 3)
        XCTAssertEqual(store.albums[7]?.album.title, "Album")
        XCTAssertNil(store.cachedArtworkURL(image))
        let count = contentChanges
        LoadingProtocol.release(image.path)
        await fulfillment(of: [imageReady], timeout: 3)
        XCTAssertEqual(contentChanges, count)
        await load.value
        await store.invalidate()
        network.invalidateAndCancel()
    }

    func testSubscriptionsPublishIndependentlyWhenOtherCategoryFails() async throws {
        let artistsPath = "/eapi/artist/sublist", albumsPath = "/eapi/album/sublist"
        for blockedPath in [artistsPath, albumsPath] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let waiting = expectation(description: "Other subscription request is pending")
            let ready = expectation(description: "Completed subscription category is visible")
            var responses = [
                artistsPath: #"{"code":200,"data":[{"id":7,"name":"Artist"}],"hasMore":false}"#,
                albumsPath: #"{"code":200,"data":[{"id":8,"name":"Album"}],"hasMore":false}"#
            ]
            responses[blockedPath] = #"{"code":500}"#
            let network = network(responses, blocked: [blockedPath], started: {
                if $0 == blockedPath { waiting.fulfill() }
            })
            let store = NeteaseArtistStore(client: client(network), directory: root, artworkSession: network)
            await store.activate(try session(), refresh: false)
            var published = false
            store.onChange = {
                let available = blockedPath == artistsPath ? store.subscribedAlbums.first?.id == 8 : store.subscribedArtists.first?.id == 7
                if available, !published { published = true; ready.fulfill() }
            }
            let refresh = Task { await store.refresh() }
            await fulfillment(of: [waiting, ready], timeout: 3)
            LoadingProtocol.release(blockedPath)
            await refresh.value
            if blockedPath == artistsPath {
                XCTAssertEqual(store.subscribedAlbums.map(\.id), [8])
                XCTAssertNotNil(store.errors["subscriptions:artists"])
            } else {
                XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
                XCTAssertNotNil(store.errors["subscriptions:albums"])
            }
            await store.invalidate()
            network.invalidateAndCancel()
        }
    }

    func testBiographyPublishesInEitherArrivalOrderBeforeReleasesAndSimilarArtists() async throws {
        let profilePath = "/eapi/v1/artist/7", biographyPath = "/eapi/artist/introduction"
        let releasesPath = "/eapi/artist/albums/7", similarPath = "/eapi/discovery/simiArtist"
        for delayedPath in [profilePath, biographyPath] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let firstResponse = expectation(description: "First profile or biography response delivered")
            let firstPath = delayedPath == profilePath ? biographyPath : profilePath
            let biographyReady = expectation(description: "Full biography visible before other sections")
            let network = network([
                profilePath: #"{"code":200,"artist":{"id":7,"name":"Artist","briefDesc":"Brief"},"hotSongs":[]}"#,
                biographyPath: #"{"code":200,"briefDesc":"Full biography"}"#,
                releasesPath: #"{"code":200,"hotAlbums":[],"more":false}"#,
                similarPath: #"{"code":200,"artists":[]}"#
            ], blocked: [delayedPath, releasesPath, similarPath], completed: { path in
                if path == firstPath { firstResponse.fulfill() }
            })
            let store = NeteaseArtistStore(client: client(network), directory: root, artworkSession: network)
            await store.activate(try session(), refresh: false)
            var emptyPublications = 0, fullPublished = false
            store.onChange = {
                if store.details[7] == nil { emptyPublications += 1 }
                if !fullPublished, store.details[7]?.biography == "Full biography" {
                    fullPublished = true; biographyReady.fulfill()
                }
            }
            let load = Task { await store.loadArtist(id: 7) }
            await fulfillment(of: [firstResponse], timeout: 3)
            LoadingProtocol.release(delayedPath)
            await fulfillment(of: [biographyReady], timeout: 3)
            XCTAssertEqual(store.details[7]?.biography, "Full biography")
            XCTAssertEqual(emptyPublications, 0, "A biography response alone has no page content to publish")
            XCTAssertNil(store.releases[7])
            XCTAssertNil(store.similar[7])
            LoadingProtocol.release(releasesPath)
            LoadingProtocol.release(similarPath)
            await load.value
            await store.invalidate()
            network.invalidateAndCancel()
        }
    }

    func testCoverHTTPAndCacheWriteFailuresKeepMetadataUsable() async throws {
        for blockedStorage in [false, true] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sentinel = Data("Existing file".utf8)
            if blockedStorage { try sentinel.write(to: root) }
            let image = URL(string: "https://fixture.test/failed-cover")!
            let network = network([
                "/eapi/user/playlist": #"{"code":200,"playlist":[{"id":7,"name":"Library","creator":{"userId":42,"nickname":"Test"},"trackCount":0}],"more":false}"#,
                "/eapi/song/like/get": #"{"code":200,"ids":[]}"#,
                image.path: "image"
            ], statuses: [image.path: blockedStorage ? 200 : 503])
            let store = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
            var artworkChanges = 0
            store.onArtworkChange = { _ in artworkChanges += 1 }
            await store.activate(try session())
            do {
                _ = try await store.artwork(image)
                XCTFail("Failed artwork must not become ready")
            } catch {
                if !blockedStorage { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
            }
            XCTAssertEqual(store.playlists.map(\.id), [7])
            XCTAssertFalse(store.isLoading)
            XCTAssertNil(store.cachedArtworkURL(image))
            XCTAssertEqual(artworkChanges, 0)
            if blockedStorage { XCTAssertEqual(try Data(contentsOf: root), sentinel) }
            await store.invalidate()
            network.invalidateAndCancel()
        }
    }

    func testAccountSwitchCancelsArtworkBeforeOldOwnerCanCommitFiles() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = URL(string: "https://fixture.test/old-cover")!
        let started = expectation(description: "Old artwork started")
        let stopped = expectation(description: "Old artwork cancelled")
        let network = network([
            "/eapi/v1/album/7": #"{"code":200,"album":{"id":7,"name":"Old","size":0,"picUrl":"https://fixture.test/old-cover"},"songs":[]}"#,
            image.path: "image"
        ], blocked: [image.path], started: { if $0 == image.path { started.fulfill() } },
           stopped: { if $0 == image.path { stopped.fulfill() } })
        let store = NeteaseArtistStore(client: client(network), directory: root, artworkSession: network)
        await store.activate(try session(), refresh: false)
        let revision = store.sessionRevision
        await store.loadAlbum(id: 7)
        await fulfillment(of: [started], timeout: 3)
        var artworkChanges = 0
        store.onArtworkChange = { _ in artworkChanges += 1 }
        await store.activate(try session(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        LoadingProtocol.release(image.path)
        XCTAssertEqual(store.userID, 99)
        XCTAssertNotEqual(store.sessionRevision, revision)
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertNil(store.cachedArtworkURL(image))
        XCTAssertEqual(artworkChanges, 0)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertFalse(files.contains { $0.pathExtension == "image" })
        await store.invalidate()
        network.invalidateAndCancel()
    }

    func testHomeRequestsFirstVisibleCoversThenDeduplicatesDemandForLaterCards() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<10).map { URL(string: "https://fixture.test/cover\($0)")! }
        let items = urls.enumerated().map { ["id": $0.offset, "name": "Card", "picUrl": $0.element.absoluteString] as [String: Any] }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["code": 200, "result": items]), as: UTF8.self)
        var responses = Dictionary(uniqueKeysWithValues: urls.map { ($0.path, "image") })
        responses["/eapi/personalized/playlist"] = body
        let firstImages = expectation(description: "First six covers")
        firstImages.expectedFulfillmentCount = 6
        let demandedImage = expectation(description: "Later visible card cover")
        let network = network(responses)
        let store = NeteaseHomeStore(client: client(network), directory: root, artworkSession: network)
        store.onArtworkChange = { changed in
            for url in changed {
                if urls.prefix(6).contains(url) { firstImages.fulfill() }
                if url == urls[9] { demandedImage.fulfill() }
            }
        }
        await store.activate(nil)
        await fulfillment(of: [firstImages], timeout: 3)
        let initial = LoadingProtocol.state.withLock { $0.startedPaths }
        XCTAssertFalse(initial.contains(urls[6].path))
        XCTAssertFalse(initial.contains(urls[9].path))
        store.requestArtwork([urls[9], urls[9]])
        await fulfillment(of: [demandedImage], timeout: 3)
        XCTAssertEqual(LoadingProtocol.state.withLock { $0.startedPaths.filter { $0 == urls[9].path }.count }, 1)
        await store.activate(try session(), refresh: false)
        network.invalidateAndCancel()
    }

    func testAccountSwitchCancelsSharedPlaylistRestoreBeforeWaitingForValidation() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/eapi/v6/playlist/detail"
        let started = expectation(description: "Saved favorites request started")
        let switched = expectation(description: "New account activation finished")
        let network = network([
            "/eapi/user/playlist": #"{"code":200,"playlist":[{"id":7,"name":"Favorites","creator":{"userId":42,"nickname":"Test"},"trackCount":0,"specialType":5}],"more":false}"#,
            "/eapi/song/like/get": #"{"code":200,"ids":[]}"#,
            path: #"{"code":200,"playlist":{"id":7,"name":"Favorites","creator":{"userId":42,"nickname":"Test"},"trackCount":0,"trackIds":[]}}"#
        ], blocked: [path], started: { if $0 == path { started.fulfill() } })
        let music = NeteaseMusicStore(client: client(network), directory: root, artworkSession: network)
        let first = try session(), second = try session(99)
        var saved: NeteaseSavedSession? = first
        let account = NeteaseAccount(readSession: { saved }, saveSession: { saved = $0 }, deleteSession: { saved = nil },
            validateCredential: { $0 == first.credential ? first.profile : second.profile },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: music)
        let restore = Task { await account.restore() }
        await fulfillment(of: [started], timeout: 3)
        let login = Task {
            try await account.completeLogin(credential: second.credential)
            switched.fulfill()
        }
        await fulfillment(of: [switched], timeout: 3)
        LoadingProtocol.release(path)
        try await login.value
        await restore.value
        XCTAssertEqual(account.profile?.userID, 99)
        XCTAssertEqual(music.userID, 99)
        XCTAssertEqual(saved?.profile.userID, 99)
        try await account.logout()
        network.invalidateAndCancel()
    }

    func testRestoringArtworkIndexDropsMissingFilesAndPreservesPresentFiles() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let present = URL(string: "https://fixture.test/present")!, missing = URL(string: "https://fixture.test/missing")!
        try Data([1]).write(to: root.appendingPathComponent("42-present.image"))
        let snapshot = NeteaseMusicStore.Snapshot(playlists: [], songs: [:], tracks: [:], liked: [], times: [:], lyrics: [:],
            artwork: [present.absoluteString: "present.image", missing.absoluteString: "missing.image"])
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("42.json"))
        let store = NeteaseMusicStore(directory: root)
        await store.activate(try session(), refresh: false)
        XCTAssertEqual(store.cachedArtworkURL(present), root.appendingPathComponent("42-present.image"))
        XCTAssertNil(store.cachedArtworkURL(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("42.json").path))
        await store.invalidate()
        let restored = NeteaseMusicStore(directory: root)
        await restored.activate(try session(), refresh: false)
        XCTAssertEqual(restored.cachedArtworkURL(present), root.appendingPathComponent("42-present.image"))
        XCTAssertNil(restored.cachedArtworkURL(missing))
        await restored.invalidate()
    }
}

private final class LoadingProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [String: String] = [:]
        var blocked: Set<String> = []
        var statuses: [String: Int] = [:]
        var pending: [String: [LoadingProtocol]] = [:]
        var startedPaths: [String] = []
        var started: @Sendable (String) -> Void = { _ in }
        var stopped: @Sendable (String) -> Void = { _ in }
        var completed: @Sendable (String) -> Void = { _ in }
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let (response, callback) = Self.state.withLock { value -> (String?, @Sendable (String) -> Void) in
            value.startedPaths.append(path)
            if value.blocked.contains(path) { value.pending[path, default: []].append(self); return (nil, value.started) }
            return (value.responses[path] ?? #"{"code":500}"#, value.started)
        }
        callback(path)
        if let response { respond(response) }
    }
    override func stopLoading() {
        let path = request.url!.path
        let callback = Self.state.withLock { value in
            value.pending[path]?.removeAll { $0 === self }
            return value.stopped
        }
        callback(path)
    }
    private func respond(_ body: String) {
        let status = Self.state.withLock { $0.statuses[request.url!.path] ?? 200 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
        let completed = Self.state.withLock { $0.completed }
        completed(request.url!.path)
    }
    static func release(_ path: String) {
        let (pending, response) = state.withLock { value in
            value.blocked.remove(path)
            return (value.pending.removeValue(forKey: path) ?? [], value.responses[path] ?? #"{"code":500}"#)
        }
        pending.forEach { $0.respond(response) }
    }
}
