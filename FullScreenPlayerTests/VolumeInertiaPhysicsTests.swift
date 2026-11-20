import XCTest
@testable import FullScreenPlayer

final class VolumeInertiaPhysicsTests: XCTestCase {
    func testStepDecaysVelocityAndAdvancesValue() {
        let result = VolumeInertiaPhysics.step(value: 0.5, velocity: 2.0, dt: 1.0 / 60.0)
        XCTAssertGreaterThan(result.value, 0.5)
        XCTAssertLessThan(result.value, 1.0)
        XCTAssertGreaterThan(result.velocity, 0)
        XCTAssertLessThan(result.velocity, 2.0)
        XCTAssertFalse(result.shouldStop)
    }

    func testStepStopsAtLowerAndUpperBounds() {
        let upper = VolumeInertiaPhysics.step(value: 0.99, velocity: 8.0, dt: 1.0 / 60.0)
        XCTAssertEqual(upper.value, 1.0)
        XCTAssertTrue(upper.shouldStop)

        let lower = VolumeInertiaPhysics.step(value: 0.01, velocity: -8.0, dt: 1.0 / 60.0)
        XCTAssertEqual(lower.value, 0.0)
        XCTAssertTrue(lower.shouldStop)
    }

    func testStepStopsBelowMinimumVelocity() {
        let result = VolumeInertiaPhysics.step(value: 0.5, velocity: 0.01, dt: 1.0 / 60.0)
        XCTAssertTrue(result.shouldStop)
    }

    func testStepClampsLargeFrameDelta() {
        let normal = VolumeInertiaPhysics.step(value: 0.2, velocity: 3.0, dt: VolumeInertiaPhysics.maxStepDuration)
        let huge = VolumeInertiaPhysics.step(value: 0.2, velocity: 3.0, dt: 5.0)
        XCTAssertEqual(normal, huge)
    }

    func testReleaseVelocityEstimatesWindowAndClamps() {
        let samples = [
            VolumeInertiaPhysics.TouchSample(timestamp: 1.000, x: 10),
            VolumeInertiaPhysics.TouchSample(timestamp: 1.020, x: 40),
            VolumeInertiaPhysics.TouchSample(timestamp: 1.040, x: 110)
        ]
        let velocity = VolumeInertiaPhysics.releaseVelocity(
            samples: samples,
            lastMotionTimestamp: 1.040,
            endTimestamp: 1.045,
            trackWidth: 200
        )
        // (110 - 10) / 200 / 0.04 = 12.5 -> clamped to 12.0
        XCTAssertEqual(velocity, 12.0, accuracy: 0.001)
    }

    func testReleaseVelocityReturnsZeroWhenStaleOrTooShort() {
        let samples = [
            VolumeInertiaPhysics.TouchSample(timestamp: 1.000, x: 10),
            VolumeInertiaPhysics.TouchSample(timestamp: 1.035, x: 60)
        ]
        let stale = VolumeInertiaPhysics.releaseVelocity(
            samples: samples,
            lastMotionTimestamp: 1.035,
            endTimestamp: 1.200,
            trackWidth: 200
        )
        XCTAssertEqual(stale, 0)

        let tooShort = VolumeInertiaPhysics.releaseVelocity(
            samples: [
                VolumeInertiaPhysics.TouchSample(timestamp: 1.000, x: 10),
                VolumeInertiaPhysics.TouchSample(timestamp: 1.002, x: 60)
            ],
            lastMotionTimestamp: 1.002,
            endTimestamp: 1.003,
            trackWidth: 200
        )
        XCTAssertEqual(tooShort, 0)
    }
}
