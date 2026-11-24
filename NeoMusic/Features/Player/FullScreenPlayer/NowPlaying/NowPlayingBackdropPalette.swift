import SwiftUI
import UIKit

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

    let swatches: [Swatch]
    let seed: UInt64

    static let fallback = NowPlayingBackdropPalette(
        swatches: [0.20, 0.16, 0.11].flatMap { level in
            Array(repeating: Swatch(red: level, green: level, blue: level * 1.04), count: columns)
        },
        seed: 0
    )

    static func make(fromRGBA8 bytes: UnsafePointer<UInt8>, width: Int, height: Int) -> Self {
        guard width >= columns, height >= rows else { return .fallback }

        var lSamples: [Float] = []
        lSamples.reserveCapacity(width * height)
        var colorSamples: [ColorSample] = []
        colorSamples.reserveCapacity((width / 4 + 1) * (height / 4 + 1))

        var sumL: Double = 0
        var sumA: Double = 0
        var sumB: Double = 0
        var weightedA: Double = 0
        var weightedB: Double = 0
        var weightTotal: Double = 0
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325

        let lut = sRGBToLinearLUT
        let bytesPerRow = width * 4

        var y = 0
        while y < height {
            let rowPtr = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let px = rowPtr + x * 4
                let r = lut[Int(px[0])]
                let g = lut[Int(px[1])]
                let b = lut[Int(px[2])]
                let lab = ArtworkColorSpace.linearToOKLab(r: r, g: g, b: b) { cbrt(max($0, 0)) }
                let c = hypot(lab.a, lab.b)

                lSamples.append(lab.l)
                sumL += Double(lab.l)
                sumA += Double(lab.a)
                sumB += Double(lab.b)

                let lumGate = smoothstep(edge0: 0.14, edge1: 0.56, x: lab.l)
                let w = pow(Double(c), 1.4) * Double(lumGate)
                weightedA += Double(lab.a) * w
                weightedB += Double(lab.b) * w
                weightTotal += w

                if x % 4 == 0, y % 4 == 0 {
                    colorSamples.append(ColorSample(
                        l: lab.l, a: lab.a, b: lab.b,
                        x: (Float(x) + 0.5) / Float(width),
                        y: (Float(y) + 0.5) / Float(height)
                    ))
                }
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
        let p10L = lSamples[min(Int(Float(sampleCount - 1) * 0.10), sampleCount - 1)]
        let p85L = lSamples[min(Int(Float(sampleCount - 1) * 0.85), sampleCount - 1)]

        let accentA = weightTotal > 1e-6 ? Float(weightedA / weightTotal) : 0
        let accentB = weightTotal > 1e-6 ? Float(weightedB / weightTotal) : 0
        let accentC = hypot(accentA, accentB)
        let accentStrength = min(max(accentC / 0.12, 0), 1)

        let tonalL = min(max(meanL * 0.65 + p85L * 0.35, 0), 1)
        let highKeyLift = pow(max(tonalL - 0.62, 0) / 0.38, 1.5) * 0.21
        let targetCenterL = min(max(0.19 + tonalL * 0.32 + highKeyLift, 0.19), 0.71)
        let range = max(p85L - p10L, 0.05)
        let lSpreadScale = min(max(0.32 / range, 0.45), 1.35)

        let clusters = dominantColors(in: colorSamples)
        let dominant = clusters.isEmpty
            ? [ColorCluster(l: meanL, a: meanA, b: meanB, x: 0.5, y: 0.5, weight: 1)]
            : clusters

        let wash: Float = 0.20
        let sigma: Float = 0.32
        let sigmaSquaredTwice = 2 * sigma * sigma

        let swatches = (0..<(columns * rows)).map { index in
            let u = Float(index % columns) / Float(max(columns - 1, 1))
            let v = Float(index / columns) / Float(max(rows - 1, 1))

            var totalWeight: Float = 0
            var cellL: Float = 0
            var cellA: Float = 0
            var cellB: Float = 0
            for cluster in dominant {
                let dx = u - cluster.x
                let dy = v - cluster.y
                let weight = cluster.weight * exp(-(dx * dx + dy * dy) / sigmaSquaredTwice)
                cellL += cluster.l * weight
                cellA += cluster.a * weight
                cellB += cluster.b * weight
                totalWeight += weight
            }
            guard totalWeight > 1e-6 else { return Swatch(red: 0, green: 0, blue: 0) }
            cellL /= totalWeight
            cellA /= totalWeight
            cellB /= totalWeight

            var a = cellA + (meanA - cellA) * wash
            var b = cellB + (meanB - cellB) * wash

            let chroma = hypot(a, b)
            let chromaCap: Float = 0.075
            if chroma > chromaCap {
                a *= chromaCap / chroma
                b *= chromaCap / chroma
            }

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
            let linear = ArtworkColorSpace.oklabToLinearSRGB(l: l, a: a, b: b) * verticalShade(row: row)
            return Swatch(
                red: ArtworkColorSpace.linearToSRGB(linear.x),
                green: ArtworkColorSpace.linearToSRGB(linear.y),
                blue: ArtworkColorSpace.linearToSRGB(linear.z)
            )
        }

        return Self(swatches: swatches, seed: seed)
    }

    private struct ColorSample {
        let l: Float
        let a: Float
        let b: Float
        let x: Float
        let y: Float
    }

    private struct ColorCluster {
        var l: Float
        var a: Float
        var b: Float
        var x: Float
        var y: Float
        var weight: Float
    }

    private static func dominantColors(in samples: [ColorSample]) -> [ColorCluster] {
        guard !samples.isEmpty else { return [] }

        func vector(_ sample: ColorSample) -> SIMD3<Float> {
            SIMD3(sample.l, sample.a, sample.b)
        }
        func squaredDistance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
            let delta = lhs - rhs
            return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
        }

        let mean = samples.reduce(SIMD3<Float>.zero) { $0 + vector($1) } / Float(samples.count)
        var centers: [SIMD3<Float>] = [mean]

        if let farthest = samples.max(by: { squaredDistance(vector($0), mean) < squaredDistance(vector($1), mean) }) {
            centers.append(vector(farthest))
            if let third = samples.max(by: { lhs, rhs in
                let lhsDistance = min(squaredDistance(vector(lhs), centers[0]), squaredDistance(vector(lhs), centers[1]))
                let rhsDistance = min(squaredDistance(vector(rhs), centers[0]), squaredDistance(vector(rhs), centers[1]))
                return lhsDistance < rhsDistance
            }), squaredDistance(vector(third), mean) > 0.0004 {
                centers.append(vector(third))
            }
        }

        var clusters = centers.map { ColorCluster(l: $0.x, a: $0.y, b: $0.z, x: 0.5, y: 0.5, weight: 0) }

        for _ in 0..<8 {
            var labSums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            var positionSums = [SIMD2<Float>](repeating: .zero, count: centers.count)
            var counts = [Float](repeating: 0, count: centers.count)

            for sample in samples {
                let value = vector(sample)
                var bestIndex = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (index, center) in centers.enumerated() {
                    let distance = squaredDistance(value, center)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                labSums[bestIndex] += value
                positionSums[bestIndex] += SIMD2(sample.x, sample.y)
                counts[bestIndex] += 1
            }

            for index in centers.indices where counts[index] > 0 {
                let count = counts[index]
                centers[index] = labSums[index] / count
                clusters[index].l = centers[index].x
                clusters[index].a = centers[index].y
                clusters[index].b = centers[index].z
                clusters[index].x = positionSums[index].x / count
                clusters[index].y = positionSums[index].y / count
                clusters[index].weight = count / Float(samples.count)
            }
        }

        var result: [ColorCluster] = []
        for cluster in clusters.filter({ $0.weight > 0.03 }).sorted(by: { $0.weight > $1.weight }) {
            let duplicate = result.contains { existing in
                squaredDistance(
                    SIMD3(existing.l, existing.a, existing.b),
                    SIMD3(cluster.l, cluster.a, cluster.b)
                ) < 0.0009
            }
            if !duplicate { result.append(cluster) }
        }
        return result
    }

    private static func verticalShade(row: Int) -> Float {
        let y = Float(row) / Float(max(rows - 1, 1))
        let ramp = smoothstep(edge0: 0.10, edge1: 0.96, x: y)
        let shade = 1.02 + (0.82 - 1.02) * ramp
        return shade * shade * shade
    }

    private static let sRGBToLinearLUT: [Float] = (0..<256).map { index in
        ArtworkColorSpace.sRGBToLinear(Float(index) / 255.0, power: pow)
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

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
