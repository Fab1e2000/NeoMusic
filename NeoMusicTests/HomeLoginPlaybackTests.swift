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
        case "/eapi/v3/discovery/recommend/songs": body = #"{"code":200,"data":{"dailySongs":[]}}"#
        default: body = #"{"code":200,"result":[],"recommend":[]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
