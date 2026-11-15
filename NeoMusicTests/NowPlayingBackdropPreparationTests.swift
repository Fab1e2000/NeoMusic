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

        // A neutral cover after chromatic tracks must not inherit their color.
        let whiteSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.white)))
        try renderSync(engine: engine, target: backdropTarget, source: whiteSource, time: 0, crossfade: 1, hasFrozen: false)
        let center = pixelBGRA(readBGRA(from: backdropTarget), x: 80, y: 160, width: backdropTarget.width)
        let channelSpread = max(abs(Int(center[0]) - Int(center[1])), abs(Int(center[1]) - Int(center[2])))
        XCTAssertLessThanOrEqual(channelSpread, 4, "Pure white cover must stay neutral after chromatic tracks")
        XCTAssertTrue((135...188).contains(Int(center[2])), "White cover should keep calibrated brightness")
    }

    func testFluidBackdropResourcesRenderAndFollowVisibility() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this destination") }
        await NowPlayingFluidBackdropResources.shared.prepare()
        let pipelines = try XCTUnwrap(NowPlayingFluidBackdropResources.shared.pipelines,
                                      "The app must contain the compiled fluid backdrop Metal library")
        let view = NowPlayingFluidBackdropView(pipelines: pipelines)
        let controller = UIViewController()
        let window = UIWindow(windowScene: try await applicationWindowScene())
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        defer { view.stop(); window.isHidden = true }
        controller.view.addSubview(view)
        view.frame = controller.view.bounds
        XCTAssertFalse(view.hasActiveDisplayLink, "A backdrop without a source has no work to schedule")

        let source = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.systemTeal)))
        view.update(source: source, isPlaying: true, reduceMotion: false)
        view.layoutIfNeeded()

        XCTAssertEqual(view.layer.contentsScale, 1.0)
        XCTAssertTrue(view.hasActiveDisplayLink)
        XCTAssertTrue(try XCTUnwrap(view.layer as? CAMetalLayer).framebufferOnly)

        // A retained fullscreen player must stop immediately when collapsed or inactive,
        // even while music plays or a track crossfade is pending.
        let nextSource = try XCTUnwrap(NowPlayingFluidBackdropSource.make(from: image(.systemOrange)))
        view.update(source: nextSource, isPlaying: true, reduceMotion: false, isActive: false)
        XCTAssertFalse(view.hasActiveDisplayLink)
        view.removeFromSuperview()
        controller.view.addSubview(view)
        view.layoutIfNeeded()
        XCTAssertFalse(view.hasActiveDisplayLink)
        view.update(source: nextSource, isPlaying: true, reduceMotion: false, isActive: true)
        XCTAssertTrue(view.hasActiveDisplayLink)

        view.update(source: nextSource, isPlaying: false, reduceMotion: true)
        for _ in 0..<60 where view.hasActiveDisplayLink {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(view.hasActiveDisplayLink)

        view.update(source: nextSource, isPlaying: true, reduceMotion: false)
        XCTAssertTrue(view.hasActiveDisplayLink)
        view.removeFromSuperview()
        XCTAssertFalse(view.hasActiveDisplayLink)
        controller.view.addSubview(view)
        XCTAssertTrue(view.hasActiveDisplayLink)
        view.stop()
        XCTAssertFalse(view.hasActiveDisplayLink)
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
        XCTAssertEqual(command.status, .completed, "GPU rendering failed: \(String(describing: command.error))")
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
