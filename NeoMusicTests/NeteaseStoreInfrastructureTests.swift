import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

@MainActor
final class NeteaseStoreInfrastructureTests: XCTestCase {
    func testSessionCancelsAndWaitsForRegisteredWorkAcrossConcurrentTransitions() async {
        let scope = NeteaseSessionScope()
        let entered = expectation(description: "Request entered")
        let cancelled = expectation(description: "Request received cancellation")
        var finish: CheckedContinuation<Void, Never>?
        var transitionsFinished = 0
        let initial = scope.revision
        let request = scope.throwingTask {
            try await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    finish = continuation
                    entered.fulfill()
                }
                try Task.checkCancellation()
            } onCancel: {
                cancelled.fulfill()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let next = scope.advance()
        let firstTransition = Task {
            await scope.cancelAndDrain().value
            transitionsFinished += 1
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let final = scope.advance()
        let joining = expectation(description: "Next transition entered")
        let secondTransition = Task {
            joining.fulfill()
            await scope.cancelAndDrain().value
            transitionsFinished += 1
        }
        await fulfillment(of: [joining], timeout: 2)
        XCTAssertTrue(request.isCancelled)
        XCTAssertEqual(transitionsFinished, 0)
        XCTAssertFalse(scope.isCurrent(initial))
        XCTAssertFalse(scope.isCurrent(next))
        XCTAssertTrue(scope.isCurrent(final))
        finish?.resume()
        await firstTransition.value
        await secondTransition.value
        XCTAssertEqual(transitionsFinished, 2)
    }

    func testOnlyCurrentSignedInAuthenticationFailuresTriggerRecheck() {
        let scope = NeteaseSessionScope()
        var rechecks = 0
        scope.onAuthenticationRequired = { rechecks += 1 }
        let old = scope.revision
        let current = scope.advance()

        scope.report(NeteaseAccountError.authenticationRequired, revision: old, signedIn: true)
        scope.report(NeteaseAccountError.authenticationRequired, revision: current, signedIn: false)
        scope.report(NeteaseAccountError.http(403), revision: current, signedIn: true)
        XCTAssertEqual(rechecks, 0)

        scope.report(NeteaseAccountError.authenticationRequired, revision: current, signedIn: true)
        XCTAssertEqual(rechecks, 1)
    }

    func testKeyedWriterCommitsLatestValueIndependentlyByScopeAndDrainsStaleWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = NeteaseSessionScope()
        let cache = NeteasePageCache(directory: directory)
        let writer = KeyedPageCacheWriter(cache: cache, session: session)
        let encoded = Mutex<[Int]>([])
        for value in 1...10 {
            writer.save(TracedValue(value: value, didEncode: { item in encoded.withLock { $0.append(item) } }),
                scope: "1", key: "library")
        }
        writer.save(11, scope: "2", key: "library")
        await writer.flush()
        XCTAssertEqual(encoded.withLock { $0 }, [10])

        _ = session.advance()
        writer.save(12, scope: "1", key: "library")
        _ = session.advance()
        var pending = SessionTaskBag()
        writer.takePending(into: &pending)
        await session.cancelAndDrain(pending).value
        let first = try await cache.load(Int.self, scope: "1", key: "library")
        let second = try await cache.load(Int.self, scope: "2", key: "library")
        XCTAssertEqual(first, 10)
        XCTAssertEqual(second, 11)

        writer.save(13, scope: "1", key: "library")
        await writer.flush()
        let updated = try await cache.load(Int.self, scope: "1", key: "library")
        XCTAssertEqual(updated, 13)
    }

    func testPaginationPreservesOffsetsAndRejectsDuplicateOnlyNonFinalPages() async throws {
        var offsets: [Int] = []
        let result = try await NeteasePagination.collect(id: { $0 }) { offset in
            offsets.append(offset)
            return offset == 0 ? .init(items: [1, 1, 2], hasMore: true, advance: 200)
                : .init(items: [2, 3], hasMore: false, advance: 2)
        }
        XCTAssertEqual(offsets, [0, 200])
        XCTAssertEqual(result, [1, 2, 3])

        do {
            _ = try await NeteasePagination.collect(id: { $0 }) { _ in
                .init(items: [Int64(1)], hasMore: true, advance: 1)
            }
            XCTFail("Accepted a non-final page without new IDs")
        } catch { XCTAssertEqual(error as? NeteaseAccountError, .invalidResponse) }
    }

    func testSongDecodersPreserveEndpointAliasPriorityAndCredits() throws {
        let data = Data("""
        {"id":7,"name":"Song","ar":[{"id":-1,"name":"Compact"}],"artists":[{"id":8,"name":"Long"}],
         "al":{"id":5,"name":"Compact album","picUrl":"http://example.com/cover"},
         "album":{"id":6,"name":"Long album"},"dt":1000,"duration":2000,"no":3,"cd":"2"}
        """.utf8)
        let decoder = JSONDecoder()
        let music = try decoder.decode(NeteaseSongPayload.Music.self, from: data).model
        let home = try decoder.decode(NeteaseSongPayload.Home.self, from: data).model
        let search = try decoder.decode(NeteaseSongPayload.Search.self, from: data).model
        let download = try decoder.decode(NeteaseSongPayload.Download.self, from: data).model

        XCTAssertEqual(music.artists?.map(\.id), [-1])
        XCTAssertEqual(music.artworkURL?.scheme, "https")
        XCTAssertEqual(music.trackNumber, 3)
        XCTAssertEqual(home.artist, "Long")
        XCTAssertEqual(home.albumID, 6)
        XCTAssertEqual(home.duration, 2)
        XCTAssertNil(home.trackNumber)
        XCTAssertEqual(search.artist, "Compact")
        XCTAssertEqual(search.albumID, 5)
        XCTAssertEqual(search.duration, 1)
        XCTAssertNil(download.song.artists)
        XCTAssertNil(download.song.trackNumber)
        XCTAssertEqual(download.trackNumber, 3)
        XCTAssertEqual(download.discNumber, 2)
    }
}


private struct TracedValue: Encodable, Sendable {
    let value: Int
    let didEncode: @Sendable (Int) -> Void

    func encode(to encoder: any Encoder) throws {
        didEncode(value)
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
