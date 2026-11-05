import Nuke
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var nowPlayingBackdropAnchor: NowPlayingBackdropAnchor? = nil
    @Entry var nowPlayingBackdropImage: UIImage? = nil
    @Entry var nowPlayingUndimmedBackdropImage: UIImage? = nil
}

/// 从封面颜色生成静态背景；只在换歌时交叉淡入。
struct NowPlayingArtworkBackdrop: View {
    let artworkURL: URL?
    var trackID: String? = nil
    var ignoresSafeArea = true
    /// 作为背景副本画在别的视图底下：没有封面时完全透明（露出真背景），不画黑色打底和压暗。
    var isUnderlay = false
    /// 背景实际铺开的范围（含安全区），给背景副本对齐用。
    var onFrameChange: ((CGRect) -> Void)? = nil
    var onImageChange: ((UIImage?) -> Void)? = nil
    var onUndimmedImageChange: ((UIImage?) -> Void)? = nil
    var anchor: NowPlayingBackdropAnchor?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var image: UIImage?
    @State private var renderedTrackID: String?

    init(
        artworkURL: URL?,
        trackID: String? = nil,
        ignoresSafeArea: Bool = true,
        isUnderlay: Bool = false,
        onFrameChange: ((CGRect) -> Void)? = nil,
        onImageChange: ((UIImage?) -> Void)? = nil,
        onUndimmedImageChange: ((UIImage?) -> Void)? = nil,
        anchor: NowPlayingBackdropAnchor? = nil
    ) {
        self.artworkURL = artworkURL
        self.trackID = trackID
        _renderedTrackID = State(initialValue: trackID)
        self.ignoresSafeArea = ignoresSafeArea
        self.isUnderlay = isUnderlay
        self.onFrameChange = onFrameChange
        self.onImageChange = onImageChange
        self.onUndimmedImageChange = onUndimmedImageChange
        self.anchor = anchor
        // 已经缓存的封面直接拿来用，第一次出现就有图，不会先黑一下再淡入。
        _image = State(initialValue: artworkURL.flatMap {
            NowPlayingBackdropRenderer.shared.cached(for: $0)?.dimmed
        })
    }

    private struct BackdropRequestID: Equatable {
        let url: URL?
        let trackID: String?
    }

    private static func request(for url: URL?) -> ImageRequest? {
        guard let url else { return nil }
        var request = ImageRequest(url: url)
        request.thumbnail = .init(size: decodeSize, unit: .pixels, contentMode: .aspectFill)
        return request
    }

    /// 只用来模糊，解码一张小图就够了。
    private static let decodeSize = CGSize(width: 240, height: 240)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if !isUnderlay {
                    Color.black
                }

                if let image {
                    NowPlayingBackdropImage(image: image, animated: !accessibilityReduceMotion)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }


            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // 在铺满安全区之后的里层量：外层量到的是不含安全区的框，副本会按错的大小画，
            // 和真背景错开，列表顶部的渐隐带里就会显出一道印子。
            .background { if let anchor { NowPlayingBackdropAnchorView(anchor: anchor) } }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(NowPlayingContentCoordinateSpace.name))
            } action: {
                onFrameChange?($0)
            }
        }
        .ignoresSafeArea(edges: ignoresSafeArea ? .all : [])
        .accessibilityHidden(true)
        .onChange(of: image, initial: true) { _, value in onImageChange?(value) }
        .task(id: BackdropRequestID(url: artworkURL, trackID: trackID)) {
            // Retain the backdrop while loading, but never attribute another song's cover to a missing image.
            guard let artworkURL, let request = Self.request(for: artworkURL) else {
                if trackID == nil || renderedTrackID != trackID {
                    image = nil; onUndimmedImageChange?(nil)
                }
                return
            }
            let renderer = NowPlayingBackdropRenderer.shared
            let rendered: NowPlayingBackdropRenderer.Images?
            if let cached = renderer.cached(for: artworkURL) {
                rendered = cached
            } else if let loaded = try? await ImagePipeline.shared.image(for: request), !Task.isCancelled {
                rendered = await renderer.render(loaded, for: artworkURL)
            } else {
                rendered = nil
            }
            guard !Task.isCancelled else { return }
            if rendered == nil, trackID != nil, renderedTrackID == trackID { return }
            renderedTrackID = trackID
            onUndimmedImageChange?(rendered?.undimmed)
            guard rendered?.dimmed !== image else { return }
            // The image view owns the overlay fade; the opaque base stays in place.
            image = rendered?.dimmed
        }
    }
}


/// Keeps both derived backgrounds together without retaining decoded source covers.
@MainActor
final class NowPlayingBackdropRenderer {
    struct Images: Sendable {
        let dimmed: UIImage
        let undimmed: UIImage
    }
    final class CacheEntry {
        let images: Images
        init(_ images: Images) { self.images = images }
    }
    static let shared = NowPlayingBackdropRenderer()
    let cache: NSCache<NSURL, CacheEntry> = {
        let cache = NSCache<NSURL, CacheEntry>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1_024
        return cache
    }()
    private let processor = NowPlayingBackdropProcessor()

