import Foundation

public enum ArtworkColorSpace {
    public static func sRGBToLinear<T: BinaryFloatingPoint>(_ value: T, power: (T, T) -> T) -> T {
        value <= 0.04045 ? value / 12.92 : power((value + 0.055) / 1.055, 2.4)
    }

    public static func linearToOKLab<T: BinaryFloatingPoint>(r: T, g: T, b: T, cubeRoot: (T) -> T) -> (l: T, a: T, b: T) {
        let l = cubeRoot(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cubeRoot(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cubeRoot(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    public static func oklabToLinearSRGB(l: Float, a: Float, b: Float) -> SIMD3<Float> {
        let lRoot = l + 0.3963377774 * a + 0.2158037573 * b
        let mRoot = l - 0.1055613458 * a - 0.0638541728 * b
        let sRoot = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = lRoot * lRoot * lRoot
        let m3 = mRoot * mRoot * mRoot
        let s3 = sRoot * sRoot * sRoot
        return SIMD3<Float>(
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    public static func linearToSRGB(_ value: Float) -> Float {
        let v = min(max(value, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }
}
