import Accelerate
import Foundation

public struct Peak: Equatable, Sendable {
    public var frequency: Double
    public var levelDB: Float
    public init(frequency: Double = 0, levelDB: Float = -200) {
        self.frequency = frequency
        self.levelDB = levelDB
    }
}

public struct AnalyzerConfiguration: Equatable, Sendable {
    public var sampleRate: Double
    /// FFT sizes, largest first. 1 size = classic FFT, 2–3 sizes = multi-resolution.
    public var fftSizes: [Int]
    public var window: WindowKind
    public var displayBins: Int
    /// Samples between two analyses (sampleRate / fps).
    public var hop: Int
    public var minFrequency: Double
    public var maxFrequency: Double
    public var maxPeaks: Int
    public var peakThresholdDB: Float
    public var truePeak: Bool

    public init(sampleRate: Double = 48000,
                fftSizes: [Int] = [32768, 8192, 2048],
                window: WindowKind = .hann,
                displayBins: Int = 512,
                hop: Int = 800,
                minFrequency: Double = 20,
                maxFrequency: Double = 20000,
                maxPeaks: Int = 5,
                peakThresholdDB: Float = -90,
                truePeak: Bool = false) {
        self.sampleRate = sampleRate
        self.fftSizes = fftSizes.sorted(by: >)
        self.window = window
        self.displayBins = displayBins
        self.hop = max(hop, 32)
        self.minFrequency = minFrequency
        self.maxFrequency = min(maxFrequency, sampleRate * 0.5 * 0.995)
        self.maxPeaks = maxPeaks
        self.peakThresholdDB = peakThresholdDB
        self.truePeak = truePeak
    }

    /// Crossover frequencies between resolutions (constant-Q-like split).
    public var crossovers: [Double] {
        switch fftSizes.count {
        case 0, 1: return []
        case 2: return [500]
        default: return [300, 2500]
        }
    }
}

/// Result of the last analysis. Storage is pre-allocated and overwritten in place.
public final class AnalysisResult {
    public let display: FloatBuffer       // dBFS per log-spaced display bin (raw)
    public let bands: FloatBuffer         // dBFS per ISO 1/3-octave band (31)
    public private(set) var peaks: [Peak] // fixed capacity, first `peakCount` valid
    public internal(set) var peakCount = 0
    public internal(set) var rmsDB: Float = -200
    public internal(set) var samplePeakDB: Float = -200
    public internal(set) var truePeakDB: Float = -200
    public internal(set) var isSilent = true
    public internal(set) var sequence: UInt64 = 0

    init(displayBins: Int, maxPeaks: Int) {
        display = FloatBuffer(displayBins, value: -200)
        bands = FloatBuffer(ISOBands.count, value: -200)
        peaks = [Peak](repeating: Peak(), count: max(maxPeaks, 1))
    }

    public var dominant: Peak? { peakCount > 0 ? peaks[0] : nil }
    public var validPeaks: ArraySlice<Peak> { peaks[0..<peakCount] }

    @inline(__always) func setPeak(_ i: Int, _ p: Peak) { peaks[i] = p }
}

/// Multi-resolution spectrum analyser.
///
/// * Long windows for the bass, short ones for the treble, merged on a log axis.
/// * Peaks: parabolic interpolation on the log spectrum, then phase-vocoder
///   refinement between two frames exactly `hop` samples apart.
/// * Levels in dBFS calibrated on a sine (window gain and scalloping compensated).
/// * Zero allocation after `init`.
public final class SpectrumAnalyzer {
    public let configuration: AnalyzerConfiguration
    public let result: AnalysisResult
    /// Centre frequency of each display bin (log-spaced).
    public let displayFrequencies: [Double]

    let resolutions: [FFTResolution]
    private let maxN: Int
    private let hop: Int

    // History of the last samples, linear (with occasional compaction).
    private let history: FloatBuffer
    private var writePosition: Int
    private var hopCounter = 0
    private var samplesSinceSound = Int.max / 4

