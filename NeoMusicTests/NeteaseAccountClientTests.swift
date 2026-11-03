import CommonCrypto
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseAccountClientTests: XCTestCase, @unchecked Sendable {
    func testCredentialAcceptsOnlyLiveCookiesFromExactNeteaseDomains() throws {
        let credential = try NeteaseCredential(cookies: [
            cookie("MUSIC_U", "foreign", domain: "evil163.com"),
            cookie("MUSIC_U", "subdomain", domain: "accounts.music.163.com"),
            cookie("MUSIC_U", "root", domain: ".163.com"),
            cookie("MUSIC_U", "music", domain: ".music.163.com"),
            cookie("__csrf", "csrf", domain: "music.163.com"),
            cookie("unrelated", "ignored", domain: "music.163.com")
        ])
        XCTAssertEqual(credential.musicU, "music")
        XCTAssertEqual(credential.csrf, "csrf")
        let encoded = try JSONEncoder().encode(credential)
        XCTAssertEqual(try JSONDecoder().decode(NeteaseCredential.self, from: encoded), credential)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("ignored"))
    }

    func testCredentialRejectsMissingEmptyAndExpiredAuthentication() {
        let inputs: [[HTTPCookie]] = [[], [cookie("__csrf", "csrf")],
                                    [cookie("MUSIC_U", " ")],
                                    [cookie("MUSIC_U", "expired", expires: Date(timeIntervalSinceNow: -60))],
                                    [cookie("MUSIC_U", "foreign", domain: "music.163.com.example.com")]]
        for cookies in inputs {
            XCTAssertThrowsError(try NeteaseCredential(cookies: cookies)) {
                XCTAssertEqual($0 as? NeteaseAccountError, .authenticationRequired)
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(NeteaseCredential.self, from: Data(#"{"musicU":""}"#.utf8)))
    }

    @MainActor func testEphemeralConfigurationAndEncryptedAccountRequest() throws {
        let configuration = NeteaseAccountClient.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        let credential = try NeteaseCredential(musicU: "fixture-token", csrf: "fixture-csrf")
        let request = try NeteaseAccountClient(deviceID: "fixture-device").makeRequest(credential: credential)
        XCTAssertEqual(request.url?.absoluteString, "https://interface.music.163.com/eapi/w/nuser/account/get")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=fixture-token") == true)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("params="))
        XCTAssertFalse(body.contains("fixture-token"))
        let framed = try decrypt(String(body.dropFirst("params=".count)))
        let parts = framed.components(separatedBy: "-36cd479b6b5-")
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        XCTAssertEqual(parts[0], "/api/w/nuser/account/get")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
        let header = try XCTUnwrap(payload["header"] as? [String: String])
        XCTAssertEqual(header["MUSIC_U"], "fixture-token")
        XCTAssertEqual(header["__csrf"], "fixture-csrf")
        XCTAssertEqual(header["deviceId"], "fixture-device")
        XCTAssertEqual(payload["e_r"] as? Bool, false)
        let expectedDigest = Insecure.MD5.hash(data: Data("nobody\(parts[0])use\(parts[1])md5forencrypt".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(parts[2], expectedDigest)
    }

    @MainActor func testProfileDecodesStableIdentityAndOptionalAvatar() async throws {
        let (client, session) = makeClient(body: #"{"code":200,"profile":{"userId":922337203685477,"nickname":"听众","avatarUrl":"https://p1.music.126.net/avatar.jpg"}}"#)
        defer { session.invalidateAndCancel() }
        let profile = try await client.profile(credential: credential())
        XCTAssertEqual(profile.userID, 922337203685477)
        XCTAssertEqual(profile.nickname, "听众")
        XCTAssertEqual(profile.avatarURL?.host, "p1.music.126.net")
        NeteaseAccountURLProtocol.state.withLock {
            $0.body = Data(#"{"code":200,"profile":{"userId":7,"nickname":"无头像"}}"#.utf8)
        }
        let withoutAvatar = try await client.profile(credential: credential())
        XCTAssertNil(withoutAvatar.avatarURL)
    }

    @MainActor func testAuthenticationServerHTTPAndMalformedResponsesStayDistinct() async throws {
        let cases: [(String, Int, NeteaseAccountError)] = [
            (#"{"code":301}"#, 200, .authenticationRequired),
            (#"{"code":401}"#, 200, .authenticationRequired),
            (#"{"code":200,"account":null,"profile":null}"#, 200, .authenticationRequired),
            (#"{"code":301,"profile":{"unexpected":true}}"#, 200, .authenticationRequired),
            ("", 401, .authenticationRequired),
            ("", 503, .http(503)),
            (#"{"code":460}"#, 200, .server(460)),
            ("", 200, .invalidResponse),
            (#"{"code":200}"#, 200, .invalidResponse),
            (#"{"code":200,"profile":null}"#, 200, .invalidResponse),
            (#"{"code":200,"account":null}"#, 200, .invalidResponse),
            (#"{"code":200,"account":{"id":7},"profile":null}"#, 200, .invalidResponse),
            (#"{"code":200,"profile":{"userId":0,"nickname":"invalid"}}"#, 200, .invalidResponse),
            (#"{"code":200,"profile":{"userId":8,"nickname":" "}}"#, 200, .invalidResponse)
        ]
        for (body, status, expected) in cases {
            let (client, session) = makeClient(body: body, status: status)
            do { _ = try await client.profile(credential: credential()); XCTFail("Accepted \(expected)") }
            catch { XCTAssertEqual(error as? NeteaseAccountError, expected) }
            session.invalidateAndCancel()
        }
    }

    @MainActor func testHTTPAvatarUpgradesToHTTPSAndInvalidAvatarPreservesAccount() async throws {
        let avatars: [(String, String?)] = [
            ("http://p1.music.126.net/avatar.jpg?param=160y160", "https://p1.music.126.net/avatar.jpg?param=160y160"),
            ("https://p1.music.126.net/avatar.jpg", "https://p1.music.126.net/avatar.jpg"),
            ("file:///tmp/avatar.jpg", nil),
            ("https:///avatar.jpg", nil),
            ("/avatar.jpg", nil),
            ("", nil)
        ]
        for (avatar, expected) in avatars {
            let data = try JSONSerialization.data(withJSONObject: [
                "code": 200,
                "profile": ["userId": 7, "nickname": "听众", "avatarUrl": avatar]
            ])
            let (client, session) = makeClient(body: String(decoding: data, as: UTF8.self))
            let profile = try await client.profile(credential: credential())
            XCTAssertEqual(profile.userID, 7)
            XCTAssertEqual(profile.nickname, "听众")
            XCTAssertEqual(profile.avatarURL?.absoluteString, expected)
            session.invalidateAndCancel()
        }
    }

    @MainActor func testNetworkFailureRetainsURLFailureCode() async throws {
        let (client, session) = makeClient(error: URLError(.notConnectedToInternet))
        defer { session.invalidateAndCancel() }
        do { _ = try await client.profile(credential: credential()); XCTFail("Accepted offline request") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .network(.notConnectedToInternet)) }
    }

    @MainActor func testCancellationStopsURLSessionRequest() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request cancelled")
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        NeteaseAccountURLProtocol.state.withLock {
            $0.wait = true
            $0.started = started
            $0.stopped = stopped
        }
        let credential = try credential()
        let task = Task { try await client.profile(credential: credential) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a profile") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    @MainActor private func makeClient(body: String = "", status: Int = 200, error: URLError? = nil) -> (NeteaseAccountClient, URLSession) {
        NeteaseAccountURLProtocol.state.withLock { $0 = .init(body: Data(body.utf8), status: status, error: error) }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [NeteaseAccountURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (NeteaseAccountClient(session: session, deviceID: "fixture-device"), session)
    }

    private func credential() throws -> NeteaseCredential { try .init(musicU: "fixture-token") }

    private func cookie(_ name: String, _ value: String, domain: String = "music.163.com", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func decrypt(_ hex: String) throws -> String {
        let bytes = Array(hex.utf8)
        let data = Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(bytes: bytes[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
        })
        let key = "e82ckenh8dichen8"
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                key.withCString { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), key, kCCKeySizeAES128, nil,
                            source.baseAddress, data.count, destination.baseAddress, capacity, &length)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        output.count = length
        return try XCTUnwrap(String(data: output, encoding: .utf8))
    }
}

private final class NeteaseAccountURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var body = Data()
        var status = 200
        var error: URLError?
        var wait = false
        var started: XCTestExpectation?
        var stopped: XCTestExpectation?
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.state.withLock { $0 }
        state.started?.fulfill()
        guard !state.wait else { return }
        if let error = state.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: state.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.withLock { $0.stopped }?.fulfill() }
}
