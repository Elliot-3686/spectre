import AppKit
import QuartzCore

/// Drives every spectrum view. No fixed display timer:
/// * while audio flows, frames are triggered by the analysis thread (one per hop);
/// * when audio stops, a coalesced timer runs only until the matter is at rest;
/// * at rest, nothing runs at all (0 fps).
final class FrameScheduler {
    private let views = NSHashTable<SpectrumMetalView>.weakObjects()
    private let pendingLock = NSLock()
    private var pending = false
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0

    /// (some view needs audio, highest fps wanted)
    var onDemandChanged: ((Bool, Double) -> Void)?
    /// Called at most 4×/s on the main thread while frames are drawn (read-outs).
    var onReadoutTick: (() -> Void)?
    private var lastReadout: CFTimeInterval = 0

    var captureRunning = false { didSet { if captureRunning != oldValue { updateTimer() } } }
    /// Screen locked, asleep, screensaver…
    var suspended = false { didSet { if suspended != oldValue { visibilityChanged() } } }

    private(set) var framesDrawn: UInt64 = 0

    func add(_ v: SpectrumMetalView) {
        views.add(v)
        v.scheduler = self
        visibilityChanged()
    }

    func remove(_ v: SpectrumMetalView) {
        views.remove(v)
        visibilityChanged()
    }

    var activeViews: [SpectrumMetalView] {
        suspended ? [] : views.allObjects.filter { $0.isOnScreen && $0.targetFPS > 0 }
    }

    var demand: (Bool, Double) {
        let a = activeViews
        return (!a.isEmpty, a.map(\.targetFPS).max() ?? 0)
    }

    func visibilityChanged() {
        let d = demand
        onDemandChanged?(d.0, d.1)
        updateTimer()
        if d.0 { requestFrame() }
    }

    /// From the analysis thread: coalesce into one main-thread tick.
    func analysisFrameReady() {
        pendingLock.lock()
        if pending { pendingLock.unlock(); return }
        pending = true
        pendingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock(); self.pending = false; self.pendingLock.unlock()
            self.tick(newData: true)
        }
    }

    /// Style/size change: draw once and let the settle timer take over if needed.
    func requestFrame() {
        for v in views.allObjects { v.renderer.markActive() }
        DispatchQueue.main.async { [weak self] in
            self?.tick(newData: true)
            self?.updateTimer()
        }
    }

    private func tick(newData: Bool) {
        let now = CACurrentMediaTime()
        var drew = false
        for v in activeViews where v.wantsFrame(at: now, newData: newData) {
            v.renderFrame(now: now)
            drew = true
            framesDrawn &+= 1
        }
        if drew, now - lastReadout > 0.25 {
            lastReadout = now
            onReadoutTick?()
        }
        if !newData || !captureRunning { updateTimer() }
    }

    /// Settle timer: only when audio is not driving frames and something still moves.
    private func updateTimer() {
        let active = activeViews
        let needs = !captureRunning && active.contains { !$0.renderer.isAtRest }
        if needs {
            let fps = active.map(\.targetFPS).max() ?? 30
            let interval = 1.0 / max(fps, 1)
            if timer == nil || abs(interval - timerInterval) > 1e-4 {
                timer?.cancel()
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 1000 * 0.15) + 1))
                t.setEventHandler { [weak self] in self?.tick(newData: false) }
                t.resume()
                timer = t
                timerInterval = interval
            }
        } else if let t = timer {
            t.cancel()
            timer = nil
            onReadoutTick?()
        }
    }

    var isTimerRunning: Bool { timer != nil }
}
