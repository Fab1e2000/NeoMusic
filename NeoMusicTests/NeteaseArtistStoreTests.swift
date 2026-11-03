import XCTest
import Synchronization
@testable import NeoMusic

@MainActor final class NeteaseArtistStoreTests: XCTestCase {
    private func store(offline: Bool = false) async throws -> NeteaseArtistStore {
        ArtistStoreProtocol.state.withLock { $0 = (offline, 0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistStoreProtocol.self]
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: configuration)))
        let store = NeteaseArtistStore(client: client, directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.activate(.init(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test")), refresh: false)
        return store
    }
    func testSuccessfulWriteWithMismatchingReadbackFails() async throws {
        let store = try await store()
        do { try await store.setArtistSubscribed(id: 7, subscribed: true); XCTFail("Mismatching state accepted") }
        catch { XCTAssertFalse(store.subscribedArtists.contains { $0.id == 7 }) }
        XCTAssertEqual(ArtistStoreProtocol.state.withLock { $0.1 }, 2)
    }
    func testOfflineWriteDoesNotReadBackOrRetry() async throws {
        let store = try await store(offline: true)
        do { try await store.setArtistSubscribed(id: 7, subscribed: true); XCTFail("Offline write accepted") }
        catch { XCTAssertTrue(store.subscribedArtists.isEmpty) }
        XCTAssertEqual(ArtistStoreProtocol.state.withLock { $0.1 }, 1)
    }
    func testInvalidationClearsAndSuppressesPendingLoad() async throws {
        let store = try await store()
        let task = Task { await store.loadArtist(id: 7) }
        await Task.yield()
        await store.invalidate()
        await task.value
        XCTAssertNil(store.userID)
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
        XCTAssertTrue(store.errors.isEmpty)
    }
    func testAccountCacheIsolationAndGuestRestoration() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = """
        {"details":[],"releases":[],"similar":[],"albums":[],"artists":[{"id":7,"name":"Public"}],"collected":[],"artwork":{}}
        """
        try Data(cache.utf8).write(to: root.appendingPathComponent("public.json"))
        let store = NeteaseArtistStore(directory: root)
        await store.activate(nil, refresh: false)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
        await store.invalidate()
        XCTAssertTrue(store.subscribedArtists.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        await store.activate(nil, refresh: false)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
    }
    func testGuestCannotWriteSubscriptions() async {
        let store = NeteaseArtistStore(directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do {
            try await store.setArtistSubscribed(id: 7, subscribed: true)
            XCTFail("Guest write succeeded")
        } catch {
            XCTAssertEqual(error as? NeteaseAccountError, .authenticationRequired)
        }
        XCTAssertTrue(store.subscribedArtists.isEmpty)
    }
}

private final class ArtistStoreProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex((false, 0))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let offline = Self.state.withLock { value in value.1 += 1; return value.0 }
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let body = #"{"code":200,"data":[],"hasMore":false}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
