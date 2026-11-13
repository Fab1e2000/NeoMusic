import XCTest
import Synchronization
@testable import NeoMusic

@MainActor final class NeteaseHomeTests: XCTestCase {
    func testMissingFailedHomeSectionKeepsItsPlaceAndCachedSectionKeepsItsItems() {
        let chart = feedBlock("HOMEPAGE_BLOCK_TOPLIST", id: 12, title: "排行榜")
        let feed = NeteaseHomeFeed(blocks: [chart], hasMore: false, cursor: nil)
        let issues: [HomeFeedIssue] = [
            .init(id: "feed", title: "推荐内容", message: "Failed", sectionID: nil),
            .init(id: "recommendations", title: "推荐歌单", message: "Failed", sectionID: "recommendedPlaylists"),
            .init(id: "charts", title: "排行榜", message: "Failed", sectionID: "charts")
        ]
        let sections = HomeMusicIntegration.feedSections(feed, issues: issues, artwork: { _ in .missing })
        XCTAssertEqual(sections.map(\.id), ["recommendedPlaylists", "charts"])
        XCTAssertEqual(sections.first?.title, "推荐歌单")
        XCTAssertTrue(sections.first?.items.isEmpty == true)
        XCTAssertEqual(sections.last?.items.map(\.id), ["list/12"])
    }

    func testSourceRetriesRequestOnlyTheirOwnEndpoint() async throws {
        let endpoints: [(NeteaseHomeStore.RetrySource, String)] = [
            (.feed, "/eapi/homepage/block/page"),
            (.recommendations, "/eapi/v1/discovery/recommend/resource"),
            (.likedRecommendations, "/eapi/v1/discovery/simiSong"),
            (.charts, "/eapi/toplist"),
            (.followedReleases, "/eapi/sub/artist/new/works/song/list"),
            (.newSongs, "/eapi/v1/discovery/new/songs")
        ]
        for (source, path) in endpoints {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let network = try paginationNetwork(count: 1)
            defer { network.invalidateAndCancel() }
            HomePaginationProtocol.state.withLock { $0.responses["/eapi/v1/discovery/simiSong"] = songResponse([2], key: "songs") }
            let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
            await store.activate(try savedSession(), refresh: false)
            if source == .likedRecommendations {
                let seed = NeteaseMusicSong(id: 1, title: "Seed", artist: "Artist", album: "Album", artworkURL: nil, duration: 1)
                store.updateLikedSongs(playlistID: 12, songs: [seed], likedAt: [1: Date()], likedIDs: [1])
                await store.retry(.likedRecommendations)
                HomePaginationProtocol.state.withLock { $0.paths = [] }
            }
            await store.retry(source)
            XCTAssertEqual(HomePaginationProtocol.state.withLock { $0.paths }, [path], source.rawValue)
            XCTAssertTrue(store.refreshingSources.isEmpty)
            await store.flush()
        }
    }

