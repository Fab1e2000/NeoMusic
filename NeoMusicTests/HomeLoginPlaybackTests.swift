import XCTest
@testable import NeoMusic

@MainActor final class HomeLoginPlaybackTests: XCTestCase {
    private func makeIntegration() -> HomeMusicIntegration {
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})
        return HomeMusicIntegration(account: account)
    }
    func testSuccessfulLoginDismissalPreservesPlaybackRequest() async throws {
        try await exerciseLogin(cancel: false)
    }
    func testCancelledLoginRequestDoesNotPlayAfterLoginSucceeds() async throws {
        try await exerciseLogin(cancel: true)
    }
    func testQuickActionLoginResumesBatchWithManualQueueConfirmation() async throws {
        try await withQuickActionIntegration { account, _, integration, player in
            integration.requestQuickAction(.privateRoaming)
            XCTAssertTrue(integration.showsLogin)
            XCTAssertEqual(integration.pendingQuickAction, .privateRoaming)
            try await account.completeLogin(credential: .init(musicU: "test"))
            for _ in 0..<60 where player.pendingPlay == nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(integration.showsLogin)
            integration.loginDismissed()
            XCTAssertNil(integration.pendingQuickAction)
            XCTAssertEqual(player.current.id, "local")
            XCTAssertEqual(player.pendingPlay?.songs.map(\.id), ["netease:42:7", "netease:42:9"])
            XCTAssertEqual(player.pendingPlay?.source, "私人漫游")
            XCTAssertNil(integration.model.quickActionRoute)
        }
    }
    func testCancelledQuickActionLoginDoesNotResumePlayback() async throws {
        try await withQuickActionIntegration { account, _, integration, player in
            integration.requestQuickAction(.privateRoaming)
            integration.showsLogin = false
            integration.loginDismissed()
            XCTAssertNil(integration.pendingQuickAction)
            try await account.completeLogin(credential: .init(musicU: "test"))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(player.pendingPlay)
            XCTAssertEqual(player.current.id, "local")
        }
    }
    func testRoamingBatchSurvivesCancelledConfirmationAndIsConsumedOnAcceptance() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            guard case .roaming(let preparedID, _) = try await home.performQuickAction(.privateRoaming) else {
                return XCTFail("Home did not prepare a roaming batch")
            }
            integration.requestQuickAction(.privateRoaming)
            for _ in 0..<60 where player.pendingPlay == nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNotNil(player.pendingPlay)
            player.pendingPlay = nil
            guard case .roaming(let retainedID, _) = try await home.performQuickAction(.privateRoaming) else {
                return XCTFail("Cancelled confirmation discarded the batch")
            }
            XCTAssertEqual(retainedID, preparedID)
            XCTAssertEqual(player.current.id, "local")
            integration.requestQuickAction(.privateRoaming)
            for _ in 0..<60 where player.pendingPlay == nil { try await Task.sleep(for: .milliseconds(25)) }
            player.confirmPendingPlay()
            XCTAssertEqual(player.queue.map(\.id), ["netease:42:7", "netease:42:9"])
            guard case .roaming(let nextID, _) = try await home.performQuickAction(.privateRoaming) else {
                return XCTFail("The next tap did not prepare another batch")
            }
            XCTAssertNotEqual(nextID, preparedID)
        }
    }
    func testQuickActionFailuresKeepQueueAndPublishLocalRetryState() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            integration.requestQuickAction(.similarSongs)
            for _ in 0..<60 where home.quickActionStates[.similarSongs] == nil || home.quickActionStates[.similarSongs] == .loading {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(home.quickActionStates[.similarSongs], .failed(NeteaseHomeActionError.noCurrentOnlineSong.localizedDescription))
            XCTAssertEqual(integration.model.quickActionStates[.similarSongs], .failed(NeteaseHomeActionError.noCurrentOnlineSong.localizedDescription))
            XCTAssertEqual(player.current.id, "local")
            XCTAssertNil(player.pendingPlay)
        }
    }
    func testEmptyPlaybackResponseKeepsCurrentSongAndManualQueue() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            let current = LibrarySongItem(id: "netease:42:10", title: "Current", artist: "Artist", album: "Album",
                                          albumArtist: "Artist", trackNumber: 0, artwork: .missing)
            player.play([current], startingAt: 0, from: "Existing")
            player.appendLater([current])
            let queue = player.queue
            integration.requestQuickAction(.similarSongs)
            for _ in 0..<60 where home.quickActionStates[.similarSongs] == nil || home.quickActionStates[.similarSongs] == .loading {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(home.quickActionStates[.similarSongs], .failed(NeteaseHomeActionError.emptySongs.localizedDescription))
            XCTAssertEqual(player.queue, queue)
            XCTAssertTrue(player.hasUserQueuedUpcoming)
            XCTAssertNil(player.pendingPlay)
        }
    }
    func testQuickActionNavigationResumesAfterLoginAndHotChartWorksForGuest() async throws {
        try await withQuickActionIntegration { account, _, integration, player in
            integration.requestQuickAction(.hotSongs)
            for _ in 0..<60 where integration.model.quickActionRoute == nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(integration.showsLogin)
            XCTAssertEqual(integration.model.quickActionRoute, .playlist("home:playlist:12"))
            integration.requestQuickAction(.dailySongs)
            XCTAssertTrue(integration.showsLogin)
            try await account.completeLogin(credential: .init(musicU: "test"))
            for _ in 0..<60 where integration.model.quickActionRoute == nil { try await Task.sleep(for: .milliseconds(25)) }
            guard let destination = integration.model.quickActionRoute, case .playlist(let route) = destination else {
                return XCTFail("Daily route was not published")
            }
            XCTAssertTrue(route.hasPrefix("home:daily:42:"))
            XCTAssertNil(integration.pendingQuickAction)
            XCTAssertNil(player.pendingPlay)
        }
    }
    func testAccountSwitchDiscardsPendingQuickActionResultAndNavigation() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            try await consumePreparedRoamingBatch(home)
            integration.requestQuickAction(.privateRoaming)
            for _ in 0..<60 where home.quickActionStates[.privateRoaming] != .loading { try await Task.sleep(for: .milliseconds(5)) }
            try await account.completeLogin(credential: .init(musicU: "other"))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(account.profile?.userID, 43)
            XCTAssertNil(integration.pendingQuickAction)
            XCTAssertNil(integration.model.quickActionRoute)
            XCTAssertNil(player.pendingPlay)
            XCTAssertEqual(player.current.id, "local")
        }
    }
    func testChoosingFeedSongCancelsDelayedQuickActionAndPreservesNewSelection() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            try await consumePreparedRoamingBatch(home)
            integration.requestQuickAction(.privateRoaming)
            for _ in 0..<60 where home.quickActionStates[.privateRoaming] != .loading { try await Task.sleep(for: .milliseconds(5)) }
            integration.model.play(NeteaseHomeCategory.songRecommendations.rawValue, "song/15")
            XCTAssertEqual(player.pendingPlay?.songs.map(\.id), ["netease:42:15"])
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(home.quickActionStates[.privateRoaming])
            XCTAssertNil(integration.model.quickActionStates[.privateRoaming])
            XCTAssertEqual(player.pendingPlay?.songs.map(\.id), ["netease:42:15"])
            XCTAssertEqual(player.current.id, "local")
        }
    }
    func testChoosingAnotherQuickActionCancelsDelayedPlayback() async throws {
        try await withQuickActionIntegration { account, home, integration, player in
            try await account.completeLogin(credential: .init(musicU: "test"))
            try await consumePreparedRoamingBatch(home)
            integration.requestQuickAction(.privateRoaming)
            for _ in 0..<60 where home.quickActionStates[.privateRoaming] != .loading { try await Task.sleep(for: .milliseconds(5)) }
            integration.requestQuickAction(.hotSongs)
            for _ in 0..<60 where integration.model.quickActionRoute == nil { try await Task.sleep(for: .milliseconds(25)) }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(integration.model.quickActionRoute, .playlist("home:playlist:12"))
            XCTAssertNil(home.quickActionStates[.privateRoaming])
            XCTAssertNil(player.pendingPlay)
            XCTAssertEqual(player.current.id, "local")
        }
    }
    private func consumePreparedRoamingBatch(_ home: NeteaseHomeStore) async throws {
        guard case .roaming(let id, _) = try await home.performQuickAction(.privateRoaming) else {
            return XCTFail("Expected prepared roaming batch")
        }
        home.consumeRoamingBatch(id: id)
    }
    func testHomeNavigationSeedsVisibleArtworkBeforeLoadingAndRetainsItWithoutNewCover() async throws {
        try await withQuickActionIntegration { account, _, integration, _ in
            try await account.completeLogin(credential: .init(musicU: "test"))
            let route = LibraryRoute.playlist("home:playlist:12")
            let cover = Artwork.file(URL(fileURLWithPath: "/tmp/home-visible-cover.jpg"))
            let preview = LibraryNavigationPreview(route: route, ownerID: "42", title: "Visible title", subtitle: "Creator", artwork: cover)
            integration.model.prepareNavigation(preview)
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:12")?.title, preview.title)
            XCTAssertNotNil(integration.destination(for: route))
            // The hot-card prefetch has already supplied this playlist's actual title.
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:12")?.title, "List")
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:12")?.artwork, cover)
            await integration.detailLibrary.loadOnlinePlaylist?("home:playlist:12")
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:12")?.title, "List")
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:12")?.artwork, cover)
            XCTAssertEqual(integration.detailLibrary.songs(in: "home:playlist:12").map(\.id), ["netease:42:9"])
        }
    }
    func testDailyNavigationSeedsDisplayedCoverAndLoadsRealSnapshotArtwork() async throws {
        try await withQuickActionIntegration { account, _, integration, _ in
            try await account.completeLogin(credential: .init(musicU: "test"))
            let dailyIndex = try XCTUnwrap(integration.model.quickActions.firstIndex { $0.action == .dailySongs })
            XCTAssertNotNil(integration.model.quickActions[dailyIndex].artwork)
            let visible = Artwork.file(URL(fileURLWithPath: "/tmp/visible-daily-cover.jpg"))
            integration.model.quickActions[dailyIndex].artwork = visible
            integration.requestQuickAction(.dailySongs)
            for _ in 0..<60 where integration.model.quickActionPreview == nil { try await Task.sleep(for: .milliseconds(25)) }
            let preview = try XCTUnwrap(integration.model.quickActionPreview)
            XCTAssertEqual(preview.artwork, visible)
            guard case .playlist(let route) = preview.route else { return XCTFail("Missing daily detail route") }
            XCTAssertEqual(integration.detailLibrary.playlist(route)?.artwork, visible)
            await integration.detailLibrary.loadOnlinePlaylist?(route)
            let loaded = try XCTUnwrap(integration.detailLibrary.playlist(route))
            XCTAssertNotEqual(loaded.artwork, .playlist)
            XCTAssertNotEqual(loaded.artwork, visible)
            XCTAssertEqual(integration.detailLibrary.songs(in: route).map(\.id), ["netease:42:9"])
        }
    }
    func testAccountSwitchClearsNavigationPreviewBeforeAnyDetailWasLoaded() async throws {
        try await withQuickActionIntegration { account, _, integration, _ in
            try await account.completeLogin(credential: .init(musicU: "test"))
            let route = LibraryRoute.playlist("home:playlist:13")
            let preview = LibraryNavigationPreview(route: route, ownerID: "42", title: "Old account", artwork: .favorites)
            integration.model.prepareNavigation(preview)
            try await account.completeLogin(credential: .init(musicU: "other"))
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:13")?.artwork, .playlist)
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:13")?.sourceOwnerID, "43")
            integration.model.prepareNavigation(preview)
            XCTAssertEqual(integration.detailLibrary.playlist("home:playlist:13")?.artwork, .playlist)
        }
    }
    private func withQuickActionIntegration(_ body: (NeteaseAccount, NeteaseHomeStore, HomeMusicIntegration, NowPlayingModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeLoginProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: session))
        let home = NeteaseHomeStore(client: client, directory: root.appendingPathComponent("home"))
        let music = NeteaseMusicStore(client: client, directory: root.appendingPathComponent("music"))
        await home.activate(nil, refresh: false)
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { .init(userID: $0.musicU == "other" ? 43 : 42, nickname: "Test", avatarURL: nil) },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: music, home: home)
        let local = LibrarySongItem(id: "local", title: "Local", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let player = NowPlayingModel(queue: [local], currentIndex: 0, isPlaying: false)
        player.appendLater([local])
        let priorOwner = LocalLibrary.playbackAccountID
        let priorExternal = LocalLibrary.songLibrary.externalSongs
        let integration = HomeMusicIntegration(account: account, player: player)
        integration.connect()
        defer {
            integration.cancelPendingPlayback(); player.shutdownPlayback(); home.onChange = nil
            session.invalidateAndCancel()
            LocalLibrary.playbackAccountID = priorOwner
            LocalLibrary.songLibrary.replaceExternalSongs(priorExternal)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(account, home, integration, player)
    }
    private func exerciseLogin(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let priorOwner = LocalLibrary.playbackAccountID
        let priorExternal = LocalLibrary.songLibrary.externalSongs
        defer {
            LocalLibrary.playbackAccountID = priorOwner
            LocalLibrary.songLibrary.replaceExternalSongs(priorExternal)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeLoginProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: session))
        let home = NeteaseHomeStore(client: client, directory: root.appendingPathComponent("home"))
        let music = NeteaseMusicStore(client: client, directory: root.appendingPathComponent("music"))
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in .init(userID: 42, nickname: "Test", avatarURL: nil) },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: music, home: home)
        let song = LibrarySongItem(id: "local", title: "Local", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
        let player = NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false)
        player.appendLater([song])
        let integration = HomeMusicIntegration(account: account, player: player)
        integration.connect()
        defer { integration.cancelPendingPlayback(); player.shutdownPlayback(); home.onChange = nil }
        let route = "home:playlist:12"
        integration.detailAppeared(route)
        integration.requestPlayback(route, songID: 9, shuffled: false)
        integration.detailDisappeared(route)
        if cancel { integration.showsLogin = false; integration.loginDismissed() }
        try await account.completeLogin(credential: .init(musicU: "test"))
        integration.resumePendingPlayback()
        if !cancel {
            XCTAssertFalse(integration.showsLogin)
            integration.loginDismissed()
            for _ in 0..<60 where player.pendingPlay == nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(player.pendingPlay?.songs.map(\.id), ["netease:42:9"])
            XCTAssertEqual(player.pendingPlay?.startingIndex, 0)
            XCTAssertEqual(player.pendingPlay?.collection?.ownerID, "42")
        } else {
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(player.pendingPlay)
            XCTAssertEqual(player.current.id, "local")
        }
    }

    func testLoginPresentationPreservesRequestAndCancellationDiscardsIt() {
        let integration = makeIntegration()
        let route = "home:playlist:42"
        integration.detailAppeared(route)
        integration.requestPlayback(route, songID: 7, shuffled: false)
        XCTAssertTrue(integration.showsLogin)
        integration.detailDisappeared(route)
        XCTAssertEqual(integration.pending?.route, route)
        integration.showsLogin = false
        integration.loginDismissed()
        XCTAssertNil(integration.pending)
    }
    func testUnreadyAccountDoesNotConsumePendingPlayback() {
        let integration = makeIntegration()
        let route = "home:playlist:42"
        integration.detailAppeared(route)
        integration.requestPlayback(route, songID: 7, shuffled: false)
        integration.resumePendingPlayback()
        XCTAssertEqual(integration.pending?.songID, 7)
        XCTAssertTrue(integration.showsLogin)
    }
    func testNewRequestReplacesPriorAndLeavingDetailCancels() {
        let integration = makeIntegration()
        let route = "home:playlist:42"
        integration.detailAppeared(route)
        integration.requestPlayback(route, songID: 7, shuffled: false)
        integration.requestPlayback(route, songID: 8, shuffled: false)
        XCTAssertEqual(integration.pending?.songID, 8)
        integration.showsLogin = false
        integration.detailDisappeared(route)
        XCTAssertNil(integration.pending)
    }
}

