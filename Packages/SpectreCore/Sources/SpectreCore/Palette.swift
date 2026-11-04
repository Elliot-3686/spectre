import Foundation

/// OKLab (Björn Ottosson). All palette interpolation happens here, never in RGB.
public enum OKLab {
    public static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func linearToSRGB(_ c: Double) -> Double {
        let x = min(max(c, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    public static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return SIMD3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                     1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                     0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    public static func toLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public static func fromHex(_ hex: UInt32) -> SIMD3<Double> {
        let r = srgbToLinear(Double((hex >> 16) & 0xFF) / 255)
        let g = srgbToLinear(Double((hex >> 8) & 0xFF) / 255)
        let b = srgbToLinear(Double(hex & 0xFF) / 255)
        return fromLinear(r, g, b)
    }

    public static func toSRGB8(_ lab: SIMD3<Double>) -> (UInt8, UInt8, UInt8) {
        let lin = toLinear(lab)
        func q(_ v: Double) -> UInt8 { UInt8(min(max((linearToSRGB(v) * 255).rounded(), 0), 255)) }
        return (q(lin.x), q(lin.y), q(lin.z))
    }
}

public enum ThemeKind: String, CaseIterable, Codable, Sendable {
    case sobre, monochrome, braise

    public var label: String {
        switch self {
        case .sobre: return "Sobre"
        case .monochrome: return "Monochrome"
        case .braise: return "Braise"
        }
    }
}

/// Frequency-zone palette. Seven zones, blended continuously in OKLab.
public enum Palette {
    /// Zone centre frequencies (geometric means of the zone edges).
    public static let zoneEdges: [Double] = [20, 60, 250, 500, 2000, 4000, 10000, 20000]
    public static var zoneCenters: [Double] { (0..<7).map { (zoneEdges[$0] * zoneEdges[$0 + 1]).squareRoot() } }

    public static func anchors(_ theme: ThemeKind) -> [UInt32] {
        switch theme {
        case .sobre:
            return [0xA3333D, 0xC9A24B, 0x6E9E6B, 0x3F9C98, 0x4A78B5, 0x7B6BB8, 0xB98AB0]
        case .monochrome:
            return [0x4C6C8C, 0x52789A, 0x5883A6, 0x5E8DAF, 0x6797B7, 0x72A1BE, 0x7FAAC4]
        case .braise:
            return [0x8E2B2B, 0xA63F2E, 0xBA5A32, 0xC77637, 0xCE9040, 0xD3A752, 0xCDB37D]
        }
    }

    /// Base OKLab colour at normalised log-frequency u ∈ [0, 1] (20 Hz → 20 kHz).
    public static func baseColor(_ theme: ThemeKind, u: Double, minFrequency: Double = 20, maxFrequency: Double = 20000) -> SIMD3<Double> {
        let f = minFrequency * pow(maxFrequency / minFrequency, min(max(u, 0), 1))
        let centers = zoneCenters
        let labs = anchors(theme).map(OKLab.fromHex)
        if f <= centers[0] { return labs[0] }
        if f >= centers[6] { return labs[6] }
        var i = 0
        while i < 5 && f > centers[i + 1] { i += 1 }
        let t = log(f / centers[i]) / log(centers[i + 1] / centers[i])
        let s = t * t * (3 - 2 * t)   // smooth, no visible seam between zones
        return labs[i] + (labs[i + 1] - labs[i]) * s
    }

    /// 256-entry OKLab lookup table uploaded to the GPU (L, a, b, 1).
    public static func lut(_ theme: ThemeKind, count: Int = 256) -> [SIMD4<Float>] {
        (0..<count).map { i in
            let c = baseColor(theme, u: Double(i) / Double(count - 1))
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
        }
    }

    /// Amplitude shading — mirrored exactly in Shaders.metal (`shade`).
    /// Silence → very dark, peaks → lighter but never white or fluorescent.
    public static func shade(_ base: SIMD3<Double>, amplitude: Double) -> SIMD3<Double> {
        let a = min(max(amplitude, 0), 1)
        let L = 0.16 + (min(base.x + 0.10, 0.84) - 0.16) * pow(a, 0.85)
        let chroma = 0.35 + (1.05 - 0.35) * a
        return SIMD3(L, base.y * chroma, base.z * chroma)
    }
}
