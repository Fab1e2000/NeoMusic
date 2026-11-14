import MetalKit
import UIKit
import XCTest
@testable import NeoMusic

@MainActor
final class NowPlayingBackdropPreparationTests: XCTestCase {
    func testFluidCacheDeduplicatesWithoutRetainingSourceArtwork() async throws {
        let cache = NowPlayingFluidBackdropCache()
        let url = URL(fileURLWithPath: "/fluid-backdrop/dedup.png")
        let first = await cache.prepare(image(.systemRed), for: url)
        let second = await cache.prepare(image(.systemBlue), for: url)
        XCTAssertTrue(first === second)
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

    private func pixel(_ image: UIImage, row: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let start = row * cgImage.bytesPerRow
        return Array(UnsafeBufferPointer(start: bytes + start, count: 4))
    }

    func testFluidSourceOklabProfileCalibratesExtremeCoversAndDoesNotRetainImage() async throws {
        weak var weakInput: UIImage?
        let cache = NowPlayingFluidBackdropCache()
        let url = URL(fileURLWithPath: "/fluid-backdrop/two-tone.png")
        let twoTone = splitImage(leftTop: .systemBlue, rightBottom: .systemOrange)
        let prepared: NowPlayingFluidBackdropSource?
        do {
            let transient = UIImage(cgImage: twoTone.cgImage!)
            weakInput = transient
            prepared = await cache.prepare(transient, for: url)
        }
        XCTAssertNil(weakInput, "Fluid backdrop cache must not retain decoded source artwork")
        let source = try XCTUnwrap(prepared)
        XCTAssertEqual(source.rgba8SRGBData.count, 128 * 128 * 4)
        XCTAssertGreaterThan(source.profile.accentStrength, 0.35)
        XCTAssertGreaterThanOrEqual(source.profile.targetCenterL, 0.19)
        XCTAssertLessThanOrEqual(source.profile.targetCenterL, 0.71)

        let darkSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.black)))
        let whiteSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.white)))
        XCTAssertLessThan(darkSource.profile.accentStrength, 0.05)
        XCTAssertLessThan(whiteSource.profile.accentStrength, 0.05)
        XCTAssertLessThan(darkSource.profile.targetCenterL, whiteSource.profile.targetCenterL)
        XCTAssertGreaterThan(whiteSource.profile.targetCenterL, 0.58)
        XCTAssertLessThanOrEqual(whiteSource.profile.targetCenterL, 0.71)
        XCTAssertTrue(cache.cached(for: url) === source)
    }

    func testFluidMetalPipelineRenders2DBlobsAndCrossfade() throws {
        guard let pipelines = NowPlayingBackdropMetalPipelines() else {
            throw XCTSkip("Metal pipelines unavailable on this destination")
        }
        let engine = try XCTUnwrap(NowPlayingFluidBackdropEngine(pipelines: pipelines))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: NowPlayingFluidBackdropEngine.canvasWidth,
            height: NowPlayingFluidBackdropEngine.canvasHeight,
            mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        let backdropTarget = try XCTUnwrap(pipelines.device.makeTexture(descriptor: targetDescriptor))
        let driftedTarget = try XCTUnwrap(pipelines.device.makeTexture(descriptor: targetDescriptor))
        let crossfadeTarget = try XCTUnwrap(pipelines.device.makeTexture(descriptor: targetDescriptor))

        let blueSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: splitImage(leftTop: .systemBlue, rightBottom: .systemOrange)))
        let redSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.systemRed)))

        try renderSync(engine: engine, target: backdropTarget, source: blueSource, time: 0.4, crossfade: 1, hasFrozen: false)
        try renderSync(engine: engine, target: driftedTarget, source: blueSource, time: 0.4, crossfade: 1, hasFrozen: false)

        let backdropPixels = readBGRA(from: backdropTarget)
        let driftedPixels = readBGRA(from: driftedTarget)

        // Verify true 2D horizontal/vertical variation rather than flat 1D horizontal stripe.
        let topLeft = pixelBGRA(backdropPixels, x: 24, y: 40, width: backdropTarget.width)
        let topRight = pixelBGRA(backdropPixels, x: backdropTarget.width - 24, y: 40, width: backdropTarget.width)
        let bottomCenter = pixelBGRA(backdropPixels, x: backdropTarget.width / 2, y: backdropTarget.height - 28, width: backdropTarget.width)
        XCTAssertNotEqual(topLeft, topRight, "Fluid backdrop should preserve 2D horizontal color variation")
        XCTAssertGreaterThan(luma(topLeft) + luma(topRight), 2 * luma(bottomCenter), "Top should stay lighter than anchored bottom")
        XCTAssertEqual(lumaSpread(driftedPixels), lumaSpread(backdropPixels), accuracy: 1.0)

        // Freeze Track A and crossfade halfway to red Track B; verify blended channels lie between Track A and Track B.
        let freezeBuffer = try XCTUnwrap(pipelines.queue.makeCommandBuffer())
        engine.captureFrozenFrame(using: freezeBuffer)
        freezeBuffer.commit()
        freezeBuffer.waitUntilCompleted()

        try renderSync(engine: engine, target: crossfadeTarget, source: redSource, time: 0.5, crossfade: 0.5, hasFrozen: true)
        let blended = pixelBGRA(readBGRA(from: crossfadeTarget), x: 80, y: 120, width: crossfadeTarget.width)
        XCTAssertGreaterThan(blended[2], 30, "Crossfade toward red track should gain red energy")
        XCTAssertGreaterThan(blended[0], 5, "Mid-crossfade should retain cool energy from frozen blue/orange track")

        // Mostly-white cover with a small red corner accent must keep light neutral top without pink wash.
        let whiteRedCorner = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            f.preferredRange = .standard
            return f
        }()).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.red.setFill()
            let path = UIBezierPath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 38, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 38))
            path.close()
            path.fill()
        }
        let whiteRedSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: whiteRedCorner))
        XCTAssertGreaterThan(whiteRedSource.profile.targetCenterL, 0.52)
        try renderSync(engine: engine, target: backdropTarget, source: whiteRedSource, time: 0.0, crossfade: 1, hasFrozen: false)
        let wrPixels = readBGRA(from: backdropTarget)
        let wrTopRight = pixelBGRA(wrPixels, x: 132, y: 20, width: backdropTarget.width)
        let wrSpread = max(abs(Int(wrTopRight[2]) - Int(wrTopRight[1])), abs(Int(wrTopRight[1]) - Int(wrTopRight[0])))
        XCTAssertGreaterThanOrEqual(Int(wrTopRight[1]), 135)
        XCTAssertLessThanOrEqual(wrSpread, 22, "Mostly-white cover should not wash neutral regions pink: \(wrTopRight)")
    }

    func testFluidBackdropViewRendersSynchronouslyAndStopsCleanly() async throws {
        guard let pipelines = NowPlayingBackdropMetalPipelines() else {
            throw XCTSkip("Metal pipelines unavailable on this destination")
        }
        let view = NowPlayingFluidBackdropView(pipelines: pipelines)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        view.frame = window.bounds

        let source = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.systemTeal)))
        view.update(source: source, isPlaying: true, reduceMotion: false)
        view.layoutIfNeeded()

        XCTAssertEqual(view.layer.contentsScale, 1.0)
        XCTAssertTrue(view.hasActiveDisplayLink)

        view.update(source: source, isPlaying: false, reduceMotion: true)
        for _ in 0..<30 where view.hasActiveDisplayLink {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(view.hasActiveDisplayLink)

        view.stop()
        XCTAssertFalse(view.hasActiveDisplayLink)
    }

    func testRealCoversRenderSideBySideFluidBackdrops() throws {
        guard let pipelines = NowPlayingBackdropMetalPipelines() else {
            throw XCTSkip("Metal pipelines unavailable on this destination")
        }
        let engine = try XCTUnwrap(NowPlayingFluidBackdropEngine(pipelines: pipelines))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: NowPlayingFluidBackdropEngine.canvasWidth,
            height: NowPlayingFluidBackdropEngine.canvasHeight,
            mipmapped: false
        )
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        let initialTarget = try XCTUnwrap(pipelines.device.makeTexture(descriptor: targetDescriptor))
        let driftedTarget = try XCTUnwrap(pipelines.device.makeTexture(descriptor: targetDescriptor))

        var samples: [(String, UIImage)] = []
        let refCoverURL = URL(fileURLWithPath: "/Users/elsterlee/Dev/NeoMusic/build/player-strict-reference-20261113/cover.png")
        if let refCover = UIImage(contentsOfFile: refCoverURL.path) {
            samples.append(("ref-cover", refCover))
        }
        for name in ["AlbumSample01", "AlbumSample05", "AlbumSample08", "AlbumSample12"] {
            if let img = UIImage(named: name, in: Bundle(for: NowPlayingFluidBackdropSource.self), compatibleWith: nil) {
                samples.append((name, img))
            }
        }
        samples.append(("white", image(.white)))
        XCTAssertGreaterThanOrEqual(samples.count, 4)

        let cellW = 160
        let cellH = 320
        var rows: [(cover: UIImage, initial: UIImage, drifted: UIImage)] = []
        for entry in samples {
            let source = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: entry.1))
            try renderSync(engine: engine, target: initialTarget, source: source, time: 0.0, crossfade: 1, hasFrozen: false)
            let initBytes = readBGRA(from: initialTarget)
            try renderSync(engine: engine, target: driftedTarget, source: source, time: 0.6, crossfade: 1, hasFrozen: false)
            let driftBytes = readBGRA(from: driftedTarget)
            if entry.0 == "white" {
                let center = pixelBGRA(initBytes, x: 80, y: 160, width: cellW)
                let channelSpread = max(abs(Int(center[0]) - Int(center[1])), abs(Int(center[1]) - Int(center[2])))
                XCTAssertLessThanOrEqual(channelSpread, 4, "Pure white cover must stay neutral even after prior chromatic tracks")
                XCTAssertTrue((135...188).contains(Int(center[2])), "White cover should match calibrated bright neutral gray, got \(center[2])")
            }
            let initImg = try XCTUnwrap(imageFromBGRA(initBytes, width: cellW, height: cellH))
            let driftImg = try XCTUnwrap(imageFromBGRA(driftBytes, width: cellW, height: cellH))
            rows.append((entry.1, initImg, driftImg))
        }

        let sheet = UIGraphicsImageRenderer(size: CGSize(width: cellW * 3, height: cellH * rows.count)).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: cellW * 3, height: cellH * rows.count))
            for (row, entry) in rows.enumerated() {
                let y = CGFloat(row * cellH)
                entry.cover.draw(in: CGRect(x: 0, y: y + CGFloat((cellH - cellW) / 2), width: CGFloat(cellW), height: CGFloat(cellW)))
                entry.initial.draw(in: CGRect(x: CGFloat(cellW), y: y, width: CGFloat(cellW), height: CGFloat(cellH)))
                entry.drifted.draw(in: CGRect(x: CGFloat(cellW * 2), y: y, width: CGFloat(cellW), height: CGFloat(cellH)))
            }
        }
        let attachment = XCTAttachment(image: sheet)
        attachment.name = "fluid-backdrop-comparison-sheet"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    private func imageFromBGRA(_ bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = bytes.withUnsafeBytes({ CFDataCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }),
              let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
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

    private func renderSync(
        engine: NowPlayingFluidBackdropEngine,
        target: MTLTexture,
        source: NowPlayingFluidBackdropSource,
        time: Float,
        crossfade: Float,
        hasFrozen: Bool
    ) throws {
        let command = try XCTUnwrap(engine.pipelines.queue.makeCommandBuffer())
        let encoded = engine.encodeFrame(
            into: command,
            presentTarget: target,
            source: source,
            aspect: 390.0 / 844.0,
            time: time,
            crossfade: crossfade,
            hasFrozen: hasFrozen
        )
        XCTAssertTrue(encoded)
        command.commit()
        command.waitUntilCompleted()
    }

    private func readBGRA(from texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    private func pixelBGRA(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let index = (y * width + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    private func luma(_ bgra: [UInt8]) -> Float {
        0.114 * Float(bgra[0]) + 0.587 * Float(bgra[1]) + 0.299 * Float(bgra[2])
    }

    private func lumaSpread(_ bytes: [UInt8]) -> Float {
        var minL: Float = 255
        var maxL: Float = 0
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let y = 0.114 * Float(bytes[offset]) + 0.587 * Float(bytes[offset + 1]) + 0.299 * Float(bytes[offset + 2])
            minL = min(minL, y)
            maxL = max(maxL, y)
        }
        return maxL - minL
    }
}
