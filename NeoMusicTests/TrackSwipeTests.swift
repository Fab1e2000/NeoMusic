import Observation
import os
import SwiftUI
import XCTest
@testable import NeoMusic
@testable import FrontAMPlayer

@MainActor final class TrackSwipeTests: XCTestCase {
    private typealias Swipe = NowPlayingTrackSwipe<Text, EmptyView>

    private func entry(_ index: Int) -> PlayerAdjacentTrack {
        PlayerAdjacentTrack(index: index, track: PlayerTrack(id: "song-\(index)",
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

    private func makeEntry(_ index: Int, artist: String = "Artist") -> PlayerAdjacentTrack {
        PlayerAdjacentTrack(
            index: index,
            track: PlayerTrack(
                id: "song-\(index)",
                title: "Song \(index)",
                artists: artist,
                albumTitle: "Album",
                coverURL: nil,
                duration: 60
            )
        )
    }

    func testThresholdHapticFiresDuringDragUponCrossingCommitPointAndDoesNotDoubleFireOnRelease() {
        let controller = TrackSwipeController()
        var hapticCount = 0
        controller.feedbackHandler = { hapticCount += 1 }
        controller.prepareFeedbackHandler = {}

        let current = makeEntry(1)
        let prev = makeEntry(0)
        let next = makeEntry(2)
        controller.syncTrack(song: current.track, queueIndex: current.index)

        controller.panBegan(translation: 0, distance: 100, previous: prev, next: next)
        controller.panChanged(translation: -29, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 0)

        controller.panChanged(translation: -30, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 1)

        controller.panChanged(translation: -65, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 1)

        controller.panChanged(translation: -25, distance: 100, previous: prev, next: next)
        controller.panChanged(translation: -35, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 1)

        controller.panChanged(translation: -10, distance: 100, previous: prev, next: next)
        controller.panChanged(translation: -35, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 2)

        var selected: Int?
        controller.panEnded(
            translation: -35,
            velocity: 0,
            distance: 100,
            song: current.track,
            previous: prev,
            next: next,
            reduceMotion: true
        ) { selected = $0 }
        XCTAssertEqual(selected, 2)
        XCTAssertEqual(hapticCount, 2)
    }

    func testFastFlickFiresFallbackHapticOnceAtCommitWhenStaticThresholdWasNotReached() {
        let controller = TrackSwipeController()
        var hapticCount = 0
        controller.feedbackHandler = { hapticCount += 1 }
        controller.prepareFeedbackHandler = {}

        let current = makeEntry(1)
        let prev = makeEntry(0)
        let next = makeEntry(2)
        controller.syncTrack(song: current.track, queueIndex: current.index)

        controller.panBegan(translation: 0, distance: 100, previous: prev, next: next)
        controller.panChanged(translation: -15, distance: 100, previous: prev, next: next)
        XCTAssertEqual(hapticCount, 0)

        var selected: Int?
        controller.panEnded(
            translation: -15,
            velocity: -800,
            distance: 100,
            song: current.track,
            previous: prev,
            next: next,
            reduceMotion: true
        ) { selected = $0 }
        XCTAssertEqual(selected, 2)
        XCTAssertEqual(hapticCount, 1)
    }

    func testSameArtistPinsArtistDuringDragAndPreservesPinAcrossSettleOvershoot() {
        let controller = TrackSwipeController()
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        var now = baseDate
        controller.nowProvider = { now }
        controller.feedbackHandler = {}
        controller.prepareFeedbackHandler = {}

        let song0 = makeEntry(0, artist: "Same Artist")
        let song1 = makeEntry(1, artist: "Same Artist")
        let song2 = makeEntry(2, artist: "Other Artist")
        controller.syncTrack(song: song0.track, queueIndex: song0.index)

        controller.panBegan(translation: -20, distance: 278, previous: nil, next: song1)
        XCTAssertTrue(controller.isArtistPinned(at: controller.dragOffset, song: song0.track, previous: nil, next: song1))

        controller.panEnded(
            translation: -100,
            velocity: -500,
            distance: 278,
            song: song0.track,
            previous: nil,
            next: song1,
            reduceMotion: false
        ) { _ in }

        XCTAssertTrue(controller.isSettling)
        let samples = (0...30).map { controller.currentOffset(at: baseDate.addingTimeInterval(Double($0) / 60.0)) }
        let overshootOffset = try? XCTUnwrap(samples.first { $0 < -0.5 })
        XCTAssertNotNil(overshootOffset)
        XCTAssertTrue(
            controller.isArtistPinned(at: overshootOffset ?? -2, song: song1.track, previous: song0, next: song2)
        )

        now = baseDate.addingTimeInterval(0.6)
        controller.finishSettling()

        controller.panBegan(translation: -20, distance: 278, previous: song0, next: song2)
        XCTAssertFalse(controller.isArtistPinned(at: controller.dragOffset, song: song1.track, previous: song0, next: song2))
    }

    func testInterruptedMidFlightSwipePreservesLiveOffsetAcrossConsecutiveReleases() {
        let controller = TrackSwipeController()
        let baseDate = Date(timeIntervalSinceReferenceDate: 2_000)
        var now = baseDate
        controller.nowProvider = { now }
        controller.feedbackHandler = {}
        controller.prepareFeedbackHandler = {}

        let song0 = makeEntry(0, artist: "A")
        let song1 = makeEntry(1, artist: "B")
        let song2 = makeEntry(2, artist: "C")
        controller.syncTrack(song: song0.track, queueIndex: song0.index)

        var selected: [Int] = []
        controller.panBegan(translation: -95, distance: 278, previous: nil, next: song1)
        controller.panEnded(
            translation: -95,
            velocity: -400,
            distance: 278,
            song: song0.track,
            previous: nil,
            next: song1,
            reduceMotion: false
        ) { selected.append($0) }

        now = baseDate.addingTimeInterval(0.05)
        let liveOffset = controller.currentOffset(at: now)
        XCTAssertGreaterThan(liveOffset, 20)

        controller.panBegan(translation: 0, distance: 278, previous: song0, next: song2)
        XCTAssertEqual(controller.dragOffset, liveOffset, accuracy: 0.001)

        controller.panChanged(translation: -(liveOffset + 90), distance: 278, previous: song0, next: song2)
        XCTAssertEqual(controller.dragOffset, -90, accuracy: 0.001)

        controller.panEnded(
            translation: -(liveOffset + 90),
            velocity: -500,
            distance: 278,
            song: song1.track,
            previous: song0,
            next: song2,
            reduceMotion: false
        ) { selected.append($0) }

        XCTAssertEqual(selected, [1, 2])
        XCTAssertEqual(controller.currentStep, 2)
    }

    func testReversingDirectionMidSettleCommitsTheOppositeNeighbor() {
        let controller = TrackSwipeController()
        let baseDate = Date(timeIntervalSinceReferenceDate: 2_500)
        var now = baseDate
        controller.nowProvider = { now }
        controller.feedbackHandler = {}
        controller.prepareFeedbackHandler = {}

        let song0 = makeEntry(0, artist: "A")
        let song1 = makeEntry(1, artist: "B")
        let song2 = makeEntry(2, artist: "C")
        controller.syncTrack(song: song0.track, queueIndex: song0.index)

        var selected: [Int] = []
        controller.panBegan(translation: -95, distance: 278, previous: nil, next: song1)
        controller.panEnded(
            translation: -95,
            velocity: -400,
            distance: 278,
            song: song0.track,
            previous: nil,
            next: song1,
            reduceMotion: false
        ) { selected.append($0) }
        XCTAssertEqual(selected, [1])
        XCTAssertEqual(controller.currentStep, 1)

        now = baseDate.addingTimeInterval(0.05)
        let liveOffset = controller.currentOffset(at: now)
        XCTAssertGreaterThan(liveOffset, 20)
        controller.panBegan(translation: 0, distance: 278, previous: song0, next: song2)
        controller.panChanged(translation: 140, distance: 278, previous: song0, next: song2)
        XCTAssertEqual(controller.dragOffset, liveOffset + 140, accuracy: 0.001)
        controller.panEnded(
            translation: 140,
            velocity: 500,
            distance: 278,
            song: song1.track,
            previous: song0,
            next: song2,
            reduceMotion: false
        ) { selected.append($0) }

        XCTAssertEqual(selected, [1, 0])
        XCTAssertEqual(controller.currentStep, 0)
        XCTAssertEqual(controller.motion.value, liveOffset + 140 - 278, accuracy: 0.001)
    }

    func testDifferentArtistSwitchDoesNotPinArtistAcrossSettle() {
        let controller = TrackSwipeController()
        let baseDate = Date(timeIntervalSinceReferenceDate: 3_000)
        controller.nowProvider = { baseDate }
        controller.feedbackHandler = {}
        controller.prepareFeedbackHandler = {}

        let song0 = makeEntry(0, artist: "Artist A")
        let song1 = makeEntry(1, artist: "Artist B")
        let song2 = makeEntry(2, artist: "Artist C")
        controller.syncTrack(song: song0.track, queueIndex: song0.index)

        controller.panBegan(translation: -20, distance: 278, previous: nil, next: song1)
        XCTAssertFalse(controller.isArtistPinned(at: controller.dragOffset, song: song0.track, previous: nil, next: song1))
        controller.panChanged(translation: -100, distance: 278, previous: nil, next: song1)
        XCTAssertFalse(controller.isArtistPinned(at: controller.dragOffset, song: song0.track, previous: nil, next: song1))

        var selected: [Int] = []
        controller.panEnded(
            translation: -100,
            velocity: -500,
            distance: 278,
            song: song0.track,
            previous: nil,
            next: song1,
            reduceMotion: false
        ) { selected.append($0) }

        XCTAssertEqual(selected, [1])
        XCTAssertTrue(controller.isSettling)
        XCTAssertNil(controller.pinnedArtistDuringTransition)
        let showingPrevious = controller.currentOffset(at: baseDate.addingTimeInterval(0.05))
        XCTAssertGreaterThan(showingPrevious, 20)
        XCTAssertFalse(controller.isArtistPinned(at: showingPrevious, song: song1.track, previous: song0, next: song2))
        let overshoot = controller.currentOffset(at: baseDate.addingTimeInterval(0.15))
        XCTAssertLessThan(overshoot, 0)
        XCTAssertFalse(controller.isArtistPinned(at: overshoot, song: song1.track, previous: song0, next: song2))
        controller.finishSettling()
    }

    func testUnavailableDirectionAppliesRubberBandAndDoesNotTriggerHaptic() {
        let controller = TrackSwipeController()
        var hapticCount = 0
        controller.feedbackHandler = { hapticCount += 1 }
        controller.prepareFeedbackHandler = {}

        let current = makeEntry(0)
        controller.syncTrack(song: current.track, queueIndex: current.index)

        controller.panBegan(translation: 0, distance: 200, previous: nil, next: nil)
        controller.panChanged(translation: 150, distance: 200, previous: nil, next: nil)
        XCTAssertLessThan(controller.dragOffset, 90)
        XCTAssertGreaterThan(controller.dragOffset, 0)
        XCTAssertEqual(hapticCount, 0)

        var selected: [Int] = []
        controller.panEnded(
            translation: 150,
            velocity: 900,
            distance: 200,
            song: current.track,
            previous: nil,
            next: nil,
            reduceMotion: true
        ) { selected.append($0) }
        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(hapticCount, 0)
    }

    func testMotionOffsetUpdatesContinuouslyWithoutDiscreteSlotChurn() {
        let controller = TrackSwipeController()
        controller.feedbackHandler = {}
        controller.prepareFeedbackHandler = {}

        let song0 = makeEntry(0, artist: "A")
        let song1 = makeEntry(1, artist: "B")
        controller.syncTrack(song: song0.track, queueIndex: song0.index)

        XCTAssertEqual(controller.motion.value, 0)
        XCTAssertEqual(controller.motion.edgeStrength, 0)
        XCTAssertEqual(controller.offsetSign, 0)
        XCTAssertFalse(controller.showsPreviousSlot)
        XCTAssertFalse(controller.showsNextSlot)

        controller.panBegan(translation: -20, distance: 280, previous: nil, next: song1)
        XCTAssertEqual(controller.motion.value, -20, accuracy: 0.001)
        XCTAssertEqual(controller.motion.edgeStrength, 1.0, accuracy: 0.001)
        XCTAssertEqual(controller.offsetSign, -1)
        XCTAssertTrue(controller.showsNextSlot)
        XCTAssertFalse(controller.showsPreviousSlot)

        let discreteInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = controller.isDragging
            _ = controller.isSettling
            _ = controller.currentStep
            _ = controller.exitingSlot?.step
            _ = controller.pinnedArtistDuringTransition
            _ = controller.offsetSign
            _ = controller.showsPreviousSlot
            _ = controller.showsNextSlot
            _ = controller.allowsOppositePreviousSlot
            _ = controller.allowsOppositeNextSlot
        } onChange: {
            discreteInvalidations.withLock { $0 += 1 }
        }

        controller.panChanged(translation: -40, distance: 280, previous: nil, next: song1)
        controller.panChanged(translation: -60, distance: 280, previous: nil, next: song1)
        controller.panChanged(translation: -100, distance: 280, previous: nil, next: song1)

        XCTAssertEqual(controller.motion.value, -100, accuracy: 0.001)
        XCTAssertEqual(discreteInvalidations.withLock { $0 }, 0)

        var selected: [Int] = []
        controller.panEnded(
            translation: -100,
            velocity: -450,
            distance: 280,
            song: song0.track,
            previous: nil,
            next: song1,
            reduceMotion: false
        ) { selected.append($0) }

        XCTAssertEqual(selected, [1])
        XCTAssertEqual(controller.motion.value, 180, accuracy: 0.001)
        XCTAssertEqual(controller.offsetSign, 1)
        XCTAssertTrue(controller.showsPreviousSlot)
        XCTAssertFalse(controller.showsNextSlot)

        controller.finishSettling()
        XCTAssertEqual(controller.motion.value, 0)
        XCTAssertEqual(controller.motion.edgeStrength, 0)
        XCTAssertEqual(controller.offsetSign, 0)
        XCTAssertFalse(controller.showsPreviousSlot)
        XCTAssertFalse(controller.showsNextSlot)
        XCTAssertTrue(controller.allowsOppositePreviousSlot)
        XCTAssertTrue(controller.allowsOppositeNextSlot)
    }

    func testPostCommitMainThreadStallConsumesRealSpringTimeline() {
        let controller = TrackSwipeController()
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        controller.nowProvider = { now }
        let prev = makeEntry(0, artist: "Artist A")
        let current = makeEntry(1, artist: "Artist B")
        let next = makeEntry(2, artist: "Artist C")
        var selected: [Int] = []

        controller.panBegan(translation: 0, distance: 180, previous: prev, next: next)
        controller.panChanged(translation: -72, distance: 180, previous: prev, next: next)
        controller.panEnded(
            translation: -72,
            velocity: -150,
            distance: 180,
            song: current.track,
            previous: prev,
            next: next,
            reduceMotion: false
        ) { selected.append($0) }

        XCTAssertEqual(selected, [2])
        XCTAssertTrue(controller.isSettling)
        XCTAssertEqual(controller.exitingSlot?.track.id, current.track.id)
        XCTAssertEqual(controller.motion.value, 108, accuracy: 0.01)
        let releaseDate = now

        now = releaseDate.addingTimeInterval(0.090)
        controller.stepSpringFrame(at: now)
        XCTAssertTrue(controller.isSettling)
        let releaseOffset: CGFloat = 108
        let expectedFirstFrame = releaseOffset + TrackSwipeController.spring.value(
            target: -releaseOffset,
            initialVelocity: -150,
            time: now.timeIntervalSince(releaseDate)
        )
        XCTAssertEqual(controller.motion.value, expectedFirstFrame, accuracy: 0.01)
        XCTAssertLessThan(controller.motion.value, 20,
                          "A stalled commit must not shift the release spring back onto the real timeline (got \(controller.motion.value))")

        for _ in 0..<2 {
            now = now.addingTimeInterval(1.0 / 60.0)
            controller.stepSpringFrame(at: now)
            let expected = releaseOffset + TrackSwipeController.spring.value(
                target: -releaseOffset,
                initialVelocity: -150,
                time: now.timeIntervalSince(releaseDate)
            )
            XCTAssertEqual(controller.motion.value, expected, accuracy: 0.01)
        }

        for _ in 0..<45 where controller.isSettling {
            now = now.addingTimeInterval(1.0 / 60.0)
            controller.stepSpringFrame(at: now)
        }
        XCTAssertFalse(controller.isSettling)
        XCTAssertNil(controller.exitingSlot)
        XCTAssertEqual(controller.motion.value, 0)
    }

    func testUnstalledSpringPreservesRealTimelineAndExtendedStallFinishesCleanly() {
        let controller = TrackSwipeController()
        var now = Date(timeIntervalSinceReferenceDate: 2000)
        controller.nowProvider = { now }
        let prev = makeEntry(0, artist: "Artist A")
        let current = makeEntry(1, artist: "Artist B")
        let next = makeEntry(2, artist: "Artist C")

        controller.panBegan(translation: 0, distance: 180, previous: prev, next: next)
        controller.panChanged(translation: -20, distance: 180, previous: prev, next: next)
        controller.panEnded(
            translation: -20,
            velocity: 0,
            distance: 180,
            song: current.track,
            previous: prev,
            next: next,
            reduceMotion: false
        ) { _ in }

        let expectedAtTwoFrames = controller.currentOffset(at: now.addingTimeInterval(2.0 / 60.0))
        now = now.addingTimeInterval(1.0 / 60.0)
        controller.stepSpringFrame(at: now)
        now = now.addingTimeInterval(1.0 / 60.0)
        controller.stepSpringFrame(at: now)
        XCTAssertEqual(controller.motion.value, expectedAtTwoFrames, accuracy: 0.001)

        now = now.addingTimeInterval(1.2)
        controller.stepSpringFrame(at: now)
        XCTAssertFalse(controller.isSettling)
        XCTAssertEqual(controller.motion.value, 0)
    }
}
