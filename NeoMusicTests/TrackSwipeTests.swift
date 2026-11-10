import SwiftUI
import XCTest
@testable import NeoMusic

@MainActor final class TrackSwipeTests: XCTestCase {
    private typealias Swipe = NowPlayingTrackSwipe<Text>

    private func entry(_ index: Int) -> ReferenceUpcomingTrack {
        ReferenceUpcomingTrack(index: index, track: ReferenceTrack(id: "song-\(index)",
            title: "Song \(index)", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 60))
    }

    func testReleaseSelectsNextImmediatelyAndRebasesItsPosition() {
        var selected: Int?
        let offset = Swipe.selectTarget(translation: -40, velocity: 0, previous: entry(0),
            next: entry(2), distance: 100) { selected = $0 }

        XCTAssertEqual(selected, 2)
        XCTAssertEqual(offset, 60)
    }

    func testReleaseSelectsPreviousImmediatelyAndRebasesItsPosition() {
        var selected: Int?
        let offset = Swipe.selectTarget(translation: 40, velocity: 0, previous: entry(0),
            next: entry(2), distance: 100) { selected = $0 }

        XCTAssertEqual(selected, 0)
        XCTAssertEqual(offset, -60)
    }

    func testShortDragAndUnavailableNeighborKeepTheCurrentTrack() {
        var selections: [Int] = []
        XCTAssertNil(Swipe.selectTarget(translation: -10, velocity: 0, previous: entry(0),
            next: entry(2), distance: 100) { selections.append($0) })
        XCTAssertNil(Swipe.selectTarget(translation: -60, velocity: -800, previous: entry(0),
            next: nil, distance: 100) { selections.append($0) })
        XCTAssertNil(Swipe.selectTarget(translation: 60, velocity: 800, previous: nil,
            next: entry(2), distance: 100) { selections.append($0) })
        XCTAssertTrue(selections.isEmpty)
    }

    func testVelocitySelectsOnlyInTheDirectionOfTravel() {
        var selections: [Int] = []
        XCTAssertEqual(Swipe.selectTarget(translation: -10, velocity: -800, previous: entry(0),
            next: entry(2), distance: 100) { selections.append($0) }, 90)
        XCTAssertNil(Swipe.selectTarget(translation: 10, velocity: -800, previous: entry(0),
            next: entry(2), distance: 100) { selections.append($0) })
        XCTAssertEqual(selections, [2])
    }

    func testConsecutiveReleasesUseTheNewSelectionWithoutWaitingForAnimation() {
        var currentIndex = 0
        var selections: [Int] = []
        let select: (Int) -> Void = { index in
            currentIndex = index
            selections.append(index)
        }

        for _ in 0..<2 {
            let offset = Swipe.selectTarget(translation: -40, velocity: 0,
                previous: currentIndex > 0 ? entry(currentIndex - 1) : nil,
                next: entry(currentIndex + 1), distance: 100, select: select)
            XCTAssertEqual(offset, 60)
        }
        XCTAssertEqual(currentIndex, 2)
        XCTAssertEqual(selections, [1, 2])

        currentIndex = 4
        _ = Swipe.selectTarget(translation: 40, velocity: 0, previous: entry(currentIndex - 1),
            next: entry(currentIndex + 1), distance: 100, select: select)
        XCTAssertEqual(currentIndex, 3)
        XCTAssertEqual(selections, [1, 2, 3])
    }
}
