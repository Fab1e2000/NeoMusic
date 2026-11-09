import Synchronization
import XCTest
@testable import NeoMusic

@MainActor final class NeteaseArtworkCacheTests: XCTestCase {
    private let remote = URL(string: "https://artwork.fixture.test/cover")!

    private func network(blocked: Bool = false, status: Int = 200,
                         started: @escaping @Sendable () -> Void = {}) -> URLSession {
        ArtworkCacheProtocol.state.withLock { $0 = .init(blocked: blocked, status: status, started: started) }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [ArtworkCacheProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testConcurrentConsumersShareDownloadAndCancellingOneKeepsOtherAlive() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Shared download started")
        let secondStarted = expectation(description: "Second consumer subscribed")
        let session = network(blocked: true, started: { started.fulfill() })
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        await cache.restore(scope: "42")
        let first = Task { try await cache.imageURL(for: remote, scope: "42") }
        let second = Task {
            secondStarted.fulfill()
            return try await cache.imageURL(for: remote, scope: "42")
        }
        await fulfillment(of: [started, secondStarted], timeout: 3)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer must not receive a file") }
        catch { XCTAssertTrue(error is CancellationError) }
        ArtworkCacheProtocol.finishPending()
        let file = try await second.value
        XCTAssertEqual(try Data(contentsOf: file), Data("artwork".utf8))
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 1)
        XCTAssertEqual(cache.cachedURL(for: remote, scope: "42"), file)
    }