    // Display taps
    private struct Tap { var res: Int32; var lo: Int32; var hi: Int32; var frac: Float }
    private var tapsA: [Tap]
    private var tapsB: [Tap]
    private var blendB: [Float]

    // Bands
    private var bandRes: [Int32]
    private var bandStart: [Int32]
    private var bandCount: [Int32]
    private var bandBins: [Int32]
    private var bandWeights: [Float]

    // Peaks scratch
    private var candidates: [Peak]
    private var candidateCount = 0

    // True peak (4× polyphase interpolation)
    private let truePeakTaps = 12
    private var truePeakFilters: [FloatBuffer] = []
    private let truePeakScratch: FloatBuffer

    public init(configuration: AnalyzerConfiguration) {
        self.configuration = configuration
        let sizes = configuration.fftSizes.isEmpty ? [8192] : configuration.fftSizes
        maxN = sizes[0]
        hop = configuration.hop
        result = AnalysisResult(displayBins: configuration.displayBins, maxPeaks: configuration.maxPeaks)

        // Resolutions and their frequency ownership.
        let cross = configuration.crossovers
        var res: [FFTResolution] = []
        for (i, n) in sizes.enumerated() {
            let lo = i == 0 ? configuration.minFrequency : cross[i - 1]
            let hi = i == sizes.count - 1 ? configuration.maxFrequency : cross[i]
            res.append(FFTResolution(size: n, sampleRate: configuration.sampleRate, window: configuration.window,
                                     searchLow: lo, searchHigh: hi))
        }
        resolutions = res

        history = FloatBuffer(maxN * 3 + configuration.hop * 6 + 64)
        writePosition = maxN + truePeakTaps

        // Display frequencies.
        let k = configuration.displayBins
        let fMin = configuration.minFrequency, fMax = configuration.maxFrequency
        displayFrequencies = (0..<k).map { fMin * pow(fMax / fMin, Double($0) / Double(max(k - 1, 1))) }
        let ratio = pow(fMax / fMin, 1.0 / Double(max(k - 1, 1)))

        var needLo = [Int](repeating: Int.max, count: res.count)
        var needHi = [Int](repeating: 0, count: res.count)
        func need(_ r: Int, _ lo: Int, _ hi: Int) {
            needLo[r] = min(needLo[r], lo)
            needHi[r] = max(needHi[r], hi)
        }

        func resolutionIndex(for f: Double) -> Int {
            var idx = 0
            for c in cross where f >= c { idx += 1 }
            return min(idx, res.count - 1)
        }
        func makeTap(_ r: Int, _ f: Double) -> Tap {
            let df = res[r].binWidth
            let kLo = f / ratio.squareRoot() / df
            let kHi = f * ratio.squareRoot() / df
            let half = res[r].half
            if kHi - kLo >= 1 {
                let lo = max(Int(kLo.rounded(.up)), 1)
                let hi = min(max(Int(kHi.rounded(.down)), lo), half - 2)
                need(r, lo, hi)
                return Tap(res: Int32(r), lo: Int32(lo), hi: Int32(hi), frac: -1)
            } else {
                let kc = f / df
                let lo = min(max(Int(kc.rounded(.down)), 1), half - 3)
                need(r, lo, lo + 1)
                return Tap(res: Int32(r), lo: Int32(lo), hi: Int32(lo), frac: Float(kc - Double(lo)))
            }
        }

        var ta: [Tap] = [], tb: [Tap] = [], wb: [Float] = []
        let blendOctaves = 0.25
        for f in displayFrequencies {
            let r = resolutionIndex(for: f)
            ta.append(makeTap(r, f))
            var weight: Float = 0
            var tapB = ta[ta.count - 1]
            // Crossfade around each crossover, in dB, over ±¼ octave.
            for (ci, c) in cross.enumerated() {
                let x = log2(f / c)
                if abs(x) < blendOctaves {
                    let t = (x + blendOctaves) / (2 * blendOctaves)
                    let s = Float(t * t * (3 - 2 * t))
                    // Lower resolution index = ci, higher = ci + 1
                    ta[ta.count - 1] = makeTap(ci, f)
                    tapB = makeTap(ci + 1, f)
                    weight = s
                }
            }
            tb.append(tapB)
            wb.append(weight)
        }
        tapsA = ta; tapsB = tb; blendB = wb

        // ISO 1/3-octave bands with fractional bin overlap weights.
        var bRes: [Int32] = [], bStart: [Int32] = [], bCount: [Int32] = [], bBins: [Int32] = [], bW: [Float] = []
        for fc in ISOBands.exactCenters {
            let r = resolutionIndex(for: fc)
            let df = res[r].binWidth
            let lo = fc / pow(2, 1.0 / 6), hi = min(fc * pow(2, 1.0 / 6), configuration.sampleRate / 2 - df)
            bRes.append(Int32(r))
            bStart.append(Int32(bBins.count))
            var count = 0
            let k0 = max(Int((lo / df - 0.5).rounded(.down)), 1)
            let k1 = min(Int((hi / df + 0.5).rounded(.up)), res[r].half - 2)
            if k1 >= k0 {
                for kk in k0...k1 {
                    let a = (Double(kk) - 0.5) * df, b = (Double(kk) + 0.5) * df
                    let overlap = max(0, min(b, hi) - max(a, lo)) / df
                    if overlap > 0 {
                        bBins.append(Int32(kk)); bW.append(Float(overlap)); count += 1
                        need(r, kk, kk)
                    }
                }
            }
            bCount.append(Int32(count))
        }
        bandRes = bRes; bandStart = bStart; bandCount = bCount; bandBins = bBins; bandWeights = bW

        // Peak search ranges (+ margins for prominence and interpolation).
        for (i, r) in res.enumerated() {
            let margin = configuration.window.mainLobeHalfWidth + 4
            let lo = max(Int((r.searchLow / r.binWidth).rounded(.down)) - margin, 1)
            let hi = min(Int((r.searchHigh / r.binWidth).rounded(.up)) + margin, r.half - 2)
            need(i, lo, hi)
        }
        for (i, r) in res.enumerated() {
            r.binLow = max(min(needLo[i], r.half - 2), 1)
            r.binHigh = min(max(needHi[i], r.binLow), r.half - 1)
        }

        candidates = [Peak](repeating: Peak(), count: 24)

        truePeakScratch = FloatBuffer(configuration.hop + 64)
        if configuration.truePeak { buildTruePeakFilters() }
    }

