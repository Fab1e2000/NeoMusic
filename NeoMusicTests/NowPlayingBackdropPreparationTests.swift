import UIKit
import XCTest
@testable import NeoMusic

@MainActor
final class NowPlayingBackdropPreparationTests: XCTestCase {
    func testPreparedPairPreservesCalibratedSolidColorPixels() async throws {
        let renderer = NowPlayingBackdropRenderer()
        let examples: [(UIColor, [[UInt8]], [UInt8])] = [
            (.black, [[10, 10, 10, 255], [17, 17, 17, 255], [14, 14, 14, 255]], [0, 0, 0, 255]),
            (.white, [[173, 173, 173, 255], [178, 178, 178, 255], [105, 105, 105, 255]], [255, 255, 255, 255]),
            (.red, [[214, 0, 0, 255], [243, 0, 0, 255], [143, 4, 4, 255]], [255, 0, 0, 255])
        ]
        for (index, example) in examples.enumerated() {
            let value = await renderer.render(image(example.0), for: URL(fileURLWithPath: "/backdrop/\(index).png"))
            let pair = try XCTUnwrap(value)
            XCTAssertEqual(pair.dimmed.cgImage?.width, 1)
            XCTAssertEqual(pair.dimmed.cgImage?.height, 256)
            for (position, row) in [0, 107, 255].enumerated() {
                XCTAssertEqual(try pixel(pair.dimmed, row: row), example.1[position])
                XCTAssertEqual(try pixel(pair.undimmed, row: row), example.2)
            }
        }
    }

    func testCacheReusesBothResultsWithoutRetainingSourceCover() async throws {
        let renderer = NowPlayingBackdropRenderer()
        let url = URL(fileURLWithPath: "/backdrop/reused.png")
        weak var source: UIImage?
        let first: NowPlayingBackdropRenderer.Images?
        do {
            let input = UIImage(cgImage: image(.red).cgImage!)
            source = input
            first = await renderer.render(input, for: url)
        }
        XCTAssertNil(source, "Derived background caching must not hold decoded source artwork")
        let expected = try XCTUnwrap(first)
        let cached = try XCTUnwrap(renderer.cached(for: url))
        XCTAssertTrue(cached.dimmed === expected.dimmed)
        XCTAssertTrue(cached.undimmed === expected.undimmed)
        let repeated = await renderer.render(image(.red), for: url)
        XCTAssertTrue(repeated?.dimmed === expected.dimmed)
        XCTAssertTrue(repeated?.undimmed === expected.undimmed)
        XCTAssertEqual(renderer.cache.countLimit, 32)
        XCTAssertEqual(renderer.cache.totalCostLimit, 64 * 1_024)
        renderer.cache.removeAllObjects()
        XCTAssertNil(renderer.cached(for: url))
    }

    func testDifferentArtworkIdentityAndCancelledWorkDoNotReuseOrPublishWrongBackground() async throws {
        let renderer = NowPlayingBackdropRenderer()
        let redURL = URL(fileURLWithPath: "/backdrop/red.png")
        let whiteURL = URL(fileURLWithPath: "/backdrop/white.png")
        let first = await renderer.render(image(.red), for: redURL)
        let second = await renderer.render(image(.white), for: whiteURL)
        XCTAssertNotEqual(try pixel(XCTUnwrap(first).dimmed, row: 0), try pixel(XCTUnwrap(second).dimmed, row: 0))
        let cancelledURL = URL(fileURLWithPath: "/backdrop/cancelled.png")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await renderer.render(image(.black), for: cancelledURL)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(renderer.cached(for: cancelledURL))
    }

    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func pixel(_ image: UIImage, row: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let start = row * cgImage.bytesPerRow
        return Array(UnsafeBufferPointer(start: bytes + start, count: 4))
    }
}
