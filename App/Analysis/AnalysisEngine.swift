import Foundation
import SpectreCore

/// Latest analysis, shared between the analysis thread and the renderers.
/// Fixed storage; readers copy what they need under the lock.
final class SpectrumSnapshot {
    let lock = NSLock()
    static let maxBins = 512

    private(set) var binCount = 512
    private(set) var frequencies: [Double] = []
    private(set) var tilts: [Float] = []
    let raw = FloatBuffer(SpectrumSnapshot.maxBins, value: -200)
    let smoothed = FloatBuffer(SpectrumSnapshot.maxBins, value: -200)
    let hold = FloatBuffer(SpectrumSnapshot.maxBins, value: -200)
    let bands = FloatBuffer(ISOBands.count, value: -200)
    let bandsSmoothed = FloatBuffer(ISOBands.count, value: -200)
    let bandsHold = FloatBuffer(ISOBands.count, value: -200)
    var peaks = [Peak](repeating: Peak(), count: 5)
    var peakCount = 0
    var rmsDB: Float = -200
    var samplePeakDB: Float = -200
    var truePeakDB: Float = -200
    var isSilent = true
    /// True once the smoothed curves have fully decayed too.
    var isAtRest = true
    var sequence: UInt64 = 0
    var sampleRate: Double = 48000
    var scale = SpectrumScale()

    /// Called under lock by the engine when the configuration changes (allocation allowed).
    func configure(frequencies f: [Double], sampleRate sr: Double, scale s: SpectrumScale) {
        binCount = f.count
        frequencies = f
        tilts = s.tilts(for: f)
        sampleRate = sr
        scale = s
    }

    /// Level (dBFS) at an arbitrary frequency, from the raw FFT data (hover read-out).
    func rawLevel(at frequency: Double) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard binCount > 1, let first = frequencies.first, let last = frequencies.last, frequency >= first, frequency <= last else { return nil }
        let u = log(frequency / first) / log(last / first) * Double(binCount - 1)
        let i = min(Int(u), binCount - 2)
        let t = Float(u - Double(i))
        return raw[i] + (raw[i + 1] - raw[i]) * t
    }
}

/// Dedicated analysis thread. Woken by the capture callback through a
/// semaphore (no polling); runs the FFT only when a full hop is available.
final class AnalysisEngine: @unchecked Sendable {
    let ring = AudioRingBuffer(capacity: 1 << 17)
    let snapshot = SpectrumSnapshot()

    /// Read by the real-time thread to decide when to signal (benign race on a word).
    private(set) var hop: Int = 800

    private let semaphore = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private var running = false
    private let configLock = NSLock()
    private var pending: AnalyzerConfiguration?
    private var pendingScale: SpectrumScale?
    private var analyzer: SpectrumAnalyzer
    private var smoother: SpectrumSmoother
    private var bandSmoother: SpectrumSmoother
    private var scale = SpectrumScale()
    private let scratch = FloatBuffer(16384)

    var attack: Double = 0.015
    var release: Double = 0.30
    var peakHoldTime: Double = 1.0

    /// Counters (diagnostics; benign races).
    private(set) var samplesProcessed: UInt64 = 0
    private(set) var framesPublished: UInt64 = 0

    /// Called on the analysis thread after each published frame.
    var onFrame: (() -> Void)?

    private(set) var configuration: AnalyzerConfiguration
    /// Mean analysis cost per frame (µs), for diagnostics.
    private(set) var averageFrameMicros: Double = 0

    init(configuration: AnalyzerConfiguration = AnalyzerConfiguration()) {
        self.configuration = configuration
        analyzer = SpectrumAnalyzer(configuration: configuration)
        smoother = SpectrumSmoother(count: configuration.displayBins)
        bandSmoother = SpectrumSmoother(count: ISOBands.count)
        hop = configuration.hop
        snapshot.lock.lock()
        snapshot.configure(frequencies: analyzer.displayFrequencies, sampleRate: configuration.sampleRate, scale: scale)
        snapshot.lock.unlock()
    }

    // MARK: Real-time producer side

    /// Real-time safe: lock-free copy + at most one semaphore signal per hop.
    @inline(__always)
    func ingestMono(_ samples: UnsafePointer<Float>, frames: Int) {
        if ring.write(samples, count: frames, threshold: hop) { semaphore.signal() }
    }

    @inline(__always)
    func ingestInterleaved(_ samples: UnsafePointer<Float>, channels: Int, frames: Int) {
        if ring.writeInterleavedMix(samples, channels: channels, frames: frames, threshold: hop) { semaphore.signal() }
    }

    // MARK: Control