    func testCancelledLastConsumerDoesNotCommitArtwork() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Download started")
        let stopped = expectation(description: "Underlying request stopped")
        let session = network(blocked: true, started: { started.fulfill() })
        ArtworkCacheProtocol.state.withLock { $0.stopped = { stopped.fulfill() } }
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        let request = Task { try await cache.imageURL(for: remote, scope: "42") }
        await fulfillment(of: [started], timeout: 3)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        let restored = NeteaseArtworkCache(directory: directory, session: session)
        await restored.restore(scope: "42")
        XCTAssertNil(restored.cachedURL(for: remote, scope: "42"))
    }

    func testAccountsUseSeparateFilesAndRestoreWithoutDownloading() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        let first = try await cache.imageURL(for: remote, scope: "42")
        XCTAssertNil(cache.cachedURL(for: remote, scope: "43"))
        let second = try await cache.imageURL(for: remote, scope: "43")
        XCTAssertNotEqual(first, second)
        let restored = NeteaseArtworkCache(directory: directory, session: session)
        await restored.restore(scope: "42")
        XCTAssertEqual(restored.cachedURL(for: remote, scope: "42"), first)
        let reused = try await restored.imageURL(for: remote, scope: "43")
        XCTAssertEqual(reused, second)
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 2)
    }

    func testFirstVisibleRequestFindsExistingFileWithCompatibleKeyWithoutNetwork() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Existing SHA256(scope)-SHA256(remote URL) lowercase filename, before key memoization.
        let filename = "73475cb40a568e8da8a045ced110137e159f890ac4da883b6b17dc651b3a8049-104257710801dd3ee6320d3d1a845a651c66e8c477d15f4f618c118323f68843.image"
        let existing = directory.appendingPathComponent(filename)
        let content = Data("cached artwork".utf8)
        try content.write(to: existing)
        let session = network(status: 503)
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        let file = try await cache.imageURL(for: remote, scope: "42")
        XCTAssertEqual(file, existing)
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertEqual(cache.cachedURL(for: remote, scope: "42"), existing)
        XCTAssertNil(cache.cachedURL(for: remote, scope: "43"))
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 0)
    }

    func testColdFileLookupFindsOnlyRequestedArtworkAndMissNeverDownloads() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        let original = NeteaseArtworkCache(directory: directory, session: session)
        let first = try await original.imageURL(for: remote, scope: "42")
        let other = remote.appendingPathComponent("other")
        _ = try await original.imageURL(for: other, scope: "42")
        ArtworkCacheProtocol.state.withLock { $0.requests = 0; $0.status = 503 }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        let cancelled = Task { await cache.cachedFileURL(for: remote, scope: "42") }
        cancelled.cancel()
        let cancelledFile = await cancelled.value
        XCTAssertNil(cancelledFile)
        XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        let file = await cache.cachedFileURL(for: remote, scope: "42")
        XCTAssertEqual(file, first)
        XCTAssertEqual(cache.cachedURL(for: remote, scope: "42"), first)
        XCTAssertNil(cache.cachedURL(for: other, scope: "42"))
        let otherAccount = await cache.cachedFileURL(for: remote, scope: "43")
        let missing = await cache.cachedFileURL(for: remote.appendingPathComponent("missing"), scope: "42")
        XCTAssertNil(otherAccount)
        XCTAssertNil(missing)
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 0)
    }

    func testPointLookupResourceIsInvalidatedByLaterDirectoryEviction() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        let original = NeteaseArtworkCache(directory: directory, session: session)
        let first = try await original.imageURL(for: remote, scope: "42")
        let next = remote.appendingPathComponent("next")
        let second = try await original.imageURL(for: next, scope: "42")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
        ArtworkCacheProtocol.state.withLock { $0.requests = 0; $0.status = 503 }
        let cache = NeteaseArtworkCache(directory: directory, session: session, countLimit: 1)
        let file = await cache.cachedFileURL(for: remote, scope: "42")
        XCTAssertEqual(file, first)
        XCTAssertNil(cache.cachedURL(for: next, scope: "42"))
        let evicted = expectation(description: "Point lookup resource invalidated by full restoration")
        let remote = self.remote
        let observer = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork,
            object: cache, queue: .main) { notification in
                guard let event = NeteaseArtworkCache.eviction(in: notification) else { return }
                MainActor.assumeIsolated {
                    XCTAssertEqual(event.scope, "42")
                    XCTAssertEqual(event.urls, [remote])
                    XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
                    evicted.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        await cache.restore(scope: "42")
        await fulfillment(of: [evicted], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(cache.cachedURL(for: next, scope: "42"), second)
        let removed = await cache.cachedFileURL(for: remote, scope: "42")
        XCTAssertNil(removed)
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 0)
    }

    func testAccountSwitchCancelsOldRequestWithoutSharingItsResult() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Each account owns its request")
        started.expectedFulfillmentCount = 2
        let session = network(blocked: true, started: { started.fulfill() })
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        let old = Task { try await cache.imageURL(for: remote, scope: "42") }
        let current = Task { try await cache.imageURL(for: remote, scope: "43") }
        await fulfillment(of: [started], timeout: 3)
        old.cancel()
        do { _ = try await old.value; XCTFail("Old session must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        ArtworkCacheProtocol.finishPending()
        let file = try await current.value
        XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        XCTAssertEqual(cache.cachedURL(for: remote, scope: "43"), file)
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 2)
    }

    func testFailureCanRetryAndEmptyResponseIsNotCached() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network(status: 503)
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        do { _ = try await cache.imageURL(for: remote, scope: "42"); XCTFail("HTTP error must fail") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
            XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        }
        ArtworkCacheProtocol.state.withLock { $0.status = 200; $0.data = Data() }
        do { _ = try await cache.imageURL(for: remote, scope: "42"); XCTFail("Empty response must fail") }
        catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
            XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        }
        ArtworkCacheProtocol.state.withLock { $0.data = Data("artwork".utf8) }
        let file = try await cache.imageURL(for: remote, scope: "42")
        XCTAssertEqual(try Data(contentsOf: file), Data("artwork".utf8))
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 3)
    }

    func testCapacityEvictsFilesAndMemoryIndexTogether() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        let cache = NeteaseArtworkCache(directory: directory, session: session, byteLimit: 10, countLimit: 2)
        let first = try await cache.imageURL(for: remote, scope: "42")
        let next = remote.appendingPathComponent("next")
        let second = try await cache.imageURL(for: next, scope: "42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
        let restored = NeteaseArtworkCache(directory: directory, session: session, byteLimit: 10, countLimit: 2)
        await restored.restore(scope: "42")
        XCTAssertNil(restored.cachedURL(for: remote, scope: "42"))
        XCTAssertEqual(restored.cachedURL(for: next, scope: "42"), second)
    }

    func testRestoredResourceEvictionNotifiesItsOwnerAndCanReload() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        let original = NeteaseArtworkCache(directory: directory, session: session, countLimit: 1)
        let first = try await original.imageURL(for: remote, scope: "42")
        let cache = NeteaseArtworkCache(directory: directory, session: session, countLimit: 1)
        await cache.restore(scope: "42")
        XCTAssertEqual(cache.cachedURL(for: remote, scope: "42"), first)
        let evicted = expectation(description: "Restored visible resource invalidated")
        let remote = self.remote
        let observer = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork,
            object: cache, queue: .main) { notification in
                guard let event = NeteaseArtworkCache.eviction(in: notification) else { return }
                XCTAssertTrue(NeteaseArtworkCache.evictedURLs(in: notification, scope: "43").isEmpty)
                MainActor.assumeIsolated {
                    let urls = event.scope == "42" ? event.urls : []
                    guard urls.contains(remote) else { return }
                    XCTAssertEqual(urls, [remote])
                    XCTAssertNil(cache.cachedURL(for: remote, scope: "42"))
                    evicted.fulfill()
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await cache.imageURL(for: remote.appendingPathComponent("next"), scope: "42")
        await fulfillment(of: [evicted], timeout: 3)
        let restored = try await cache.imageURL(for: remote, scope: "42")
        XCTAssertEqual(restored, first)
        XCTAssertEqual(try Data(contentsOf: restored), Data("artwork".utf8))
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 3)
    }

    func testArtistArtworkPrefersSquareImageAndReplacesTheNonSquareDefault() {
        let square = NeteaseArtworkURL.artist(img1v1Url: "http://p1.music.126.net/square.jpg", picUrl: "https://p1.music.126.net/wide.jpg")
        XCTAssertEqual(square?.absoluteString, "https://p1.music.126.net/square.jpg")
        let replaced = NeteaseArtworkURL.artist(
            img1v1Url: "https://p1.music.126.net/xxx/5639395138885805.jpg",
            picUrl: "https://p1.music.126.net/wide.jpg")
        XCTAssertEqual(replaced?.absoluteString, "https://p1.music.126.net/VnZiScyynLG7atLIZ2YPkw==/18686200114669622.jpg")
        let wide = NeteaseArtworkURL.artist(img1v1Url: " ", picUrl: "http://p1.music.126.net/wide.jpg")
        XCTAssertEqual(wide?.absoluteString, "https://p1.music.126.net/wide.jpg")
        XCTAssertEqual(NeteaseArtworkURL.downloadURL(for: remote), remote)
    }

    func testNeteaseImageDownloadsAtFixedSizeAndFallsBackToTheOriginalAddress() async throws {
        let canonical = URL(string: "https://p1.music.126.net/abc/cover.jpg?imageView=1&watermark=1")!
        let sized = NeteaseArtworkURL.downloadURL(for: canonical)
        XCTAssertEqual(sized.absoluteString, "https://p1.music.126.net/abc/cover.jpg?param=1024y1024")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = network()
        defer { session.invalidateAndCancel() }
        ArtworkCacheProtocol.state.withLock {
            $0.responses[sized.absoluteString] = (status: 503, data: Data("no".utf8))
        }
        let cache = NeteaseArtworkCache(directory: directory, session: session)
        let file = try await cache.imageURL(for: canonical, scope: "42")
        XCTAssertEqual(try Data(contentsOf: file), Data("artwork".utf8))
        XCTAssertEqual(cache.cachedURL(for: canonical, scope: "42"), file)
        let requested = ArtworkCacheProtocol.state.withLock { $0.urls.map(\.absoluteString) }
        XCTAssertEqual(requested, [sized.absoluteString, canonical.absoluteString])

        ArtworkCacheProtocol.state.withLock { $0.responses = [:]; $0.requests = 0; $0.urls = [] }
        let reused = try await cache.imageURL(for: canonical, scope: "42")
        XCTAssertEqual(reused, file)
        XCTAssertEqual(ArtworkCacheProtocol.state.withLock { $0.requests }, 0)
    }
}

private final class ArtworkCacheProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var blocked = false
        var status = 200
        var data = Data("artwork".utf8)
        var started: @Sendable () -> Void = {}
        var stopped: @Sendable () -> Void = {}
        var requests = 0
        var urls: [URL] = []
        var responses: [String: (status: Int, data: Data)] = [:]
        var pending: [ArtworkCacheProtocol] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (blocked, started) = Self.state.withLock {
            $0.requests += 1
            if let url = request.url { $0.urls.append(url) }
            if $0.blocked { $0.pending.append(self) }
            return ($0.blocked, $0.started)
        }
        started()
        if !blocked { finish() }
    }
    override func stopLoading() {
        let stopped = Self.state.withLock {
            $0.pending.removeAll { $0 === self }
            return $0.stopped
        }
        stopped()
    }
    static func finishPending() {
        let pending = state.withLock { state in
            state.blocked = false
            let pending = state.pending
            state.pending.removeAll()
            return pending
        }
        pending.forEach { $0.finish() }
    }
    private func finish() {
        let (status, data) = Self.state.withLock { state in
            if let url = request.url?.absoluteString, let special = state.responses[url] {
                return (special.status, special.data)
            }
            return (state.status, state.data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
