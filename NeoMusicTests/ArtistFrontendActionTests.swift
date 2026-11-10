import XCTest
import Synchronization
@testable import NeoMusic

@MainActor final class ArtistFrontendActionTests: XCTestCase {
    private struct Subscriptions: Encodable {
        let artists: [NeteaseArtistReference] = []
        let albums: [NeteaseArtistAlbum] = []
        let refreshedAt: [String: Date] = [:]
    }

    private func fixture(offline: Bool = false) async throws -> (ArtistMusicIntegration, NeteaseArtistStore, URL) {
        ArtistFrontendProtocol.state.withLock { $0 = .init(offline: offline) }
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        try await cache.save(Subscriptions(), scope: "42", key: "subscriptions")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistFrontendProtocol.self]
        let store = NeteaseArtistStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(
            session: URLSession(configuration: configuration))), directory: directory)
        let saved = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil),
                                       credential: try .init(musicU: "fixture"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, artists: store)
        await account.restoreCachedContent()
        if let current = LocalLibrary.toasts.current { LocalLibrary.toasts.dismiss(current) }
        return (ArtistMusicIntegration(account: account), store, directory)
    }

    func testAddingReleaseTwiceDoesNotToggleSubscriptionOff() async throws {
        let (integration, store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = LibraryRoute.album("catalog:album:8")
        await integration.setSubscribed(route, subscribed: true)
        XCTAssertEqual(store.subscribedAlbums.map(\.id), [8])
        await integration.setSubscribed(route, subscribed: true)
        XCTAssertEqual(store.subscribedAlbums.map(\.id), [8])
        XCTAssertEqual(ArtistFrontendProtocol.state.withLock { $0.writes }, 1)
        XCTAssertNil(LocalLibrary.toasts.current, "Album collection uses its confirmed button state")
        await store.invalidate()
    }

    func testArtistSuccessFeedbackFollowsConfirmedSubscription() async throws {
        let (integration, store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await integration.setSubscribed(.artist("catalog:artist:7"), subscribed: true)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
        let presentation = try XCTUnwrap(LocalLibrary.toasts.current)
        XCTAssertEqual(presentation.toast.title, "已喜爱")
        LocalLibrary.toasts.dismiss(presentation)
        await store.invalidate()
    }

    func testArtistFailureDoesNotPublishSuccess() async throws {
        let (integration, store, directory) = try await fixture(offline: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await integration.setSubscribed(.artist("catalog:artist:7"), subscribed: true)
        XCTAssertTrue(store.subscribedArtists.isEmpty)
        let presentation = try XCTUnwrap(LocalLibrary.toasts.current)
        guard case .error = presentation.toast else { return XCTFail("Failure must remain an error") }
        LocalLibrary.toasts.dismiss(presentation)
        await store.invalidate()
    }

    func testUnreadyStoreDoesNotPublishSuccessfulFeedback() async throws {
        let (integration, store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.invalidate()
        await integration.setSubscribed(.artist("catalog:artist:7"), subscribed: true)
        XCTAssertEqual(ArtistFrontendProtocol.state.withLock { $0.writes }, 0)
        let presentation = try XCTUnwrap(LocalLibrary.toasts.current)
        guard case .error = presentation.toast else { return XCTFail("Unready content must not report success") }
        LocalLibrary.toasts.dismiss(presentation)
    }

    func testReleaseFromOtherOwnerAndCancelledActionDoNotWrite() async throws {
        let (integration, store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = LibraryShelfItem(id: "catalog:album:8", title: "Album", artwork: .missing,
            route: .album("catalog:album:8"), sourceOwnerID: "43")
        XCTAssertNil(integration.collectRelease(item))
        item.sourceOwnerID = "42"
        let task = try XCTUnwrap(integration.collectRelease(item))
        task.cancel()
        await task.value
        XCTAssertEqual(ArtistFrontendProtocol.state.withLock { $0.writes }, 0)
        XCTAssertNil(LocalLibrary.toasts.current)
        await store.invalidate()
    }
}

private final class ArtistFrontendProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var offline = false
        var writes = 0
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let offline = Self.state.withLock { state in
            if path.hasSuffix("/sub") { state.writes += 1 }
            return state.offline
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: String
        if path.contains("artist/sublist") {
            body = #"{"code":200,"data":[{"id":7,"name":"Artist"}],"hasMore":false}"#
        } else if path.contains("album/sublist") {
            body = #"{"code":200,"data":[{"id":8,"name":"Album","artists":[{"id":7,"name":"Artist"}],"size":10}],"hasMore":false}"#
        } else {
            body = #"{"code":200}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
