import Foundation
import SpectreCore

/// Synthetic "music" (bass line, chords, hats, kick, pink-noise bed) generated
/// in real time. Used by the demo mode, the CI measurements and when testing
/// without Spotify. Pre-allocated, deterministic.
final class DemoSource {
    private let engine: AnalysisEngine
    let sampleRate: Double = 48000
    private var timer: DispatchSourceTimer?
    private let block = 480
    private var buffer: [Float]
    private var t: Int = 0
    private var phases = [Double](repeating: 0, count: 8)
    private var rng = SplitMix64(seed: 42)
    private var pink = [Double](repeating: 0, count: 7)
    private(set) var isRunning = false

    init(engine: AnalysisEngine) {
        self.engine = engine
        buffer = [Float](repeating: 0, count: 480)
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        let q = DispatchQueue(label: "Spectre.demo", qos: .userInitiated)
        let tm = DispatchSource.makeTimerSource(queue: q)
        let interval = Double(block) / sampleRate
        tm.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        startTime = DispatchTime.now().uptimeNanoseconds
        t = 0
        tm.setEventHandler { [weak self] in self?.catchUp() }
        tm.resume()
        timer = tm
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    // A minor – F – C – G, 92 bpm
    private static let progression: [[Double]] = [
        [110.00, 220.00, 261.63, 329.63, 440.00],
        [87.31, 174.61, 220.00, 261.63, 349.23],
        [130.81, 196.00, 261.63, 329.63, 392.00],
        [98.00, 196.00, 246.94, 293.66, 392.00],
    ]

    private var startTime: UInt64 = 0

    /// Timers can be late (virtual machines, timer coalescing): generate
    /// exactly what real time requires so the demo always runs at 48 kHz.
    private func catchUp() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9
        var due = Int(elapsed * sampleRate) - t
        if due > block * 20 { t += due - block * 20; due = block * 20 }
        while due >= block {
            render()
            due -= block
        }
    }

    private func render() {
        let sr = sampleRate
        let beat = 60.0 / 92.0
        buffer.withUnsafeMutableBufferPointer { out in
            for i in 0..<block {
                let time = Double(t + i) / sr
                let bar = Int(time / (beat * 4)) % 4
                let chord = Self.progression[bar]
                let beatPos = time.truncatingRemainder(dividingBy: beat) / beat
                let eighth = (time * 2 / beat).truncatingRemainder(dividingBy: 1)
                var s = 0.0
                for (k, f) in chord.enumerated() {
                    phases[k] += 2 * Double.pi * f / sr
                    if phases[k] > 2 * Double.pi { phases[k] -= 2 * Double.pi }
                    let amp = k == 0 ? 0.20 * (0.6 + 0.4 * exp(-beatPos * 3)) : 0.055 * (0.7 + 0.3 * sin(time * 0.7 + Double(k)))
                    s += amp * sin(phases[k]) + (k == 0 ? 0.04 * sin(2 * phases[k]) : 0)
                }
                // kick
                let kickEnv = exp(-beatPos * 18)
                phases[6] += 2 * Double.pi * (48 + 90 * kickEnv) / sr
                s += 0.45 * kickEnv * sin(phases[6])
                // pink bed + hats
                let white = rng.nextGaussian()
                pink[0] = 0.99886 * pink[0] + white * 0.0555179
                pink[1] = 0.99332 * pink[1] + white * 0.0750759
                pink[2] = 0.96900 * pink[2] + white * 0.1538520
                pink[3] = 0.86650 * pink[3] + white * 0.3104856
                pink[4] = 0.55000 * pink[4] + white * 0.5329522
                pink[5] = -0.7616 * pink[5] - white * 0.0168980
                let p = (pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362) * 0.11
                pink[6] = white * 0.115926
                let hat = exp(-eighth * 40) * (white - pink[4]) * 0.05
                s += p * 0.03 + hat
                out[i] = Float(s * 0.7)
            }
            engine.ingestMono(out.baseAddress!, frames: block)
        }
        t += block
    }
}