    func testSourceRetryAndWholeRefreshShareTheSamePendingRequest() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let chartsPath = "/eapi/toplist"
        let started = expectation(description: "Charts retry started")
        let feedStarted = expectation(description: "Whole refresh started")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(chartsPath)
            $0.started = { path in
                if path == chartsPath { started.fulfill() }
                if path == "/eapi/homepage/block/page" { feedStarted.fulfill() }
            }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let first = Task { await store.retry(.charts) }
        await fulfillment(of: [started], timeout: 3)
        let duplicate = Task { await store.retry(.charts) }
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [feedStarted], timeout: 3)
        XCTAssertEqual(store.refreshingSources.contains(.charts), true)
        HomePaginationProtocol.release(chartsPath)
        await first.value; await duplicate.value; await refresh.value
        XCTAssertEqual(HomePaginationProtocol.count(chartsPath), 1)
        XCTAssertTrue(store.refreshingSources.isEmpty)
        await store.flush()
    }

    func testCancelledSourceRetryCanBeRetriedWithoutPublishingAnError() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/homepage/block/page"
        let started = expectation(description: "Source retry started")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let retry = Task { await store.retry(.feed) }
        await fulfillment(of: [started], timeout: 3)
        retry.cancel()
        await retry.value
        XCTAssertNil(store.feedError)
        XCTAssertTrue(store.refreshingSources.isEmpty)
        HomePaginationProtocol.state.withLock { $0.started = { _ in } }
        HomePaginationProtocol.release(path)
        await store.retry(.feed)
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        XCTAssertNotNil(store.feed)
        await store.flush()
    }

    func testAccountSwitchCancelsSourceRetryAndClearsItsState() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/toplist"
        let started = expectation(description: "Charts source started")
        let stopped = expectation(description: "Charts source cancelled")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
            $0.stopped = { if $0 == path { stopped.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let retry = Task { await store.retry(.charts) }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try savedSession(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        await retry.value
        HomePaginationProtocol.release(path)
        XCTAssertEqual(store.userID, 99)
        XCTAssertNil(store.charts)
        XCTAssertNil(store.chartsError)
        XCTAssertTrue(store.refreshingSources.isEmpty)
    }

    func testLocalRetryPreservesCachedContentAndOtherSourceErrors() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/toplist"
        let charts = Data(#"{"code":200,"list":[{"id":12,"name":"Saved chart"}]}"#.utf8)
        HomePaginationProtocol.state.withLock { $0.responses[path] = charts }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        await store.retry(.charts)
        let saved = store.charts
        HomePaginationProtocol.state.withLock { $0.failures.formUnion([path, "/eapi/homepage/block/page"]) }
        await store.retry(.charts)
        await store.retry(.feed)
        XCTAssertEqual(store.charts, saved)
        XCTAssertEqual(HomeMusicIntegration.feedIssues(store).map(\.id), ["feed", "charts"])
        let started = expectation(description: "Local retry started")
        HomePaginationProtocol.state.withLock {
            $0.failures.remove(path); $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let retry = Task { await store.retry(.charts) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(HomeMusicIntegration.feedIssues(store).first(where: { $0.id == "charts" })?.isRetrying, true)
        XCTAssertEqual(store.charts, saved)
        HomePaginationProtocol.release(path)
        await retry.value
        XCTAssertEqual(HomeMusicIntegration.feedIssues(store).map(\.id), ["feed"])
        XCTAssertEqual(store.charts, saved)
        await store.flush()
    }

    func testRefreshReadsAllPagesAndReplacesSnapshotWithoutAccumulating() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/homepage/block/page"
        let old = NeteaseHomeFeed(blocks: [feedBlock("OLD", id: 99)], hasMore: false, cursor: nil)
        let pages = NeteasePageCache(directory: root)
        try await pages.save(old, scope: "42", key: "feed")
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        HomePaginationProtocol.state.withLock {
            $0.sequences[path] = [feedResponse("FIRST", id: 1, cursor: "one"), feedResponse("SCENE", id: 2)]
        }
        await store.refresh()
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        XCTAssertEqual(store.feed?.blocks.map(\.blockCode), ["FIRST", "SCENE"])
        XCTAssertEqual(store.feed?.hasMore, false)
        XCTAssertNil(store.feed?.cursor)
        HomePaginationProtocol.state.withLock { $0.responses[path] = feedResponse("NEW", id: 3) }
        await store.refresh()
        XCTAssertEqual(store.feed?.blocks.map(\.blockCode), ["NEW"])
        await store.flush()
        let restored = try await pages.load(NeteaseHomeFeed.self, scope: "42", key: "feed")
        XCTAssertEqual(restored, store.feed)
        let requests = HomePaginationProtocol.count(path)
        await store.refresh(force: false)
        XCTAssertEqual(HomePaginationProtocol.count(path), requests)
    }

    func testRefreshStopsAtRepeatedCursorOrNoAdditionalResources() async throws {
        for repeatsCursor in [true, false] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let network = try paginationNetwork(count: 1)
            defer { network.invalidateAndCancel() }
            let path = "/eapi/homepage/block/page"
            HomePaginationProtocol.state.withLock {
                $0.sequences[path] = [feedResponse("FIRST", id: 1, cursor: "one"),
                    feedResponse("FIRST", id: repeatsCursor ? 2 : 1, cursor: repeatsCursor ? "one" : "two")]
            }
            let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
            await store.activate(try savedSession(), refresh: false)
            await store.refresh()
            XCTAssertEqual(HomePaginationProtocol.count(path), 2)
            XCTAssertNil(store.feedError)
            XCTAssertEqual(store.feed?.hasMore, false)
            XCTAssertEqual(store.feed?.blocks.first?.resources.count, repeatsCursor ? 2 : 1)
            await store.flush()
        }
    }

    func testLaterPageFailurePreservesCompleteSnapshotAndSuccessfulEmptyClearsIt() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/homepage/block/page"
        let old = NeteaseHomeFeed(blocks: [feedBlock("OLD", id: 9)], hasMore: false, cursor: nil)
        let pages = NeteasePageCache(directory: root)
        try await pages.save(old, scope: "42", key: "feed")
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        HomePaginationProtocol.state.withLock {
            $0.sequences[path] = [feedResponse("NEW", id: 1, cursor: "one"), Data(#"{"code":503}"#.utf8)]
        }
        await store.refresh()
        XCTAssertEqual(store.feed, old)
        XCTAssertNotNil(store.feedError)
        await store.flush()
        let preserved = try await pages.load(NeteaseHomeFeed.self, scope: "42", key: "feed")
        XCTAssertEqual(preserved, old)
        HomePaginationProtocol.state.withLock { $0.responses[path] = Data(#"{"code":200,"data":{"blocks":[],"hasMore":false}}"#.utf8) }
        await store.refresh()
        XCTAssertTrue(store.feed?.blocks.isEmpty == true)
        XCTAssertNil(store.feedError)
    }

    func testExplicitRefreshCancelsPassiveRequestThenPerformsNewRefresh() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/homepage/block/page"
        let started = expectation(description: "Passive feed request started")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let passive = Task { await store.refresh(force: false) }
        await fulfillment(of: [started], timeout: 3)
        HomePaginationProtocol.state.withLock {
            $0.started = { _ in }
            $0.blocked.remove(path)
            $0.responses[path] = feedResponse("FRESH", id: 1)
        }
        await store.refresh(force: true)
        await passive.value
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        XCTAssertEqual(store.feed?.blocks.first?.blockCode, "FRESH")
        XCTAssertNil(store.feedError)
    }

    func testFeedRefreshCancelledWhenAccountChanges() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/homepage/block/page"
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let started = expectation(description: "Feed refresh started")
        let stopped = expectation(description: "Feed refresh cancelled")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
            $0.stopped = { if $0 == path { stopped.fulfill() } }
        }
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try savedSession(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        await refresh.value
        HomePaginationProtocol.release(path)
        XCTAssertNil(store.feed)
        XCTAssertNil(store.feedError)
        XCTAssertEqual(store.userID, 99)
    }

    func testSupplementalCacheIsolationAndNativeFeedPrecedence() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = NeteasePageCache(directory: root)
        let charts = feedBlock("NEOMUSIC_CHARTS", id: 8)
        let followed = feedBlock("NEOMUSIC_FOLLOWED_RELEASES", id: 9)
        let native = NeteaseHomeFeed(blocks: [feedBlock("HOMEPAGE_BLOCK_TOPLIST", id: 7)], hasMore: false, cursor: nil)
        try await pages.save(native, scope: "42", key: "feed")
        try await pages.save(charts, scope: "42", key: "home-charts")
        try await pages.save(followed, scope: "42", key: "home-followed")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeFailureProtocol.self]
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: config))), directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.displayFeedBlocks.map(\.blockCode), ["HOMEPAGE_BLOCK_TOPLIST", "NEOMUSIC_FOLLOWED_RELEASES"])
        await store.refresh()
        XCTAssertEqual(store.charts, charts)
        XCTAssertEqual(store.followedReleases, followed)
        XCTAssertNotNil(store.chartsError)
        XCTAssertNotNil(store.followedReleasesError)
        await store.activate(try savedSession(99), refresh: false)
        XCTAssertNil(store.charts)
        XCTAssertNil(store.followedReleases)
        XCTAssertTrue(store.displayFeedBlocks.isEmpty)
    }

    func testFixedCategoryOrderPrefersUsableFeedAndHidesUnknownOrEmptyBlocks() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = NeteasePageCache(directory: root)
        let blocks = [feedBlock("HOMEPAGE_BLOCK_OFFICIAL_PLAYLIST", id: 8), feedBlock("UNKNOWN", id: 9),
                      feedBlock("HOMEPAGE_BLOCK_MGC_PLAYLIST", id: 4), feedBlock("HOMEPAGE_BLOCK_PLAYLIST_RCMD", id: 3),
                      feedBlock("HOMEPAGE_BLOCK_TOPLIST", id: 5)]
        try await pages.save(NeteaseHomeFeed(blocks: blocks, hasMore: false, cursor: nil), scope: "42", key: "feed")
        try await pages.save(feedBlock("NEOMUSIC_CHARTS", id: 50), scope: "42", key: "home-charts")
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.displayFeedBlocks.compactMap(\.category), [.recommendedPlaylists, .radarPlaylists, .charts, .scenePlaylists])
        XCTAssertEqual(store.displayFeedBlocks.first(where: { $0.category == .charts })?.resources.first?.numericID, 5)
        let refreshedTitle = feedBlock("HOMEPAGE_BLOCK_MGC_PLAYLIST", id: 40, title: "新的雷达标题")
        XCTAssertEqual(refreshedTitle.id, blocks[2].id)
    }

    func testDifferentSongRecommendationBasesRemainSeparateAcrossPages() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func block(_ title: String, id: Int64) -> NeteaseHomeFeed.Block {
            .init(blockCode: "HOMEPAGE_BLOCK_STYLE_RCMD", uiElement: .init(mainTitle: nil, subTitle: .init(title: title), image: nil),
                  creatives: [.init(creativeId: String(id), creativeType: nil, uiElement: nil,
                                    resources: [.init(song: .init(id: id, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 1))])])
        }
        let first = NeteaseHomeFeed(blocks: [block("根据《A》推荐", id: 1)], hasMore: true, cursor: "next")
        let second = NeteaseHomeFeed(blocks: [block("根据《B》推荐", id: 2)], hasMore: false, cursor: nil)
        let merged = first.merging(second)
        XCTAssertEqual(merged.blocks.count, 2)
        try await NeteasePageCache(directory: root).save(merged, scope: "42", key: "feed")
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.displayFeedBlocks.count, 1)
        XCTAssertEqual(store.displayFeedBlocks.first?.title, "根据《A》推荐")
        XCTAssertEqual(store.displayFeedBlocks.first?.resources.compactMap(\.song).map(\.id), [1])
    }

    func testNewSongEndpointSuppliesAccurateSectionAndRecommendationsOnlyFillMissingFeed() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 3)
        defer { network.invalidateAndCancel() }
        let song = NeteaseMusicSong(id: 1, title: "Feed Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 1)
        let mixed = NeteaseHomeFeed.Block(blockCode: "HOMEPAGE_BLOCK_NEW_ALBUM_NEW_SONG",
            uiElement: .init(mainTitle: nil, subTitle: .init(title: "新歌新碟"), image: nil),
            creatives: [.init(creativeId: "mixed", creativeType: nil, uiElement: nil, resources: [.init(song: song), .init(type: "album", id: 2, title: "Album", artist: "Artist", image: nil)])])
        let feed = NeteaseHomeFeed(blocks: [mixed, feedBlock("HOMEPAGE_BLOCK_PLAYLIST_RCMD", id: 4)], hasMore: false, cursor: nil)
        struct Response: Encodable { let code = 200; let data: NeteaseHomeFeed }
        let data = try JSONEncoder().encode(Response(data: feed))
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/homepage/block/page"] = data
            $0.responses["/eapi/v1/discovery/new/songs"] = songResponse([3], key: "data")
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        await store.refresh()
        let fresh = store.displayFeedBlocks.first { $0.category == .newSongs }
        XCTAssertEqual(fresh?.title, "新歌速递")
        XCTAssertEqual(fresh?.resources.compactMap(\.song).map(\.id), [3])
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v1/discovery/new/songs"), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v1/discovery/recommend/resource"), 0)
    }

    func testLikedSeedWithoutDatesReadsRealPlaylistOrder() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 3)
        defer { network.invalidateAndCancel() }
        HomePaginationProtocol.state.withLock { $0.responses["/eapi/v1/discovery/simiSong"] = songResponse([2], key: "songs") }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        store.updateLikedSongs(playlistID: 12, songs: [], likedAt: [:], likedIDs: [1, 2, 3])
        await store.refresh()
        XCTAssertEqual(store.likedRecommendations?.title, "根据你喜欢的《Song 1》推荐")
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
    }

    func testLikedSeedChangeRefreshesAccurateFallbackAndCacheRemainsAccountScoped() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 3)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/discovery/simiSong"
        HomePaginationProtocol.state.withLock {
            $0.responses[path] = songResponse([3], key: "songs")
            $0.responses["/eapi/v1/discovery/new/songs"] = songResponse([2], key: "data")
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        store.updateLikedSongs(playlistID: 12, songs: [], likedAt: [1: Date()], likedIDs: [1])
        await store.refresh()
        XCTAssertEqual(store.likedRecommendations?.title, "根据你喜欢的《Song 1》推荐")
        XCTAssertEqual(store.displayFeedBlocks.compactMap(\.category), [.likedSongs, .newSongs])
        XCTAssertEqual(store.newSongs?.title, "新歌速递")
        let seed = NeteaseMusicSong(id: 2, title: "Second Seed", artist: "Artist", album: "Album", artworkURL: nil, duration: 1)
        store.updateLikedSongs(playlistID: 12, songs: [seed], likedAt: [1: .distantPast, 2: Date()], likedIDs: [1, 2])
        XCTAssertNil(store.likedRecommendations)
        await store.refresh()
        XCTAssertEqual(store.likedRecommendations?.title, "根据你喜欢的《Second Seed》推荐")
        await store.flush()
        let restored = NeteaseHomeStore(directory: root)
        await restored.activate(try savedSession(), refresh: false)
        XCTAssertEqual(restored.likedRecommendations?.title, store.likedRecommendations?.title)
        restored.updateLikedSongs(playlistID: 12, songs: [], likedAt: [:], likedIDs: [])
        XCTAssertNil(restored.likedRecommendations)
        await store.activate(try savedSession(99), refresh: false)
        XCTAssertNil(store.likedRecommendations)
        XCTAssertNil(store.newSongs)
    }

    func testQuickActionsReturnRealDestinationsAndOrderedSongBatches() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 3)
        defer { network.invalidateAndCancel() }
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/toplist"] = Data(#"{"code":200,"list":[{"id":99,"name":"热歌榜"}]}"#.utf8)
            $0.responses["/eapi/homepage/block/page"] = feedResponse("HOMEPAGE_BLOCK_MGC_PLAYLIST", id: 88)
            $0.responses["/eapi/playmode/intelligence/list"] = Data(#"{"code":200,"data":[{"id":3},{"id":1}]}"#.utf8)
            $0.responses["/eapi/v1/radio/get"] = songResponse([2, 1], key: "data")
            $0.responses["/eapi/v1/discovery/simiSong"] = songResponse([3, 2], key: "songs")
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        let snapshot = NeteaseDailySnapshot(date: NeteaseHomeStore.day(), songs: [.init(id: 1, title: "Daily", artist: "Artist", album: "Album", artworkURL: nil, duration: 1)])
        try await NeteasePageCache(directory: root).save(snapshot, scope: "42", key: "daily:" + snapshot.date)
        await store.activate(try savedSession(), refresh: false)
        store.updateLikedSongs(playlistID: 12, songs: snapshot.songs, likedAt: [1: Date()], likedIDs: [1])
        if case .daily(let value) = try await store.performQuickAction(.dailySongs) { XCTAssertEqual(value.id, snapshot.id) }
        else { XCTFail("Daily action should open the saved snapshot") }
        if case .playlist(let value) = try await store.performQuickAction(.hotSongs) { XCTAssertEqual(value.id, 99) }
        else { XCTFail("Hot action should open the actual chart") }
        if case .playlist(let value) = try await store.performQuickAction(.privateRadar) { XCTAssertEqual(value.id, 88) }
        else { XCTFail("Radar action should open a feed playlist") }
        for (action, expected): (NeteaseHomeQuickAction, [Int64]) in [(.heartMode, [3, 1]), (.privateRoaming, [2, 1]), (.similarSongs, [3, 2])] {
            switch try await store.performQuickAction(action, currentSongID: 1) {
            case .songs(let values), .roaming(_, let values): XCTAssertEqual(values.map(\.id), expected)
            default: XCTFail("Playback action should return a batch")
            }
        }
        XCTAssertTrue(store.quickActionStates.isEmpty)
        await store.activate(nil, refresh: false)
    }

    func testQuickActionsExposeLoginAndMissingPrerequisitesWithoutPublishingSongs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(nil, refresh: false)
        for action in NeteaseHomeQuickAction.allCases where action != .hotSongs {
            do { _ = try await store.performQuickAction(action); XCTFail("This action requires an account") }
            catch { XCTAssertEqual(error.localizedDescription, NeteaseHomeActionError.loginRequired.localizedDescription) }
        }
        await store.activate(try savedSession(), refresh: false)
        XCTAssertTrue(store.quickActionStates.isEmpty)
        for action in [NeteaseHomeQuickAction.heartMode, .similarSongs, .privateRadar, .hotSongs, .dailySongs] {
            do { _ = try await store.performQuickAction(action); XCTFail("Missing content should produce a useful error") }
            catch { XCTAssertNotNil(store.quickActionStates[action]) }
        }
        XCTAssertTrue(store.cachedSongs.isEmpty)
    }

    func testAccountSwitchCancelsQuickActionAndClearsLoadingState() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/radio/get"
        let started = expectation(description: "Roaming request started")
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.responses[path] = songResponse([1], key: "data")
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let action = Task { try await store.performQuickAction(.privateRoaming) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(store.quickActionStates[.privateRoaming], .loading)
        await store.activate(try savedSession(99), refresh: false)
        HomePaginationProtocol.release(path)
        do { _ = try await action.value; XCTFail("The prior account's action must cancel") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue(store.quickActionStates.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
    }

    func testRoamingPrefetchAndTapShareBatchUntilPlaybackAcceptsIt() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 3)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/radio/get"
        let started = expectation(description: "Home starts roaming prefetch")
        HomePaginationProtocol.state.withLock {
            $0.responses[path] = songResponse([2, 2, 1], key: "data")
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 3)
        let action = Task { try await store.performQuickAction(.privateRoaming) }
        await Task.yield()
        HomePaginationProtocol.state.withLock { $0.started = { _ in } }
        HomePaginationProtocol.release(path)
        await refresh.value
        guard case .roaming(let firstID, let firstSongs) = try await action.value else { return XCTFail("Missing prepared batch") }
        XCTAssertEqual(firstSongs.map(\.id), [2, 1])
        XCTAssertEqual(HomePaginationProtocol.count(path), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/song/enhance/player/url/v1"), 0)
        await store.refresh(force: false)
        guard case .roaming(let retainedID, _) = try await store.performQuickAction(.privateRoaming) else { return XCTFail("Missing retained batch") }
        XCTAssertEqual(retainedID, firstID)
        XCTAssertEqual(HomePaginationProtocol.count(path), 1)
        store.consumeRoamingBatch(id: firstID)
        HomePaginationProtocol.state.withLock { $0.responses[path] = songResponse([3], key: "data") }
        guard case .roaming(let nextID, let nextSongs) = try await store.performQuickAction(.privateRoaming) else { return XCTFail("Missing next batch") }
        XCTAssertNotEqual(nextID, firstID)
        XCTAssertEqual(nextSongs.map(\.id), [3])
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        // Accepting an older confirmation must not consume a newer refresh.
        store.consumeRoamingBatch(id: firstID)
        guard case .roaming(let stillPrepared, _) = try await store.performQuickAction(.privateRoaming) else { return XCTFail("Missing current batch") }
        XCTAssertEqual(stillPrepared, nextID)
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        await store.activate(nil, refresh: false)
    }

    func testNextRoamingSongsLeavesThePreparedBatchAndCardStateAlone() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/radio/get"
        HomePaginationProtocol.state.withLock { $0.responses[path] = songResponse([1], key: "data") }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        guard case .roaming(let preparedID, let prepared) = try await store.performQuickAction(.privateRoaming) else {
            return XCTFail("Missing prepared batch")
        }
        XCTAssertEqual(prepared.map(\.id), [1])
        HomePaginationProtocol.state.withLock { $0.responses[path] = songResponse([4], key: "data") }
        let more = try await store.nextRoamingSongs()
        XCTAssertEqual(more.map(\.id), [4])
        XCTAssertNil(store.quickActionStates[.privateRoaming])
        guard case .roaming(let retainedID, let retained) = try await store.performQuickAction(.privateRoaming) else {
            return XCTFail("Continuation replaced the prepared batch")
        }
        XCTAssertEqual(retainedID, preparedID)
        XCTAssertEqual(retained.map(\.id), [1])
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        store.consumeRoamingBatch(id: preparedID)
        HomePaginationProtocol.state.withLock { $0.responses[path] = songResponse([5], key: "data") }
        guard case .roaming(_, let next) = try await store.performQuickAction(.privateRoaming) else {
            return XCTFail("Missing the batch after playback")
        }
        XCTAssertEqual(next.map(\.id), [5])
        XCTAssertEqual(HomePaginationProtocol.count(path), 3)
        await store.activate(nil, refresh: false)
    }

    func testShortcutCoversRestoreExactFirstSongWithoutUsingOfficialOrLaterCover() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = NeteasePageCache(directory: root)
        let official = URL(string: "https://fixture.test/official")!
        let firstCover = URL(string: "https://fixture.test/first")!
        let laterCover = URL(string: "https://fixture.test/later")!
        let hot = NeteaseHomeFeed.Block(blockCode: "NEOMUSIC_CHARTS", uiElement: nil, creatives: [
            .init(creativeId: "charts", creativeType: nil, uiElement: nil, resources: [
                .init(type: "list", id: 99, title: "热歌榜", artist: "", image: official.absoluteString)])])
        let radar = NeteaseHomeFeed.Block(blockCode: "HOMEPAGE_BLOCK_MGC_PLAYLIST", uiElement: nil, creatives: [
            .init(creativeId: "radar", creativeType: nil, uiElement: nil, resources: [
                .init(type: "list", id: 88, title: "Radar", artist: "", image: official.absoluteString)])])
        let first = NeteaseMusicSong(id: 2, title: "First", artist: "Artist", album: "Album", artworkURL: firstCover, duration: 1)
        let later = NeteaseMusicSong(id: 1, title: "Later", artist: "Artist", album: "Album", artworkURL: laterCover, duration: 1)
        let hotDetail = NeteasePlaylistDetail(playlist: .init(id: 99, title: "热歌榜", creator: "", creatorID: 0, artworkURL: official, trackCount: 2, isFavorites: false),
            songs: [later, first], addedTimes: [:], trackIDs: [2, 1], loadedTrackCount: 2)
        let radarDetail = NeteasePlaylistDetail(playlist: .init(id: 88, title: "Radar", creator: "", creatorID: 0, artworkURL: official, trackCount: 2, isFavorites: false),
            songs: [later], addedTimes: [:], trackIDs: [3, 1], loadedTrackCount: 2)
        let daily = NeteaseDailySnapshot(date: NeteaseHomeStore.day(), songs: [
            .init(id: 3, title: "No cover", artist: "", album: "", artworkURL: nil, duration: 1), later])
        try await pages.save(hot, scope: "42", key: "home-charts")
        try await pages.save(NeteaseHomeFeed(blocks: [radar], hasMore: false, cursor: nil), scope: "42", key: "feed")
        try await pages.save(hotDetail, scope: "42", key: "playlist:99")
        try await pages.save(radarDetail, scope: "42", key: "playlist:88")
        try await pages.save(daily, scope: "42", key: "daily:" + daily.date)
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/v1/radio/get"] = Data(#"{"code":200,"data":[{"id":3,"name":"First","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":1000},{"id":1,"name":"Later","ar":[{"name":"Artist"}],"al":{"name":"Album","picUrl":"https://fixture.test/later"},"dt":1000}]}"#.utf8)
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root, artworkSession: network)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.quickActionArtwork(.hotSongs), firstCover)
        XCTAssertNil(store.quickActionArtwork(.privateRadar))
        XCTAssertNil(store.quickActionArtwork(.dailySongs))
        _ = try await store.performQuickAction(.privateRoaming)
        XCTAssertNil(store.quickActionArtwork(.privateRoaming))
        if case .playlist(let playlist) = try await store.performQuickAction(.hotSongs) { XCTAssertEqual(playlist.id, 99) }
        else { XCTFail("Hot route changed") }
        if case .playlist(let playlist) = try await store.performQuickAction(.privateRadar) { XCTAssertEqual(playlist.id, 88) }
        else { XCTFail("Radar route changed") }
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 0)
        await store.activate(try savedSession(99), refresh: false)
        XCTAssertNil(store.quickActionArtwork(.hotSongs))
        XCTAssertNil(store.quickActionArtwork(.privateRadar))
    }

    func testShortcutCoverPrefetchLoadsOneOrderedSongAndDetailStillOpensFullFirstPage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v6/playlist/detail", cover = URL(string: "https://fixture.test/first-track")!
        let ids = [2, 1] + Array(3...205)
        let response: [String: Any] = ["code": 200, "playlist": [
            "id": 12, "name": "热歌榜", "coverImgUrl": "https://fixture.test/official", "creator": ["userId": 42, "nickname": "Test"],
            "trackCount": ids.count, "trackIds": ids.map { ["id": $0] }, "tracks": [
                ["id": 1, "name": "Later", "ar": [["name": "Artist"]], "al": ["name": "Album", "picUrl": "https://fixture.test/later"], "dt": 1000],
                ["id": 2, "name": "First", "ar": [["name": "Artist"]], "al": ["name": "Album", "picUrl": cover.absoluteString], "dt": 1000]]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/toplist"] = Data(#"{"code":200,"list":[{"id":12,"name":"热歌榜","coverImgUrl":"https://fixture.test/official"}]}"#.utf8)
            $0.responses[path] = data
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root, artworkSession: network)
        await store.activate(try savedSession())
        XCTAssertEqual(store.quickActionArtwork(.hotSongs), cover)
        XCTAssertEqual(store.cachedDetail(id: 12)?.songs.map(\.id), [2])
        XCTAssertEqual(store.cachedDetail(id: 12)?.nextOffset, 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 0)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/song/enhance/player/url/v1"), 0)
        let detail = try await store.detail(id: 12)
        XCTAssertEqual(detail.songs.map(\.id), Array(ids.prefix(100)).map(Int64.init))
        XCTAssertEqual(detail.nextOffset, 100)
        XCTAssertEqual(HomePaginationProtocol.count(path), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 1)
        await store.refresh()
        XCTAssertEqual(store.cachedDetail(id: 12)?.nextOffset, 100)
        XCTAssertEqual(store.cachedDetail(id: 12)?.songs.map(\.id), detail.songs.map(\.id))
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 1)
        HomePaginationProtocol.state.withLock { $0.failures.insert(path) }
        await store.refresh()
        XCTAssertEqual(store.quickActionArtwork(.hotSongs), cover)
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/toplist"] = Data(#"{"code":200,"list":[{"id":13,"name":"热歌榜","coverImgUrl":"https://fixture.test/new-official"}]}"#.utf8)
        }
        await store.refresh()
        XCTAssertNil(store.quickActionArtwork(.hotSongs))
        await store.activate(nil, refresh: false)
    }

    func testAccountSwitchCancelsShortcutFirstTrackPrefetch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 2)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v6/playlist/detail"
        let started = expectation(description: "First track request started")
        let stopped = expectation(description: "First track request cancelled")
        HomePaginationProtocol.state.withLock {
            $0.responses["/eapi/toplist"] = Data(#"{"code":200,"list":[{"id":12,"name":"热歌榜"}]}"#.utf8)
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
            $0.stopped = { if $0 == path { stopped.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try savedSession(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        await refresh.value
        HomePaginationProtocol.release(path)
        XCTAssertNil(store.cachedDetail(id: 12))
        XCTAssertNil(store.quickActionArtwork(.hotSongs))
    }

    func testRoamingRefreshFailureAndCacheRestorePreserveRealCoverAndBatch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/radio/get", cover = URL(string: "https://fixture.test/roaming-cover")!
        HomePaginationProtocol.state.withLock {
            $0.responses[path] = Data(#"{"code":200,"data":[{"id":1,"name":"First","ar":[{"name":"Artist"}],"al":{"name":"Album","picUrl":"https://fixture.test/roaming-cover"},"dt":1000}]}"#.utf8)
        }
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: network))
        let store = NeteaseHomeStore(client: client, directory: root, artworkSession: network)
        await store.activate(try savedSession())
        guard case .roaming(let originalID, _) = try await store.performQuickAction(.privateRoaming) else { return XCTFail("Missing batch") }
        XCTAssertEqual(store.quickActionArtwork(.privateRoaming), cover)
        HomePaginationProtocol.state.withLock { $0.failures.insert(path) }
        await store.refresh()
        XCTAssertNotNil(store.quickActionStates[.privateRoaming])
        XCTAssertEqual(store.quickActionArtwork(.privateRoaming), cover)
        guard case .roaming(let retainedID, _) = try await store.performQuickAction(.privateRoaming) else { return XCTFail("Missing retained batch") }
        XCTAssertEqual(retainedID, originalID)
        await store.flush()
        let restored = NeteaseHomeStore(client: client, directory: root, artworkSession: network)
        await restored.activate(try savedSession(), refresh: false)
        XCTAssertEqual(restored.quickActionArtwork(.privateRoaming), cover)
        guard case .roaming(let cachedID, _) = try await restored.performQuickAction(.privateRoaming) else { return XCTFail("Missing cached batch") }
        XCTAssertEqual(cachedID, originalID)
        restored.consumeRoamingBatch(id: cachedID)
        await restored.flush()
        await restored.activate(try savedSession(99), refresh: false)
        XCTAssertNil(restored.quickActionArtwork(.privateRoaming))
        XCTAssertTrue(restored.cachedSongs.isEmpty)
        await restored.activate(try savedSession(), refresh: false)
        XCTAssertEqual(restored.quickActionArtwork(.privateRoaming), cover)
        HomePaginationProtocol.state.withLock { $0.failures.remove(path) }
        guard case .roaming(let renewedID, _) = try await restored.performQuickAction(.privateRoaming) else { return XCTFail("Missing renewed batch") }
        XCTAssertNotEqual(renewedID, originalID)
        await store.activate(nil, refresh: false)
        await restored.activate(nil, refresh: false)
    }

    func testAccountSwitchCancelsHomeRoamingPrefetchAndRejectsLateResponse() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let path = "/eapi/v1/radio/get"
        let started = expectation(description: "Roaming prefetch started")
        let stopped = expectation(description: "Roaming prefetch cancelled")
        HomePaginationProtocol.state.withLock {
            $0.responses[path] = songResponse([1], key: "data")
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
            $0.stopped = { if $0 == path { stopped.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try savedSession(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        await refresh.value
        HomePaginationProtocol.release(path)
        XCTAssertEqual(store.userID, 99)
        XCTAssertNil(store.quickActionArtwork(.privateRoaming))
        XCTAssertTrue(store.quickActionStates.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
    }

    func testFeedArtworkUsesHTTPSForHTTPResourceImagesAndCacheRoundTrip() throws {
        let data = Data(#"{"resourceType":"list","resourceId":"7","uiElement":{"image":{"imageUrl":"http://p1.music.126.net/example.jpg"}}}"#.utf8)
        let resource = try JSONDecoder().decode(NeteaseHomeFeed.Resource.self, from: data)
        XCTAssertEqual(resource.artworkURL?.absoluteString, "https://p1.music.126.net/example.jpg")
        let restored = try JSONDecoder().decode(NeteaseHomeFeed.Resource.self, from: JSONEncoder().encode(resource))
        XCTAssertEqual(restored.artworkURL?.absoluteString, "https://p1.music.126.net/example.jpg")
    }

    func testFeedSongUsesHomepageMetadataFieldNames() throws {
        let data = Data(#"{"resourceType":"song","resourceId":"7","resourceExtInfo":{"songData":{"id":7,"name":"Song","artists":[{"id":8,"name":"Artist"}],"album":{"id":9,"name":"Album","picUrl":"https://example.com/cover.jpg"},"duration":120000}}}"#.utf8)
        let resource = try JSONDecoder().decode(NeteaseHomeFeed.Resource.self, from: data)
        XCTAssertEqual(resource.song?.id, 7)
        XCTAssertEqual(resource.song?.artist, "Artist")
        XCTAssertEqual(resource.song?.duration, 120)
        XCTAssertEqual(resource.song?.albumID, 9)
        XCTAssertEqual(try JSONDecoder().decode(NeteaseHomeFeed.Resource.self, from: JSONEncoder().encode(resource)), resource)
    }

    func testFeedResourceIdentityRoundTripAndPageOrdering() throws {
        let data = Data(#"{"blocks":[{"blockCode":"HOMEPAGE_BLOCK_MGC_PLAYLIST","uiElement":{"subTitle":{"title":"用户的雷达歌单"}},"creatives":[{"creativeId":"first","resources":[{"resourceId":12,"resourceType":"list","uiElement":{"mainTitle":{"title":"雷达"}}},{"resourceId":"12","resourceType":"list"},{"resourceId":"12","resourceType":"album"},{"resourceId":"7","resourceType":"podcast"},{"resourceId":"0","resourceType":"song"}]}]}],"hasMore":true,"cursor":"next"}"#.utf8)
        let feed = try JSONDecoder().decode(NeteaseHomeFeed.self, from: data)
        XCTAssertEqual(feed.blocks.first?.title, "用户的雷达歌单")
        XCTAssertEqual(feed.blocks.first?.resources.map(\.id), ["list/12", "album/12"])
        XCTAssertEqual(try JSONDecoder().decode(NeteaseHomeFeed.self, from: JSONEncoder().encode(feed)), feed)
        XCTAssertEqual(feed.merging(feed).blocks.count, 1)
        XCTAssertEqual(feed.merging(feed).cursor, "next")
    }

    func testFeedCacheIsAccountIsolatedAndRefreshFailureKeepsContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = NeteaseHomeFeed(blocks: [.init(blockCode: "HOMEPAGE_BLOCK_MGC_PLAYLIST", uiElement: nil, creatives: nil)], hasMore: false, cursor: nil)
        let pages = NeteasePageCache(directory: root)
        try await pages.save(feed, scope: "42", key: "feed")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeFailureProtocol.self]
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: config))), directory: root)
        await store.activate(.init(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test")), refresh: false)
        XCTAssertEqual(store.feed, feed)
        await store.refresh()
        XCTAssertEqual(store.feed, feed)
        XCTAssertNotNil(store.feedError)
        await store.activate(nil, refresh: false)
        XCTAssertNil(store.feed)
        XCTAssertNil(store.feedError)
    }

    func testAnonymousRequestOmitsLoginCookie() throws {
        let request = try NeteaseAccountClient().makeRequest(credential: nil, path: "/api/personalized/playlist")
        XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U") == true)
    }
    func testCacheIsolationAndDailyHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Public", creator: "", creatorID: 0, artworkURL: nil, trackCount: 0, isFavorites: false)
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist]
            let snapshots: [String: NeteaseDailySnapshot]
            let details: [Int64: NeteasePlaylistDetail] = [:]
        }
        try JSONEncoder().encode(Cache(recommendations: [playlist], snapshots: [:])).write(to: root.appendingPathComponent("public.json"))
        let date = "2026-11-01"
        try JSONEncoder().encode(Cache(recommendations: [], snapshots: [date: .init(date: date, songs: [])])).write(to: root.appendingPathComponent("42.json"))
        let store = NeteaseHomeStore(directory: root)
        await store.activate(nil, refresh: false)
        XCTAssertEqual(store.recommendations.map(\.id), [12])
        let session = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test"))
        await store.activate(session, refresh: false)
        XCTAssertTrue(store.recommendations.isEmpty)
        XCTAssertNil(store.dailySnapshot(date: date))
        let historical = try await store.loadDailySnapshot(id: date)
        XCTAssertEqual(historical?.date, date)
        await store.activate(nil, refresh: false)
        XCTAssertEqual(store.recommendations.map(\.id), [12])
        XCTAssertNil(store.dailySnapshot(date: date))
        XCTAssertNil(store.daily)
    }
    func testCachedDetailsRemainReadableButRefreshFailureThrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = NeteaseMusicSong(id: 9, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 10)
        let playlist = NeteaseMusicPlaylist(id: 12, title: "List", creator: "", creatorID: 42, artworkURL: nil, trackCount: 1, isFavorites: false)
        let detail = NeteasePlaylistDetail(playlist: playlist, songs: [song], addedTimes: [:])
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist] = []
            let snapshots: [String: NeteaseDailySnapshot]
            let details: [Int64: NeteasePlaylistDetail]
        }
        let first = NeteaseDailySnapshot(date: "2026-11-03", songs: [song], id: "first")
        let second = NeteaseDailySnapshot(date: first.date, songs: [], id: "second")
        try JSONEncoder().encode(Cache(snapshots: [first.id: first, second.id: second, first.date: second], details: [12: detail]))
            .write(to: root.appendingPathComponent("42.json"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeFailureProtocol.self]
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: config))), directory: root)
        await store.activate(.init(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test")), refresh: false)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertNil(store.cachedDetail(id: 12))
        let historical = try await store.loadDailySnapshot(id: first.id)
        let latest = try await store.loadDailySnapshot(id: first.date)
        XCTAssertEqual(store.cachedSongs.map(\.id), [9])
        XCTAssertEqual(historical?.songs.map(\.id), [9])
        XCTAssertEqual(latest?.id, second.id)
        do { _ = try await store.detail(id: 12); XCTFail("Refresh failure must reach the retry UI") }
        catch { XCTAssertEqual(store.cachedDetail(id: 12)?.songs.map(\.id), [9]) }
        await store.activate(nil, refresh: false)
        XCTAssertTrue(store.cachedSongs.isEmpty)
    }

    func testStartupRestoresOnlySummaryAndTodayThenLoadsRequestedCachedPages() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Saved", creator: "Creator", creatorID: 42, artworkURL: nil, trackCount: 1, isFavorites: false)
        func song(_ id: Int64) -> NeteaseMusicSong {
            .init(id: id, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 10)
        }
        let today = NeteaseDailySnapshot(date: NeteaseHomeStore.day(), songs: [song(1)], id: "today")
        let historical = NeteaseDailySnapshot(date: "2026-10-01", songs: [song(2)], id: "history")
        let detail = NeteasePlaylistDetail(playlist: playlist, songs: [song(3)], addedTimes: [:])
        let pages = NeteasePageCache(directory: root)
        try await pages.save([playlist], scope: "42", key: "recommendations")
        try await pages.save(today, scope: "42", key: "daily:" + today.date)
        try await pages.save(historical, scope: "42", key: "daily:" + historical.id)
        try await pages.save(detail, scope: "42", key: "playlist:12")
        try await pages.save(detail, scope: "42", key: "playlist:99")
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.recommendations, [playlist])
        XCTAssertEqual(store.daily?.id, today.id)
        XCTAssertEqual(store.cachedSongs.map(\.id), [1])
        XCTAssertNil(store.dailySnapshot(id: historical.id))
        XCTAssertNil(store.cachedDetail(id: 12))
        let completed = try await store.completeDetail(id: 12)
        XCTAssertEqual(completed.songs.map(\.id), [3])
        XCTAssertEqual(store.cachedSongs.map(\.id), [1, 3])
        XCTAssertNil(store.cachedDetail(id: 99))
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 0)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 0)
        let loadedHistory = try await store.loadDailySnapshot(id: historical.id)
        XCTAssertEqual(loadedHistory?.id, historical.id)
        XCTAssertEqual(store.cachedSongs.map(\.id), [1, 2, 3])
        await store.activate(try savedSession(99), refresh: false)
        let otherPlaylist = try await store.restoreCachedDetail(id: 12)
        let otherHistory = try await store.loadDailySnapshot(id: historical.id)
        XCTAssertNil(otherPlaylist)
        XCTAssertNil(otherHistory)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        await store.activate(nil, refresh: false)
    }

    func testLegacyStartupDefersHistoryMigrationUntilRequested() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = NeteaseMusicSong(id: 9, title: "History", artist: "Artist", album: "Album", artworkURL: nil, duration: 10)
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Saved", creator: "Creator", creatorID: 42, artworkURL: nil, trackCount: 1, isFavorites: false)
        let detail = NeteasePlaylistDetail(playlist: playlist, songs: [song], addedTimes: [:])
        let today = NeteaseDailySnapshot(date: NeteaseHomeStore.day(), songs: [], id: "today")
        let historical = NeteaseDailySnapshot(date: "2026-10-01", songs: [song], id: "history")
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist]
            let snapshots: [String: NeteaseDailySnapshot]
            let details: [Int64: NeteasePlaylistDetail]
        }
        let legacyURL = root.appendingPathComponent("42.json")
        try JSONEncoder().encode(Cache(recommendations: [playlist], snapshots: [today.date: today, historical.id: historical], details: [12: detail]))
            .write(to: legacyURL)
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertEqual(store.daily?.id, today.id)
        XCTAssertEqual(store.recommendations, [playlist])
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertNil(store.cachedDetail(id: 12))
        XCTAssertNil(store.dailySnapshot(id: historical.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let loaded = try await store.restoreCachedDetail(id: 12)
        XCTAssertEqual(loaded?.songs.map(\.id), [9])
        XCTAssertNil(store.dailySnapshot(id: historical.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let archive = root.appendingPathComponent("DailyHistory/42/history.json")
        XCTAssertEqual(try JSONDecoder().decode(NeteaseDailySnapshot.self, from: Data(contentsOf: archive)).id, historical.id)
        let loadedHistory = try await store.loadDailySnapshot(id: historical.id)
        XCTAssertEqual(loadedHistory?.songs.map(\.id), [9])
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testCancelledLazyCacheReadDoesNotPublishItsPage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Saved", creator: "Creator", creatorID: 42, artworkURL: nil, trackCount: 0, isFavorites: false)
        let detail = NeteasePlaylistDetail(playlist: playlist, songs: [], addedTimes: [:])
        try await NeteasePageCache(directory: root).save(detail, scope: "42", key: "playlist:12")
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        let cancelled = Task { try await store.restoreCachedDetail(id: 12) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled consumer must not publish a page") }
        catch is CancellationError { }
        XCTAssertNil(store.cachedDetail(id: 12))
        let active = try await store.restoreCachedDetail(id: 12)
        XCTAssertEqual(active?.playlist.id, 12)
        await store.activate(nil, refresh: false)
    }

    func testOlderQueueMetadataRecoveryReturnsOnlyRequestedSongsWithoutHydratingPages() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func song(_ id: Int64) -> NeteaseMusicSong {
            .init(id: id, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 10)
        }
        let playlist = NeteaseMusicPlaylist(id: 12, title: "Saved", creator: "Creator", creatorID: 42, artworkURL: nil, trackCount: 2, isFavorites: false)
        let pages = NeteasePageCache(directory: root)
        try await pages.save(NeteasePlaylistDetail(playlist: playlist, songs: [song(7), song(70)], addedTimes: [:]), scope: "42", key: "playlist:12")
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist] = []
            let snapshots: [String: NeteaseDailySnapshot] = [:]
            let details: [Int64: NeteasePlaylistDetail]
        }
        try JSONEncoder().encode(Cache(details: [13: .init(playlist: playlist, songs: [song(8), song(80)], addedTimes: [:])]))
            .write(to: root.appendingPathComponent("42.json"))
        let history = root.appendingPathComponent("DailyHistory/42", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try JSONEncoder().encode(NeteaseDailySnapshot(date: "2026-10-01", songs: [song(9), song(90)], id: "old"))
            .write(to: history.appendingPathComponent("old.json"))
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        let recovered = await store.restoreCachedSongs(ids: [7, 8, 9])
        XCTAssertEqual(recovered.map(\.id).sorted(), [7, 8, 9])
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertNil(store.cachedDetail(id: 12))
        XCTAssertNil(store.cachedDetail(id: 13))
        XCTAssertNil(store.dailySnapshot(id: "old"))
        await store.activate(try savedSession(99), refresh: false)
        let otherOwner = await store.restoreCachedSongs(ids: [7, 8, 9])
        XCTAssertTrue(otherOwner.isEmpty)
        await store.activate(nil, refresh: false)
    }

    func testPlaylistCoverDownloadsOnCacheMissAndReusesFile() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let remote = URL(string: "https://fixture.test/first-cover")!
        HomePaginationProtocol.state.withLock { $0.responses[remote.path] = Data("image".utf8) }
        let pages = NeteasePageCache(directory: root.appendingPathComponent("home"))
        let playlist = NeteaseMusicPlaylist(id: 12, title: "List", creator: "Other", creatorID: 99,
            artworkURL: nil, trackCount: 1, isFavorites: false)
        let song = NeteaseMusicSong(id: 1, title: "Song", artist: "Artist", album: "Album", artworkURL: remote, duration: 10)
        try await pages.save(NeteasePlaylistDetail(playlist: playlist, songs: [song], addedTimes: [:]), scope: "42", key: "playlist:12")
        let images = NeteaseArtworkCache(directory: root.appendingPathComponent("artwork"), session: network)
        let store = NeteaseHomeStore(directory: root.appendingPathComponent("home"), artworkCache: images)
        await store.activate(try savedSession(), refresh: false)
        var publications = 0
        store.onDetailChange = { _ in publications += 1 }
        XCTAssertNil(store.cachedArtworkURL(remote: remote))
        let first = try await store.playlistArtworkFile(id: 12)
        XCTAssertNotNil(first)
        let second = try await store.playlistArtworkFile(id: 12)
        XCTAssertEqual(first, second)
        XCTAssertEqual(HomePaginationProtocol.count(remote.path), 1)
        XCTAssertEqual(publications, 0)
        await store.activate(nil, refresh: false)
    }

    func testArtworkIndexRestoresOnDemandAndPublishesAnAlreadyCachedCover() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let remote = try XCTUnwrap(URL(string: "https://fixture.test/restored-artwork"))
        HomePaginationProtocol.state.withLock { $0.responses[remote.path] = Data("image".utf8) }
        let artworkDirectory = root.appendingPathComponent("artwork")
        let writer = NeteaseArtworkCache(directory: artworkDirectory, session: network)
        let saved = try await writer.imageURL(for: remote, scope: "42")
        let images = NeteaseArtworkCache(directory: artworkDirectory, session: network)
        let store = NeteaseHomeStore(directory: root.appendingPathComponent("home"), artworkCache: images)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertNil(store.cachedArtworkURL(remote: remote))
        _ = try await images.imageURL(for: remote, scope: "42")
        var published = Set<URL>()
        store.onArtworkChange = { published.formUnion($0) }
        store.requestArtwork([remote])
        XCTAssertEqual(published, [remote])
        XCTAssertEqual(store.cachedArtworkURL(remote: remote), saved)
        XCTAssertEqual(HomePaginationProtocol.count(remote.path), 1)
        await store.activate(nil, refresh: false)
    }

    func testFirstPageAndCompletePlaybackReuseMetadataAndPreserveOrder() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let first = try await store.detail(id: 12)
        XCTAssertEqual(first.songs.map(\.id), Array(1...100).map(Int64.init))
        XCTAssertEqual(first.orderedTrackIDs.count, 205)
        XCTAssertTrue(first.nextOffset == 100 && !first.isComplete)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 0)
        _ = try await store.detail(id: 12)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        let second = try await store.loadMoreDetail(id: 12)
        XCTAssertEqual(second.nextOffset, 200)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 1)
        let complete = try await store.completeDetail(id: 12)
        XCTAssertEqual(complete.songs.map(\.id), Array(1...205).map(Int64.init))
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 2)
        _ = try await store.completeDetail(id: 12)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 2)
        await store.flush()
        let restored = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await restored.activate(try savedSession(), refresh: false)
        XCTAssertNil(restored.cachedDetail(id: 12))
        XCTAssertTrue(restored.cachedSongs.isEmpty)
        _ = try await restored.completeDetail(id: 12)
        XCTAssertEqual(restored.cachedDetail(id: 12)?.songs.map(\.id), complete.songs.map(\.id))
        XCTAssertTrue(restored.cachedDetail(id: 12)?.isComplete == true)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 2)
        let pages = NeteasePageCache(directory: root)
        let saved = try await pages.load(NeteasePlaylistDetail.self, scope: "42", key: "playlist:12")
        XCTAssertEqual(saved?.nextOffset, 205)
        await store.activate(nil, refresh: false)
        await restored.activate(nil, refresh: false)
    }

    func testFailedNextPagePreservesVisibleSongsAndCanRetry() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        _ = try await store.detail(id: 12)
        let path = "/eapi/v3/song/detail"
        HomePaginationProtocol.state.withLock { $0.failures.insert(path) }
        do { _ = try await store.loadMoreDetail(id: 12); XCTFail("Expected page failure") }
        catch { XCTAssertEqual(store.cachedDetail(id: 12)?.nextOffset, 100) }
        HomePaginationProtocol.state.withLock { $0.failures.remove(path) }
        let retry = try await store.loadMoreDetail(id: 12)
        XCTAssertEqual(retry.nextOffset, 200)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testNextPageWaitingForRefreshStillAdvancesPastTheVisiblePage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        _ = try await store.detail(id: 12)
        let started = expectation(description: "Refresh started")
        let path = "/eapi/v6/playlist/detail"
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let refresh = Task { try await store.detail(id: 12, force: true) }
        await fulfillment(of: [started], timeout: 3)
        let next = Task { try await store.loadMoreDetail(id: 12) }
        await Task.yield()
        HomePaginationProtocol.release(path)
        _ = try await refresh.value
        let loaded = try await next.value
        XCTAssertEqual(loaded.nextOffset, 200)
        XCTAssertEqual(HomePaginationProtocol.count(path), 2)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 1)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testCoverLoadingDoesNotPublishPlaylistContent() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        var publications = 0
        store.onDetailChange = { _ in publications += 1 }
        _ = try await store.playlistArtworkFile(id: 12)
        XCTAssertEqual(publications, 0)
        XCTAssertNotNil(store.cachedDetail(id: 12))
        _ = try await store.detail(id: 12)
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(store.cachedDetail(id: 12)?.nextOffset, 100)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testPlaybackJoiningFirstPageCompletesWithoutRepeatingPlaylistRequest() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        let started = expectation(description: "First page started")
        let path = "/eapi/v6/playlist/detail"
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let first = Task { try await store.detail(id: 12) }
        await fulfillment(of: [started], timeout: 3)
        let playback = Task { try await store.completeDetail(id: 12) }
        await Task.yield()
        HomePaginationProtocol.release(path)
        let detail = try await playback.value
        let initial = try await first.value
        XCTAssertEqual(initial.nextOffset, 100)
        XCTAssertEqual(detail.nextOffset, 205)
        XCTAssertTrue(detail.isComplete)
        XCTAssertEqual(HomePaginationProtocol.count(path), 1)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testCancellingCompletionConsumerKeepsSharedPlaybackRequestAlive() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 101)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        _ = try await store.detail(id: 12)
        let started = expectation(description: "Completion started")
        let path = "/eapi/v3/song/detail"
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let prior = Task { try await store.completeDetail(id: 12) }
        await fulfillment(of: [started], timeout: 3)
        let current = Task { try await store.completeDetail(id: 12) }
        await Task.yield()
        HomePaginationProtocol.state.withLock { $0.blocked.remove(path); $0.started = { _ in } }
        prior.cancel()
        HomePaginationProtocol.release(path)
        _ = await prior.result
        let detail = try await current.value
        XCTAssertEqual(detail.nextOffset, 101)
        XCTAssertTrue(detail.isComplete)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        XCTAssertEqual(HomePaginationProtocol.count(path), 1)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testDailyHistorySurvivesPageCacheEvictionAndRemainsAccountScoped() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = NeteaseMusicSong(id: 9, title: "History", artist: "Artist", album: "Album", artworkURL: nil, duration: 10)
        let snapshot = NeteaseDailySnapshot(date: "2026-10-01", songs: [song], id: "historic")
        struct Cache: Encodable {
            let recommendations: [NeteaseMusicPlaylist] = []
            let snapshots: [String: NeteaseDailySnapshot]
            let details: [Int64: NeteasePlaylistDetail] = [:]
        }
        try JSONEncoder().encode(Cache(snapshots: [snapshot.id: snapshot, snapshot.date: snapshot]))
            .write(to: root.appendingPathComponent("42.json"))
        let store = NeteaseHomeStore(directory: root)
        await store.activate(try savedSession(), refresh: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("42.json").path))
        _ = try await store.loadDailySnapshot(id: snapshot.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("42.json").path))
        let cache = NeteasePageCache(directory: root, capacity: 1)
        try await cache.save("another page", scope: "42", key: "other")
        let restored = NeteaseHomeStore(directory: root)
        await restored.activate(try savedSession(), refresh: false)
        XCTAssertNil(restored.dailySnapshot(id: snapshot.id))
        let archived = try await restored.loadDailySnapshot(id: snapshot.id)
        XCTAssertEqual(archived?.songs.map(\.id), [9])
        await restored.flush()
        await restored.activate(try savedSession(99), refresh: false)
        let otherOwner = try await restored.loadDailySnapshot(id: snapshot.id)
        XCTAssertNil(otherOwner)
        await store.activate(nil, refresh: false)
        await restored.activate(nil, refresh: false)
    }

    func testCompleteCachedPlaylistDoesNotWaitForAnInFlightRefresh() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        _ = try await store.detail(id: 12)
        let started = expectation(description: "Refresh started")
        let ready = expectation(description: "Cached playback ready while refresh waits")
        let path = "/eapi/v6/playlist/detail"
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
        }
        let refresh = Task { try await store.detail(id: 12, force: true) }
        await fulfillment(of: [started], timeout: 3)
        let playback = Task {
            let detail = try await store.completeDetail(id: 12)
            ready.fulfill()
            return detail
        }
        await fulfillment(of: [ready], timeout: 3)
        refresh.cancel()
        HomePaginationProtocol.release(path)
        _ = await refresh.result
        let detail = try await playback.value
        XCTAssertEqual(detail.songs.map(\.id), [1])
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 0)
        await store.flush()
        await store.activate(nil, refresh: false)
    }

    func testAccountSwitchCancelsPendingPageAndDoesNotPublishOldSongs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Page request started")
        let stopped = expectation(description: "Page request cancelled")
        let path = "/eapi/v6/playlist/detail"
        let network = try paginationNetwork(count: 205)
        defer { network.invalidateAndCancel() }
        HomePaginationProtocol.state.withLock {
            $0.blocked.insert(path)
            $0.started = { if $0 == path { started.fulfill() } }
            $0.stopped = { if $0 == path { stopped.fulfill() } }
        }
        let store = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: network)), directory: root)
        await store.activate(try savedSession(), refresh: false)
        let load = Task { try await store.detail(id: 12) }
        await fulfillment(of: [started], timeout: 3)
        await store.activate(try savedSession(99), refresh: false)
        await fulfillment(of: [stopped], timeout: 3)
        do { _ = try await load.value; XCTFail("Old owner request must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.cachedDetail(id: 12))
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertEqual(store.userID, 99)
        let pages = NeteasePageCache(directory: root)
        let old = try await pages.load(NeteasePlaylistDetail.self, scope: "42", key: "playlist:12")
        XCTAssertNil(old)
        await store.activate(nil, refresh: false)
    }

    func testDisplayedHomePlaylistStartsPlaybackWithoutRepeatingMetadataRequests() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let priorOwner = LocalLibrary.playbackAccountID
        let priorExternal = LocalLibrary.songLibrary.externalSongs
        defer {
            LocalLibrary.playbackAccountID = priorOwner
            LocalLibrary.songLibrary.replaceExternalSongs(priorExternal)
        }
        let network = try paginationNetwork(count: 1)
        defer { network.invalidateAndCancel() }
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: network))
        let home = NeteaseHomeStore(client: client, directory: root.appendingPathComponent("home"))
        let music = NeteaseMusicStore(client: client, directory: root.appendingPathComponent("music"))
        let saved = try savedSession()
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, music: music, home: home)
        await account.restore()
        let local = LibrarySongItem(id: "local", title: "Local", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let player = NowPlayingModel(queue: [local], currentIndex: 0, isPlaying: false)
        player.appendLater([local])
        let integration = HomeMusicIntegration(account: account, player: player)
        integration.connect()
        let route = "home:playlist:12"
        _ = integration.destination(for: .playlist(route))
        integration.detailAppeared(route)
        await integration.detailLibrary.loadOnlinePlaylist?(route)
        XCTAssertEqual(integration.detailLibrary.songs(in: route).map(\.id), ["netease:42:1"])
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        integration.requestPlayback(route, songID: 1, shuffled: false)
        for _ in 0..<60 where player.pendingPlay == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.pendingPlay?.songs.map(\.id), ["netease:42:1"])
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v6/playlist/detail"), 1)
        XCTAssertEqual(HomePaginationProtocol.count("/eapi/v3/song/detail"), 0)
        integration.cancelPendingPlayback()
        home.onChange = nil; home.onDetailChange = nil; home.onArtworkChange = nil
        player.shutdownPlayback()
        try await account.logout()
    }

    private func songResponse(_ ids: [Int64], key: String) -> Data {
        let songs: [[String: Any]] = ids.map {
            ["id": $0, "name": "Song \($0)", "ar": [["id": 1, "name": "Artist"]], "al": ["id": 1, "name": "Album"], "dt": 1000]
        }
        return try! JSONSerialization.data(withJSONObject: ["code": 200, key: songs])
    }

    private func feedBlock(_ code: String, id: Int64, title: String = "List") -> NeteaseHomeFeed.Block {
        .init(blockCode: code, uiElement: .init(mainTitle: nil, subTitle: .init(title: title), image: nil),
              creatives: [.init(creativeId: code, creativeType: nil, uiElement: nil,
                                resources: [.init(type: "list", id: id, title: title, artist: "Artist", image: nil)])])
    }
    private func feedResponse(_ code: String, id: Int64, cursor: String? = nil) -> Data {
        let value = NeteaseHomeFeed(blocks: [feedBlock(code, id: id)], hasMore: cursor != nil, cursor: cursor)
        struct Response: Encodable { let code = 200; let data: NeteaseHomeFeed }
        return try! JSONEncoder().encode(Response(data: value))
    }

    private func savedSession(_ id: Int64 = 42) throws -> NeteaseSavedSession {
        .init(profile: .init(userID: id, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test-\(id)"))
    }

    private func paginationNetwork(count: Int) throws -> URLSession {
        let songs: [[String: Any]] = (1...count).map {
            ["id": $0, "name": "Song \($0)", "ar": [["id": 1, "name": "Artist"]], "al": ["id": 1, "name": "Album"], "dt": 1000]
        }
        let playlist: [String: Any] = ["code": 200, "playlist": [
            "id": 12, "name": "List", "creator": ["userId": 42, "nickname": "Test"], "trackCount": count,
            "trackIds": (1...count).map { ["id": $0] }, "tracks": Array(songs.prefix(100))
        ]]
        let responses: [String: Data] = [
            "/eapi/v6/playlist/detail": try JSONSerialization.data(withJSONObject: playlist),
            "/eapi/v3/song/detail": try JSONSerialization.data(withJSONObject: ["code": 200, "songs": songs]),
            "/eapi/user/playlist": Data(#"{"code":200,"playlist":[],"more":false}"#.utf8),
            "/eapi/song/like/get": Data(#"{"code":200,"ids":[]}"#.utf8),
            "/eapi/homepage/block/page": Data(#"{"code":200,"data":{"blocks":[],"hasMore":false}}"#.utf8),
            "/eapi/toplist": Data(#"{"code":200,"list":[]}"#.utf8),
            "/eapi/sub/artist/new/works/song/list": Data(#"{"code":200,"data":{"newWorks":[]}}"#.utf8),
            "/eapi/v1/discovery/new/songs": Data(#"{"code":200,"data":[]}"#.utf8),
            "/eapi/v3/discovery/recommend/songs": Data(#"{"code":200,"data":{"dailySongs":[]}}"#.utf8)
        ]
        HomePaginationProtocol.state.withLock { $0 = .init(responses: responses) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomePaginationProtocol.self]
        return URLSession(configuration: config)
    }

}

private final class HomeFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}

private final class HomePaginationProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [String: Data] = [:]
        var sequences: [String: [Data]] = [:]
        var paths: [String] = []
        var failures: Set<String> = []
        var blocked: Set<String> = []
        var pending: [String: [HomePaginationProtocol]] = [:]
        var started: @Sendable (String) -> Void = { _ in }
        var stopped: @Sendable (String) -> Void = { _ in }
    }
    static let state = Mutex(State())
    static func count(_ path: String) -> Int { state.withLock { $0.paths.filter { $0 == path }.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let (data, fails, blocks, started) = Self.state.withLock { value in
            value.paths.append(path)
            if value.blocked.contains(path) { value.pending[path, default: []].append(self) }
            let next = value.sequences[path]?.isEmpty == false ? value.sequences[path]!.removeFirst() : value.responses[path]
            return (next ?? Data(#"{"code":200,"recommend":[],"result":[]}"#.utf8),
                    value.failures.contains(path), value.blocked.contains(path), value.started)
        }
        started(path)
        if blocks { return }
        if fails { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        respond(data)
    }
    private func respond(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        let path = request.url!.path
        let stopped = Self.state.withLock { value in
            value.pending[path]?.removeAll { $0 === self }
            return value.stopped
        }
        stopped(path)
    }
    static func release(_ path: String) {
        let (pending, data) = state.withLock { value in
            value.blocked.remove(path)
            return (value.pending.removeValue(forKey: path) ?? [], value.responses[path] ?? Data())
        }
        for request in pending { request.respond(data) }
    }
}
