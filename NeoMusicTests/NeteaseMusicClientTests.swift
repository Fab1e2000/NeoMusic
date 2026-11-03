import CommonCrypto
import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseMusicClientTests: XCTestCase, @unchecked Sendable {
    @MainActor func testTrialIsSkippedForCompleteLowerQuality() async throws {
        let client = makeClient([
            #"{"code":200,"data":[{"id":1,"url":"https://example.com/trial","freeTrialInfo":{}}]}"#,
            #"{"code":200,"data":[{"id":1,"url":"https://example.com/full","expi":600,"level":"exhigh"}]}"#
        ])
        let result = try await client.stream(id: 1, quality: .lossless, credential: credential())
        XCTAssertEqual(result.url.path, "/full")
        XCTAssertEqual(result.quality, .high)
        XCTAssertGreaterThan(result.expiresAt.timeIntervalSinceNow, 560)
    }
    @MainActor func testMissingSongsKeepTheirRequestedPositions() async throws {
        let client = makeClient([
            #"{"code":200,"playlist":{"id":2,"name":"Example","creator":{"userId":3,"nickname":"User"},"trackCount":2,"trackIds":[{"id":11,"at":1000},{"id":12}]}}"#,
            #"{"code":200,"songs":[{"id":12,"name":"Song","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":90000}]}"#
        ])
        let result = try await client.detail(id: 2, credential: credential())
        XCTAssertEqual(result.songs.map(\.id), [11, 12])
        XCTAssertTrue(result.songs[0].unavailable)
        XCTAssertEqual(result.songs[1].duration, 90)
        XCTAssertEqual(result.addedTimes[11], Date(timeIntervalSince1970: 1))
        XCTAssertNil(result.addedTimes[12])
    }
    @MainActor func testExplicitAuthenticationFailureDoesNotBecomeEmptyContent() async throws {
        let client = makeClient([#"{"code":301}"#])
        do {
            _ = try await client.likedIDs(userID: 1, credential: credential())
            XCTFail("Expected authentication error")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .authenticationRequired) }
    }
    @MainActor func testAccountSwitchRemovesOldLibraryAndRejectsOldRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = makeClient([
            #"{"code":200,"playlist":[{"id":10,"name":"Old","creator":{"userId":1,"nickname":"First"},"trackCount":0}],"more":false}"#,
            #"{"code":200,"ids":[11]}"#
        ])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "First", avatarURL: nil), credential: credential()))
        XCTAssertEqual(store.playlists.map(\.id), [10])
        let started = expectation(description: "Stream request started")
        MusicFixtureProtocol.started.withLock { $0 = { started.fulfill() } }
        MusicFixtureProtocol.responses.withLock { $0 = ["pending"] }
        let request = Task { try await store.stream(songID: 11) }
        await fulfillment(of: [started], timeout: 2)
        await store.invalidate()
        do { _ = try await request.value; XCTFail("Old stream must be cancelled") } catch {}
        MusicFixtureProtocol.started.withLock { $0 = nil }
        MusicFixtureProtocol.responses.withLock { $0 = [#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[22]}"#] }
        await store.activate(try .init(profile: .init(userID: 2, nickname: "Second", avatarURL: nil), credential: credential()))
        XCTAssertEqual(store.userID, 2)
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertEqual(store.likedIDs, [22])
        XCTAssertFalse(store.isLoading)
        await store.invalidate()
    }

    @MainActor func testFailedDetailKeepsPreviouslyLoadedOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = makeClient([
            #"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[]}"#,
            #"{"code":200,"playlist":{"id":2,"name":"Example","creator":{"userId":1,"nickname":"User"},"trackIds":[{"id":12}],"trackCount":1}}"#,
            #"{"code":200,"songs":[{"id":12,"name":"Song","ar":[],"al":{"name":"Album"},"dt":1000}]}"#,
            #"{"code":500}"#
        ])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()))
        await store.loadPlaylist(id: 2)
        await store.loadPlaylist(id: 2)
        XCTAssertEqual(store.playlistTracks[2], [12])
        XCTAssertNotNil(store.playlistErrors[2])
        XCTAssertFalse(store.loadingPlaylists.contains(2))
        await store.invalidate()
    }
    @MainActor func testPlaylistPaginationUsesLimitRatherThanExtraSystemRowCount() async throws {
        func item(_ id: Int) -> [String: Any] { ["id": id, "name": "List", "creator": ["userId": 1, "nickname": "User"], "trackCount": 0] }
        let first = try JSONSerialization.data(withJSONObject: ["code": 200, "playlist": (0...200).map(item), "more": true])
        let second = try JSONSerialization.data(withJSONObject: ["code": 200, "playlist": [item(200), item(201)], "more": false])
        let client = makeClient([String(decoding: first, as: UTF8.self), String(decoding: second, as: UTF8.self)])
        let lists = try await client.playlists(userID: 1, credential: credential())
        XCTAssertEqual(lists.map(\.id), Array(0...201).map(Int64.init))
        let requests = MusicFixtureProtocol.bodies.withLock { $0 }
        let offsets = try requests.map { body -> Int in
            let frame = try decrypt(String(String(decoding: body, as: UTF8.self).dropFirst(7)))
            let json = try XCTUnwrap(frame.components(separatedBy: "-36cd479b6b5-").dropFirst().first)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try XCTUnwrap(fields["offset"] as? Int)
        }
        XCTAssertEqual(offsets, [0, 200])
    }

    @MainActor func testFailedLikeReadsBackWithoutReportingSuccessOrRetryingWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = makeClient([#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[]}"#, "offline", #"{"code":200,"ids":[]}"#])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()))
        do { try await store.setLiked(songID: 8, liked: true); XCTFail("Failed write must not appear successful") } catch {}
        XCTAssertFalse(store.likedIDs.contains(8))
        XCTAssertNil(store.likedAt[8])
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0.filter { $0.contains("radio/like") }.count }, 1)
        await store.invalidate()
    }

    @MainActor func testOldLikeWriteCannotPublishToNewSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = makeClient([#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[]}"#, "pending"])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "First", avatarURL: nil), credential: credential()))
        let started = expectation(description: "Like write in flight")
        MusicFixtureProtocol.started.withLock { $0 = { started.fulfill() } }
        let write = Task { try await store.setLiked(songID: 8, liked: true) }
        await fulfillment(of: [started], timeout: 2)
        await store.invalidate()
        do { try await write.value; XCTFail("Cancelled write succeeded") } catch {}
        MusicFixtureProtocol.started.withLock { $0 = nil }
        MusicFixtureProtocol.responses.withLock { $0 = [#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[9]}"#] }
        await store.activate(try .init(profile: .init(userID: 2, nickname: "Second", avatarURL: nil), credential: credential()))
        XCTAssertEqual(store.likedIDs, [9])
        XCTAssertNil(store.likedAt[8])
        await store.invalidate()
    }

    @MainActor func testOfflineRestoreRetainsCachedLibraryForItsOwner() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = NeteaseMusicStore.Snapshot(playlists: [.init(id: 4, title: "Cached", creator: "User", creatorID: 1, artworkURL: nil, trackCount: 0, isFavorites: false)], songs: [:], tracks: [:], liked: [8], times: [:], lyrics: [:], artwork: [:])
        try JSONEncoder().encode(cached).write(to: folder.appendingPathComponent("1.json"))
        let store = NeteaseMusicStore(client: makeClient(["offline"]), directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()))
        XCTAssertEqual(store.playlists.map(\.id), [4])
        XCTAssertEqual(store.likedIDs, [8])
        XCTAssertNotNil(store.error)
        await store.invalidate()
        await store.activate(try .init(profile: .init(userID: 2, nickname: "Other", avatarURL: nil), credential: credential()), refresh: false)
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertTrue(store.likedIDs.isEmpty)
        await store.invalidate()
    }
    @MainActor func testCancelledCandidateSaveRestoresCredentialAndMusicOwner() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let music = NeteaseMusicStore(client: makeClient([#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[11]}"#]), directory: folder)
        let first = NeteaseProfile(userID: 1, nickname: "First", avatarURL: nil)
        let second = NeteaseProfile(userID: 2, nickname: "Second", avatarURL: nil)
        let firstCredential = try credential()
        var saved: NeteaseSavedSession? = .init(profile: first, credential: firstCredential)
        var login: Task<Void, Error>?
        let account = NeteaseAccount(readSession: { saved }, saveSession: { candidate in
            saved = candidate
            if candidate.profile.userID == 2 { login?.cancel() }
        }, deleteSession: { saved = nil }, validateCredential: { $0 == firstCredential ? first : second },
           cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: music)
        await account.restore()
        XCTAssertEqual(music.userID, 1)
        let candidate = try NeteaseCredential(musicU: "candidate")
        login = Task { try await account.completeLogin(credential: candidate) }
        do { try await login?.value; XCTFail("Cancelled candidate published") } catch {}
        XCTAssertEqual(saved?.profile.userID, 1)
        XCTAssertEqual(account.profile?.userID, 1)
        XCTAssertEqual(music.userID, 1)
        await music.invalidate()
    }

    @MainActor func testConcurrentDetailConsumersWaitForOneRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = makeClient([#"{"code":200,"playlist":[],"more":false}"#, #"{"code":200,"ids":[]}"#, "pending"])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()))
        let started = expectation(description: "Detail started")
        MusicFixtureProtocol.started.withLock { $0 = { started.fulfill() } }
        let first = Task { await store.loadPlaylist(id: 2) }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "Second consumer joined")
        var secondReturned = false
        let second = Task { joined.fulfill(); await store.loadPlaylist(id: 2); secondReturned = true }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertFalse(secondReturned)
        first.cancel()
        let requests = MusicFixtureProtocol.pending.withLock { values in let result = values; values = []; return result }
        XCTAssertEqual(requests.count, 1)
        for request in requests {
            request(#"{"code":200,"playlist":{"id":2,"name":"Loaded","creator":{"userId":1,"nickname":"User"},"trackCount":0,"trackIds":[]}}"#)
        }
        await first.value; await second.value
        XCTAssertEqual(store.playlistTracks[2], [])
        XCTAssertTrue(secondReturned)
        XCTAssertNil(store.playlistErrors[2])
        MusicFixtureProtocol.started.withLock { $0 = nil }
        await store.invalidate()
    }

    @MainActor private func makeClient(_ responses: [String]) -> NeteaseMusicClient {
        MusicFixtureProtocol.responses.withLock { $0 = responses }
        MusicFixtureProtocol.pending.withLock { $0 = [] }
        MusicFixtureProtocol.bodies.withLock { $0 = [] }
        MusicFixtureProtocol.paths.withLock { $0 = [] }
        MusicFixtureProtocol.started.withLock { $0 = nil }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [MusicFixtureProtocol.self]
        return NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: configuration)))
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
    private func credential() throws -> NeteaseCredential { try .init(musicU: "test-fixture") }
}
private final class MusicFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let pending = Mutex<[@Sendable (String) -> Void]>([])
    static let bodies = Mutex<[Data]>([])
    static let paths = Mutex<[String]>([])
    static let responses = Mutex<[String]>([])
    static let started = Mutex<(@Sendable () -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.bodies.withLock { $0.append(body) }
        Self.paths.withLock { $0.append(request.url?.path ?? "") }
        let response = Self.responses.withLock { $0.isEmpty ? #"{"code":500}"# : $0.removeFirst() }
        if response == "offline" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if response == "pending" {
            let complete: @Sendable (String) -> Void = { [weak self] body in self?.finish(body) }
            Self.pending.withLock { $0.append(complete) }
            Self.started.withLock { $0 }?()
            return
        }
        finish(response)
    }
    func finish(_ response: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
