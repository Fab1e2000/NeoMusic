import XCTest
import Observation
import Synchronization
@testable import NeoMusic

@MainActor final class NeteaseArtistStoreTests: XCTestCase {
    private func store(offline: Bool = false) async throws -> NeteaseArtistStore {
        ArtistStoreProtocol.state.withLock { $0 = (offline, 0, []) }
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
        let paths = ArtistStoreProtocol.state.withLock { $0.2 }
        XCTAssertEqual(Set(paths), ["/weapi/artist/sub"], "Offline writes must not trigger a read-back request: \(paths)")
        await store.invalidate()
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
    private func contentStore(directory: URL? = nil, userID: Int64? = nil) async throws -> NeteaseArtistStore {
        ArtistContentProtocol.state.withLock { $0 = .init() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistContentProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = NeteaseArtistStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: session)),
                                      directory: directory ?? URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                      artworkSession: session)
        let saved = try userID.map { NeteaseSavedSession(profile: .init(userID: $0, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test")) }
        await store.activate(saved, refresh: false)
        return store
    }

    func testArtistPlaybackLoadRequestsOnlySongsAndPublishesOnce() async throws {
        let store = try await contentStore()
        var publications = 0
        store.onChange = { publications += 1 }
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(store.details[7]?.songs.map(\.id), [70])
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths }, ["/eapi/v1/artist/7"])
        XCTAssertEqual(publications, 1)
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths.count }, 1)
        XCTAssertEqual(publications, 1)
        await store.loadArtistSongs(id: 7, force: true)
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths.count }, 2)
        XCTAssertEqual(publications, 1, "Identical network content keeps the existing page")
        await store.invalidate()
    }

    func testOverlappingArtistSongLoadsShareOneRequest() async throws {
        let store = try await contentStore()
        async let first: Void = store.loadArtistSongs(id: 7)
        async let second: Void = store.loadArtistSongs(id: 7)
        _ = await (first, second)
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths }, ["/eapi/v1/artist/7"])
        XCTAssertEqual(store.cachedSongs.map(\.id), [70])
        await store.invalidate()
    }

    func testFullArtistLoadPublishesEachResourceAtMostOnce() async throws {
        let store = try await contentStore()
        var publications = 0
        store.onChange = { publications += 1 }
        await store.loadArtist(id: 7)
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths.count }, 4)
        XCTAssertEqual(store.details[7]?.biography, "Full biography")
        XCTAssertLessThanOrEqual(publications, 4)
        XCTAssertGreaterThanOrEqual(publications, 3)
        await store.invalidate()
    }

    func testUnrelatedArtistLoadDoesNotInvalidatePresentedArtist() async throws {
        let store = try await contentStore()
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
                                    validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
                                    cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, artists: store)
        let integration = ArtistMusicIntegration(account: account)
        integration.connect()
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(integration.artistDetail(7)?.name, "Artist 7")
        let changes = Mutex(0)
        withObservationTracking { _ = integration.artistDetail(7) } onChange: { changes.withLock { $0 += 1 } }
        await store.loadArtistSongs(id: 8)
        XCTAssertEqual(changes.withLock { $0 }, 0)
        XCTAssertEqual(integration.artistDetail(8)?.songs.map(\.title), ["Song 80"])
        await store.invalidate()
    }

    func testRemovedArtistSongsLeaveThePublishedCatalog() async throws {
        let store = try await contentStore(userID: 42)
        let saved = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
                                    validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil },
                                    loadAvatar: { _ in Data() }, clearAvatarCache: {}, artists: store)
        await account.restoreCachedContent()
        let integration = ArtistMusicIntegration(account: account)
        integration.connect()
        await store.loadArtistSongs(id: 7)
        XCTAssertNotNil(LocalLibrary.songLibrary.song(id: "netease:42:70"))
        ArtistContentProtocol.state.withLock { $0.emptySongs = true }
        await store.loadArtistSongs(id: 7, force: true)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertNil(LocalLibrary.songLibrary.song(id: "netease:42:70"))
        XCTAssertEqual(integration.artistDetail(7)?.songs.count, 0)
        await store.invalidate()
    }

    func testFailedRefreshPreservesArtistAndRetryClearsError() async throws {
        let store = try await contentStore()
        await store.loadArtistSongs(id: 7)
        ArtistContentProtocol.state.withLock { $0.offline = true }
        await store.loadArtistSongs(id: 7, force: true)
        XCTAssertEqual(store.details[7]?.songs.map(\.id), [70])
        XCTAssertNotNil(store.errors["artist:7"])
        ArtistContentProtocol.state.withLock { $0.offline = false }
        await store.loadArtistSongs(id: 7)
        XCTAssertNil(store.errors["artist:7"])
        XCTAssertEqual(store.details[7]?.songs.map(\.id), [70])
        await store.invalidate()
    }

    func testArtistPageRestoresFreshnessAndAccountScope() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        let artist = NeteaseArtistReference(id: 7, name: "Cached", artworkURL: nil)
        let detail = NeteaseArtistDetail(artist: artist, biography: "Saved", songs: [])
        let page = ArtistPageFixture(detail: detail, biography: "Saved", releases: [], similar: [], refreshedAt: ["artist:7": Date()])
        try await cache.save(page, scope: "42", key: "artist:7")
        let store = try await contentStore(directory: directory, userID: 42)
        XCTAssertNil(store.details[7], "Activation restores the library summary without opening artist pages")
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(store.details[7]?.artist.name, "Cached")
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty })
        await store.activate(.init(profile: .init(userID: 43, nickname: "Other", avatarURL: nil), credential: try .init(musicU: "other")), refresh: false)
        XCTAssertNil(store.details[7])
        XCTAssertTrue(store.cachedSongs.isEmpty)
        await store.activate(.init(profile: .init(userID: 42, nickname: "Test", avatarURL: nil), credential: try .init(musicU: "test")), refresh: false)
        XCTAssertNil(store.details[7])
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(store.details[7]?.biography, "Saved")
        await store.invalidate()
    }

    func testExpiredArtistPageRefreshesOnlyRequestedResource() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        let detail = NeteaseArtistDetail(artist: .init(id: 7, name: "Old", artworkURL: nil), biography: "Full biography", songs: [])
        try await cache.save(ArtistPageFixture(detail: detail, biography: "Full biography", releases: [], similar: [],
                                              refreshedAt: ["artist:7": Date().addingTimeInterval(-301)]), scope: "public", key: "artist:7")
        let store = try await contentStore(directory: directory)
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(store.details[7]?.artist.name, "Artist 7")
        XCTAssertEqual(store.details[7]?.biography, "Full biography")
        XCTAssertEqual(ArtistContentProtocol.state.withLock { $0.paths }, ["/eapi/v1/artist/7"])
        await store.invalidate()
    }

    func testActivationOnlyRestoresSubscriptionsAndDemandLoadsOnePage() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        let artist = NeteaseArtistReference(id: 7, name: "Cached artist", artworkURL: nil)
        let album = NeteaseArtistAlbum(id: 8, title: "Cached album", artist: "Cached artist", artworkURL: nil,
                                      publishTime: nil, type: "Album", trackCount: 0)
        try await cache.save(ArtistSubscriptionsFixture(artists: [artist], albums: [album], refreshedAt: [:]), scope: "42", key: "subscriptions")
        try await cache.save(ArtistPageFixture(detail: .init(artist: artist, biography: "Saved", songs: []), biography: "Saved",
                                              releases: [], similar: [], refreshedAt: ["artist:7": Date()]), scope: "42", key: "artist:7")
        try await cache.save(ArtistAlbumPageFixture(detail: .init(album: album, songs: []), refreshedAt: Date().addingTimeInterval(-301)), scope: "42", key: "album:8")
        try await cache.save("Unrelated page remains unopened", scope: "42", key: "artist:99")
        let store = try await contentStore(directory: directory, userID: 42)
        XCTAssertEqual(store.subscribedArtists.map(\.id), [7])
        XCTAssertEqual(store.subscribedAlbums.map(\.id), [8])
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        let unopened = try await cache.load(String.self, scope: "42", key: "artist:99")
        XCTAssertEqual(unopened, "Unrelated page remains unopened")
        await store.loadArtistSongs(id: 7)
        XCTAssertEqual(store.details.keys.sorted(), [7])
        XCTAssertTrue(store.albums.isEmpty)
        let albumReady = await store.prepareAlbumPlayback(id: 8)
        XCTAssertTrue(albumReady)
        XCTAssertEqual(store.albums[8]?.album.title, "Cached album")
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty }, "Playback reuses the cached complete album")
        await store.invalidate()
    }

    func testArtistPlaybackUsesExpiredDiskPageWithoutOtherRequests() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        let detail = NeteaseArtistDetail(artist: .init(id: 7, name: "Cached", artworkURL: nil), biography: "Saved", songs: [])
        try await cache.save(ArtistPageFixture(detail: detail, biography: "Saved", releases: nil, similar: nil,
                                              refreshedAt: ["artist:7": Date().addingTimeInterval(-301)]), scope: "public", key: "artist:7")
        let store = try await contentStore(directory: directory)
        var publications = 0
        store.onChange = { publications += 1 }
        async let first = store.prepareArtistPlayback(id: 7)
        async let second = store.prepareArtistPlayback(id: 7)
        let results = await (first, second)
        XCTAssertTrue(results.0 && results.1)
        XCTAssertEqual(store.details[7]?.artist.name, "Cached")
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty })
        await store.invalidate()
    }

    func testLegacySummaryAndRequestedDetailRestoreWithoutTouchingOtherEntities() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"artists":[{"id":7,"name":"Legacy"}],"collected":[],"details":[7,{"artist":{"id":7,"name":"Legacy"},"biography":"Saved","songs":[]},99,"Unrelated invalid entity"],"releases":[],"similar":[],"albums":[],"artwork":{}}"#.utf8)
        let legacyURL = directory.appendingPathComponent("public.json")
        try data.write(to: legacyURL)
        let store = try await contentStore(directory: directory)
        XCTAssertEqual(store.subscribedArtists.map(\.name), ["Legacy"])
        XCTAssertTrue(store.details.isEmpty)
        let ready = await store.prepareArtistPlayback(id: 7)
        XCTAssertTrue(ready)
        XCTAssertEqual(store.details.keys.sorted(), [7])
        XCTAssertEqual(store.details[7]?.biography, "Saved")
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty })
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
        await store.invalidate()
    }

    func testCachedSongLookupReturnsOnlyRequestedAccountSongsWithoutOpeningRoutes() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        let artist = NeteaseArtistReference(id: 7, name: "Cached artist", artworkURL: nil)
        let artistSong = NeteaseMusicSong(id: 70, title: "Artist song", artist: artist.name, album: "Album", artworkURL: nil, duration: 1)
        let unrelated = NeteaseMusicSong(id: 71, title: "Unrequested song", artist: artist.name, album: "Album", artworkURL: nil, duration: 1)
        let albumSong = NeteaseMusicSong(id: 80, title: "Album song", artist: artist.name, album: "Album", artworkURL: nil, duration: 1)
        let otherAccount = NeteaseMusicSong(id: 90, title: "Other account", artist: artist.name, album: "Album", artworkURL: nil, duration: 1)
        let album = NeteaseArtistAlbum(id: 8, title: "Album", artist: artist.name, artworkURL: nil, publishTime: nil, type: "Album", trackCount: 1)
        try await cache.save(ArtistPageFixture(detail: .init(artist: artist, biography: "", songs: [artistSong, unrelated]), biography: nil,
                                              releases: nil, similar: nil, refreshedAt: ["artist:7": Date()]), scope: "42", key: "artist:7")
        try await cache.save(ArtistAlbumPageFixture(detail: .init(album: album, songs: [albumSong]), refreshedAt: nil), scope: "42", key: "album:8")
        try await cache.save(ArtistAlbumPageFixture(detail: .init(album: album, songs: [otherAccount]), refreshedAt: nil), scope: "43", key: "album:8")
        let store = try await contentStore(directory: directory, userID: 42)
        var publications = 0
        store.onChange = { publications += 1 }
        let songs = await store.restoreCachedSongs(ids: [70, 80, 90])
        XCTAssertEqual(songs, [artistSong, albumSong])
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty })
        await store.loadArtistSongs(id: 7)
        try await cache.remove(scope: "42", key: "artist:7")
        let memorySongs = await store.restoreCachedSongs(ids: [70])
        XCTAssertEqual(memorySongs, [artistSong], "Existing resolved songs are reused without needing their disk page")
        let cancelled = Task { await store.restoreCachedSongs(ids: [70, 80]) }
        cancelled.cancel()
        let cancelledSongs = await cancelled.value
        XCTAssertTrue(cancelledSongs.isEmpty)
        await store.invalidate()
    }

    func testCachedSongLookupReadsLegacySongsWithoutHydratingOrChangingSnapshot() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"artists":[],"collected":[],"details":[7,{"songs":[{"id":70,"title":"Legacy artist song","artist":"Artist","album":"Album","duration":1,"unavailable":false},{"id":71,"title":"Unrequested","artist":"Artist","album":"Album","duration":1,"unavailable":false}]}],"albums":{"8":{"songs":[{"id":80,"title":"Legacy album song","artist":"Artist","album":"Album","duration":1,"unavailable":false}]}},"artwork":{}}"#.utf8)
        let legacyURL = directory.appendingPathComponent("public.json")
        try data.write(to: legacyURL)
        let store = try await contentStore(directory: directory)
        var publications = 0
        store.onChange = { publications += 1 }
        let songs = await store.restoreCachedSongs(ids: [70, 80, 99])
        XCTAssertEqual(songs.map(\.id), [70, 80])
        XCTAssertEqual(songs.map(\.title), ["Legacy artist song", "Legacy album song"])
        XCTAssertTrue(store.details.isEmpty)
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.cachedSongs.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(ArtistContentProtocol.state.withLock { $0.paths.isEmpty })
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
        await store.invalidate()
    }

}