    // MARK: - Input

    /// Feeds samples. Analyses at every hop boundary (at most the last two
    /// boundaries of a large block, to catch up without wasting CPU).
    /// Returns the number of analyses performed.
    @discardableResult
    public func process(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        var offset = 0
        let boundaries = (hopCounter + count) / hop
        var boundary = 0
        var analysed = 0
        while offset < count {
            let piece = min(count - offset, hop - hopCounter)
            append(samples + offset, count: piece)
            offset += piece
            hopCounter += piece
            if hopCounter == hop {
                hopCounter = 0
                boundary += 1
                if boundary > boundaries - 2 {
                    analyse()
                    analysed += 1
                } else {
                    for r in resolutions { r.hasPrevious = false }
                }
            }
        }
        return analysed
    }

    /// Forgets the past (e.g. after a capture restart).
    public func reset() {
        history.fill(0)
        writePosition = maxN + truePeakTaps
        hopCounter = 0
        samplesSinceSound = Int.max / 4
        for r in resolutions { r.hasPrevious = false }
        result.isSilent = true
        result.peakCount = 0
        result.display.fill(-200)
        result.bands.fill(-200)
    }

    @inline(__always)
    private func append(_ src: UnsafePointer<Float>, count: Int) {
        if writePosition + count > history.count {
            let keep = maxN + truePeakTaps + hop
            (history.pointer).update(from: history.pointer + writePosition - keep, count: keep)
            writePosition = keep
        }
        (history.pointer + writePosition).update(from: src, count: count)
        writePosition += count
        var peak: Float = 0
        vDSP_maxmgv(src, 1, &peak, vDSP_Length(count))
        if peak > 1e-6 { samplesSinceSound = 0 } else { samplesSinceSound += count }
    }

