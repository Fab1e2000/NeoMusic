import FrontAMPages
import XCTest

final class CollectionMenuTests: XCTestCase {
    @MainActor func testPlaylistEditingUsesHostCapabilityWithOpaqueIDs() {
        let route = FrontAMRoute.playlist("opaque-id")
        let item = FrontAMShelfItem(id: "opaque-id", title: "Playlist", artwork: .playlist, route: route)
        var lastMovedID: String?
        var actions = CollectionMenuActions(requestMove: { lastMovedID = $0 }, canDelete: { $0 == route })

        let editable = actions.sections(for: item, route: route).flatMap { $0 }
        XCTAssertTrue(editable.contains { $0.systemImage == "pencil" && !$0.isDisabled })
        XCTAssertTrue(editable.contains { $0.systemImage == "person.badge.plus" })

        actions.showsPlaylistEditingActions = { $0 != "opaque-id" }
        let readOnly = actions.sections(for: item, route: route).flatMap { $0 }
        XCTAssertFalse(readOnly.contains { ["pencil", "person.badge.plus"].contains($0.systemImage) })
        readOnly.first { $0.systemImage == "folder" }?.perform()
        XCTAssertEqual(lastMovedID, "opaque-id")
        XCTAssertTrue(readOnly.contains { $0.systemImage == "trash" })
    }
}
