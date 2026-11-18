import SwiftUI
import UIKit

/// 每首歌只从封面采样一次的 3×3 MeshGradient 配色。
/// 亮度与彩度沿用原流体背景的 Oklab 校准思路，让极暗、极亮和高饱和封面都能作为可读背景。
struct NowPlayingBackdropPalette: Hashable, Sendable {
    struct Swatch: Hashable, Sendable {
        let red: Float
        let green: Float
        let blue: Float

        init(red: Float, green: Float, blue: Float) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
        }

        var color: Color {
            Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1)
        }
    }

    static let columns = 3
    static let rows = 3

    /// 行优先：左上到右下，共 `columns * rows` 个色块。
    let swatches: [Swatch]
    /// 由封面像素派生，供背景动画的起始方向使用，使不同封面不会走完全相同的轨迹。
    let seed: UInt64

    static let fallback = NowPlayingBackdropPalette(
        swatches: [0.20, 0.16, 0.11].flatMap { level in
            Array(repeating: Swatch(red: level, green: level, blue: level * 1.04), count: columns)
        },
        seed: 0
    )

    /// 分析 128×128 的不透明 sRGB 像素，返回按行优先排列的九宫格配色。
    static func make(fromRGBA8 bytes: UnsafePointer<UInt8>, width: Int, height: Int) -> Self {
        guard width >= columns, height >= rows else { return .fallback }

        var cellSums = Array(repeating: SIMD3<Double>.zero, count: columns * rows)
        var cellCounts = Array(repeating: 0, count: columns * rows)
        var lSamples: [Float] = []
        lSamples.reserveCapacity(width * height)

        var sumL: Double = 0
        var sumA: Double = 0
        var sumB: Double = 0
        var sumC: Double = 0
        var weightedA: Double = 0
        var weightedB: Double = 0
        var weightTotal: Double = 0
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325

        let lut = sRGBToLinearLUT
        let bytesPerRow = width * 4

        var y = 0
        while y < height {
            let row = min(y * rows / height, rows - 1)
            let rowPtr = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let px = rowPtr + x * 4
                let r = lut[Int(px[0])]
                let g = lut[Int(px[1])]
                let b = lut[Int(px[2])]
                let lab = linearToOklab(r: r, g: g, b: b)
                let c = hypot(lab.a, lab.b)
                let cell = row * columns + min(x * columns / width, columns - 1)

                cellSums[cell] += SIMD3<Double>(Double(lab.l), Double(lab.a), Double(lab.b))
                cellCounts[cell] += 1
                lSamples.append(lab.l)
                sumL += Double(lab.l)
                sumA += Double(lab.a)
                sumB += Double(lab.b)
                sumC += Double(c)

                // 偏中亮度的彩色作为整张封面的主色，避免暗部与过曝区域主导。
                let lumGate = smoothstep(edge0: 0.14, edge1: 0.56, x: lab.l)
                let w = pow(Double(c), 1.4) * Double(lumGate)
                weightedA += Double(lab.a) * w
                weightedB += Double(lab.b) * w
                weightTotal += w

                if x % 8 == 0, y % 8 == 0 {
                    seed = (seed ^ UInt64(px[0])) &* 0x0000_0100_0000_01b3
                    seed = (seed ^ UInt64(px[1])) &* 0x0000_0100_0000_01b3
                    seed = (seed ^ UInt64(px[2])) &* 0x0000_0100_0000_01b3
                }
                x += 1
            }
            y += 1
        }

        let sampleCount = lSamples.count
        guard sampleCount > 0 else { return .fallback }

        lSamples.sort()
        let meanL = Float(sumL / Double(sampleCount))
        let meanA = Float(sumA / Double(sampleCount))
        let meanB = Float(sumB / Double(sampleCount))
        let meanC = Float(sumC / Double(sampleCount))
        let p10L = lSamples[min(Int(Float(sampleCount - 1) * 0.10), sampleCount - 1)]
        let p85L = lSamples[min(Int(Float(sampleCount - 1) * 0.85), sampleCount - 1)]

        let accentA = weightTotal > 1e-6 ? Float(weightedA / weightTotal) : 0
        let accentB = weightTotal > 1e-6 ? Float(weightedB / weightTotal) : 0
        let accentC = hypot(accentA, accentB)
        let accentStrength = min(max(accentC / 0.12, 0), 1)

        // 把整张封面的明暗中心校准到适合做背景的范围：亮封面不刺眼，黑封面仍保留层次。
        let tonalL = min(max(meanL * 0.65 + p85L * 0.35, 0), 1)
        let highKeyLift = pow(max(tonalL - 0.62, 0) / 0.38, 1.5) * 0.21
        let targetCenterL = min(max(0.19 + tonalL * 0.32 + highKeyLift, 0.19), 0.71)
        let range = max(p85L - p10L, 0.05)
        let lSpreadScale = min(max(0.32 / range, 0.45), 1.35)

        // 九宫格只保留封面配色的轻微空间差异，整体仍是一种主色调，
        // 避免两块补色各占一角、切歌时整屏颜色大幅翻转。
        let wash: Float = 0.62

        let swatches = (0..<(columns * rows)).map { index in
            let count = max(cellCounts[index], 1)
            let sum = cellSums[index]
            let cellL = Float(sum.x / Double(count))
            let cellA = Float(sum.y / Double(count))
            let cellB = Float(sum.z / Double(count))
            var a = cellA + (meanA - cellA) * wash
            var b = cellB + (meanB - cellB) * wash

            // 彩度压在背景可接受的范围内，接近 Apple Music 那种偏灰的封面染色。
            let chroma = hypot(a, b)
            let chromaCap: Float = 0.075
            if chroma > chromaCap {
                a *= chromaCap / chroma
                b *= chromaCap / chroma
            }

            // 封面主体偏灰时补极少量主色，避免完全变成灰底。
            if accentStrength > 0.08, accentC > 0.004 {
                let floorC = min(accentC, 0.08) * 0.30 * accentStrength
                    * min(max((0.78 - meanL) / 0.18, 0), 1)
                if chroma < floorC {
                    a += accentA / accentC * (floorC - chroma)
                    b += accentB / accentC * (floorC - chroma)
                }
            }

            let blendedL = cellL + (meanL - cellL) * wash
            let l = min(max(targetCenterL + (blendedL - meanL) * lSpreadScale * 0.72, 0.16), 0.68)
            let row = index / columns
            let linear = oklabToLinearSRGB(l: l, a: a, b: b) * verticalShade(row: row)
            return Swatch(
                red: linearToSRGB(linear.x),
                green: linearToSRGB(linear.y),
                blue: linearToSRGB(linear.z)
            )
        }

        return Self(swatches: swatches, seed: seed)
    }

    /// 与参考实现一致的纵向压暗曲线：顶部略提亮，底部收敛。
    private static func verticalShade(row: Int) -> Float {
        let y = Float(row) / Float(max(rows - 1, 1))
        let ramp = smoothstep(edge0: 0.10, edge1: 0.96, x: y)
        let shade = 1.02 + (0.82 - 1.02) * ramp
        return shade * shade * shade
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

    private static func oklabToLinearSRGB(l: Float, a: Float, b: Float) -> SIMD3<Float> {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_
        return SIMD3<Float>(
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    private static func linearToSRGB(_ value: Float) -> Float {
        let v = min(max(value, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 按封面 URL 缓存已算好的配色，避免滚回同一首歌时重新分析像素。
final class NowPlayingBackdropCache: @unchecked Sendable {
    static let shared = NowPlayingBackdropCache()

    private final class Entry: NSObject {
        let palette: NowPlayingBackdropPalette
        init(_ palette: NowPlayingBackdropPalette) { self.palette = palette }
    }

    private let cache = NSCache<NSURL, Entry>()

    init() {
        cache.countLimit = 64
    }

    func cached(for url: URL) -> NowPlayingBackdropPalette? {
        cache.object(forKey: url as NSURL)?.palette
    }

    func removeCached(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func prepare(_ image: UIImage, for url: URL) async -> NowPlayingBackdropPalette? {
        if let existing = cached(for: url) { return existing }
        let palette = await Task.detached(priority: .userInitiated) {
            Self.analyze(image)
        }.value
        guard let palette else { return nil }
        cache.setObject(Entry(palette), forKey: url as NSURL)
        return palette
    }

    private static func analyze(_ image: UIImage) -> NowPlayingBackdropPalette? {
        guard let cgImage = image.cgImage else { return nil }
        let size = 128
        let bytesPerRow = size * 4
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var data = Data(count: bytesPerRow * size)
        let palette = data.withUnsafeMutableBytes { rawBuffer -> NowPlayingBackdropPalette? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }

            // 先铺不透明黑底，半透明封面也不会被预乘压暗。
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

            return NowPlayingBackdropPalette.make(
                fromRGBA8: baseAddress.assumingMemoryBound(to: UInt8.self),
                width: size,
                height: size
            )
        }
        return palette
    }
}
