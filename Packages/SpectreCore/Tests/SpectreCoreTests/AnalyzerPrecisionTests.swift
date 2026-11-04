import XCTest
import SpectreCore

/// Precision requirements: < 0.1 Hz below 1 kHz, < 0.1 % above; levels in exact dBFS.
final class AnalyzerPrecisionTests: XCTestCase {
    static let configs: [(String, AnalyzerConfiguration)] = [
        ("multi-res 32768/8192/2048", AnalyzerConfiguration(sampleRate: 48000, fftSizes: [32768, 8192, 2048], hop: 800)),
        ("8192 seule", AnalyzerConfiguration(sampleRate: 48000, fftSizes: [8192], hop: 800)),
        ("économie 4096", AnalyzerConfiguration(sampleRate: 48000, fftSizes: [4096], displayBins: 256, hop: 2400)),
        ("44,1 kHz multi-res", AnalyzerConfiguration(sampleRate: 44100, fftSizes: [32768, 8192, 2048], hop: 735)),
    ]

    func run(_ analyzer: SpectrumAnalyzer, _ signal: [Float]) {
        signal.withUnsafeBufferPointer { buf in
            // Feed in irregular chunks like a real audio callback.
            var offset = 0
            var chunk = 471
            while offset < buf.count {
                let n = min(chunk, buf.count - offset)
                analyzer.process(buf.baseAddress! + offset, count: n)
                offset += n
                chunk = chunk == 471 ? 512 : 471
            }
        }
    }

    func tolerance(_ f: Double) -> Double { f < 1000 ? 0.1 : f * 0.001 }

    func testPureSines() {
        let freqs: [Double] = [50, 440, 1000, 5000, 15000, 50.37, 440.21, 997.3, 4999.7, 15013.3, 82.41, 123.47]
        var report = "\nSINUS PURS (amplitude 0,5 → −6,02 dBFS)\n"
        for (name, cfg) in Self.configs {
            report += "  [\(name)]\n"
            for f in freqs {
                let a = SpectrumAnalyzer(configuration: cfg)
                let n = cfg.fftSizes[0] + cfg.hop * 6
                run(a, SignalGenerator.sine(frequency: f, amplitude: 0.5, sampleRate: cfg.sampleRate, count: n))
                guard let p = a.result.dominant else { XCTFail("\(name): no peak for \(f) Hz"); continue }
                let err = p.frequency - f
                report += String(format: "    %9.2f Hz → %10.4f Hz  erreur %+.4f Hz  niveau %.3f dBFS\n", f, p.frequency, err, p.levelDB)
                XCTAssertLessThan(abs(err), tolerance(f), "\(name): \(f) Hz measured \(p.frequency)")
                XCTAssertEqual(p.levelDB, -6.0206, accuracy: 0.1, "\(name): level at \(f) Hz")
            }
        }
        print(report)
    }

    func testA4And1000Hz() {
        let cfg = Self.configs[0].1
        for (f, expected) in [(440.0, "A4"), (1000.0, "B5")] {
            let a = SpectrumAnalyzer(configuration: cfg)
            run(a, SignalGenerator.sine(frequency: f, amplitude: 0.5, sampleRate: 48000, count: 32768 + 4000))
            let p = a.result.dominant!
            XCTAssertEqual(p.frequency, f, accuracy: 0.5)
            let note = MusicalNote.describe(frequency: p.frequency)!
            XCTAssertEqual(note.noteName, expected)
        }
        XCTAssertEqual(MusicalNote.describe(frequency: 440)!.label, "A4 +0 cents")
        XCTAssertEqual(MusicalNote.describe(frequency: 1000)!.label, "B5 +21 cents")
        XCTAssertEqual(MusicalNote.describe(frequency: 445)!.cents, 20)
        XCTAssertEqual(MusicalNote.describe(frequency: 261.6256)!.noteName, "C4")
        XCTAssertEqual(MusicalNote.describe(frequency: 27.5)!.noteName, "A0")
    }

    func testFullScaleCalibration() {
        for window in WindowKind.allCases {
            let cfg = AnalyzerConfiguration(fftSizes: [32768, 8192, 2048], window: window, hop: 800, truePeak: true)
            let a = SpectrumAnalyzer(configuration: cfg)
            run(a, SignalGenerator.sine(frequency: 1234.5, amplitude: 1, sampleRate: 48000, count: 40000))
            let p = a.result.dominant!
            XCTAssertEqual(p.levelDB, 0, accuracy: 0.05, "\(window) peak level")
            XCTAssertEqual(a.result.rmsDB, -3.0103, accuracy: 0.05, "\(window) RMS")
            XCTAssertEqual(a.result.truePeakDB, 0, accuracy: 0.2, "\(window) true peak")
            print(String(format: "CALIBRATION %@ : pic %.3f dBFS, RMS %.3f dBFS, true peak %.3f dBTP",
                         window.rawValue, p.levelDB, a.result.rmsDB, a.result.truePeakDB))
        }
    }

