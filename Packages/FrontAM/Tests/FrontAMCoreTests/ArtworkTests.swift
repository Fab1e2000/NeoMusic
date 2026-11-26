import UIKit
import XCTest
@testable import FrontAMCore

final class ArtworkTests: XCTestCase {
    func testToastResourcesKeepChineseAndFormatEnglishCounts() throws {
        let chinese = try XCTUnwrap(Bundle.module.url(forResource: "zh-Hans", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let english = try XCTUnwrap(Bundle.module.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)))
        XCTAssertEqual(String(localized: "已喜爱", bundle: chinese), "已喜爱")
        XCTAssertEqual(String(localized: "已喜爱", bundle: english), "Favorited")
        let count = 2
        XCTAssertEqual(String(localized: "已添加\(count)首歌曲", bundle: chinese), "已添加2首歌曲")
        XCTAssertEqual(String(localized: "已添加\(count)首歌曲", bundle: english), "Songs added: 2")
    }

    func testSRGBAndOKLabReferencePoints() {
        XCTAssertEqual(ArtworkColorSpace.sRGBToLinear(0.5, power: pow), 0.21404114, accuracy: 0.000001)

        let white = ArtworkColorSpace.linearToOKLab(r: 1.0, g: 1.0, b: 1.0, cubeRoot: cbrt)
        XCTAssertEqual(white.l, 1, accuracy: 0.000001)
        XCTAssertEqual(white.a, 0, accuracy: 0.000001)
        XCTAssertEqual(white.b, 0, accuracy: 0.000001)

        let red = ArtworkColorSpace.linearToOKLab(r: 1.0, g: 0.0, b: 0.0, cubeRoot: cbrt)
        let linear = ArtworkColorSpace.oklabToLinearSRGB(l: Float(red.l), a: Float(red.a), b: Float(red.b))
        XCTAssertEqual(linear.x, 1, accuracy: 0.00001)
        XCTAssertEqual(linear.y, 0, accuracy: 0.00001)
        XCTAssertEqual(linear.z, 0, accuracy: 0.00001)
    }

    @MainActor func testFileProviderDecodesAndReusesImageIOThumbnail() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }
        try png.write(to: url)
        let provider = FrontAMLocalArtworkProvider()
        XCTAssertNil(provider.cached(url, pixels: 80))
        let first = await provider.load(url, pixels: 80)
        let image = try XCTUnwrap(first)
        XCTAssertEqual(image.cgImage?.width, 80)
        XCTAssertEqual(image.cgImage?.height, 40)

        provider.registerResolvedArtwork("opaque-cover", url: url)
        XCTAssertTrue(provider.cachedResolved("opaque-cover", pixels: 80) === image)
        let second = await provider.load(url, pixels: 80)
        XCTAssertTrue(second === image)

        let other = FrontAMLocalArtworkProvider()
        XCTAssertNil(other.resolvedURL(for: "opaque-cover"))
        XCTAssertNil(other.cached(url, pixels: 80))
    }
}
