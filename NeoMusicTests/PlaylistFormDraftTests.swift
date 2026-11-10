import XCTest
@testable import NeoMusic

@MainActor
final class PlaylistFormDraftTests: XCTestCase {
    func testNewPlaylistIsUnchangedUntilItHasMeaningfulTitleOrCover() {
        let initial = PlaylistDraftSnapshot()

        XCTAssertFalse(initial.hasChanges(title: ""))
        XCTAssertFalse(initial.hasChanges(title: " \n\t "))
        XCTAssertTrue(initial.hasChanges(title: "新的播放列表"))
        XCTAssertTrue(initial.hasChanges(title: "", hasCoverChange: true))
    }

    func testTitleChangesBecomeCleanWhenRestoredToSavedValue() {
        let initial = PlaylistDraftSnapshot(title: " 原来的标题\n")

        XCTAssertFalse(initial.hasChanges(title: "原来的标题"))
        XCTAssertTrue(initial.hasChanges(title: "新的标题"))
        XCTAssertFalse(initial.hasChanges(title: "\t原来的标题 "))
    }

    func testDescriptionChangesArePreservedAndCanBeReverted() {
        let initial = PlaylistDraftSnapshot(title: "播放列表", description: "原来的描述")

        XCTAssertFalse(initial.hasChanges(title: "播放列表", description: "原来的描述"))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", description: "新的描述"))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", description: "原来的描述\n"))
        XCTAssertFalse(initial.hasChanges(title: "播放列表", description: "原来的描述"))
    }

    func testSongMembershipAndOrderChangesCanBeReverted() {
        let initial = PlaylistDraftSnapshot(title: "播放列表", songIDs: ["first", "second"])

        XCTAssertFalse(initial.hasChanges(title: "播放列表", songIDs: ["first", "second"]))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", songIDs: ["second", "first"]))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", songIDs: ["first", "second", "third"]))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", songIDs: ["first"]))
        XCTAssertTrue(initial.hasChanges(title: "播放列表", songIDs: []))
        XCTAssertFalse(initial.hasChanges(title: "播放列表", songIDs: ["first", "second"]))
    }

    func testCoverChangeMakesOtherwiseUnchangedDraftDirty() {
        let initial = PlaylistDraftSnapshot(title: "播放列表", description: "描述", songIDs: ["song"])

        XCTAssertTrue(initial.hasChanges(title: "播放列表", description: "描述", songIDs: ["song"], hasCoverChange: true))
        XCTAssertFalse(initial.hasChanges(title: "播放列表", description: "描述", songIDs: ["song"], hasCoverChange: false))
    }
}
