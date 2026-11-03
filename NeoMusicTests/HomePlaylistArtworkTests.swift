import XCTest
import UIKit
@testable import NeoMusic

@MainActor final class HomePlaylistArtworkTests: XCTestCase {
    func testBlurPreservesOpaqueWhiteAtBottomAndSideEdges() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 248, height: 248), format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 248, height: 248))
        }
        let result = await HomePlaylistArtworkRenderer().render(cover, key: "white", scale: 1)
        let images = try XCTUnwrap(result)
        let image = try XCTUnwrap(images.background.cgImage)
        var pixels = [UInt8](repeating: 0, count: 248 * 330 * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 248, height: 330, bitsPerComponent: 8,
                                             bytesPerRow: 248 * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 248, height: 330))
        for (x, y) in [(0, 0), (124, 0), (247, 0), (0, 329), (124, 329), (247, 329), (124, 165)] {
            let offset = (y * 248 + x) * 4
            for channel in 0..<4 { XCTAssertGreaterThanOrEqual(pixels[offset + channel], 253, "Edge pixel \(x),\(y)") }
        }
    }
}
