import XCTest
import SQLite3
@testable import NeoMusic

@MainActor final class NeteasePageCacheTests: XCTestCase {
    private struct Snapshot: Codable, Sendable, Equatable {
        let title: String
        let nextOffset: Int
    }

    private func directory() -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testInitializationDoesNotCreateDatabase() {
        let root = directory()
        _ = NeteasePageCache(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPagesAreUpdatedIndependentlyAndAccountScopesAreIsolated() async throws {
        let cache = NeteasePageCache(directory: directory())
        let first = Snapshot(title: "First page", nextOffset: 100)
        let updated = Snapshot(title: "Updated page", nextOffset: 200)
        let other = Snapshot(title: "Other account", nextOffset: 50)
        try await cache.save(first, scope: "account-42", key: "playlist:'7'")
        try await cache.save(first, scope: "account-42", key: "playlist:8")
        try await cache.save(other, scope: "account-43", key: "playlist:'7'")
        try await cache.save(updated, scope: "account-42", key: "playlist:'7'")

        let page = try await cache.load(Snapshot.self, scope: "account-42", key: "playlist:'7'")
        let unchanged = try await cache.load(Snapshot.self, scope: "account-42", key: "playlist:8")
        let otherOwner = try await cache.load(Snapshot.self, scope: "account-43", key: "playlist:'7'")
        let missing = try await cache.load(Snapshot.self, scope: "public", key: "playlist:'7'")
        XCTAssertEqual(page, updated)
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(otherOwner, other)
        XCTAssertNil(missing)
    }

    func testReopenedCacheRestoresPaginationAndPrefixIsLiteral() async throws {
        let root = directory()
        let cache = NeteasePageCache(directory: root)
        let snapshot = Snapshot(title: "Loaded", nextOffset: 200)
        try await cache.save(snapshot, scope: "42", key: "playlist_%:7")
        try await cache.save(snapshot, scope: "42", key: "playlist_XX:8")
        try await cache.save(snapshot, scope: "43", key: "playlist_%:9")

        let reopened = NeteasePageCache(directory: root)
        let pages = try await reopened.entries(Snapshot.self, scope: "42", prefix: "playlist_%:")
        XCTAssertEqual(pages, ["playlist_%:7": snapshot])
    }

    func testRemovingOnePageOrAccountPreservesOtherContent() async throws {
        let cache = NeteasePageCache(directory: directory())
        let snapshot = Snapshot(title: "Saved", nextOffset: 100)
        try await cache.save(snapshot, scope: "42", key: "playlist:1")
        try await cache.save(snapshot, scope: "42", key: "playlist:2")
        try await cache.save(snapshot, scope: "43", key: "playlist:1")
        try await cache.remove(scope: "42", key: "playlist:1")
        let remaining = try await cache.entries(Snapshot.self, scope: "42", prefix: "")
        XCTAssertEqual(remaining, ["playlist:2": snapshot])

        try await cache.removeAll(scope: "42")
        let removedAccount = try await cache.entries(Snapshot.self, scope: "42", prefix: "")
        let otherAccount = try await cache.entries(Snapshot.self, scope: "43", prefix: "")
        XCTAssertTrue(removedAccount.isEmpty)
        XCTAssertEqual(otherAccount, ["playlist:1": snapshot])
    }

    func testCapacityEvictsLeastRecentlyUpdatedPageAcrossScopes() async throws {
        let cache = NeteasePageCache(directory: directory(), capacity: 2)
        let snapshot = Snapshot(title: "Saved", nextOffset: 100)
        try await cache.save(snapshot, scope: "42", key: "first")
        try await cache.save(snapshot, scope: "43", key: "second")
        try await cache.save(Snapshot(title: "Refreshed", nextOffset: 200), scope: "42", key: "first")
        try await cache.save(snapshot, scope: "42", key: "third")

        let newest = try await cache.entries(Snapshot.self, scope: "42", prefix: "")
        let evicted = try await cache.load(Snapshot.self, scope: "43", key: "second")
        XCTAssertEqual(Set(newest.keys), ["first", "third"])
        XCTAssertEqual(newest["first"]?.nextOffset, 200)
        XCTAssertNil(evicted)
    }

    func testCancelledSaveDoesNotOpenOrWriteCache() async {
        let root = directory()
        let cache = NeteasePageCache(directory: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await cache.save(Snapshot(title: "Cancelled", nextOffset: 100), scope: "42", key: "playlist:1")
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testEncodingFailurePreservesPreviousSnapshot() async throws {
        struct FailingSnapshot: Encodable, Sendable {
            struct Failure: Error { }
            func encode(to encoder: Encoder) throws { throw Failure() }
        }
        let cache = NeteasePageCache(directory: directory(), capacity: 1)
        let snapshot = Snapshot(title: "Previous", nextOffset: 100)
        try await cache.save(snapshot, scope: "42", key: "playlist:1")
        do {
            try await cache.save(FailingSnapshot(), scope: "42", key: "playlist:1")
            XCTFail("Encoding failure should reach the caller")
        } catch is FailingSnapshot.Failure { }
        let previous = try await cache.load(Snapshot.self, scope: "42", key: "playlist:1")
        XCTAssertEqual(previous, snapshot)
    }

    func testMalformedPageDoesNotPreventOtherPagesRestoring() async throws {
        let root = directory()
        let cache = NeteasePageCache(directory: root)
        let snapshot = Snapshot(title: "Good", nextOffset: 100)
        try await cache.save(snapshot, scope: "42", key: "playlist:good")
        try await cache.save(snapshot, scope: "42", key: "playlist:broken")
        try corruptPage(at: root, key: "playlist:broken")
        let pages = try await cache.entries(Snapshot.self, scope: "42", prefix: "playlist:")
        XCTAssertEqual(pages, ["playlist:good": snapshot])

        try await cache.save(snapshot, scope: "42", key: "playlist:broken")
        try corruptPage(at: root, key: "playlist:broken")
        let broken = try await cache.load(Snapshot.self, scope: "42", key: "playlist:broken")
        let good = try await cache.load(Snapshot.self, scope: "42", key: "playlist:good")
        XCTAssertNil(broken)
        XCTAssertEqual(good, snapshot)
    }

    func testDatabaseOpenFailureIsReportedAndExistingFileIsPreserved() async throws {
        let root = directory()
        let existing = Data("Existing file".utf8)
        try existing.write(to: root)
        let cache = NeteasePageCache(directory: root)
        do {
            try await cache.save(Snapshot(title: "New", nextOffset: 0), scope: "42", key: "playlist:1")
            XCTFail("An unusable cache directory should report its error")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: root), existing)
    }

    func testEncodingAndDecodingRunOffMainThread() async throws {
        struct ExecutionSnapshot: Codable, Sendable {
            let encodedOnMain: Bool
            let decodedOnMain: Bool
            init() { encodedOnMain = true; decodedOnMain = true }
            init(from decoder: Decoder) throws {
                encodedOnMain = try decoder.singleValueContainer().decode(Bool.self)
                decodedOnMain = Thread.isMainThread
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(Thread.isMainThread)
            }
        }
        let cache = NeteasePageCache(directory: directory())
        try await cache.save(ExecutionSnapshot(), scope: "42", key: "execution")
        let value = try await cache.load(ExecutionSnapshot.self, scope: "42", key: "execution")
        XCTAssertEqual(value?.encodedOnMain, false)
        XCTAssertEqual(value?.decodedOnMain, false)
    }

    private func corruptPage(at directory: URL, key: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open(directory.appendingPathComponent("content.sqlite").path, &database)
        defer { sqlite3_close_v2(database) }
        guard status == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(status)) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "UPDATE pageContent SET payload = x'7B' WHERE cacheKey = ?", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(prepared)) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = sqlite3_bind_text(statement, 1, key, -1, transient)
        guard bound == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(bound)) }
        let updated = sqlite3_step(statement)
        guard updated == SQLITE_DONE else { throw NSError(domain: "SQLiteFixture", code: Int(updated)) }
    }
}