private final class HomeLoginProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case "/eapi/v6/playlist/detail":
            Thread.sleep(forTimeInterval: 0.15)
            body = #"{"code":200,"playlist":{"id":12,"name":"List","creator":{"userId":42,"nickname":"Test"},"trackCount":1,"trackIds":[{"id":9}]}}"#
        case "/eapi/v3/song/detail": body = #"{"code":200,"songs":[{"id":9,"name":"Song","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":10000}]}"#
        case "/eapi/user/playlist": body = #"{"code":200,"playlist":[],"more":false}"#
        case "/eapi/song/like/get": body = #"{"code":200,"ids":[]}"#
        case "/eapi/v3/discovery/recommend/songs": body = #"{"code":200,"data":{"dailySongs":[{"id":9,"name":"Daily song","ar":[{"name":"Artist"}],"al":{"name":"Album","picUrl":"https://fixture.test/daily-cover"},"dt":10000}]}}"#
        case "/eapi/v1/radio/get":
            Thread.sleep(forTimeInterval: 0.15)
            body = #"{"code":200,"data":[{"id":7,"name":"First","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":10000},{"id":9,"name":"Second","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":10000}]}"#
        case "/eapi/toplist": body = #"{"code":200,"list":[{"id":12,"name":"热歌榜"}]}"#
        case "/eapi/homepage/block/page": body = #"{"code":200,"data":{"blocks":[{"blockCode":"HOMEPAGE_BLOCK_STYLE_RCMD","uiElement":{"subTitle":{"title":"根据《Seed》推荐"}},"creatives":[{"resources":[{"resourceType":"song","resourceId":"15","song":{"id":15,"title":"Feed song","artist":"Artist","album":"Album","duration":20,"unavailable":false}}]}]}],"hasMore":false}}"#
        case "/eapi/sub/artist/new/works/song/list": body = #"{"code":200,"data":{"newWorks":[]}}"#
        case "/eapi/v1/discovery/new/songs": body = #"{"code":200,"data":[]}"#
        case "/eapi/v1/discovery/simiSong": body = #"{"code":200,"songs":[]}"#
        default: body = #"{"code":200,"result":[],"recommend":[]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