    func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "Spectre.analysis"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        running = false
        semaphore.signal()
        thread = nil
    }

    func setConfiguration(_ c: AnalyzerConfiguration) {
        configLock.lock()
        pending = c
        hop = c.hop
        configLock.unlock()
        semaphore.signal()
    }

    func setScale(_ s: SpectrumScale) {
        configLock.lock()
        pendingScale = s
        configLock.unlock()
        snapshot.lock.lock()
        snapshot.configure(frequencies: snapshot.frequencies, sampleRate: snapshot.sampleRate, scale: s)
        snapshot.lock.unlock()
    }

    /// Discards buffered audio (capture restart).
    func flush() {
        let n = ring.available
        ring.skip(n)
        configLock.lock()
        if pending == nil { pending = configuration }
        configLock.unlock()
        semaphore.signal()
    }

    // MARK: Silence feed (lets the visuals decay naturally after a stop)

    private var silenceTimer: DispatchSourceTimer?
    private let zeros = FloatBuffer(4800)

    /// After the capture stops, feeds digital silence at real-time rate through
    /// the normal pipeline until the smoothed spectrum has fully decayed.
    func startSilenceFeed() {
        guard silenceTimer == nil else { return }
        let q = DispatchQueue(label: "Spectre.silence", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.snapshot.lock.lock()
            let rest = self.snapshot.isAtRest
            let sr = self.snapshot.sampleRate
            self.snapshot.lock.unlock()
            if rest { self.stopSilenceFeed(); return }
            self.ingestMono(self.zeros.pointer, frames: min(Int(sr * 0.02), self.zeros.count))
        }
        silenceTimer = t
        t.resume()
    }

    func stopSilenceFeed() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    /// Synchronous processing on the caller's thread (snapshots / benchmarks only;
    /// the analysis thread must not be running).
    func processSynchronously(_ samples: UnsafePointer<Float>, count: Int, onFrame: () -> Void) {
        applyPending()
        let h = analyzer.configuration.hop
        var offset = 0
        while offset < count {
            let n = min(h, count - offset)
            let frames = analyzer.process(samples + offset, count: n)
            if frames > 0 {
                publish(dt: Double(h) / analyzer.configuration.sampleRate * Double(frames))
                onFrame()
            }
            offset += n
        }
    }

    // MARK: Thread

    private func applyPending() {
        configLock.lock()
        let c = pending
        pending = nil
        if let s = pendingScale { scale = s; pendingScale = nil }
        configLock.unlock()
        guard let c else { return }
        configuration = c
        analyzer = SpectrumAnalyzer(configuration: c)
        if smoother.count != c.displayBins { smoother = SpectrumSmoother(count: c.displayBins) }
        snapshot.lock.lock()
        snapshot.configure(frequencies: analyzer.displayFrequencies, sampleRate: c.sampleRate, scale: scale)
        snapshot.lock.unlock()
    }

    private func loop() {
        while running {
            semaphore.wait()
            if !running { break }
            applyPending()
            ring.clearNotify()
            let h = analyzer.configuration.hop
            while ring.available >= h {
                // Too far behind (e.g. after a stall): keep only the freshest audio.
                if ring.available > h * 8 { ring.skip(ring.available - h * 2) }
                let n = ring.read(into: scratch.pointer, count: min(ring.available, scratch.count))
                let t0 = DispatchTime.now().uptimeNanoseconds
                let frames = analyzer.process(scratch.pointer, count: n)
                samplesProcessed &+= UInt64(n)
                if frames > 0 {
                    framesPublished &+= UInt64(frames)
                    publish(dt: Double(h) / analyzer.configuration.sampleRate * Double(frames))
                    let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000 / Double(frames)
                    averageFrameMicros = averageFrameMicros * 0.98 + us * 0.02
                    onFrame?()
                }
            }
        }
    }

    private func publish(dt: Double) {
        let r = analyzer.result
        smoother.attack = attack; smoother.release = release; smoother.holdTime = peakHoldTime
        bandSmoother.attack = attack; bandSmoother.release = release; bandSmoother.holdTime = peakHoldTime
        smoother.update(UnsafePointer(r.display.pointer), dt: dt)
        bandSmoother.update(UnsafePointer(r.bands.pointer), dt: dt)
        let n = r.display.count
        let floor = scale.floorDB - 25
        let rest = r.isSilent && smoother.isAtRest(below: floor) && bandSmoother.isAtRest(below: floor)

        let s = snapshot
        s.lock.lock()
        s.raw.pointer.update(from: r.display.pointer, count: n)
        s.smoothed.pointer.update(from: smoother.smoothed.pointer, count: n)
        s.hold.pointer.update(from: smoother.hold.pointer, count: n)
        s.bands.pointer.update(from: r.bands.pointer, count: ISOBands.count)
        s.bandsSmoothed.pointer.update(from: bandSmoother.smoothed.pointer, count: ISOBands.count)
        s.bandsHold.pointer.update(from: bandSmoother.hold.pointer, count: ISOBands.count)
        s.peakCount = min(r.peakCount, s.peaks.count)
        for i in 0..<s.peakCount { s.peaks[i] = r.peaks[i] }
        s.rmsDB = r.rmsDB
        s.samplePeakDB = r.samplePeakDB
        s.truePeakDB = r.truePeakDB
        s.isSilent = r.isSilent
        s.isAtRest = rest
        s.sequence &+= 1
        s.lock.unlock()
    }
}