    // MARK: - Analysis

    private func analyse() {
        let res = result
        res.sequence &+= 1
        let hopStart = history.pointer + writePosition - hop

        var rms: Float = 0
        vDSP_rmsqv(hopStart, 1, &rms, vDSP_Length(hop))
        var peak: Float = 0
        vDSP_maxmgv(hopStart, 1, &peak, vDSP_Length(hop))
        res.rmsDB = 20 * log10(max(rms, 1e-10))
        res.samplePeakDB = 20 * log10(max(peak, 1e-10))
        res.truePeakDB = configuration.truePeak ? 20 * log10(max(truePeak(hopStart: hopStart, samplePeak: peak), 1e-10)) : res.samplePeakDB

        // Whole longest window silent → nothing to analyse (zero FFT cost).
        if samplesSinceSound >= maxN {
            if !res.isSilent {
                res.display.fill(-200)
                res.bands.fill(-200)
                res.peakCount = 0
                res.isSilent = true
            }
            for r in resolutions { r.hasPrevious = false }
            return
        }
        res.isSilent = false

        for r in resolutions {
            r.run(UnsafePointer(history.pointer + writePosition - r.n))
        }
        buildDisplay()
        buildBands()
        findPeaks()
        for r in resolutions { r.hasPrevious = true }
    }

    @inline(__always)
    private func tapValue(_ t: Tap) -> Float {
        let db = resolutions[Int(t.res)].db.pointer
        if t.frac < 0 {
            var m: Float = 0
            vDSP_maxv(db + Int(t.lo), 1, &m, vDSP_Length(Int(t.hi - t.lo) + 1))
            return m
        }
        let a = db[Int(t.lo)], b = db[Int(t.lo) + 1]
        return a + (b - a) * t.frac
    }

    private func buildDisplay() {
        let out = result.display.pointer
        for j in 0..<tapsA.count {
            var v = tapValue(tapsA[j])
            let w = blendB[j]
            if w > 0 {
                let vb = tapValue(tapsB[j])
                v += (vb - v) * w
            }
            out[j] = v
        }
    }

    private func buildBands() {
        let out = result.bands.pointer
        for b in 0..<bandRes.count {
            let r = resolutions[Int(bandRes[b])]
            let p = r.power.pointer
            var acc: Float = 0
            let s = Int(bandStart[b]), c = Int(bandCount[b])
            for i in s..<(s + c) {
                acc += p[Int(bandBins[i])] * bandWeights[i]
            }
            out[b] = 10 * log10(max(acc / r.enbw, 1e-20))
        }
    }

    private func findPeaks() {
        candidateCount = 0
        let threshold = configuration.peakThresholdDB
        let w = configuration.window.mainLobeHalfWidth + 2
        for r in resolutions {
            let db = r.db.pointer
            let k0 = max(Int((r.searchLow / r.binWidth).rounded(.up)), 2, r.binLow + 1)
            let k1 = min(Int((r.searchHigh / r.binWidth).rounded(.down)), r.binHigh - 1)
            if k1 <= k0 { continue }
            var k = k0
            while k <= k1 {
                let b = db[k]
                if b < threshold || !(b > db[k - 1] && b >= db[k + 1]) { k += 1; continue }
                // Prominence: both sides must fall by ≥ 12 dB within the main lobe + 2 bins.
                var minL = b, minR = b
                let wl = min(w, k - r.binLow), wr = min(w, r.binHigh - k)
                for i in 1...wl { minL = min(minL, db[k - i]) }
                for i in 1...wr { minR = min(minR, db[k + i]) }
                if b - max(minL, minR) < 12 { k += 1; continue }
                let p = refine(r, k)
                if p.frequency >= r.searchLow * 0.999 && p.frequency < r.searchHigh * 1.001 {
                    insertCandidate(p)
                }
                k += 2
            }
        }
        // Keep the strongest, drop near-duplicates (< 1 % apart).
        var count = 0
        let maxPeaks = result.peaks.count
        var i = 0
        while i < candidateCount && count < maxPeaks {
            let c = candidates[i]
            var dup = false
            for j in 0..<count where abs(result.peaks[j].frequency - c.frequency) < c.frequency * 0.01 { dup = true; break }
            if !dup { result.setPeak(count, c); count += 1 }
            i += 1
        }
        result.peakCount = count
    }