    func cached(for url: URL) -> Images? { cache.object(forKey: url as NSURL)?.images }

    func render(_ image: UIImage, for url: URL) async -> Images? {
        guard !Task.isCancelled else { return nil }
        if let cached = cached(for: url) { return cached }
        guard let source = image.cgImage, let images = await processor.render(source), !Task.isCancelled else { return nil }
        let cost = [images.dimmed, images.undimmed].reduce(0) {
            $0 + ($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0)
        }
        cache.setObject(CacheEntry(images), forKey: url as NSURL, cost: cost)
        return images
    }
}

/// Three cover-derived color anchors, calibrated against eight AM screenshots.
/// Sampling and interpolation stay in encoded sRGB, away from the UI actor.
private actor NowPlayingBackdropProcessor {

    private struct Tuning {
        let lightPower: Double
        let darkPower: Double
        let chromaWeight: Double
        let warmth: Double
        let luminanceGain: Double
        let luminanceBias: Double
        let saturation: Double
    }

    // Top, middle (42% of height), bottom. Shared constants for every cover.
    private static let tuning: [Tuning] = [
        .init(lightPower: -0.287, darkPower: 0.150, chromaWeight: 0, warmth: 1.917,
              luminanceGain: 0.637, luminanceBias: 0.040, saturation: 0.845),
        .init(lightPower: 0.889, darkPower: 0.459, chromaWeight: 0, warmth: -0.563,
              luminanceGain: 0.632, luminanceBias: 0.065, saturation: 0.959),
        .init(lightPower: -0.627, darkPower: -0.627, chromaWeight: 6, warmth: -0.775,
              luminanceGain: 0.357, luminanceBias: 0.056, saturation: 0.546)
    ]

    func render(_ source: CGImage) -> NowPlayingBackdropRenderer.Images? {
        guard !Task.isCancelled, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let sampled = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard sampled else { return nil }
        var sums = [SIMD3<Double>](repeating: .zero, count: 3)
        var totals = [Double](repeating: 0, count: 3)
        var meanLight = 0.0
        var meanChroma = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            // Transparent source pixels are composited on black by the sampling context.
            let color = SIMD3(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2])) / 255
            let light = luminance(color)
            let chroma = max(color.x, color.y, color.z) - min(color.x, color.y, color.z)
            meanLight += light
            meanChroma += chroma
            for (i, setting) in Self.tuning.enumerated() {
                let weight = pow(max(light, 0.005), setting.lightPower)
                    * pow(max(1 - light, 0.005), setting.darkPower)
                    * (1 + setting.chromaWeight * chroma)
                    * exp(setting.warmth * (color.x - color.z))
                sums[i] += color * weight
                totals[i] += weight
            }
        }
        meanLight /= Double(side * side)
        meanChroma /= Double(side * side)
        // Keep light, colorful covers luminous without lifting neutral white covers.
        let pastelLift = min(0.12, max(0, meanLight - 0.45) * max(0, meanChroma - 0.12) * 4)
        let averages = sums.enumerated().map { $0.element / max(totals[$0.offset], 0.001) }
        let undimmed = averages.map { SIMD3(clamp($0.x), clamp($0.y), clamp($0.z)) }
        let dimmed = Self.tuning.enumerated().map { i, setting in
            let average = averages[i]
            let light = luminance(average)
            let color = (average - SIMD3(repeating: light)) * setting.saturation
                + SIMD3(repeating: light * setting.luminanceGain + setting.luminanceBias + (i < 2 ? pastelLift : 0))
            return SIMD3(clamp(color.x), clamp(color.y), clamp(color.z))
        }
        guard !Task.isCancelled,
              let dimmedImage = rasterize(dimmed, space: space),
              let undimmedImage = rasterize(undimmed, space: space) else { return nil }
        return NowPlayingBackdropRenderer.Images(dimmed: dimmedImage, undimmed: undimmedImage)
    }

    private func rasterize(_ anchors: [SIMD3<Double>], space: CGColorSpace) -> UIImage? {
        // Rasterize once so SwiftUI does not change the calibrated interpolation space.
        let height = 256
        var gradient = [UInt8](repeating: 255, count: height * 4)
        for row in 0..<height {
            let y = Double(row) / Double(height - 1)
            let section = y <= 0.42 ? 0 : 1
            let fraction = section == 0 ? y / 0.42 : (y - 0.42) / 0.58
            let color = anchors[section] * (1 - fraction) + anchors[section + 1] * fraction
            for channel in 0..<3 { gradient[row * 4 + channel] = UInt8((clamp(color[channel]) * 255).rounded()) }
        }
        guard let provider = CGDataProvider(data: Data(gradient) as CFData),
              let rendered = CGImage(width: 1, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    private func luminance(_ c: SIMD3<Double>) -> Double {
        c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
    }
    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
