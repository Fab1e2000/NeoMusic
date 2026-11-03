import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseAvatarClientTests: XCTestCase, @unchecked Sendable {
    private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aHfkAAAAASUVORK5CYII=")!

    func testConfigurationEnablesDedicatedDiskCacheWithoutAuthenticationStorage() throws {
        let configuration = NeteaseAvatarClient.sessionConfiguration()
        let cache = try XCTUnwrap(configuration.urlCache)
        XCTAssertFalse(cache === URLCache.shared)
        XCTAssertEqual(cache.memoryCapacity, 2 * 1024 * 1024)
        XCTAssertEqual(cache.diskCapacity, 20 * 1024 * 1024)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testNativeURLCacheReturnsAvatarForUnresolvableHostWithoutNetworkProtocolStub() async throws {
        let cache = makeCache()
        let url = URL(string: "https://avatar-cache-hit.invalid/\(UUID().uuidString).png")!
        store(image, at: url, in: cache)
        let session = makeSession(cache: cache)
        defer { session.invalidateAndCancel(); cache.removeAllCachedResponses() }

        let data = try await NeteaseAvatarClient(session: session).data(for: url)

        XCTAssertEqual(data, image)
        XCTAssertEqual(cache.cachedResponse(for: request(url))?.data, image)
    }

    func testCachedDataImmediatelyReturnsExpiredAvatarForUnresolvableHost() async throws {
        let cache = makeCache()
        let url = URL(string: "https://avatar-expired.invalid/\(UUID().uuidString).png")!
        store(image, at: url, in: cache, fresh: false)
        let session = makeSession(cache: cache)
        defer { session.invalidateAndCancel(); cache.removeAllCachedResponses() }
        let client = NeteaseAvatarClient(session: session)

        let cached = await client.cachedData(for: url)
        let missing = await client.cachedData(for: URL(string: "https://avatar-expired.invalid/missing.png")!)

        XCTAssertEqual(cached, image)
        XCTAssertNil(missing)
    }

    func testDiskOnlyCacheRestoresAvatarThroughANewCacheAndClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NeteaseAvatarCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://avatar-persisted.invalid/avatar.png")!
        do {
            let cache = URLCache(memoryCapacity: 0, diskCapacity: 20 * 1024 * 1024, directory: directory)
            store(image, at: url, in: cache, storagePolicy: .allowed)
            let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { [weak cache] _, _ in
                (cache?.currentDiskUsage ?? 0) > 0
            }, object: nil)
            await fulfillment(of: [persisted], timeout: 10)
            XCTAssertGreaterThan(cache.currentDiskUsage, 0)
        }

        let restoredCache = URLCache(memoryCapacity: 0, diskCapacity: 20 * 1024 * 1024, directory: directory)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { [image] _, _ in
            restoredCache.cachedResponse(for: URLRequest(url: url))?.data == image
        }, object: nil)
        await fulfillment(of: [restored], timeout: 10)
        let session = makeSession(cache: restoredCache)
        defer { session.invalidateAndCancel(); restoredCache.removeAllCachedResponses() }

        let data = await NeteaseAvatarClient(session: session).cachedData(for: url)

        XCTAssertEqual(data, image)
        XCTAssertEqual(restoredCache.memoryCapacity, 0)
    }

    func testDifferentAvatarURLDoesNotReusePreviousCachedImage() async throws {
        let cache = makeCache()
        let first = URL(string: "https://avatar-cache.invalid/first.png")!
        let second = URL(string: "https://avatar-cache.invalid/second.png")!
        store(image, at: first, in: cache)
        NeteaseAvatarURLProtocol.state.withLock { $0 = .init(error: URLError(.notConnectedToInternet)) }
        let session = makeSession(cache: cache, usesProtocolStub: true)
        defer { session.invalidateAndCancel(); cache.removeAllCachedResponses() }

        do {
            _ = try await NeteaseAvatarClient(session: session).data(for: second)
            XCTFail("An uncached URL must not return the previous avatar")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }

        XCTAssertNil(cache.cachedResponse(for: request(second)))
        XCTAssertEqual(cache.cachedResponse(for: request(first))?.data, image)
        XCTAssertEqual(NeteaseAvatarURLProtocol.state.withLock { $0.request?.url }, second)
    }

    func testClearingAvatarCachePreservesIndependentCache() async throws {
        let avatarCache = makeCache(), otherCache = makeCache()
        let url = URL(string: "https://avatar-cache.invalid/shared-name.png")!
        let otherData = Data("independent cached response".utf8)
        store(image, at: url, in: avatarCache)
        store(otherData, at: url, in: otherCache)
        let session = makeSession(cache: avatarCache)
        defer { session.invalidateAndCancel(); otherCache.removeAllCachedResponses() }

        NeteaseAvatarClient(session: session).clearCache()

        XCTAssertNil(avatarCache.cachedResponse(for: request(url)))
        XCTAssertEqual(otherCache.cachedResponse(for: request(url))?.data, otherData)
    }

    func testAvatarRequestKeepsCookiesAndAuthorizationOutOfTransport() async throws {
        let cache = makeCache()
        NeteaseAvatarURLProtocol.state.withLock { $0 = .init(body: image) }
        let session = makeSession(cache: cache, usesProtocolStub: true)
        defer { session.invalidateAndCancel(); cache.removeAllCachedResponses() }
        let url = URL(string: "https://avatar-transport.invalid/image.png")!

        let data = try await NeteaseAvatarClient(session: session).data(for: url)

        XCTAssertEqual(data, image)
        let sent = try XCTUnwrap(NeteaseAvatarURLProtocol.state.withLock { $0.request })
        XCTAssertEqual(sent.url, url)
        XCTAssertEqual(sent.cachePolicy, .useProtocolCachePolicy)
        XCTAssertFalse(sent.httpShouldHandleCookies)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testHTTPFailureAndEmptyImageAreReported() async throws {
        for (status, body) in [(401, image), (404, image), (503, image), (200, Data())] {
            let cache = makeCache()
            NeteaseAvatarURLProtocol.state.withLock { $0 = .init(body: body, status: status) }
            let session = makeSession(cache: cache, usesProtocolStub: true)
            let url = URL(string: "https://avatar-response.invalid/\(status).png")!
            do {
                _ = try await NeteaseAvatarClient(session: session).data(for: url)
                XCTFail("Expected the invalid avatar response to fail")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
            session.invalidateAndCancel()
        }
    }

    func testCancellationStopsPendingAvatarRequest() async throws {
        let started = expectation(description: "Avatar request started")
        let stopped = expectation(description: "Avatar request cancelled")
        NeteaseAvatarURLProtocol.state.withLock {
            $0 = .init(wait: true, started: started, stopped: stopped)
        }
        let cache = makeCache()
        let session = makeSession(cache: cache, usesProtocolStub: true)
        defer { session.invalidateAndCancel(); cache.removeAllCachedResponses() }
        let client = NeteaseAvatarClient(session: session)
        let task = Task { try await client.data(for: URL(string: "https://avatar-cancel.invalid/image.png")!) }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()

        do { _ = try await task.value; XCTFail("A cancelled avatar request must fail") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    private func makeCache() -> URLCache {
        URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, directory: nil)
    }

    private func makeSession(cache: URLCache, usesProtocolStub: Bool = false) -> URLSession {
        let configuration = NeteaseAvatarClient.sessionConfiguration()
        configuration.urlCache = cache
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        if usesProtocolStub { configuration.protocolClasses = [NeteaseAvatarURLProtocol.self] }
        return URLSession(configuration: configuration)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.httpShouldHandleCookies = false
        return request
    }

    private func store(_ data: Data, at url: URL, in cache: URLCache, fresh: Bool = true,
                       storagePolicy: URLCache.StoragePolicy = .allowedInMemoryOnly) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png",
                                                      "Date": formatter.string(from: fresh ? Date() : Date(timeIntervalSince1970: 0)),
                                                      "Cache-Control": fresh ? "public, max-age=86400" : "public, max-age=0"])!
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data, storagePolicy: storagePolicy),
                                  for: request(url))
    }
}

private final class NeteaseAvatarURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var body = Data()
        var status = 200
        var error: URLError?
        var wait = false
        var started: XCTestExpectation?
        var stopped: XCTestExpectation?
        var request: URLRequest?
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.state.withLock { state in
            state.request = request
            return state
        }
        state.started?.fulfill()
        guard !state.wait else { return }
        if let error = state.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: state.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.withLock { $0.stopped }?.fulfill() }
}
