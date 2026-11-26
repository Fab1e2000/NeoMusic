import SwiftUI
import CoreImage.CIFilterBuiltins

public struct AlbumArtworkBackdrop: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    public var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    private static let imageContext = CIContext()
    public var colorScheme: ColorScheme {
        let (r, g, b) = linearRGB
        let okL = ArtworkColorSpace.linearToOKLab(r: r, g: g, b: b, cubeRoot: cbrt).l
        return okL <= 0.65 ? .dark : .light
    }

    public var linearRGB: (Double, Double, Double) {
        (ArtworkColorSpace.sRGBToLinear(red, power: pow),
         ArtworkColorSpace.sRGBToLinear(green, power: pow),
         ArtworkColorSpace.sRGBToLinear(blue, power: pow))
    }

    public static func extract(from data: Data) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            guard let input = CIImage(data: data) else { return nil }
            return extract(from: input)
        }
    }

    public static func extract(from cgImage: CGImage) -> AlbumArtworkBackdrop? {
        autoreleasepool {
            extract(from: CIImage(cgImage: cgImage))
        }
    }

    private static func extract(from input: CIImage) -> AlbumArtworkBackdrop? {
        candidates(from: input).max { $0.weight < $1.weight }?.color
    }

    public struct Candidate: Sendable {
        public let color: AlbumArtworkBackdrop
        public let weight: Double

        public var chroma: Double {
            max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        }
    }

    public static func candidates(from input: CIImage) -> [Candidate] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let scale = min(1, 128 / max(input.extent.width, input.extent.height))
        let reduced = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.kMeans()
        filter.inputImage = reduced
        filter.extent = reduced.extent
        filter.count = 8
        filter.passes = 10
        filter.perceptual = false
        guard let output = filter.outputImage else { return [] }
        let context = imageContext
        var weighted = [Float](repeating: 0, count: 32)
        context.render(output, toBitmap: &weighted, rowBytes: 128,
                       bounds: output.extent, format: .RGBAf, colorSpace: space)
        var colors = [Float](repeating: 0, count: 32)
        context.render(output.settingAlphaOne(in: output.extent), toBitmap: &colors, rowBytes: 128,
                       bounds: output.extent, format: .RGBAf, colorSpace: space)
        return (0..<8).compactMap { cluster in
            let i = cluster * 4
            let weight = Double(weighted[i + 3])
            guard weight > 0 else { return nil }
            let color = AlbumArtworkBackdrop(red: Double(colors[i]), green: Double(colors[i + 1]), blue: Double(colors[i + 2]))
            return Candidate(color: color, weight: weight)
        }
    }

    public init(red: Double,
                green: Double,
                blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