private final class ArtistStoreProtocol: URLProtocol, @unchecked Sendable {
    static let state = Mutex((false, 0, [String]()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let offline = Self.state.withLock { value in value.1 += 1; value.2.append(request.url!.path); return value.0 }
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let body = #"{"code":200,"data":[],"hasMore":false}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct ArtistPageFixture: Codable, Sendable {
    let detail: NeteaseArtistDetail?
    let biography: String?
    let releases: [NeteaseArtistAlbum]?
    let similar: [NeteaseArtistReference]?
    let refreshedAt: [String: Date]
}

private final class ArtistContentProtocol: URLProtocol, @unchecked Sendable {
    struct State { var paths: [String] = []; var offline = false; var emptySongs = false }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let offline = Self.state.withLock { $0.paths.append(path); return $0.offline }
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let body: String
        let emptySongs = Self.state.withLock { $0.emptySongs }
        if path.contains("/v1/artist/"), let id = Int(path.split(separator: "/").last ?? "") {
            let songs = emptySongs ? "[]" : """
            [{"id":\(id * 10),"name":"Song \(id * 10)","ar":[{"id":\(id),"name":"Artist \(id)"}],"al":{"id":1,"name":"Album"},"dt":1000}]
            """
            body = """
            {"code":200,"artist":{"id":\(id),"name":"Artist \(id)","briefDesc":"Brief"},"hotSongs":\(songs)}
            """
        } else if path.hasSuffix("/artist/introduction") {
            body = #"{"code":200,"briefDesc":"Full biography","introduction":[]}"#
        } else if path.contains("/artist/albums/") {
            body = #"{"code":200,"hotAlbums":[],"more":false}"#
        } else if path.hasSuffix("/discovery/simiArtist") {
            body = #"{"code":200,"artists":[]}"#
        } else {
            body = #"{"code":200,"data":[],"hasMore":false}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct ArtistSubscriptionsFixture: Codable, Sendable {
    let artists: [NeteaseArtistReference]
    let albums: [NeteaseArtistAlbum]
    let refreshedAt: [String: Date]
}
private struct ArtistAlbumPageFixture: Codable, Sendable {
    let detail: NeteaseArtistAlbumDetail
    let refreshedAt: Date?
}
