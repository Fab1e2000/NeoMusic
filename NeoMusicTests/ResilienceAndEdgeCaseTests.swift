import AVFoundation
import Foundation
import Synchronization
import XCTest
@testable import FrontAMPages
@testable import NeoMusic

@MainActor
final class ResilienceAndEdgeCaseTests: XCTestCase {
    func testCorruptAudioAndCoversFailWithoutHidingValidTracks() async throws {
        let root = try directory()
        let valid = root.appending(path: "valid.wav")
        try PlayerTestFixtures.silentAudio(at: valid)
        let corrupt = root.appending(path: "broken.wav")
        let truncated = root.appending(path: "truncated.wav")
        try Data("not audio".utf8).write(to: corrupt)
        try Data([0x52, 0x49, 0x46, 0x46, 0x40, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]).write(to: truncated)
        let cover = root.appending(path: "cover.jpg")
        let empty = root.appending(path: "folder.png")
        try Data([0xff, 0xd8, 0xff]).write(to: cover)
        try Data().write(to: empty)
        let result = try await LocalMusicScanner().scan(root: root)
        XCTAssertEqual(result.tracks.map(\.id), ["valid.wav"])
        XCTAssertEqual(Set(result.failures), ["broken.wav", "truncated.wav"])
        XCTAssertNil(result.tracks.first?.artworkData)
        for file in [cover, empty] {
            let image = await LocalArtworkImages.load(file, pixels: 48)
            XCTAssertNil(image)
            XCTAssertNil(LocalArtworkImages.cached(file, pixels: 48))
        }

        let container = root.appending(path: "truncated.ncm")
        try Data("CTENFDAM".utf8).write(to: container)
        do {
            _ = try await NeteaseDownloadedAudio.prepare(container, declaredType: "ncm", staging: root)
            XCTFail("Accepted a truncated NCM container")
        } catch NeteaseDownloadedAudio.Failure.damagedContainer {
        }
    }

    func testMalformedLRCStillLoadsValidLinesAndRejectsBrokenEncoding() async throws {
        let root = try directory()
        let lyrics = root.appending(path: "track.lrc")
        try """
            [offset:-1e999]
            [999e999:32]invalid
            [00:61]invalid
            [00:03.25]surviving line
            [00:02.00
            """.write(to: lyrics, atomically: true, encoding: .utf8)
        let document = try await LyricsReader.loadDownloadedFile(lyrics)
        XCTAssertEqual(document.lines.map(\.text), ["surviving line"])
        XCTAssertEqual(document.lines.map(\.time), [3.25])
        XCTAssertNil(document.activeLine(at: 3.24))
        XCTAssertEqual(document.activeLine(at: 3.25), 0)

        try Data([0xff, 0xfe, 0xff]).write(to: lyrics)
        do {
            _ = try await LyricsReader.loadDownloadedFile(lyrics)
            XCTFail("Accepted invalid UTF-8")
        } catch is CocoaError {
        }
    }