    func testFlatTopDisplayAmplitude() {
        // Flat-top: the displayed curve itself must read the exact level even between bins.
        let cfg = AnalyzerConfiguration(fftSizes: [8192], window: .flatTop, displayBins: 2048, hop: 800)
        let a = SpectrumAnalyzer(configuration: cfg)
        run(a, SignalGenerator.sine(frequency: 1002.93, amplitude: 0.25, sampleRate: 48000, count: 8192 + 4000))
        var m: Float = -200
        for i in 0..<a.result.display.count { m = max(m, a.result.display[i]) }
        XCTAssertEqual(m, -12.041, accuracy: 0.05)
    }

    func testChord() {
        let chord = [220.0, 277.18, 329.63, 440.0, 1318.51]
        for (name, cfg) in Self.configs.prefix(2) {
            let a = SpectrumAnalyzer(configuration: cfg)
            run(a, SignalGenerator.chord(chord, amplitude: 0.2, sampleRate: 48000, count: cfg.fftSizes[0] + 6000))
            let found = a.result.validPeaks.map(\.frequency)
            var line = "ACCORD [\(name)] :"
            for f in chord {
                let best = found.min(by: { abs($0 - f) < abs($1 - f) }) ?? 0
                line += String(format: " %.2f→%.3f", f, best)
                XCTAssertLessThan(abs(best - f), tolerance(f), "\(name): chord note \(f)")
            }
            for p in a.result.validPeaks { XCTAssertEqual(p.levelDB, -13.98, accuracy: 0.5) }
            print(line)
        }
    }

    func testPinkNoiseIsFlatInThirdOctaves() {
        let cfg = Self.configs[0].1
        let a = SpectrumAnalyzer(configuration: cfg)
        let noise = SignalGenerator.pinkNoise(count: 48000 * 24, amplitude: 0.1)
        var sums = [Double](repeating: 0, count: ISOBands.count)
        var frames = 0
        noise.withUnsafeBufferPointer { buf in
            var offset = 0
            let block = 800
            var counter = 0
            while offset + block <= buf.count {
                a.process(buf.baseAddress! + offset, count: block)
                offset += block
                counter += 1
                if offset > 48000 && counter % 30 == 0 {
                    for b in 0..<ISOBands.count { sums[b] += pow(10, Double(a.result.bands[b]) / 10) }
                    frames += 1
                }
            }
        }
        let levels = sums.map { 10 * log10($0 / Double(frames)) }
        let ref = levels[17] // 1 kHz
        var line = "BRUIT ROSE (tiers d'octave, relatif à 1 kHz):"
        for b in 3...27 {
            line += String(format: " %@:%+.1f", ISOBands.label(b), levels[b] - ref)
            XCTAssertEqual(levels[b], ref, accuracy: 1.5, "band \(ISOBands.label(b))")
        }
        print(line)
    }

    func testLogSweepTracking() {
        let cfg = Self.configs[0].1
        let a = SpectrumAnalyzer(configuration: cfg)
        let duration = 20.0
        let sweep = SignalGenerator.logSweep(from: 20, to: 20000, duration: duration, sampleRate: 48000, amplitude: 0.5)
        var maxRel = [0.0, 0.0, 0.0]
        var hits = [0, 0, 0]
        sweep.withUnsafeBufferPointer { buf in
            var offset = 0
            var counter = 0
            while offset + 800 <= buf.count {
                a.process(buf.baseAddress! + offset, count: 800)
                offset += 800
                counter += 1
                guard counter % 15 == 0, let p = a.result.dominant else { continue }
                // Centre of the window of the resolution that owns this frequency.
                let guess = p.frequency
                let n = guess < 300 ? 32768 : (guess < 2500 ? 8192 : 2048)
                let tCenter = (Double(offset) - Double(n) / 2) / 48000
                guard tCenter > 0.5, tCenter < duration - 0.5 else { continue }
                let truth = SignalGenerator.sweepFrequency(from: 20, to: 20000, duration: duration, at: tCenter)
                guard truth > 25, truth < 19000 else { continue }
                let rel = abs(p.frequency - truth) / truth
                let idx = truth < 300 ? 0 : (truth < 2500 ? 1 : 2)
                maxRel[idx] = max(maxRel[idx], rel)
                hits[idx] += 1
            }
        }
        print(String(format: "BALAYAGE 20 Hz→20 kHz/20 s: erreur relative max graves %.3f %%, médiums %.3f %%, aigus %.3f %% (mesures : %d / %d / %d)",
                     maxRel[0] * 100, maxRel[1] * 100, maxRel[2] * 100, hits[0], hits[1], hits[2]))
        XCTAssertGreaterThan(hits[1] + hits[2], 20)
        XCTAssertLessThan(maxRel[0], 0.03)
        XCTAssertLessThan(maxRel[1], 0.01)
        XCTAssertLessThan(maxRel[2], 0.01)
    }

