import Foundation

/// Analysis windows.
/// - `hann`: best compromise for frequency estimation (parabolic + phase).
/// - `blackmanHarris`: 4-term, −92 dB side lobes, for very dynamic spectra.
/// - `flatTop`: < 0.01 dB scalloping, exact amplitudes on the displayed curve.
public enum WindowKind: String, CaseIterable, Codable, Sendable {
    case hann
    case blackmanHarris
    case flatTop

    public var label: String {
        switch self {
        case .hann: return "Hann (résolution)"
        case .blackmanHarris: return "Blackman-Harris (dynamique)"
        case .flatTop: return "Flat-top (amplitude exacte)"
        }
    }

    /// Half-width of the main lobe, in bins.
    public var mainLobeHalfWidth: Int {
        switch self {
        case .hann: return 2
        case .blackmanHarris: return 4
        case .flatTop: return 5
        }
    }

    var coefficients: [Double] {
        switch self {
        case .hann: return [0.5, 0.5]
        case .blackmanHarris: return [0.35875, 0.48829, 0.14128, 0.01168]
        case .flatTop: return [0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368]
        }
    }

    /// Periodic ("DFT-even") window of length n.
    public func make(count n: Int) -> [Float] {
        let a = coefficients
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = 2.0 * Double.pi * Double(i) / Double(n)
            var v = 0.0
            for (m, c) in a.enumerated() {
                v += (m % 2 == 0 ? c : -c) * cos(Double(m) * x)
            }
            w[i] = Float(v)
        }
        return w
    }
}

/// Normalised magnitude response |W(δ)| / |W(0)| of a window for a sinusoid
/// located δ bins away from a bin centre, sampled on δ ∈ [0, 1].
/// Used to correct the amplitude of detected peaks exactly (scalloping loss).
final class WindowResponseTable {
    static let resolution = 128
    let values: [Float]

    private static var cache: [String: WindowResponseTable] = [:]
    private static let lock = NSLock()

    static func table(for kind: WindowKind, size n: Int, window: [Float]) -> WindowResponseTable {
        let key = "\(kind.rawValue)-\(n)"
        lock.lock(); defer { lock.unlock() }
        if let t = cache[key] { return t }
        let t = WindowResponseTable(window: window)
        cache[key] = t
        return t
    }

    private init(window: [Float]) {
        let n = window.count
        var sums = [Double](repeating: 0, count: Self.resolution + 1)
        for j in 0...Self.resolution {
            let delta = Double(j) / Double(Self.resolution)
            let theta = -2.0 * Double.pi * delta / Double(n)
            // Rotating phasor recurrence: z_{k+1} = z_k · e^{iθ}
            let cr = cos(theta), ci = sin(theta)
            var zr = 1.0, zi = 0.0
            var accR = 0.0, accI = 0.0
            for k in 0..<n {
                let w = Double(window[k])
                accR += w * zr
                accI += w * zi
                let nr = zr * cr - zi * ci
                zi = zr * ci + zi * cr
                zr = nr
                if k & 1023 == 1023 { // renormalise to kill drift
                    let m = (zr * zr + zi * zi).squareRoot()
                    zr /= m; zi /= m
                }
            }
            sums[j] = (accR * accR + accI * accI).squareRoot()
        }
        let ref = sums[0]
        values = sums.map { Float($0 / ref) }
    }

    @inline(__always)
    func response(_ delta: Double) -> Float {
        let x = min(max(abs(delta), 0), 1) * Double(Self.resolution)
        let i = min(Int(x), Self.resolution - 1)
        let t = Float(x - Double(i))
        return values[i] * (1 - t) + values[i + 1] * t
    }
}
