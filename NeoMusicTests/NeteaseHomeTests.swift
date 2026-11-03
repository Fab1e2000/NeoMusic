import XCTest
@testable import NeoMusic

@MainActor final class NeteaseHomeTests: XCTestCase {
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
        XCTAssertEqual(store.dailySnapshot(date: date)?.date, date)
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
        XCTAssertEqual(store.cachedSongs.map(\.id), [9])
        XCTAssertEqual(store.dailySnapshot(id: first.id)?.songs.map(\.id), [9])
        XCTAssertEqual(store.dailySnapshot(date: first.date)?.id, second.id)
        do { _ = try await store.detail(id: 12); XCTFail("Refresh failure must reach the retry UI") }
        catch { XCTAssertEqual(store.cachedDetail(id: 12)?.songs.map(\.id), [9]) }
        await store.activate(nil, refresh: false)
        XCTAssertTrue(store.cachedSongs.isEmpty)
    }

}

private final class HomeFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}