    func testFiveThousandSongsFilterSortAndBuildNativeIndex() async throws {
        let songs = (0..<5_000).map { index -> LibrarySongItem in
            let group = ["Alpha", "Bravo", "99"][index % 3]
            let title = group + String(format: "%04d", index) + (index.isMultiple(of: 5) ? " needle" : "")
            return LibrarySongItem(id: String(index), title: title, artist: group, album: "Album",
                albumArtist: group, trackNumber: index, artwork: .missing, addedOrder: index,
                isFavorite: index.isMultiple(of: 2))
        }
        let projection = AsyncListProjection<SongsListView.ProjectionInput, SongsListView.Projection>()
        let expected = songs.filter { $0.isFavorite && $0.title.hasSuffix(" needle") }

        for (sort, letters) in [(SongSort.name, ["A", "B", "#"]), (.artist, ["#", "B", "A"]), (.addedDate, nil)] {
            let input = SongsListView.ProjectionInput(songs: songs, query: "NEEDLE", filter: .favorites, sort: sort)
            await input.project(using: projection)
            let result = try XCTUnwrap(projection.resolvedValue(for: input))
            XCTAssertEqual(result.ordered.count, 500)
            XCTAssertEqual(Set(result.ordered.map(\.id)), Set(expected.map(\.id)))
            XCTAssertEqual(result.indexedSections?.map(\.title), letters)
            if let letters {
                XCTAssertEqual(result.sections.map(\.letter), letters)
                XCTAssertEqual(result.indexedSections?.flatMap(\.songIDs), result.ordered.map(\.id))
                for section in result.sections {
                    let actual = section.items.map(\.addedOrder)
                    XCTAssertEqual(actual, actual.sorted())
                }
            } else {
                XCTAssertEqual(result.ordered.map(\.addedOrder), Array(expected.map(\.addedOrder).reversed()))
            }
        }

        let superseded = SongsListView.ProjectionInput(songs: songs, query: "", filter: .all, sort: .name)
        let cancelled = Task { await superseded.project(using: projection) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNil(projection.resolvedValue(for: superseded))
        XCTAssertEqual(projection.committedOutput?.ordered.count, 500)
        await superseded.project(using: projection)
        XCTAssertEqual(projection.resolvedValue(for: superseded)?.ordered.count, 5_000)
    }

    func testLogoutCancelsPageArtworkAndTransferAndDiscardsLateCompletion() async throws {
        let root = try directory()
        let started = expectation(description: "Old account page, cover, and download started")
        let stopped = expectation(description: "Old account requests cancelled")
        started.expectedFulfillmentCount = 3
        stopped.expectedFulfillmentCount = 3
        ResilienceRequestProtocol.activity.withLock { $0 = .init(started: started, stopped: stopped) }
        defer { ResilienceRequestProtocol.activity.withLock { $0 = nil } }

        let configuration = NeteaseAccountClient.sessionConfiguration()
        configuration.protocolClasses = [ResilienceRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = NeteaseMusicClient(transport: NeteaseAccountClient(session: session))
        let home = NeteaseHomeStore(client: client, directory: root.appending(path: "Home"), artworkSession: session)
        let downloadRoot = root.appending(path: "Download")
        let transport = NeteaseDownloadTransport(spool: downloadRoot.appending(path: "Transfers"), configuration: configuration)
        let downloads = NeteaseDownloadStore(client: client, directory: downloadRoot,
            musicDirectory: root.appending(path: "Music"), transport: transport)

        let song = NeteaseMusicSong(id: 12, title: "Old", artist: "Artist", album: "Album", artworkURL: nil, duration: 60)
        let metadata = NeteaseDownloadSong(song: song, albumArtist: song.artist, trackNumber: 1, discNumber: 1)
        let job = NeteaseDownloadJob(id: UUID(), ownerID: 1, metadata: metadata, requestedQuality: .lossless)
        try AtomicJSONStore.write(DownloadSnapshot(jobs: [job]), to: downloadRoot.appending(path: "index.json"))

        let previous = try savedSession(owner: 1)
        let account = NeteaseAccount(readSession: { previous }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in previous.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, home: home, downloads: downloads)
        await account.restoreCachedContent()
        XCTAssertNil(downloads.userID)
        XCTAssertEqual(downloads.states[song.id], .queued)
        await account.resumeRestoredDownloads()
        await account.restoreHomeCachedContent()
        XCTAssertEqual(home.userID, 1)
        XCTAssertEqual(downloads.userID, 1)

        let remote = try XCTUnwrap(URL(string: "https://resilience.invalid/cover.jpg"))
        let page = Task { try await home.detail(id: 90) }
        home.requestArtwork([remote])
        await fulfillment(of: [started], timeout: 5)
        try await account.logout()
        await fulfillment(of: [stopped], timeout: 5)
        do {
            _ = try await page.value
            XCTFail("Old page escaped cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)

        let replacement = try savedSession(owner: 2)
        await home.activate(replacement, refresh: false)
        await downloads.activate(replacement)
        let staleFile = root.appending(path: "late.transfer")
        try Data("fLaC-old".utf8).write(to: staleFile)
        transport.onEvent?(.completed(job.id, staleFile))

        XCTAssertEqual(home.userID, 2)
        XCTAssertEqual(downloads.userID, 2)
        XCTAssertNil(home.cachedDetail(id: 90))
        XCTAssertNil(home.cachedArtworkURL(remote: remote))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertNil(downloads.states[song.id])
        XCTAssertNil(downloads.records[song.id])
        let requestPaths = ResilienceRequestProtocol.activity.withLock { $0?.cancelled }
        XCTAssertEqual(requestPaths, ["/eapi/v6/playlist/detail", "/cover.jpg", "/transfer"])
    }

    func testDiagnosticsSanitizerRedactsSecretsAndLeavesNumericStatus() {
        let scenarios: [(String, [String])] = [
            ("request failed status=401 code=-1200 MUSIC_U=short __csrf=abc", ["MUSIC_U", "short", "__csrf", "abc"]),
            ("Cookie: theme=blue; MUSIC_U=a\n  continued=secret-value\nnext event", ["Cookie", "theme", "continued", "secret-value"]),
            (#"{"Authorization":"Bearer small-key","ignored":"value"}"#, ["Authorization", "small-key"]),
            ("open /Users/Alice Smith/Music/my-song.m4a", ["Alice", "my-song", "/Users/"]),
            ("open file:///Users/Alice Smith/Music/my-song.m4a", ["Alice", "Smith", "my-song"]),
            ("read /private/var/mobile/Containers/Data/Application/folder/song.m4a", ["/private/var", "song.m4a"]),
            (#"open \/Users\/example\/private-song"#, ["example", "private-song"]),
            ("mail user+music@example.com phone +86 138-0013-8000", ["user+music", "example.com", "138", "8000"]),
            ("https://example.com/song?key=abc&sig=xyz", ["https", "key=abc", "sig=xyz"]),
            ("https%3A%2F%2Fexample.com%2Fa%3Fsession%3Dsecret", ["example.com", "session", "secret"]),
            ("token=\"short value\" raw=eyAbcdEf0123456789_WXYZabcdef012345", ["short value", "eyAbcdEf"]),
        ]
        for (input, forbidden) in scenarios {
            let result = DiagnosticsLogExporter.sanitize(input)
            XCTAssertTrue(result.contains("[REDACTED]"))
            for value in forbidden { XCTAssertFalse(result.contains(value)) }
            XCTAssertEqual(DiagnosticsLogExporter.sanitize(result), result)
        }
        XCTAssertEqual(DiagnosticsLogExporter.sanitize("transport.rejected status=401 code=-1200"),
                       "transport.rejected status=401 code=-1200")
    }

    func testDiagnosticsReportHandlesZeroLimit() async throws {
        let report = try await DiagnosticsLogExporter.report(window: 60, limit: 0)
        XCTAssertTrue(report.hasPrefix("NeoMusic diagnostics v1\n"))
        XCTAssertTrue(report.contains("records=0 limit=0"))
        XCTAssertEqual(report.split(separator: "\n").count, 2)
    }

    func testRepeatedInterruptionsPreserveIntentUnlessOutputIsRemoved() async throws {
        let root = try directory()
        let url = root.appending(path: "audio.wav")
        try PlayerTestFixtures.silentAudio(at: url, seconds: 4)
        let activation = SessionActivation()
        let engine = LocalPlaybackEngine(activateSession: { try await activation.activate() })
        defer { engine.shutdown() }
        engine.load(url: url, autoplay: true)
        try await waitUntil { await activation.count == 1 }

        engine.handleInterruption(began: true)
        engine.handleInterruption(began: true)
        engine.handleInterruption(began: false, shouldResume: true)
        try await waitUntil { await activation.count == 2 }
        routeChange(.newDeviceAvailable)
        try await activation.complete(0)
        XCTAssertFalse(engine.isPlaying)
        try await activation.complete(1)
        try await waitUntil { engine.isPlaying }

        engine.handleInterruption(began: true)
        engine.handleInterruption(began: true)
        routeChange(.oldDeviceUnavailable)
        engine.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(engine.isActivating)
        XCTAssertFalse(engine.isPlaying)
        let requests = await activation.count
        XCTAssertEqual(requests, 2)

        engine.play()
        try await waitUntil { await activation.count == 3 }
        try await activation.complete(2)
        try await waitUntil { engine.isPlaying }
    }

    private struct DownloadSnapshot: Encodable {
        let records: [NeteaseDownloadRecord] = []
        let collections: [NeteaseDownloadCollection] = []
        let jobs: [NeteaseDownloadJob]
    }

    private func savedSession(owner: Int64) throws -> NeteaseSavedSession {
        try .init(profile: .init(userID: owner, nickname: "Fixture", avatarURL: nil),
                  credential: .init(musicU: "fixture-\(owner)"))
    }

    private func directory() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func routeChange(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !(await predicate()) {
            guard clock.now < deadline else { throw WaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitFailure: Error { case timeout }
}

private final class ResilienceRequestProtocol: URLProtocol, @unchecked Sendable {
    struct Activity {
        let started: XCTestExpectation
        let stopped: XCTestExpectation
        var requested: Set<String> = []
        var cancelled: Set<String> = []
    }

    static let activity = Mutex<Activity?>(nil)
    private static let heldPaths: Set = ["/eapi/v6/playlist/detail", "/cover.jpg", "/transfer"]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if Self.heldPaths.contains(url.path) {
            let expectation = Self.activity.withLock { value -> XCTestExpectation? in
                guard value?.requested.insert(url.path).inserted == true else { return nil }
                return value?.started
            }
            expectation?.fulfill()
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body = #"{"code":200,"data":{"id":12,"url":"https://resilience.invalid/transfer","type":"flac","level":"lossless"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let path = request.url?.path, Self.heldPaths.contains(path) else { return }
        let expectation = Self.activity.withLock { value -> XCTestExpectation? in
            guard value?.cancelled.insert(path).inserted == true else { return nil }
            return value?.stopped
        }
        expectation?.fulfill()
    }
}