    @inline(__always)
    private func insertCandidate(_ p: Peak) {
        let cap = candidates.count
        if candidateCount == cap && p.levelDB <= candidates[cap - 1].levelDB { return }
        var i = min(candidateCount, cap - 1)
        while i > 0 && candidates[i - 1].levelDB < p.levelDB {
            candidates[i] = candidates[i - 1]
            i -= 1
        }
        candidates[i] = p
        candidateCount = min(candidateCount + 1, cap)
    }

    /// Sub-bin frequency + exact amplitude of the peak at bin k.
    @inline(__always)
    private func refine(_ r: FFTResolution, _ k: Int) -> Peak {
        let db = r.db.pointer
        let a = Double(db[k - 1]), b = Double(db[k]), c = Double(db[k + 1])
        let denom = a - 2 * b + c
        var p = denom < 0 ? 0.5 * (a - c) / denom : 0
        p = min(max(p, -0.5), 0.5)
        var nu = Double(k) + p

        // Phase-vocoder refinement (frames exactly `hop` samples apart).
        if r.hasPrevious {
            let twoPi = 2 * Double.pi
            let h = Double(hop), n = Double(r.n)
            let dphi = r.phaseSign * (r.phase(k) - r.previousPhase(k))
            let expected = twoPi * Double(k) * h / n
            let dev = remainder(dphi - expected, twoPi)
            let scale = n / (twoPi * h)       // radians → bins
            let period = n / h                 // alias spacing in bins
            let base = dev * scale
            let m = ((nu - Double(k) - base) / period).rounded()
            let nuPhase = Double(k) + base + m * period
            if abs(nuPhase - nu) < 0.3 { nu = nuPhase }
        }

        // Exact amplitude: divide by the window response at the fractional offset.
        let k0 = min(max(Int(nu.rounded()), r.binLow), r.binHigh)
        let delta = nu - Double(k0)
        let resp = r.response.response(delta)
        let amp2 = r.power[k0] / max(resp * resp, 1e-6)
        return Peak(frequency: nu * r.binWidth, levelDB: 10 * log10(max(amp2, 1e-20)))
    }

    // MARK: - True peak

    private func buildTruePeakFilters() {
        let phases = 4, taps = truePeakTaps
        let total = phases * taps
        var proto = [Double](repeating: 0, count: total)
        let center = Double(total - 1) / 2
        for i in 0..<total {
            let x = (Double(i) - center) / Double(phases)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let kaiserLike = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(total))
            proto[i] = sinc * kaiserLike
        }
        truePeakFilters = (1..<phases).map { ph in
            let fb = FloatBuffer(taps)
            var sum = 0.0
            for j in 0..<taps { sum += proto[j * phases + ph] }
            // Store reversed for vDSP_conv (correlation) and normalise DC gain to 1.
            for j in 0..<taps { fb[taps - 1 - j] = Float(proto[j * phases + ph] / sum) }
            return fb
        }
    }

    private func truePeak(hopStart: UnsafeMutablePointer<Float>, samplePeak: Float) -> Float {
        var best = samplePeak
        let taps = truePeakTaps
        for f in truePeakFilters {
            vDSP_conv(hopStart - (taps - 1), 1, f.pointer, 1, truePeakScratch.pointer, 1,
                      vDSP_Length(hop), vDSP_Length(taps))
            var m: Float = 0
            vDSP_maxmgv(truePeakScratch.pointer, 1, &m, vDSP_Length(hop))
            best = max(best, m)
        }
        return best
    }
}
