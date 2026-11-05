import CommonCrypto
import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseMusicClientTests: XCTestCase, @unchecked Sendable {
    @MainActor func testPlaybackUsesMeloXIOSProfileAndKeepsCredentialsScoped() async throws {
        let client = makeClient([#"{"code":200,"data":[{"id":1,"url":"https://example.com/full","expi":600,"level":"lossless"}]}"#])
        _ = try await client.stream(id: 1, quality: .lossless, credential: credential())
        let request = try XCTUnwrap(MusicFixtureProtocol.requests.withLock { $0.last })
        XCTAssertEqual(request.url?.path, "/eapi/song/enhance/player/url/v1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "MUSIC_U=test-fixture; __remember_me=true; appver=9.0.90; os=ios")
        let body = try XCTUnwrap(MusicFixtureProtocol.bodies.withLock { $0.last })
        let frame = try decrypt(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "params=", with: ""))
        let json = try XCTUnwrap(frame.components(separatedBy: "-36cd479b6b5-").dropFirst().first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let header = try XCTUnwrap(payload["header"] as? [String: String])
        XCTAssertEqual(header["os"], "ios")
        XCTAssertEqual(header["osver"], "18.0")
        XCTAssertEqual(header["appver"], "9.0.90")
        XCTAssertEqual(header["channel"], "distribution")
        XCTAssertEqual(header["MUSIC_U"], "test-fixture")
        XCTAssertTrue(header["requestId"]?.hasSuffix("_0000") == true)
        XCTAssertNil(header["deviceId"])
        XCTAssertEqual(payload["ids"] as? String, "[1]")
        XCTAssertEqual(payload["level"] as? String, "lossless")
        XCTAssertEqual(payload["encodeType"] as? String, "flac")
        XCTAssertEqual(payload["e_r"] as? Bool, false)
    }

    @MainActor func testPlaybackRejectionIsNotRetriedOrCachedAsASource() async throws {
        let client = makeClient([#"{"code":500}"#,
            #"{"code":200,"data":[{"id":1,"url":"https://example.com/full","expi":600}]}"#])
        do {
            _ = try await client.stream(id: 1, quality: .lossless, credential: credential())
            XCTFail("Expected server rejection")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .server(500)) }
        XCTAssertEqual(MusicFixtureProtocol.requests.withLock { $0.count }, 1)
        let resource = try await client.stream(id: 1, quality: .lossless, credential: credential())
        XCTAssertEqual(resource.url.path, "/full")
        XCTAssertEqual(MusicFixtureProtocol.requests.withLock { $0.count }, 2)
    }

    @MainActor func testPlaybackRecoversOneTransientTLSHandshakeFailure() async throws {
        let client = makeClient(["tls", #"{"code":200,"data":[{"id":1,"url":"https://example.com/full","expi":600,"level":"lossless"}]}"#])
        let resource = try await client.stream(id: 1, quality: .lossless, credential: credential())
        XCTAssertEqual(resource.quality, .lossless)
        XCTAssertEqual(resource.url.path, "/full")
        XCTAssertEqual(MusicFixtureProtocol.requests.withLock { $0.count }, 2)
    }

    @MainActor func testPlaybackStopsAfterSecondTLSFailureAndNeverRetriesCertificateOrCancellation() async throws {
        for (fixture, code, count) in [("tls", URLError.secureConnectionFailed, 2),
                                       ("certificate", .serverCertificateUntrusted, 1),
                                       ("cancelled", .cancelled, 1)] {
            let client = makeClient([fixture, fixture])
            do {
                _ = try await client.stream(id: 1, quality: .lossless, credential: credential())
                XCTFail("Expected connection failure")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
            XCTAssertEqual(MusicFixtureProtocol.requests.withLock { $0.count }, count)
        }
    }

    @MainActor func testAccountWriteDoesNotRetryTLSFailure() async throws {
        let client = makeClient(["tls", #"{"code":200}"#])
        do {
            try await client.setLiked(id: 1, liked: true, credential: credential())
            XCTFail("Expected connection failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed) }
        XCTAssertEqual(MusicFixtureProtocol.requests.withLock { $0.count }, 1)
    }

    @MainActor func testWebRequestUsesScopedNeoDizzyClientProfile() throws {
        let transport = NeteaseAccountClient(deviceID: "test-device")
        let request = try transport.makeWebRequest(path: "/api/album/sub", fields: ["id": 7], credential: .init(musicU: "token+value", csrf: "csrf"))
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        for field in ["MUSIC_U=token%2Bvalue", "__csrf=csrf", "os=ios", "appver=9.0.90", "deviceId=test-device", "WEVNSM=1.0.0", "__remember_me=true"] {
            XCTAssertTrue(cookie.contains(field), field)
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://music.163.com")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/124.0.0.0") == true)
    }
    @MainActor func testWebBusinessRejectionPreservesServerMessage() async throws {
        let client = makeClient([#"{"code":301,"msg":"专辑暂不支持收藏"}"#])
        do {
            try await client.setAlbumSubscribed(id: 12, subscribed: true, credential: credential())
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? NeteaseWebResponseError, .init(code: 301, message: "专辑暂不支持收藏"))
        }
    }
    @MainActor func testWebSubscriptionUsesWebAPIAndRSAEnvelope() async throws {
        let client = makeClient([#"{"code":200}"#])
        try await client.setAlbumSubscribed(id: 12, subscribed: true, credential: credential())
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0.last }, "/weapi/album/sub")
        let body = try XCTUnwrap(MusicFixtureProtocol.bodies.withLock { $0.last })
        let fields = String(decoding: body, as: UTF8.self).split(separator: "&")
        let rsa = try XCTUnwrap(fields.first { $0.hasPrefix("encSecKey=") })
        XCTAssertEqual(rsa.dropFirst("encSecKey=".count).count, 256)
        XCTAssertTrue(fields.contains { $0.hasPrefix("params=") })
    }
    @MainActor func testIncompleteAlbumFails() async throws {
        let client = makeClient([#"{"code":200,"album":{"id":1,"name":"Album","size":2},"songs":[]}"#])
        do {
            _ = try await client.albumDetail(id: 1, credential: nil)
            XCTFail("Incomplete album accepted")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .invalidResponse) }
    }
    @MainActor func testPlayerForwardsSelectedArtist() {
        var selection: (String, String)?
        let actions = ReferencePlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in }, addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in XCTFail("Wrong callback") }, artistNames: { _ in ["First", "Second"] }, openNamedArtist: { selection = ($0, $1) })
        let track = ReferenceTrack(id: "netease:1:12", title: "Song", artists: "First / Second", albumTitle: "Album", coverURL: nil, duration: 90)
        XCTAssertEqual(actions.artistNames(for: track), ["First", "Second"])
        actions.openArtist("Second", track: track)
        XCTAssertEqual(selection?.0, track.id)
        XCTAssertEqual(selection?.1, "Second")
    }
    @MainActor func testArtistAlbumsPreservePagesAndRemoveDuplicateIDs() async throws {
        let client = makeClient([
            #"{"code":200,"hotAlbums":[{"id":2,"name":"Second"},{"id":1,"name":"First"}],"more":true}"#,
            #"{"code":200,"hotAlbums":[{"id":1,"name":"First"},{"id":3,"name":"Third"}],"more":false}"#
        ])
        let albums = try await client.artistAlbums(id: 4, credential: nil)
        XCTAssertEqual(albums.map(\.id), [2, 1, 3])
    }
    @MainActor func testSongDetailsRetainMultipleArtistIdentities() async throws {
        let client = makeClient([#"{"code":200,"songs":[{"id":12,"name":"Song","ar":[{"id":1,"name":"Same"},{"id":2,"name":"Same"}],"al":{"id":3,"name":"Album"},"dt":90000}]}"#])
        let song = try await client.songDetail(id: 12, credential: nil)
        XCTAssertEqual(song.artists?.map(\.id), [1, 2])
        XCTAssertEqual(song.albumID, 3)
    }
    func testLegacySongCacheDecodesWithoutArtistIdentity() throws {
        let data = Data(#"{"id":12,"title":"Song","artist":"Artist","album":"Album","duration":90,"unavailable":false}"#.utf8)
        let song = try JSONDecoder().decode(NeteaseMusicSong.self, from: data)
        XCTAssertNil(song.artists)
        XCTAssertNil(song.albumID)
    }
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

    @MainActor func testResponseDecodingRunsOffMainThread() async throws {
        struct Response: Decodable, Sendable {
            let decodedOnMainThread: Bool
            init(from decoder: any Decoder) throws { decodedOnMainThread = Thread.isMainThread }
        }
        let client = makeClient([#"{"code":200}"#])
        let result: Response = try await client.read("/api/test", [:], nil)
        XCTAssertFalse(result.decodedOnMainThread)
    }

    @MainActor func testPlaylistFirstPageUsesEmbeddedTracksAndContinuesWithoutReloadingMetadata() async throws {
        let ids = (1...205).map(Int64.init)
        let client = makeClient([
            try playlistResponse(ids: ids, embedded: Array(ids.prefix(100))),
            try songsResponse(Array(ids[100..<200])),
            try songsResponse(Array(ids[200...]))
        ])
        let first = try await client.detail(id: 2, credential: credential(), trackLimit: 100)
        XCTAssertEqual(first.songs.map(\.id), Array(ids.prefix(100)))
        XCTAssertEqual(first.orderedTrackIDs, ids)
        XCTAssertEqual(first.nextOffset, 100)
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0 }, ["/eapi/v6/playlist/detail"])

        let second = try await client.loadMore(first, credential: credential())
        XCTAssertEqual(second.nextOffset, 200)
        XCTAssertFalse(second.isComplete)
        let complete = try await client.complete(second, credential: credential())
        XCTAssertEqual(complete.songs.map(\.id), ids)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.addedTimes[1], Date(timeIntervalSince1970: 1))
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0 }, ["/eapi/v6/playlist/detail", "/eapi/v3/song/detail", "/eapi/v3/song/detail"])
        XCTAssertEqual(try requestedSongIDs(), [Array(ids[100..<200]), Array(ids[200...])])
    }

    @MainActor func testPlaylistReusesKnownSongsAndFetchesOnlyMissingIDsInServerOrder() async throws {
        let known = NeteaseMusicSong(id: 10, title: "Known", artist: "Artist", album: "Album", artworkURL: nil, duration: 60)
        let client = makeClient([try playlistResponse(ids: [30, 20, 10], embedded: [30]), try songsResponse([20])])
        let detail = try await client.detail(id: 2, credential: nil, prefetched: [known])
        XCTAssertEqual(detail.songs.map(\.id), [30, 20, 10])
        XCTAssertEqual(detail.songs.last?.title, "Known")
        XCTAssertEqual(try requestedSongIDs(), [[20]])
        XCTAssertTrue(detail.isComplete)
        let completed = try await client.complete(detail, credential: nil)
        XCTAssertEqual(completed.songs, detail.songs)
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0.count }, 2)
    }

    @MainActor func testPlaylistCompletionUsesHundredSongBatchesAndKeepsMissingPositions() async throws {
        let ids = (1...405).map(Int64.init)
        let response = try songsResponse(Array(ids.dropFirst(2)).filter { $0 != 250 }.reversed())
        let client = makeClient(Array(repeating: response, count: 5))
        let firstSongs = ids.prefix(2).map { NeteaseMusicSong(id: $0, title: "Loaded", artist: "Artist", album: "Album", artworkURL: nil, duration: 60) }
        let partial = NeteasePlaylistDetail(playlist: .init(id: 2, title: "List", creator: "User", creatorID: 1, artworkURL: nil, trackCount: ids.count, isFavorites: false),
                                           songs: firstSongs, addedTimes: [:], trackIDs: ids, loadedTrackCount: 2)
        let result = try await client.complete(partial, credential: nil)
        XCTAssertEqual(result.songs.map(\.id), ids)
        XCTAssertTrue(result.songs[249].unavailable)
        XCTAssertTrue(result.isComplete)
        let requested = try requestedSongIDs()
        XCTAssertEqual(requested.count, 5)
        XCTAssertTrue(requested.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(requested.flatMap { $0 }.sorted(), Array(ids.dropFirst(2)))
    }

    @MainActor func testCancelledPlaylistCompletionDoesNotRequestAnotherPage() async throws {
        let client = makeClient([])
        let partial = NeteasePlaylistDetail(playlist: .init(id: 2, title: "List", creator: "User", creatorID: 1, artworkURL: nil, trackCount: 1, isFavorites: false),
                                           songs: [], addedTimes: [:], trackIDs: [1], loadedTrackCount: 0)
        let request = Task { @MainActor in try await client.complete(partial, credential: nil) }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled page load succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
    }

    func testLegacyPlaylistCacheRemainsComplete() throws {
        let detail = NeteasePlaylistDetail(playlist: .init(id: 2, title: "List", creator: "User", creatorID: 1, artworkURL: nil, trackCount: 1, isFavorites: false),
                                           songs: [.init(id: 1, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 60)], addedTimes: [:])
        let decoded = try JSONDecoder().decode(NeteasePlaylistDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertNil(decoded.trackIDs)
        XCTAssertNil(decoded.loadedTrackCount)
        XCTAssertEqual(decoded.orderedTrackIDs, [1])
        XCTAssertEqual(decoded.nextOffset, 1)
        XCTAssertTrue(decoded.isComplete)
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
        await store.loadPlaylist(id: 2, force: true)
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

    @MainActor func testLyricsReadDiskOnDemandAndReuseLoadedValue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = NeteasePageCache(directory: folder)
        try await cache.save(NeteaseMusicLyrics(original: "Before activation", translation: ""), scope: "1", key: "lyrics:12")
        let store = NeteaseMusicStore(client: makeClient([]), directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()), refresh: false)

        try await cache.save(NeteaseMusicLyrics(original: "Requested lyrics", translation: "Translation"), scope: "1", key: "lyrics:12")
        let loaded = try await store.lyrics(songID: 12)
        XCTAssertEqual(loaded.original, "Requested lyrics")
        XCTAssertEqual(loaded.translation, "Translation")
        try await cache.remove(scope: "1", key: "lyrics:12")
        let repeated = try await store.lyrics(songID: 12)
        XCTAssertEqual(repeated.original, loaded.original)
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await store.invalidate()
    }

    @MainActor func testOlderLibrarySummaryRestoresFavoritesPreviewWithoutOtherPlaylists() async throws {
        struct OlderSummary: Encodable, Sendable {
            let playlists: [NeteaseMusicPlaylist]
            let liked: Set<Int64>
            let times: [Int64: Date]
            let legacyArtwork: [String: String]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favorites = NeteaseMusicPlaylist(id: 2, title: "Favorites", creator: "User", creatorID: 1, artworkURL: nil, trackCount: 101, isFavorites: true)
        let other = NeteaseMusicPlaylist(id: 3, title: "Other", creator: "User", creatorID: 1, artworkURL: nil, trackCount: 101, isFavorites: false)
        let songs = (1...101).map { NeteaseMusicSong(id: Int64($0), title: "Song \($0)", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, unavailable: false) }
        let cache = NeteasePageCache(directory: folder)
        try await cache.save(OlderSummary(playlists: [favorites, other], liked: Set(songs.map(\.id)), times: [:], legacyArtwork: [:]), scope: "1", key: "library")
        for playlist in [favorites, other] {
            try await cache.save(NeteasePlaylistDetail(playlist: playlist, songs: songs, addedTimes: [:]), scope: "1", key: "playlist:\(playlist.id)")
        }
        let store = NeteaseMusicStore(client: makeClient([]), directory: folder)
        let saved = try NeteaseSavedSession(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential())
        await store.activate(saved, refresh: false)
        XCTAssertEqual(store.playlistTracks[2]?.count, 100)
        XCTAssertNil(store.playlistTracks[3])
        XCTAssertEqual(store.songs.count, 100)
        await store.waitForCacheWrites()
        await store.invalidate()

        try await cache.remove(scope: "1", key: "playlist:2")
        await store.activate(saved, refresh: false)
        XCTAssertEqual(store.playlistTracks[2]?.count, 100)
        XCTAssertEqual(store.playlistTotalCount(id: 2), 101)
        XCTAssertTrue(store.hasMorePlaylist(id: 2))
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await store.invalidate()
    }

    @MainActor func testLazyLyricsCacheIsAccountScopedAndPersistsNetworkMiss() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = NeteasePageCache(directory: folder)
        try await cache.save(NeteaseMusicLyrics(original: "First owner", translation: ""), scope: "1", key: "lyrics:12")
        try await cache.save(NeteaseMusicLyrics(original: "Second owner", translation: ""), scope: "2", key: "lyrics:12")
        let store = NeteaseMusicStore(client: makeClient([#"{"code":200,"lrc":{"lyric":"Network lyrics"},"tlyric":{"lyric":"Network translation"}}"#]), directory: folder)
        for owner in 1...2 {
            await store.activate(try .init(profile: .init(userID: Int64(owner), nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
            let lyrics = try await store.lyrics(songID: 12)
            XCTAssertEqual(lyrics.original, owner == 1 ? "First owner" : "Second owner")
        }
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await store.activate(try .init(profile: .init(userID: 3, nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
        let lyrics = try await store.lyrics(songID: 12)
        XCTAssertEqual(lyrics.original, "Network lyrics")
        await store.waitForCacheWrites()
        let persisted = try await cache.load(NeteaseMusicLyrics.self, scope: "3", key: "lyrics:12")
        XCTAssertEqual(persisted?.translation, "Network translation")
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0.count }, 1)
        await store.invalidate()
    }

    @MainActor func testAdoptedPlaylistCacheRequiresCurrentOwnerAndSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NeteaseMusicStore(client: makeClient([]), directory: folder)
        let initial = store.sessionRevision
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
        let revision = store.sessionRevision
        let playlist = NeteaseMusicPlaylist(id: 2, title: "Retained home playlist", creator: "Creator", creatorID: 7, artworkURL: nil, trackCount: 1, isFavorites: false)
        let song = NeteaseMusicSong(id: 12, title: "Cached", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, unavailable: false)
        let detail = NeteasePlaylistDetail(playlist: playlist, songs: [song], addedTimes: [:])
        store.adoptCachedPlaylist(detail, ownerID: 2, revision: revision)
        store.adoptCachedPlaylist(detail, ownerID: 1, revision: initial)
        XCTAssertNil(store.playlistTracks[2])
        store.adoptCachedPlaylist(detail, ownerID: 1, revision: revision)
        let complete = await store.completePlaylist(id: 2)
        XCTAssertTrue(complete)
        XCTAssertEqual(store.playlistTracks[2], [12])
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await store.activate(try .init(profile: .init(userID: 2, nickname: "Other", avatarURL: nil), credential: credential()), refresh: false)
        store.adoptCachedPlaylist(detail, ownerID: 1, revision: revision)
        XCTAssertNil(store.playlistTracks[2])
        await store.invalidate()
    }

    @MainActor func testRestoringReferencedSongsReadsOnlyCurrentOwnerWithoutHydratingPlaylists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = NeteasePageCache(directory: folder)
        let playlist = NeteaseMusicPlaylist(id: 2, title: "Cached", creator: "Creator", creatorID: 7, artworkURL: nil, trackCount: 2, isFavorites: false)
        for owner in 1...2 {
            let songs = [12, 13].map { NeteaseMusicSong(id: Int64($0), title: "Owner \(owner)", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, unavailable: false) }
            try await cache.save(NeteasePlaylistDetail(playlist: playlist, songs: songs, addedTimes: [:]), scope: String(owner), key: "playlist:2")
        }
        let store = NeteaseMusicStore(client: makeClient([]), directory: folder)
        for owner in 1...2 {
            await store.activate(try .init(profile: .init(userID: Int64(owner), nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
            let songs = await store.restoreCachedSongs(ids: [12, 99])
            XCTAssertEqual(songs.map(\.id), [12])
            XCTAssertEqual(songs.first?.title, "Owner \(owner)")
            XCTAssertTrue(store.songs.isEmpty)
            XCTAssertTrue(store.playlistTracks.isEmpty)
        }
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await store.invalidate()
        let signedOut = await store.restoreCachedSongs(ids: [12])
        XCTAssertTrue(signedOut.isEmpty)
    }

    @MainActor func testReferencedMetadataRestoresOldQueueAndMixedPlaylistWithoutPublishingCatalog() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = LocalLibrary.songLibrary.songs
        let local = LibrarySongItem(id: "local.wav", title: "Local", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        LocalLibrary.songLibrary.replace([local])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replace(previous)
            try? FileManager.default.removeItem(at: folder)
        }
        let cache = NeteasePageCache(directory: folder)
        let playlist = NeteaseMusicPlaylist(id: 2, title: "Cached", creator: "Creator", creatorID: 7, artworkURL: nil, trackCount: 1, isFavorites: false)
        let cached = NeteaseMusicSong(id: 12, title: "Recovered title", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, unavailable: false)
        try await cache.save(NeteasePlaylistDetail(playlist: playlist, songs: [cached], addedTimes: [:]), scope: "1", key: "playlist:2")
        let store = NeteaseMusicStore(client: makeClient([]), directory: folder)
        let saved = try NeteaseSavedSession(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential())
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in XCTFail("Cache restoration must not use network"); return saved.profile },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: store)
        await account.restoreCachedContent()
        let queue = NowPlayingModel.SavedQueue(ids: ["netease:1:12", local.id], index: 0, elapsed: 4, repeatMode: .all, shuffled: false)
        player.configurePlayback(resolveURL: { _ in nil }, persistenceURL: folder.appendingPathComponent("playback.json"))
        XCTAssertTrue(player.restoreQueue(songs: [local], restoredState: .success(queue)))
        XCTAssertEqual(player.queue.map(\.id), queue.ids)
        XCTAssertEqual(player.elapsed, 4)
        player.restoreOnlineIdentity(ownerID: "1")
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: folder.appendingPathComponent("playlists.json"), songs: [local])
        let id = try XCTUnwrap(library.createPlaylist(named: "Mixed", artwork: .playlist, in: nil)).id
        XCTAssertEqual(library.addSongs([.unavailable("netease:1:12"), local], to: id), 2)
        library.restoreOnlineIdentity(ownerID: "1")

        await OnlineMusicIntegration(account: account).restoreReferencedMetadata(player: player, playlistLibrary: library)
        XCTAssertEqual(player.current.title, "Recovered title")
        XCTAssertEqual(player.elapsed, 4)
        XCTAssertTrue(player.unavailableIDs.isEmpty)
        XCTAssertEqual(library.songs(in: id).map(\.title), ["Recovered title", "Local"])
        XCTAssertTrue(store.songs.isEmpty)
        XCTAssertTrue(store.playlistTracks.isEmpty)
        XCTAssertTrue(MusicFixtureProtocol.paths.withLock { $0.isEmpty })
        await player.flushQueuePersistence()
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

    @MainActor func testCancelledCompletionConsumerDoesNotCancelReplacementConsumer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = (1...101).map(Int64.init)
        let client = makeClient([try playlistResponse(ids: ids, embedded: Array(ids.prefix(100))), "pending"])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
        await store.loadPlaylist(id: 2)
        let started = expectation(description: "Complete queue request started")
        MusicFixtureProtocol.started.withLock { $0 = { started.fulfill() } }
        let first = Task { await store.completePlaylist(id: 2) }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        let joined = expectation(description: "Replacement query joined completion")
        let replacement = Task { joined.fulfill(); return await store.completePlaylist(id: 2) }
        await fulfillment(of: [joined], timeout: 2)
        let pending = MusicFixtureProtocol.pending.withLock { values in let result = values; values = []; return result }
        XCTAssertEqual(pending.count, 1)
        let response = try songsResponse([101])
        for request in pending { request(response) }
        let cancelledResult = await first.value
        let replacementResult = await replacement.value
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(replacementResult)
        XCTAssertEqual(store.playlistTracks[2], ids)
        XCTAssertFalse(store.hasMorePlaylist(id: 2))
        XCTAssertNil(store.playlistErrors[2])
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0.filter { $0 == "/eapi/v3/song/detail" }.count }, 1)
        MusicFixtureProtocol.started.withLock { $0 = nil }
        await store.invalidate()
    }

    @MainActor func testPlaylistRetryResumesFailedCompletionDespiteFreshFirstPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = (1...101).map(Int64.init)
        let client = makeClient([try playlistResponse(ids: ids, embedded: Array(ids.prefix(100))), #"{"code":500}"#, try songsResponse([101])])
        let store = NeteaseMusicStore(client: client, directory: folder)
        await store.activate(try .init(profile: .init(userID: 1, nickname: "User", avatarURL: nil), credential: credential()), refresh: false)
        await store.loadPlaylist(id: 2)
        let completed = await store.completePlaylist(id: 2)
        XCTAssertFalse(completed)
        XCTAssertEqual(store.playlistTracks[2]?.count, 100)
        XCTAssertNotNil(store.playlistErrors[2])
        // The detail page's retry action uses this same entry point.
        await store.loadPlaylist(id: 2)
        XCTAssertEqual(store.playlistTracks[2], ids)
        XCTAssertFalse(store.hasMorePlaylist(id: 2))
        XCTAssertNil(store.playlistErrors[2])
        XCTAssertEqual(MusicFixtureProtocol.paths.withLock { $0 }, ["/eapi/v6/playlist/detail", "/eapi/v3/song/detail", "/eapi/v3/song/detail"])
        await store.invalidate()
    }

    @MainActor private func makeClient(_ responses: [String]) -> NeteaseMusicClient {
        MusicFixtureProtocol.responses.withLock { $0 = responses }
        MusicFixtureProtocol.pending.withLock { $0 = [] }
        MusicFixtureProtocol.bodies.withLock { $0 = [] }
        MusicFixtureProtocol.requests.withLock { $0 = [] }
        MusicFixtureProtocol.paths.withLock { $0 = [] }
        MusicFixtureProtocol.started.withLock { $0 = nil }
        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [MusicFixtureProtocol.self]
        return NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: configuration)))
    }
    private func playlistResponse(ids: [Int64], embedded: [Int64]) throws -> String {
        let playlist: [String: Any] = ["id": 2, "name": "List", "creator": ["userId": 1, "nickname": "User"],
                                      "trackCount": ids.count, "trackIds": ids.map { ["id": $0, "at": $0 * 1000] },
                                      "tracks": embedded.map(songJSON)]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["code": 200, "playlist": playlist]), as: UTF8.self)
    }

    private func songsResponse(_ ids: some Sequence<Int64>) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["code": 200, "songs": ids.map(songJSON)]), as: UTF8.self)
    }

    private func songJSON(_ id: Int64) -> [String: Any] {
        ["id": id, "name": "Song \(id)", "ar": [["id": 1, "name": "Artist"]], "al": ["name": "Album"], "dt": 60000]
    }

    private func requestedSongIDs() throws -> [[Int64]] {
        let paths = MusicFixtureProtocol.paths.withLock { $0 }
        let bodies = MusicFixtureProtocol.bodies.withLock { $0 }
        return try zip(paths, bodies).compactMap { path, body in
            guard path == "/eapi/v3/song/detail" else { return nil }
            let frame = try decrypt(String(String(decoding: body, as: UTF8.self).dropFirst(7)))
            let json = try XCTUnwrap(frame.components(separatedBy: "-36cd479b6b5-").dropFirst().first)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let encoded = try XCTUnwrap(fields["c"] as? String)
            let ids = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Int64]])
            return try ids.map { try XCTUnwrap($0["id"]) }
        }
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
    static let requests = Mutex<[URLRequest]>([])
    static let pending = Mutex<[@Sendable (String) -> Void]>([])
    static let bodies = Mutex<[Data]>([])
    static let paths = Mutex<[String]>([])
    static let responses = Mutex<[String]>([])
    static let started = Mutex<(@Sendable () -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
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
        let response = Self.responses.withLock { responses in
            guard let first = responses.first else { return #"{"code":500}"# }
            let path = request.url?.path ?? ""
            // The library's independent playlist and liked-ID refreshes can arrive in either order.
            if ["/eapi/user/playlist", "/eapi/song/like/get"].contains(path),
               let firstPath = Self.refreshPath(for: first), firstPath != path,
               let index = responses.firstIndex(where: { Self.refreshPath(for: $0).map { $0 == path } ?? true }) {
                return responses.remove(at: index)
            }
            return responses.removeFirst()
        }
        if response == "offline" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if let code: URLError.Code = ["tls": .secureConnectionFailed, "certificate": .serverCertificateUntrusted, "cancelled": .cancelled][response] {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
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

    private static func refreshPath(for response: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] else { return nil }
        if root["playlist"] is [Any] { return "/eapi/user/playlist" }
        if root["ids"] is [Any] { return "/eapi/song/like/get" }
        return nil
    }
}
