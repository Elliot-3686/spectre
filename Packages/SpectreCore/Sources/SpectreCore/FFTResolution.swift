import Accelerate
import Foundation

/// One FFT size of the multi-resolution analysis.
/// Everything is allocated once in `init`; `run` performs no allocation.
final class FFTResolution {
    let n: Int
    let half: Int
    let sampleRate: Double
    let binWidth: Double
    let kind: WindowKind

    /// Frequency range in which this resolution owns peak detection.
    let searchLow: Double
    let searchHigh: Double

    private let setup: vDSP_DFT_Setup
    private let window: FloatBuffer
    private let windowed: FloatBuffer
    private let evenIn: FloatBuffer
    private let oddIn: FloatBuffer
    private(set) var re: UnsafeMutablePointer<Float>
    private(set) var im: UnsafeMutablePointer<Float>
    private(set) var prevRe: UnsafeMutablePointer<Float>
    private(set) var prevIm: UnsafeMutablePointer<Float>
    private let reStore: FloatBuffer, imStore: FloatBuffer, prevReStore: FloatBuffer, prevImStore: FloatBuffer

    /// Amplitude² normalised so that a full-scale sine on a bin centre reads 1.0 (0 dBFS).
    let power: FloatBuffer
    /// 10·log10(power) → dBFS (sine-calibrated).
    let db: FloatBuffer

    /// Equivalent noise bandwidth in bins (for band-energy sums).
    let enbw: Float
    let response: WindowResponseTable

    /// Bins actually needed (display taps, bands, peak search). Only those are converted.
    var binLow: Int
    var binHigh: Int

    private var ampNorm2: Float = 1
    private(set) var phaseSign: Double = 1
    var hasPrevious = false

    init(size: Int, sampleRate: Double, window kind: WindowKind, searchLow: Double, searchHigh: Double) {
        precondition(size >= 256 && size & (size - 1) == 0, "FFT size must be a power of two")
        n = size
        half = size / 2
        self.sampleRate = sampleRate
        binWidth = sampleRate / Double(size)
        self.kind = kind
        self.searchLow = searchLow
        self.searchHigh = searchHigh

        guard let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup failed for size \(size)")
        }
        setup = s

        let w = kind.make(count: size)
        window = FloatBuffer(size)
        window.pointer.update(from: w, count: size)
        windowed = FloatBuffer(size)
        evenIn = FloatBuffer(half)
        oddIn = FloatBuffer(half)
        reStore = FloatBuffer(half); imStore = FloatBuffer(half)
        prevReStore = FloatBuffer(half); prevImStore = FloatBuffer(half)
        re = reStore.pointer; im = imStore.pointer
        prevRe = prevReStore.pointer; prevIm = prevImStore.pointer
        power = FloatBuffer(half, value: 1e-20)
        db = FloatBuffer(half, value: -200)

        var sum: Double = 0, sum2: Double = 0
        for v in w { sum += Double(v); sum2 += Double(v) * Double(v) }
        enbw = Float(Double(size) * sum2 / (sum * sum))
        response = WindowResponseTable.table(for: kind, size: size, window: w)

        binLow = 1
        binHigh = half - 1

        calibrate(windowSum: sum)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    // MARK: - Calibration (scale and phase convention measured, not assumed)

    private func calibrate(windowSum: Double) {
        // 1. Scale: DFT of a unit impulse is 1 for every bin; vDSP may scale by 2.
        evenIn.fill(0); oddIn.fill(0)
        evenIn[0] = 1
        vDSP_DFT_Execute(setup, evenIn.pointer, oddIn.pointer, re, im)
        let scale = Double(hypotf(re[1], im[1]))
        let ampNorm = 2.0 / (scale * windowSum)
        ampNorm2 = Float(ampNorm * ampNorm)

        // 2. Phase direction: shift a sinusoid by H samples and check which sign
        //    of the phase advance recovers its true frequency.
        let nu = 10.3
        let hop = max(n / 16, 1)
        let signal0 = (0..<n).map { Float(cos(2 * Double.pi * nu * Double($0) / Double(n))) }
        let signal1 = (0..<n).map { Float(cos(2 * Double.pi * nu * Double($0 + hop) / Double(n))) }
        signal0.withUnsafeBufferPointer { transform($0.baseAddress!) }
        let p0 = atan2(Double(im[10]), Double(re[10]))
        signal1.withUnsafeBufferPointer { transform($0.baseAddress!) }
        let p1 = atan2(Double(im[10]), Double(re[10]))
        func estimate(_ sign: Double) -> Double {
            let expected = 2 * Double.pi * 10 * Double(hop) / Double(n)
            let dev = remainder(sign * (p1 - p0) - expected, 2 * Double.pi)
            return 10 + dev * Double(n) / (2 * Double.pi * Double(hop))
        }
        phaseSign = abs(estimate(1) - nu) <= abs(estimate(-1) - nu) ? 1 : -1
        hasPrevious = false
        re.update(repeating: 0, count: half); im.update(repeating: 0, count: half)
        prevRe.update(repeating: 0, count: half); prevIm.update(repeating: 0, count: half)
    }

    // MARK: - Hot path

    /// Windows + transforms the n samples starting at `samples`.
    /// The previous frame's complex spectrum is kept for phase refinement.
    @inline(__always)
    private func transform(_ samples: UnsafePointer<Float>) {
        vDSP_vmul(samples, 1, window.pointer, 1, windowed.pointer, 1, vDSP_Length(n))
        windowed.pointer.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            var split = DSPSplitComplex(realp: evenIn.pointer, imagp: oddIn.pointer)
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
        }
        swap(&re, &prevRe)
        swap(&im, &prevIm)
        vDSP_DFT_Execute(setup, evenIn.pointer, oddIn.pointer, re, im)
    }

    func run(_ samples: UnsafePointer<Float>) {
        transform(samples)
        let lo = binLow
        let count = vDSP_Length(binHigh - binLow + 1)
        var split = DSPSplitComplex(realp: re + lo, imagp: im + lo)
        vDSP_zvmags(&split, 1, power.pointer + lo, 1, count)
        var norm = ampNorm2
        vDSP_vsmul(power.pointer + lo, 1, &norm, power.pointer + lo, 1, count)
        var tiny: Float = 1e-20
        vDSP_vsadd(power.pointer + lo, 1, &tiny, power.pointer + lo, 1, count)
        var one: Float = 1
        vDSP_vdbcon(power.pointer + lo, 1, &one, db.pointer + lo, 1, count, 0)
    }

    @inline(__always) func phase(_ k: Int) -> Double { atan2(Double(im[k]), Double(re[k])) }
    @inline(__always) func previousPhase(_ k: Int) -> Double { atan2(Double(prevIm[k]), Double(prevRe[k])) }
}
