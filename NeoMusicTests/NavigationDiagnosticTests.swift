import XCTest
@testable import NeoMusic

final class NavigationDiagnosticTests: XCTestCase {
    func testDiagnosticFilePreservesEventOrderAndEscapesTitles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = NavigationDiagnosticFile(directory: directory)
        file.append(["event": "willAppear", "sequence": "1", "title": "专辑\n\"标题\""])
        file.append(["event": "transitionCompleted", "sequence": "2", "cancelled": "true"])
        await file.flush()
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let records = try text.split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0["sequence"] }, ["1", "2"])
        XCTAssertEqual(records[0]["title"], "专辑\n\"标题\"")
        XCTAssertEqual(records[1]["cancelled"], "true")
    }
}
