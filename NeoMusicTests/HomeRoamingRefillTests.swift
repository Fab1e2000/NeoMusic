import Foundation
import Observation
import Synchronization
import XCTest
@testable import NeoMusic

@MainActor final class HomeRoamingRefillTests: XCTestCase {
    func testPausingWhileTailAdvanceWaitsKeepsTheNextBatchPaused() async throws {
        try await withRoamingFixture { _, player in
            let continuation = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(1)], from: "私人漫游", shuffled: false, continuation: continuation)
            player.skipForward()
            let request = try await self.waitForRequest()
            player.togglePlayback()
            XCTAssertFalse(player.isPlaying)

            request.respond(songIDs: [2, 3, 4])
            try await self.waitUntil { player.current.id == "netease:42:2" }

            XCTAssertEqual(player.queue.map(\.id), [1, 2, 3, 4].map { "netease:42:\($0)" })
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.hasUserQueuedUpcoming)
            XCTAssertEqual(player.continuation, continuation)
            XCTAssertEqual(ControlledRoamingProtocol.state.withLock { $0.requests.count }, 1)
        }
    }

    func testNaturalEndThenManualNextSharesRequestAndStopsOnFailure() async throws {
        try await withRoamingFixture { _, player in
            let continuation = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(1)], from: "私人漫游", shuffled: false, continuation: continuation)
            player.replenishQueue?(continuation, true, true)
            let request = try await self.waitForRequest()
            player.skipForward()
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(ControlledRoamingProtocol.state.withLock { $0.requests.count }, 1)

            request.respond(body: #"{"code":500}"#)
            try await self.waitUntil { !player.isPlaying }

            XCTAssertEqual(player.queue.map(\.id), ["netease:42:1"])
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertEqual(player.continuation, continuation)
            XCTAssertEqual(ControlledRoamingProtocol.state.withLock { $0.requests.count }, 1)
        }
    }

    func testLateBatchKeepsReplacementContinuationPausedAndUnchanged() async throws {
        try await withRoamingFixture { _, player in
            let first = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(1)], from: "私人漫游", shuffled: false, continuation: first)
            player.skipForward()
            let request = try await self.waitForRequest()

            let replacement = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(8)], from: "私人漫游", shuffled: false, continuation: replacement)
            player.togglePlayback()
            let changed = self.expectation(description: "Late batch changes the replacement playback")
            changed.isInverted = true
            withObservationTracking {
                _ = player.queue
                _ = player.currentIndex
                _ = player.isPlaying
            } onChange: { changed.fulfill() }

            request.respond(songIDs: [2, 3, 4])
            await self.fulfillment(of: [changed], timeout: 0.5)

            XCTAssertEqual(player.queue.map(\.id), ["netease:42:8"])
            XCTAssertEqual(player.continuation, replacement)
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testLateFailureKeepsReplacementContinuationPlaying() async throws {
        try await withRoamingFixture { _, player in
            let first = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(1)], from: "私人漫游", shuffled: false, continuation: first)
            player.replenishQueue?(first, true, true)
            let request = try await self.waitForRequest()

            let replacement = PlaybackQueueContinuation(ownerID: "42")
            player.play([self.song(8)], from: "私人漫游", shuffled: false, continuation: replacement)
            let changed = self.expectation(description: "Late failure changes the replacement playback")
            changed.isInverted = true
            withObservationTracking {
                _ = player.queue
                _ = player.currentIndex
                _ = player.isPlaying
            } onChange: { changed.fulfill() }

            request.respond(body: #"{"code":500}"#)
            await self.fulfillment(of: [changed], timeout: 0.5)

            XCTAssertEqual(player.queue.map(\.id), ["netease:42:8"])
            XCTAssertEqual(player.continuation, replacement)
            XCTAssertTrue(player.isPlaying)
        }
    }

    private func song(_ id: Int) -> LibrarySongItem {
        LibrarySongItem(id: "netease:42:\(id)", title: "Song \(id)", artist: "Artist", album: "Album",
                        albumArtist: "Artist", trackNumber: 0, artwork: .missing)
    }

    private func waitForRequest() async throws -> ControlledRoamingProtocol {
        try await waitUntil { ControlledRoamingProtocol.state.withLock { !$0.requests.isEmpty } }
        return try XCTUnwrap(ControlledRoamingProtocol.state.withLock { $0.requests.first })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the controlled roaming request")
        throw FixtureError.timeout
    }

    private func withRoamingFixture(_ body: (HomeMusicIntegration, NowPlayingModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ControlledRoamingProtocol.state.withLock { $0.requests = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledRoamingProtocol.self]
        let session = URLSession(configuration: configuration)
        let home = NeteaseHomeStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: session)), directory: root)
        let saved = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil),
                                       credential: try .init(musicU: "roaming-fixture"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, home: home)
        await account.restoreCachedContent()
        await home.activate(saved, refresh: false)
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let previousOwner = LocalLibrary.playbackAccountID
        let previousExternal = LocalLibrary.songLibrary.externalSongs
        let integration = HomeMusicIntegration(account: account, player: player)
        integration.connect()
        defer {
            integration.cancelPendingPlayback()
            player.shutdownPlayback()
            home.onChange = nil
            session.invalidateAndCancel()
            ControlledRoamingProtocol.state.withLock { $0.requests = [] }
            LocalLibrary.playbackAccountID = previousOwner
            LocalLibrary.songLibrary.replaceExternalSongs(previousExternal)
        }
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        do {
            try await body(integration, player)
        } catch {
            do { try await account.logout() }
            catch { XCTFail("Fixture account cleanup failed: \(error)") }
            throw error
        }
        try await account.logout()
    }

    private enum FixtureError: Error { case timeout }
}

private final class ControlledRoamingProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var requests: [ControlledRoamingProtocol] = []
    }
    static let state = Mutex(State())
    private let finished = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/eapi/v1/radio/get" {
            Self.state.withLock { $0.requests.append(self) }
        } else {
            respond(body: #"{"code":200,"result":[],"recommend":[]}"#)
        }
    }

    func respond(songIDs: [Int]) {
        let songs = songIDs.map {
            #"{"id":\#($0),"name":"Song \#($0)","ar":[{"name":"Artist"}],"al":{"name":"Album"},"dt":10000}"#
        }.joined(separator: ",")
        respond(body: #"{"code":200,"data":[\#(songs)]}"#)
    }

    func respond(body: String) {
        let shouldFinish = finished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
