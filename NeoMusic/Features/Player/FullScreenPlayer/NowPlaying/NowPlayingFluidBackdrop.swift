import MetalKit
import SwiftUI
import UIKit

/// Per-track Oklab statistics extracted once from a downsampled cover image to keep
/// extreme dark, bright, or neon album art balanced and legible behind controls and lyrics.
struct NowPlayingBackdropColorProfile: Equatable, Sendable {
    let meanL: Float
    let p10L: Float
    let p85L: Float
    let meanC: Float
    let accentA: Float
    let accentB: Float
    let accentStrength: Float
    let satBoost: Float
    let targetCenterL: Float
    let lSpreadScale: Float

    static let fallback = NowPlayingBackdropColorProfile(
        meanL: 0.35,
        p10L: 0.18,
        p85L: 0.55,
        meanC: 0.06,
        accentA: 0.0,
        accentB: 0.0,
        accentStrength: 0.0,
        satBoost: 1.0,
        targetCenterL: 0.30,
        lSpreadScale: 0.90
    )

    static func analyze(rgba8Bytes bytes: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int = 4) -> Self {
        guard width > 0, height > 0 else { return .fallback }

        var lSamples: [Float] = []
        lSamples.reserveCapacity((width / max(stride, 1) + 1) * (height / max(stride, 1) + 1))

        var sumL: Double = 0
        var sumC: Double = 0
        var weightedA: Double = 0
        var weightedB: Double = 0
        var weightTotal: Double = 0
        var sampleCount = 0

        let lut = sRGBToLinearLUT
        let bytesPerRow = width * 4
        let step = max(stride, 1)

        var y = 0
        while y < height {
            let rowPtr = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let px = rowPtr + x * 4
                let r = lut[Int(px[0])]
                let g = lut[Int(px[1])]
                let b = lut[Int(px[2])]
                let lab = linearToOklab(r: r, g: g, b: b)
                let c = hypot(lab.a, lab.b)

                lSamples.append(lab.l)
                sumL += Double(lab.l)
                sumC += Double(c)
                sampleCount += 1

                // Favor mid-bright chromatic accents over dark shadows or blown highlights.
                let lumGate = smoothstep(edge0: 0.14, edge1: 0.56, x: lab.l)
                let w = pow(Double(c), 1.4) * Double(lumGate)
                weightedA += Double(lab.a) * w
                weightedB += Double(lab.b) * w
                weightTotal += w
                x += step
            }
            y += step
        }

        guard sampleCount > 0, !lSamples.isEmpty else { return .fallback }
        lSamples.sort()
        let p10Index = min(max(Int(Float(lSamples.count - 1) * 0.10), 0), lSamples.count - 1)
        let p85Index = min(max(Int(Float(lSamples.count - 1) * 0.85), 0), lSamples.count - 1)

        let meanL = Float(sumL / Double(sampleCount))
        let p10L = lSamples[p10Index]
        let p85L = lSamples[p85Index]
        let meanC = Float(sumC / Double(sampleCount))

        let accentA = weightTotal > 1e-6 ? Float(weightedA / weightTotal) : 0
        let accentB = weightTotal > 1e-6 ? Float(weightedB / weightTotal) : 0
        let accentC = hypot(accentA, accentB)
        let accentStrength = min(max(accentC / 0.12, 0), 1)

        let satBoost: Float = if meanC < 0.006 {
            1.0
        } else {
            min(max(1.28 - (meanC - 0.02) * 1.7, 0.92), 1.32)
        }

        // Calibrate target brightness to stay calm over bright covers and subtly luminous over black covers.
        let tonalL = min(max(meanL * 0.65 + p85L * 0.35, 0), 1)
        let highKeyLift = pow(max(tonalL - 0.62, 0) / 0.38, 1.5) * 0.21
        let targetCenterL = min(max(0.19 + tonalL * 0.32 + highKeyLift, 0.19), 0.71)

