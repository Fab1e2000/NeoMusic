import XCTest
@testable import NeoMusic

final class AtomicJSONStoreTests: XCTestCase {
    private struct Snapshot: Codable, Equatable {
        let elapsed: Double
        let date: Date
    }

    func testCreatesParentsAndPreservesLegacyJSONEncoding() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "nested/playback.json")
        XCTAssertNil(try AtomicJSONStore.read(Snapshot.self, from: url))

        let initial = Snapshot(elapsed: 12, date: Date(timeIntervalSinceReferenceDate: 42))
        try AtomicJSONStore.write(initial, to: url)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)), initial)

        let legacy = Snapshot(elapsed: 15, date: Date(timeIntervalSinceReferenceDate: 45))
        try JSONEncoder().encode(legacy).write(to: url)
        XCTAssertEqual(try AtomicJSONStore.read(Snapshot.self, from: url), legacy)
        XCTAssertThrowsError(try AtomicJSONStore.write(Snapshot(elapsed: .nan, date: initial.date), to: url))
        XCTAssertEqual(try AtomicJSONStore.read(Snapshot.self, from: url), legacy)

        try Data("malformed".utf8).write(to: url)
        XCTAssertThrowsError(try AtomicJSONStore.read(Snapshot.self, from: url)) {
            XCTAssertTrue($0 is DecodingError)
        }
    }
}

@MainActor
final class PersistenceInfrastructureTests: XCTestCase {
    func testSelectionSetReadsAndWritesOnlyItsInjectedDefaults() throws {
        let suite = "SelectionSetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = UserDefaults.standard.stringArray(forKey: "pinnedAlbums")
        defaults.set(["existing"], forKey: "pinnedAlbums")

        let selection = LibrarySelectionSet(ids: ["seed"], key: AppDefaultsKey.pinnedAlbums, defaults: defaults)
        XCTAssertEqual(selection.ids, ["existing"])
        selection.toggle("existing")
        selection.insert("new")
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedAlbums"), ["new"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "pinnedAlbums"), previous)
    }

    func testPersistenceQueueRunsSeriallyAndFlushWaitsForEveryWrite() async {
        let queue = BackgroundTaskPersistenceQueue()
        var steps: [String] = []
        queue.startIfIdle {
            steps.append("first began")
            await Task.yield()
            steps.append("first finished")
        }
        queue.startIfIdle { XCTFail("A drain is already queued") }
        queue.enqueue { steps.append("second finished") }
        await queue.flush()
        XCTAssertEqual(steps, ["first began", "first finished", "second finished"])
    }
}
