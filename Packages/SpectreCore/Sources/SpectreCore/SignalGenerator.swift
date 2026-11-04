import Foundation

/// Deterministic test signals (tests, demo mode, snapshots, diagnostics).
public enum SignalGenerator {
    public static func sine(frequency: Double, amplitude: Float = 0.5, sampleRate: Double,
                            count: Int, phase: Double = 0) -> [Float] {
        let w = 2 * Double.pi * frequency / sampleRate
        return (0..<count).map { Float(Double(amplitude) * sin(w * Double($0) + phase)) }
    }

    public static func sum(_ signals: [[Float]]) -> [Float] {
        guard let n = signals.map(\.count).min() else { return [] }
        var out = [Float](repeating: 0, count: n)
        for s in signals { for i in 0..<n { out[i] += s[i] } }
        return out
    }

    public static func chord(_ frequencies: [Double], amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        sum(frequencies.enumerated().map { i, f in
            sine(frequency: f, amplitude: amplitude, sampleRate: sampleRate, count: count, phase: Double(i) * 1.3)
        })
    }

    /// Pink noise (Paul Kellet's refined filter on seeded white noise).
    public static func pinkNoise(count: Int, amplitude: Float = 0.1, seed: UInt64 = 0x5EC7_12E5) -> [Float] {
        var rng = SplitMix64(seed: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let white = rng.nextGaussian()
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            out[i] = Float(pink * 0.11) * amplitude * 10
        }
        return out
    }

    /// Exponential (log) sweep f0 → f1 over `duration` seconds.
    public static func logSweep(from f0: Double, to f1: Double, duration: Double, sampleRate: Double,
                                amplitude: Float = 0.5) -> [Float] {
        let n = Int(duration * sampleRate)
        let k = log(f1 / f0) / duration
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * f0 * (exp(k * t) - 1) / k
            return Float(Double(amplitude) * sin(phase))
        }
    }

    public static func sweepFrequency(from f0: Double, to f1: Double, duration: Double, at t: Double) -> Double {
        f0 * exp(log(f1 / f0) / duration * t)
    }
}

/// Small, fast, deterministic PRNG.
public struct SplitMix64 {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func nextGaussian() -> Double {
        if let s = spare { spare = nil; return s }
        let u1 = max(nextUniform(), 1e-300), u2 = nextUniform()
        let r = (-2 * log(u1)).squareRoot()
        spare = r * sin(2 * Double.pi * u2)
        return r * cos(2 * Double.pi * u2)
    }
}
