import UIKit
import XCTest
@testable import NeoMusic
@testable import FullScreenPlayer

@MainActor
final class NowPlayingBackdropPreparationTests: XCTestCase {
    func testBackdropCacheDeduplicatesAndForgetsRemovedArtwork() async {
        let cache = NowPlayingBackdropCache()
        let url = URL(fileURLWithPath: "/backdrop-palette/dedup.png")
        let first = await cache.prepare(image(.systemRed), for: url)
        let second = await cache.prepare(image(.systemBlue), for: url)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(cache.cached(for: url))
        cache.removeCached(for: url)
        XCTAssertNil(cache.cached(for: url))
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

    private func palette(for image: UIImage, name: String) async throws -> NowPlayingBackdropPalette {
        let cache = NowPlayingBackdropCache()
        let url = URL(fileURLWithPath: "/backdrop-palette/\(name).png")
        defer { cache.removeCached(for: url) }
        let prepared = await cache.prepare(image, for: url)
        return try XCTUnwrap(prepared)
    }

    private func luma(_ swatch: NowPlayingBackdropPalette.Swatch) -> Float {
        0.299 * swatch.red + 0.587 * swatch.green + 0.114 * swatch.blue
    }

    private func averageLuma(_ row: Int, of palette: NowPlayingBackdropPalette) -> Float {
        let swatches = palette.swatches[(row * NowPlayingBackdropPalette.columns)..<((row + 1) * NowPlayingBackdropPalette.columns)]
        return swatches.reduce(0) { $0 + luma($1) } / Float(swatches.count)
    }

    func testPaletteDoesNotRetainSourceArtworkAndKeepsTwoToneVariation() async throws {
        weak var weakInput: UIImage?
        let cache = NowPlayingBackdropCache()
        let url = URL(fileURLWithPath: "/backdrop-palette/two-tone.png")
        defer { cache.removeCached(for: url) }
        let twoTone = splitImage(leftTop: .systemBlue, rightBottom: .systemOrange)
        let prepared: NowPlayingBackdropPalette?
        do {
            let transient = UIImage(cgImage: twoTone.cgImage!)
            weakInput = transient
            prepared = await cache.prepare(transient, for: url)
        }
        XCTAssertNil(weakInput, "Backdrop cache must not retain decoded source artwork")
        let palette = try XCTUnwrap(prepared)
        XCTAssertEqual(palette.swatches.count, 9)

        let topLeft = palette.swatches[0]
        let bottomRight = palette.swatches[8]
        let channelGap = max(abs(topLeft.red - bottomRight.red),
                             abs(topLeft.green - bottomRight.green),
                             abs(topLeft.blue - bottomRight.blue))
        XCTAssertGreaterThan(channelGap, 0.05, "Spatially separated cover colors must reach opposite mesh corners")
    }

    func testPaletteCalibratesExtremeCoversAndKeepsNeutralCoversNeutral() async throws {
        let dark = try await palette(for: image(.black), name: "black")
        let white = try await palette(for: image(.white), name: "white")

        XCTAssertLessThan(luma(dark.swatches[4]), luma(white.swatches[4]))
        XCTAssertTrue((0.40...0.70).contains(luma(white.swatches[4])),
                      "White covers should stay a calm background tone: \(luma(white.swatches[4]))")
        XCTAssertTrue((0.03...0.22).contains(luma(dark.swatches[4])),
                      "Black covers should keep a faint visible tone: \(luma(dark.swatches[4]))")

        for swatch in white.swatches {
            let spread = max(abs(swatch.red - swatch.green),
                             abs(swatch.green - swatch.blue),
                             abs(swatch.red - swatch.blue))
            XCTAssertLessThanOrEqual(spread, 0.02, "A neutral cover must not tint the backdrop: \(swatch)")
        }

        // 顶行只比中间行略亮，底行明显更暗，保证控制栏与歌词区域的可读性。
        XCTAssertGreaterThan(averageLuma(0, of: white), averageLuma(1, of: white))
        XCTAssertGreaterThan(averageLuma(1, of: white), averageLuma(2, of: white))
    }

    private func splitImage(leftTop: UIColor, rightBottom: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            leftTop.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            rightBottom.setFill()
            context.fill(CGRect(x: 32, y: 32, width: 32, height: 32))
        }
    }
}