        let range = max(p85L - p10L, 0.05)
        let lSpreadScale = min(max(0.32 / range, 0.45), 1.35)

        return Self(
            meanL: meanL,
            p10L: p10L,
            p85L: p85L,
            meanC: meanC,
            accentA: accentA,
            accentB: accentB,
            accentStrength: accentStrength,
            satBoost: satBoost,
            targetCenterL: targetCenterL,
            lSpreadScale: lSpreadScale
        )
    }

    private static let sRGBToLinearLUT: [Float] = (0..<256).map { index in
        let u = Float(index) / 255.0
        return u <= 0.04045 ? (u / 12.92) : pow((u + 0.055) / 1.055, 2.4)
    }

    private static func linearToOklab(r: Float, g: Float, b: Float) -> (l: Float, a: Float, b: Float) {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(max(l, 0))
        let m_ = cbrt(max(m, 0))
        let s_ = cbrt(max(s, 0))
        return (
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Compact 128x128 opaque sRGB pixel payload paired with its Oklab tone profile.
/// Stores raw RGBA bytes instead of retaining full-resolution album artwork UIImage instances.
final class NowPlayingFluidBackdropSource: Sendable {
    static let dimension = 128

    let id = UUID()
    let width: Int
    let height: Int
    let rgba8SRGBData: Data
    let profile: NowPlayingBackdropColorProfile

    init(width: Int, height: Int, rgba8SRGBData: Data, profile: NowPlayingBackdropColorProfile) {
        self.width = width
        self.height = height
        self.rgba8SRGBData = rgba8SRGBData
        self.profile = profile
    }

    static func make(from image: UIImage) -> NowPlayingFluidBackdropSource? {
        guard let cgImage = image.cgImage else { return nil }
        return make(from: cgImage)
    }

    static func make(from cgImage: CGImage) -> NowPlayingFluidBackdropSource? {
        let size = dimension
        let bytesPerRow = size * 4
        let byteCount = bytesPerRow * size
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var data = Data(count: byteCount)
        let rendered = data.withUnsafeMutableBytes { rawBuffer -> NowPlayingBackdropColorProfile? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }

            // Fill opaque black first so partially transparent artwork never introduces premultiplied darkening.
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

            let bytePtr = baseAddress.assumingMemoryBound(to: UInt8.self)
            return NowPlayingBackdropColorProfile.analyze(rgba8Bytes: bytePtr, width: size, height: size, stride: 4)
        }

        guard let profile = rendered else { return nil }
        return NowPlayingFluidBackdropSource(width: size, height: size, rgba8SRGBData: data, profile: profile)
    }
}

final class NowPlayingFluidBackdropCache: @unchecked Sendable {
    static let shared = NowPlayingFluidBackdropCache()

    private final class Entry: NSObject {
        let source: NowPlayingFluidBackdropSource
        init(_ source: NowPlayingFluidBackdropSource) { self.source = source }
    }

    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    func cached(for url: URL) -> NowPlayingFluidBackdropSource? {
        cache.object(forKey: url as NSURL)?.source
    }

    func removeCached(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func prepare(_ image: UIImage, for url: URL) async -> NowPlayingFluidBackdropSource? {
        if let existing = cached(for: url) { return existing }
        let source = await Task.detached(priority: .userInitiated) {
            NowPlayingFluidBackdropSource.make(from: image)
        }.value
        guard let source else { return nil }
        cache.setObject(Entry(source), forKey: url as NSURL, cost: source.rgba8SRGBData.count)
        return source
    }
}

@Observable @MainActor
final class NowPlayingFluidBackdropResources {
    static let shared = NowPlayingFluidBackdropResources()
    private(set) var pipelines: NowPlayingBackdropMetalPipelines?
    @ObservationIgnored private var preparation: Task<NowPlayingBackdropMetalPipelines?, Never>?

    var isReady: Bool { pipelines != nil }

    func prepare() async {
        if pipelines != nil { return }
        let task: Task<NowPlayingBackdropMetalPipelines?, Never>
        if let existing = preparation {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { NowPlayingBackdropMetalPipelines() }
            preparation = task
        }
        let compiled = await task.value
        if pipelines == nil { pipelines = compiled }
    }
}

/// Precompiled Metal pipelines shared across player backdrop rendering passes.
final class NowPlayingBackdropMetalPipelines: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let composePipeline: MTLRenderPipelineState
    let downsamplePipeline: MTLRenderPipelineState
    let upsamplePipeline: MTLRenderPipelineState
    let conditionPipeline: MTLRenderPipelineState
    let presentPipeline: MTLRenderPipelineState

    convenience init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), queue: MTLCommandQueue? = nil) {
        guard let device,
              let commandQueue = queue ?? device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: PlayerResources.bundle) else { return nil }
        self.init(device: device, queue: commandQueue, library: library)
    }

    init?(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) {
        guard let vertex = library.makeFunction(name: "backdropVertex"),
              let compose = Self.makePipeline(device: device, vertex: vertex, fragmentName: "fluidBackdropComposeFragment", pixelFormat: .rgba16Float, library: library),
              let downsample = Self.makePipeline(device: device, vertex: vertex, fragmentName: "kawaseDownsampleFragment", pixelFormat: .rgba16Float, library: library),
              let upsample = Self.makePipeline(device: device, vertex: vertex, fragmentName: "kawaseUpsampleFragment", pixelFormat: .rgba16Float, library: library),
              let condition = Self.makePipeline(device: device, vertex: vertex, fragmentName: "fluidBackdropConditionFragment", pixelFormat: .rgba16Float, library: library),
              let present = Self.makePipeline(device: device, vertex: vertex, fragmentName: "fluidBackdropPresentFragment", pixelFormat: .bgra8Unorm, library: library)
        else { return nil }

        self.device = device
        self.queue = queue
        self.composePipeline = compose
        self.downsamplePipeline = downsample
        self.upsamplePipeline = upsample
        self.conditionPipeline = condition
        self.presentPipeline = present
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragmentName: String,
        pixelFormat: MTLPixelFormat,
        library: MTLLibrary
    ) -> MTLRenderPipelineState? {
        guard let fragment = library.makeFunction(name: fragmentName) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

private struct BackdropComposeUniforms {
    var timing: SIMD4<Float>
    var coverStats: SIMD4<Float>
    var accent: SIMD4<Float>
}

private struct BackdropBlurUniforms {
    var texel: SIMD4<Float>
}

private struct BackdropConditionUniforms {
    var params: SIMD4<Float>
    var coverStats: SIMD4<Float>
    var tone: SIMD4<Float>
}

private struct BackdropPresentUniforms {
    var params: SIMD4<Float>
}

/// Multi-pass GPU engine executing cover composition, Dual Kawase blur, Oklab conditioning,
/// crossfade blending, EDR extraction, and dithered presentation.
nonisolated final class NowPlayingFluidBackdropEngine: @unchecked Sendable {
    static let canvasWidth = 160
    static let canvasHeight = 320

    let pipelines: NowPlayingBackdropMetalPipelines

    private var artworkTexture: MTLTexture
    private var uploadedSourceID: UUID?

    private let composeTexture: MTLTexture
    private let downTextures: [MTLTexture]
    private let upTextures: [MTLTexture]
    private let avgTexture: MTLTexture
    private let conditionedTexture: MTLTexture
    private let frozenTexture: MTLTexture
    private let renderPass: MTLRenderPassDescriptor = {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }()

    init?(pipelines: NowPlayingBackdropMetalPipelines) {
        let device = pipelines.device
        let w = Self.canvasWidth
        let h = Self.canvasHeight

        guard let artwork = Self.makeTexture(device: device, width: NowPlayingFluidBackdropSource.dimension, height: NowPlayingFluidBackdropSource.dimension, format: .rgba8Unorm_srgb, usage: [.shaderRead], storageMode: .shared),
              let compose = Self.makeTexture(device: device, width: w, height: h, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let d1 = Self.makeTexture(device: device, width: 80, height: 160, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let d2 = Self.makeTexture(device: device, width: 40, height: 80, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let d3 = Self.makeTexture(device: device, width: 20, height: 40, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let d4 = Self.makeTexture(device: device, width: 10, height: 20, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let avg = Self.makeTexture(device: device, width: 1, height: 1, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let u3 = Self.makeTexture(device: device, width: 20, height: 40, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let u2 = Self.makeTexture(device: device, width: 40, height: 80, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let u1 = Self.makeTexture(device: device, width: 80, height: 160, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let u0 = Self.makeTexture(device: device, width: w, height: h, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let conditioned = Self.makeTexture(device: device, width: w, height: h, format: .rgba16Float, usage: [.renderTarget, .shaderRead]),
              let frozen = Self.makeTexture(device: device, width: w, height: h, format: .rgba16Float, usage: [.shaderRead])
        else { return nil }

        self.pipelines = pipelines
        self.artworkTexture = artwork
        self.composeTexture = compose
        self.downTextures = [d1, d2, d3, d4]
        self.avgTexture = avg
        self.upTextures = [u3, u2, u1, u0]
        self.conditionedTexture = conditioned
        self.frozenTexture = frozen
    }

    func captureFrozenFrame(using commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: conditionedTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: conditionedTexture.width, height: conditionedTexture.height, depth: 1),
            to: frozenTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    @discardableResult
    func encodeFrame(
        into commandBuffer: MTLCommandBuffer,
        presentTarget: MTLTexture,
        source: NowPlayingFluidBackdropSource,
        aspect: Float,
        time: Float,
        crossfade: Float,
        hasFrozen: Bool
    ) -> Bool {
        uploadArtworkIfNeeded(source)

        let profile = source.profile
        let contrastFactor: Float = 1.0

        // Pass 1: Multi-layer warped artwork blend in linear Oklab space.
        var composeUniforms = BackdropComposeUniforms(
            timing: SIMD4<Float>(time, max(aspect, 0.25), 0, contrastFactor),
            coverStats: SIMD4<Float>(profile.meanL, profile.p10L, profile.p85L, profile.meanC),
            accent: SIMD4<Float>(profile.accentA, profile.accentB, profile.accentStrength, profile.satBoost)
        )
        guard encodeQuad(
            commandBuffer: commandBuffer,
            pipeline: pipelines.composePipeline,
            target: composeTexture,
            textures: [artworkTexture],
            uniforms: &composeUniforms
        ) else { return false }

        // Pass 2: Dual Kawase downsample pyramid (160x320 -> 10x20) + 1x1 global average.
        var previous = composeTexture
        for target in downTextures {
            guard encodeBlur(
                commandBuffer: commandBuffer,
                pipeline: pipelines.downsamplePipeline,
                source: previous,
                target: target,
                radius: 1.0
            ) else { return false }
            previous = target
        }

        guard encodeBlur(
            commandBuffer: commandBuffer,
            pipeline: pipelines.downsamplePipeline,
            source: downTextures[3],
            target: avgTexture,
            radius: 2.5
        ) else { return false }

        // Pass 3: Dual Kawase upsample back to 160x320.
        var upSource = downTextures[3]
        for target in upTextures {
            guard encodeBlur(
                commandBuffer: commandBuffer,
                pipeline: pipelines.upsamplePipeline,
                source: upSource,
                target: target,
                radius: 1.0
            ) else { return false }
            upSource = target
        }

        // Pass 4: Oklab lightness/chroma conditioning + crossfade blend with frozen previous track.
        var conditionUniforms = BackdropConditionUniforms(
            params: SIMD4<Float>(0, crossfade, hasFrozen ? 1.0 : 0.0, contrastFactor),
            coverStats: SIMD4<Float>(profile.meanL, profile.meanC, profile.accentA, profile.accentB),
            tone: SIMD4<Float>(profile.targetCenterL, profile.lSpreadScale, profile.accentStrength, 0)
        )
        guard encodeQuad(
            commandBuffer: commandBuffer,
            pipeline: pipelines.conditionPipeline,
            target: conditionedTexture,
            textures: [upTextures[3], avgTexture, frozenTexture],
            uniforms: &conditionUniforms
        ) else { return false }

        // Pass 5: Present final vertically shaded, linear->sRGB encoded, dithered image.
        let topShade: Float = 1.03
        let bottomShade: Float = 0.76
        var presentUniforms = BackdropPresentUniforms(
            params: SIMD4<Float>(0, topShade, bottomShade, 1.0 / 255.0)
        )
        guard encodeQuad(
            commandBuffer: commandBuffer,
            pipeline: pipelines.presentPipeline,
            target: presentTarget,
            textures: [conditionedTexture],
            uniforms: &presentUniforms
        ) else { return false }

        return true
    }

    private func uploadArtworkIfNeeded(_ source: NowPlayingFluidBackdropSource) {
        let sourceID = source.id
        guard uploadedSourceID != sourceID else { return }
        if artworkTexture.width != source.width || artworkTexture.height != source.height,
           let resized = Self.makeTexture(device: pipelines.device, width: source.width, height: source.height, format: .rgba8Unorm_srgb, usage: [.shaderRead], storageMode: .shared) {
            artworkTexture = resized
        }
        source.rgba8SRGBData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            artworkTexture.replace(
                region: MTLRegionMake2D(0, 0, source.width, source.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: source.width * 4
            )
        }
        uploadedSourceID = sourceID
    }

    private func encodeBlur(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        source: MTLTexture,
        target: MTLTexture,
        radius: Float
    ) -> Bool {
        var uniforms = BackdropBlurUniforms(
            texel: SIMD4<Float>(1.0 / Float(max(source.width, 1)), 1.0 / Float(max(source.height, 1)), radius, 0)
        )
        return encodeQuad(commandBuffer: commandBuffer, pipeline: pipeline, target: target, textures: [source], uniforms: &uniforms)
    }

    private func encodeQuad<U>(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        target: MTLTexture,
        textures: [MTLTexture],
        uniforms: inout U
    ) -> Bool {
        renderPass.colorAttachments[0].texture = target
        // Encoders capture the pass configuration; release the drawable from the reusable descriptor.
        defer { renderPass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<U>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private static func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat,
        usage: MTLTextureUsage,
        storageMode: MTLStorageMode = .private
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = storageMode
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }
}

/// Live Metal layer driving ambient fluid playback, 0.6s interruptible track crossfades,
/// and page-aware contrast between Artwork and Lyrics/Queue pages.
final class NowPlayingFluidBackdropView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    @MainActor private final class DisplayProxy: NSObject {
        weak var view: NowPlayingFluidBackdropView?
        init(_ view: NowPlayingFluidBackdropView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.renderTick(timestamp: link.targetTimestamp) }
    }

    private final class EncodingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = false

        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !inFlight else { return false }
            inFlight = true
            return true
        }

        func release() {
            lock.lock()
            inFlight = false
            lock.unlock()
        }
    }

    private let engine: NowPlayingFluidBackdropEngine?
    private let renderQueue = DispatchQueue(
        label: "com.elsterlee.NeoMusic.FluidBackdropRender",
        qos: .userInteractive
    )
    private let encodingGate = EncodingGate()
    private var source: NowPlayingFluidBackdropSource?
    private var currentSourceID: UUID?
    /// A new cover that arrived while the app was inactive is displayed only
    /// after the foreground hold, then crossfades like a normal track change.
    private var pendingSource: NowPlayingFluidBackdropSource?
    private var pendingCommit: Task<Void, Never>?
    private var commitGeneration = 0
    private var foregroundHoldUntil: TimeInterval = 0
    private var prefersForegroundHold = false
    /// SwiftUI can stop delivering scene-phase updates while the app is suspended,
    /// so the UIKit view tracks the application state itself.
    private var isAppActive = UIApplication.shared.applicationState != .background
    private var isObservingApplicationState = false

    private var targetMoving: Bool = true
    private var currentSpeed: Float = 1
    private var isReduceMotion = false
    private var isActive = true
    private var isTransitioning = false

    private var hasRenderedFrame = false
    private var hasFrozenTrack = false
    private var captureFrozenOnNextRender = false
    private var crossfadeStartTimestamp: CFTimeInterval = 0
    private var lastTickTimestamp: CFTimeInterval?
    private var phaseTime: Double = 0
    private var needsRender = true

    private var displayLink: CADisplayLink?
    private var lastDrawableSize: CGSize = .zero

    var hasActiveDisplayLink: Bool { displayLink != nil && displayLink?.isPaused == false }
    var currentPreferredFrameRateRange: CAFrameRateRange? { displayLink?.preferredFrameRateRange }

    private static let crossfadeDuration: CFTimeInterval = 0.60
    private static let motionScale: Double = 0.45

    init(pipelines: NowPlayingBackdropMetalPipelines) {
        self.engine = NowPlayingFluidBackdropEngine(pipelines: pipelines)
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false

        metalLayer.device = pipelines.device
        metalLayer.pixelFormat = .bgra8Unorm
        // 着色器最终输出 linearToSRGB 编码像素，显式声明 sRGB 避免无标签图层与屏幕直出管线色彩失配。
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = 1.0
        metalLayer.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { nil }

    func update(
        source: NowPlayingFluidBackdropSource,
        isPlaying: Bool,
        reduceMotion: Bool,
        isActive: Bool = true,
        isTransitioning: Bool = false
    ) {
        if self.isTransitioning != isTransitioning {
            self.isTransitioning = isTransitioning
        }
        if self.isActive != isActive {
            self.isActive = isActive
            lastTickTimestamp = nil
            needsRender = true
        }
        let newSourceID = source.id
        if newSourceID == currentSourceID {
            // The requested artwork is already displayed; drop any held change
            // that is no longer current.
            cancelPendingCommit()
        } else if pendingSource?.id != newSourceID {
            let now = ProcessInfo.processInfo.systemUptime
            if isAppActive, now >= foregroundHoldUntil {
                cancelPendingCommit()
                applySource(source, reduceMotion: reduceMotion)
            } else {
                pendingSource = source
                if isAppActive {
                    schedulePendingCommit(after: max(0, foregroundHoldUntil - now))
                }
            }
        } else if pendingCommit == nil, isAppActive {
            let now = ProcessInfo.processInfo.systemUptime
            schedulePendingCommit(after: max(0, foregroundHoldUntil - now))
        }

        let nextMoving = isPlaying && !reduceMotion
        if targetMoving != nextMoving || isReduceMotion != reduceMotion {
            targetMoving = nextMoving
            isReduceMotion = reduceMotion
            if reduceMotion {
                currentSpeed = 0
            }
            needsRender = true
        }

        updateDisplayLink()
        if isActive, isAppActive, !hasRenderedFrame, bounds.width > 0, bounds.height > 0, window != nil {
            renderTick(timestamp: CACurrentMediaTime())
        }
    }

    private func applySource(_ source: NowPlayingFluidBackdropSource, reduceMotion: Bool) {
        let hadPrevious = currentSourceID != nil && hasRenderedFrame
        currentSourceID = source.id
        self.source = source
        if hadPrevious, !reduceMotion, isActive, isAppActive {
            captureFrozenOnNextRender = true
            crossfadeStartTimestamp = CACurrentMediaTime()
        } else {
            hasFrozenTrack = false
            captureFrozenOnNextRender = false
            crossfadeStartTimestamp = 0
        }
        needsRender = true
    }

    private func schedulePendingCommit(after delay: TimeInterval) {
        pendingCommit?.cancel()
        guard pendingSource != nil else { return }
        commitGeneration &+= 1
        let generation = commitGeneration
        pendingCommit = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int((max(0, delay) * 1000).rounded())))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.commitGeneration == generation else { return }
            self.commitPendingSource()
        }
    }

    private func commitPendingSource() {
        guard let pending = pendingSource else { return }
        pendingSource = nil
        pendingCommit = nil
        applySource(pending, reduceMotion: isReduceMotion)
        updateDisplayLink()
    }

    private func cancelPendingCommit() {
        pendingSource = nil
        pendingCommit?.cancel()
        pendingCommit = nil
        commitGeneration &+= 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
            pendingCommit?.cancel()
            pendingCommit = nil
            stopObservingApplicationState()
            lastTickTimestamp = nil
        } else {
            startObservingApplicationState()
            needsRender = true
            updateDisplayLink()
            setNeedsLayout()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func startObservingApplicationState() {
        guard !isObservingApplicationState else { return }
        isObservingApplicationState = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private func stopObservingApplicationState() {
        guard isObservingApplicationState else { return }
        isObservingApplicationState = false
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        isAppActive = false
        pendingCommit?.cancel()
        pendingCommit = nil
        stopDisplayLink()
    }

    @objc private func appDidEnterBackground() {
        isAppActive = false
        pendingCommit?.cancel()
        pendingCommit = nil
        stopDisplayLink()
    }

    @objc private func appWillEnterForeground() {
        isAppActive = true
        prefersForegroundHold = true
        foregroundHoldUntil = ProcessInfo.processInfo.systemUptime + 0.5
        lastTickTimestamp = nil
        needsRender = true
        if pendingSource != nil {
            schedulePendingCommit(after: 0.5)
        }
    }

    @objc private func appDidBecomeActive() {
        isAppActive = true
        let now = ProcessInfo.processInfo.systemUptime
        if prefersForegroundHold {
            prefersForegroundHold = false
            // Start the visible hold once the app is actually active, not while
            // the launch transition is still covering the player.
            foregroundHoldUntil = max(foregroundHoldUntil, now + 0.5)
        }
        if pendingSource != nil {
            schedulePendingCommit(after: max(0, foregroundHoldUntil - now))
        }
        updateDisplayLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let targetSize = CGSize(width: max(floor(bounds.width), 1), height: max(floor(bounds.height), 1))
        if targetSize != lastDrawableSize {
            lastDrawableSize = targetSize
            metalLayer.contentsScale = 1.0
            metalLayer.drawableSize = targetSize
            needsRender = true
        }
        if window != nil && !hasRenderedFrame {
            renderTick(timestamp: CACurrentMediaTime())
        }
    }

    private func updateDisplayLink() {
        guard isActive, isAppActive, window != nil, engine != nil, source != nil else {
            stopDisplayLink()
            return
        }
        let crossfading = hasFrozenTrack || captureFrozenOnNextRender
        let speedSettling = abs((targetMoving ? Float(1.0) : Float(0.0)) - currentSpeed) > 0.01
        let shouldRun = needsRender || targetMoving || crossfading || speedSettling

        guard shouldRun else {
            stopDisplayLink()
            return
        }

        if displayLink == nil {
            let link = CADisplayLink(target: DisplayProxy(self), selector: #selector(DisplayProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        displayLink?.isPaused = false
    }

    func stop() {
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func renderTick(timestamp: CFTimeInterval) {
        guard isActive, isAppActive, window != nil, let engine, let source,
              bounds.width > 0, bounds.height > 0 else { return }

        let dt: Double
        if let lastTickTimestamp {
            dt = min(max(timestamp - lastTickTimestamp, 0), 0.05)
        } else {
            dt = 0
        }
        lastTickTimestamp = timestamp

        if isReduceMotion {
            currentSpeed = 0
        } else {
            let targetSpeed: Float = targetMoving ? 1.0 : 0.0
            let speedAlpha = Float(1.0 - exp(-4.5 * dt))
            currentSpeed += (targetSpeed - currentSpeed) * speedAlpha
            if abs(targetSpeed - currentSpeed) < 0.005 { currentSpeed = targetSpeed }
        }

        phaseTime += dt * Double(currentSpeed) * Self.motionScale

        var crossfade: Float = 1.0
        if hasFrozenTrack || captureFrozenOnNextRender {
            let elapsed = timestamp - crossfadeStartTimestamp
            crossfade = Float(min(max(elapsed / Self.crossfadeDuration, 0), 1))
        }

        let shouldCaptureFrozen = captureFrozenOnNextRender
        let hadFrozen = hasFrozenTrack
        if captureFrozenOnNextRender {
            captureFrozenOnNextRender = false
            hasFrozenTrack = true
        }
        let aspect = Float(bounds.width / max(bounds.height, 1))
        let time = Float(phaseTime)

        if encodingGate.tryAcquire() {
            nonisolated(unsafe) let layer = metalLayer
            nonisolated(unsafe) let renderEngine = engine
            nonisolated(unsafe) let renderSource = source
            let gate = encodingGate
            renderQueue.async {
                Self.encodeAndPresent(
                    layer: layer,
                    engine: renderEngine,
                    source: renderSource,
                    aspect: aspect,
                    time: time,
                    crossfade: crossfade,
                    shouldCaptureFrozen: shouldCaptureFrozen,
                    hasFrozen: hadFrozen || shouldCaptureFrozen,
                    gate: gate
                )
            }
        }

        let finishedCrossfade = hasFrozenTrack && crossfade >= 0.999
        if finishedCrossfade {
            hasFrozenTrack = false
        }

        hasRenderedFrame = true
        needsRender = false
        updateDisplayLink()
    }

    nonisolated private static func encodeAndPresent(
        layer: CAMetalLayer,
        engine: NowPlayingFluidBackdropEngine,
        source: NowPlayingFluidBackdropSource,
        aspect: Float,
        time: Float,
        crossfade: Float,
        shouldCaptureFrozen: Bool,
        hasFrozen: Bool,
        gate: EncodingGate
    ) {
        defer { gate.release() }
        guard let commandBuffer = engine.pipelines.queue.makeCommandBuffer(),
              let drawable = layer.nextDrawable() else { return }
        if shouldCaptureFrozen {
            engine.captureFrozenFrame(using: commandBuffer)
        }
        let didEncode = engine.encodeFrame(
            into: commandBuffer,
            presentTarget: drawable.texture,
            source: source,
            aspect: aspect,
            time: time,
            crossfade: crossfade,
            hasFrozen: hasFrozen
        )
        guard didEncode else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct NowPlayingFluidBackdropRepresentable: UIViewRepresentable {
    let source: NowPlayingFluidBackdropSource
    let isPlaying: Bool
    let reduceMotion: Bool
    let isActive: Bool
    var isTransitioning: Bool = false
    let pipelines: NowPlayingBackdropMetalPipelines

    func makeUIView(context: Context) -> NowPlayingFluidBackdropView {
        let view = NowPlayingFluidBackdropView(pipelines: pipelines)
        view.update(
            source: source,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            isActive: isActive,
            isTransitioning: isTransitioning
        )
        return view
    }

    func updateUIView(_ view: NowPlayingFluidBackdropView, context: Context) {
        view.update(
            source: source,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            isActive: isActive,
            isTransitioning: isTransitioning
        )
    }

    static func dismantleUIView(_ view: NowPlayingFluidBackdropView, coordinator: ()) {
        view.stop()
    }
}
