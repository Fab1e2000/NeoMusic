import CommonCrypto
import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseHomeSupplementalTests: XCTestCase, @unchecked Sendable {
    func testChartsKeepServerOrderDeduplicateAndNormalizeArtwork() throws {
        let data = Data(#"{"list":[{"id":2,"name":"Chart B","coverImgUrl":"http://p1.music.126.net/b.jpg"},{"id":1,"name":"Chart A"},{"id":2,"name":"duplicate"},{"id":0,"name":"invalid"}]}"#.utf8)
        let block = try JSONDecoder().decode(NeteaseHomeSupplemental.Charts.self, from: data).block
        XCTAssertEqual(block.resources.map(\.numericID), [2, 1])
        XCTAssertEqual(block.resources.first?.artworkURL?.scheme, "https")
        XCTAssertEqual(block.blockCode, "NEOMUSIC_CHARTS")
    }
    func testFollowedSingleUsesAlbumIdentityAndPreservesArtist() throws {
        let data = Data(#"{"data":{"newWorks":[{"blockType":"song","albumId":42,"blockTitle":{"resourceId":99,"resourceName":"Single","artistName":"Artist","resourcePicUrl":"https://example.com/a.jpg"}},{"blockType":"album","albumId":42,"blockTitle":{"resourceId":42,"resourceName":"Duplicate","artistName":"Artist"}},{"blockType":"mv","albumId":10,"blockTitle":{"resourceId":10,"resourceName":"Video","artistName":"Artist"}}]}}"#.utf8)
        let block = try JSONDecoder().decode(NeteaseHomeSupplemental.Followed.self, from: data).block
        XCTAssertEqual(block.resources.count, 1)
        XCTAssertEqual(block.resources.first?.numericID, 42)
        XCTAssertEqual(block.resources.first?.resourceType, "album")
        XCTAssertEqual(block.resources.first?.uiElement?.subTitle?.title, "Artist")
    }
    func testSongBatchPreservesMusicIdentityAcrossResponseShapes() throws {
        let data = Data(#"{"data":[{"id":7,"name":"Older keys","artists":[{"id":11,"name":"First"},{"id":12,"name":"Second"}],"album":{"id":13,"name":"Album","picUrl":"http://p1.music.126.net/cover.jpg"},"duration":90000},{"id":8,"name":"Detail keys","ar":[{"id":21,"name":"Artist"}],"al":{"id":23,"name":"Album"},"dt":120000},{"id":7,"name":"Duplicate","ar":[],"al":{"name":"Album"},"dt":0},{"id":0,"name":"Invalid","ar":[],"al":{"name":"Album"},"dt":0}]}"#.utf8)
        let songs = try JSONDecoder().decode(NeteaseHomeSupplemental.SongBatch.self, from: data).songs
        XCTAssertEqual(songs.map(\.id), [7, 8])
        XCTAssertEqual(songs.map(\.duration), [90, 120])
        XCTAssertEqual(songs.first?.artist, "First / Second")
        XCTAssertEqual(songs.first?.artists?.map(\.id), [11, 12])
        XCTAssertEqual(songs.first?.albumID, 13)
        XCTAssertEqual(songs.first?.artworkURL?.scheme, "https")
    }

    @MainActor func testIntelligenceUsesLikedPlaylistAndRestoresServerSongOrder() async throws {
        let client = makeClient([
            #"{"code":200,"data":[{"id":8},{"id":7},{"id":8},{"id":0},{"id":9}]}"#,
            songResponse(key: "songs", ids: [7, 8])
        ])
        let result = try await client.intelligenceModeSongs(playlistID: 123, seedSongID: 456, credential: credential())
        XCTAssertEqual(result.map(\.id), [8, 7])
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0 }, ["/eapi/playmode/intelligence/list", "/eapi/v3/song/detail"])
        let fields = try requestFields(at: 0)
        XCTAssertEqual(fields["playlistId"] as? Int, 123)
        XCTAssertEqual(fields["songId"] as? Int, 456)
        XCTAssertEqual(fields["startMusicId"] as? Int, 456)
        XCTAssertEqual(fields["type"] as? String, "fromPlayOne")
        XCTAssertEqual(fields["count"] as? Int, 1)
        let encoded = try XCTUnwrap(requestFields(at: 1)["c"] as? String)
        let ids = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Int]])
        XCTAssertEqual(ids.compactMap { $0["id"] }, [8, 7, 9])
    }

    @MainActor func testEmptyIntelligenceSkipsSongDetailRequest() async throws {
        let client = makeClient([#"{"code":200,"data":[]}"#])
        let songs = try await client.intelligenceModeSongs(playlistID: 1, seedSongID: 2, credential: credential())
        XCTAssertTrue(songs.isEmpty)
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0.count }, 1)
    }

    @MainActor func testIntelligenceDetailFailurePropagatesWithoutPartialResult() async throws {
        let client = makeClient([#"{"code":200,"data":[{"id":8}]}"#, #"{"code":500}"#])
        do {
            _ = try await client.intelligenceModeSongs(playlistID: 1, seedSongID: 2, credential: credential())
            XCTFail("Expected detail failure")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .server(500)) }
    }

    @MainActor func testPersonalFMRequestsExploreBatch() async throws {
        let client = makeClient([songResponse(key: "data", ids: [3, 1])])
        let songs = try await client.personalFM(credential: credential())
        XCTAssertEqual(songs.map(\.id), [3, 1])
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0 }, ["/eapi/v1/radio/get"])
        let fields = try requestFields(at: 0)
        XCTAssertEqual(fields["mode"] as? String, "EXPLORE")
        XCTAssertEqual(fields["limit"] as? Int, 30)
    }

    @MainActor func testSimilarSongsUsesCurrentSongSeed() async throws {
        let client = makeClient([songResponse(key: "songs", ids: [4, 5])])
        let songs = try await client.similarSongs(id: 123, credential: credential())
        XCTAssertEqual(songs.map(\.id), [4, 5])
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0 }, ["/eapi/v1/discovery/simiSong"])
        let fields = try requestFields(at: 0)
        XCTAssertEqual(fields["songid"] as? Int, 123)
        XCTAssertEqual(fields["limit"] as? Int, 50)
        XCTAssertEqual(fields["offset"] as? Int, 0)
    }

    @MainActor func testNewSongsUsesNewSongSourceAndPreservesLimitedOrder() async throws {
        let client = makeClient([songResponse(key: "data", ids: [3, 1, 2])])
        let songs = try await client.newSongs(credential: nil, limit: 2)
        XCTAssertEqual(songs.map(\.id), [3, 1])
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0 }, ["/eapi/v1/discovery/new/songs"])
        let fields = try requestFields(at: 0)
        XCTAssertEqual(fields["areaId"] as? Int, 0)
        XCTAssertEqual(fields["total"] as? Bool, true)
    }

    @MainActor func testSupplementalAuthenticationFailureRemainsAnError() async throws {
        let client = makeClient([#"{"code":301}"#])
        do {
            _ = try await client.personalFM(credential: credential())
            XCTFail("Expected authentication failure")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .authenticationRequired) }
    }

    @MainActor func testFeedRefreshIsExplicitOnlyOnFirstRequest() async throws {
        let client = makeClient([
            #"{"code":200,"data":{"blocks":[],"hasMore":true,"cursor":"next"}}"#,
            #"{"code":200,"data":{"blocks":[],"hasMore":false}}"#
        ])
        let first = try await client.homeFeed(credential: nil, refresh: true)
        _ = try await client.homeFeed(credential: nil, refresh: false, cursor: first.cursor)
        XCTAssertEqual(SupplementalFixtureProtocol.paths.withLock { $0 }, Array(repeating: "/eapi/homepage/block/page", count: 2))
        let initial = try requestFields(at: 0)
        XCTAssertEqual(initial["refresh"] as? Bool, true)
        XCTAssertNil(initial["cursor"])
        let continuation = try requestFields(at: 1)
        XCTAssertEqual(continuation["refresh"] as? Bool, false)
        XCTAssertEqual(continuation["cursor"] as? String, "next")
    }

    @MainActor private func makeClient(_ responses: [String]) -> NeteaseMusicClient {
        SupplementalFixtureProtocol.responses.withLock { $0 = responses }
        SupplementalFixtureProtocol.paths.withLock { $0 = [] }
        SupplementalFixtureProtocol.bodies.withLock { $0 = [] }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [SupplementalFixtureProtocol.self]
        return NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: configuration)))
    }

    private func songResponse(key: String, ids: [Int]) -> String {
        let songs = ids.map { #"{"id":\#($0),"name":"Song","ar":[{"id":1,"name":"Artist"}],"al":{"id":2,"name":"Album"},"dt":60000}"# }
        return #"{"code":200,"\#(key)":[\#(songs.joined(separator: ","))]}"#
    }

    private func credential() throws -> NeteaseCredential { try .init(musicU: "test-fixture") }

    private func requestFields(at index: Int) throws -> [String: Any] {
        let bodies = SupplementalFixtureProtocol.bodies.withLock { $0 }
        let hex = String(decoding: bodies[index], as: UTF8.self).dropFirst("params=".count)
        let bytes = Array(hex.utf8)
        let encrypted = Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(bytes: bytes[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
        })
        let key = "e82ckenh8dichen8"
        var output = Data(count: encrypted.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            encrypted.withUnsafeBytes { source in
                key.withCString { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), key, kCCKeySizeAES128, nil,
                            source.baseAddress, encrypted.count, destination.baseAddress, capacity, &length)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        output.count = length
        let frame = try XCTUnwrap(String(data: output, encoding: .utf8))
        let json = try XCTUnwrap(frame.components(separatedBy: "-36cd479b6b5-").dropFirst().first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

private final class SupplementalFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Mutex<[String]>([])
    static let paths = Mutex<[String]>([])
    static let bodies = Mutex<[Data]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.paths.withLock { $0.append(request.url?.path ?? "") }
        Self.bodies.withLock { $0.append(body) }
        let response = Self.responses.withLock { $0.isEmpty ? #"{"code":500}"# : $0.removeFirst() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