    func testSilence() {
        let a = SpectrumAnalyzer(configuration: Self.configs[0].1)
        run(a, [Float](repeating: 0, count: 48000))
        XCTAssertTrue(a.result.isSilent)
        XCTAssertEqual(a.result.peakCount, 0)
        XCTAssertLessThan(a.result.display.array.max()!, -150)
    }

    func testSmootherAttackRelease() {
        let s = SpectrumSmoother(count: 1)
        var loud: Float = 0, quiet: Float = -200
        s.attack = 0.01; s.release = 0.5
        for _ in 0..<6 { s.update(&loud, dt: 1.0 / 60) }
        XCTAssertGreaterThan(s.smoothed[0], -5)
        for _ in 0..<6 { s.update(&quiet, dt: 1.0 / 60) }
        XCTAssertGreaterThan(s.smoothed[0], -100) // slow release
        XCTAssertGreaterThan(s.hold[0], -1)       // peak hold
    }

    func testPerformance() {
        var report = "\nCOÛT CPU DE L'ANALYSE (1 cœur)\n"
        let cases: [(String, AnalyzerConfiguration, Double)] = [
            ("Haut  32768/8192/2048 @60 i/s", AnalyzerConfiguration(fftSizes: [32768, 8192, 2048], displayBins: 512, hop: 800), 60),
            ("Moyen 16384/4096      @30 i/s", AnalyzerConfiguration(fftSizes: [16384, 4096], displayBins: 384, hop: 1600), 30),
            ("Éco   4096            @20 i/s", AnalyzerConfiguration(fftSizes: [4096], displayBins: 256, hop: 2400), 20),
        ]
        let music = SignalGenerator.sum([
            SignalGenerator.pinkNoise(count: 48000 * 6, amplitude: 0.05),
            SignalGenerator.chord([110, 220, 277.18, 329.63, 880], amplitude: 0.1, sampleRate: 48000, count: 48000 * 6),
        ])
        for (name, cfg, fps) in cases {
            let a = SpectrumAnalyzer(configuration: cfg)
            let start = DispatchTime.now().uptimeNanoseconds
            var frames = 0
            music.withUnsafeBufferPointer { buf in
                var offset = 0
                while offset + cfg.hop <= buf.count {
                    frames += a.process(buf.baseAddress! + offset, count: cfg.hop)
                    offset += cfg.hop
                }
            }
            let us = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(max(frames, 1))
            report += String(format: "  %@ : %.1f µs/trame → %.2f %% d'un cœur\n", name, us, us * fps / 1e4)
        }
        print(report)
    }
}

final class PaletteTests: XCTestCase {
    func testOKLabRoundTrip() {
        for hex: UInt32 in [0xA3333D, 0xC9A24B, 0x6E9E6B, 0x3F9C98, 0x4A78B5, 0x7B6BB8, 0xB98AB0, 0x07080B] {
            let lab = OKLab.fromHex(hex)
            let (r, g, b) = OKLab.toSRGB8(lab)
            XCTAssertEqual(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), hex)
        }
    }

    func testZoneCentersMatchBrief() {
        let centers = Palette.zoneCenters
        for (i, hex) in Palette.anchors(.sobre).enumerated() {
            let u = log(centers[i] / 20) / log(1000)
            let (r, g, b) = OKLab.toSRGB8(Palette.baseColor(.sobre, u: u))
            XCTAssertEqual(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), hex, "zone \(i)")
        }
    }

    func testShadingNeverWhiteNorFluo() {
        for theme in ThemeKind.allCases {
            for i in 0...64 {
                let base = Palette.baseColor(theme, u: Double(i) / 64)
                let hot = Palette.shade(base, amplitude: 1)
                XCTAssertLessThanOrEqual(hot.x, 0.84 + 1e-9)
                let chroma = (hot.y * hot.y + hot.z * hot.z).squareRoot()
                XCTAssertLessThan(chroma, 0.2, "\(theme) too saturated")
                let dark = Palette.shade(base, amplitude: 0)
                XCTAssertLessThan(dark.x, 0.2)
            }
        }
    }
}
