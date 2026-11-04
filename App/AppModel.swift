import AppKit
import Combine
import SpectreCore

/// Values shown as text (always from the raw FFT, never from the visual simulation).
struct Readout: Equatable {
    var hasSignal = false
    var peaks: [Peak] = []
    var rmsDB: Float = -200
    var samplePeakDB: Float = -200
    var truePeakDB: Float = -200
}

final class ReadoutStore: ObservableObject {
    @Published var readout = Readout()
    @Published var nowPlaying: String?
}

/// Central coordinator: capture ↔ analysis ↔ rendering ↔ energy policy.
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let engine = AnalysisEngine()
    let capture: CaptureController
    let scheduler = FrameScheduler()
    let power = PowerMonitor()
    let ctx = RenderContext.shared
    let wallpaper = WallpaperController()
    private(set) var windowView: SpectrumMetalView?

    @Published private(set) var status: CaptureController.Status = .idle
    /// Fast-changing values live in their own store so that only the text views redraw.
    let live = ReadoutStore()
    var readout: Readout { live.readout }
    var nowPlaying: String? { live.nowPlaying }
    @Published private(set) var windowLevel: QualityLevel = .high
    @Published private(set) var wallpaperLevel: QualityLevel = .medium
    @Published private(set) var analysisDescription = ""

    private var cancellables: Set<AnyCancellable> = []
    private var applyScheduled = false

    init() {
        capture = CaptureController(engine: engine)
        engine.onFrame = { [weak scheduler] in scheduler?.analysisFrameReady() }
        scheduler.onDemandChanged = { [weak self] active, _ in
            self?.capture.demand = active
            self?.updateAnalyzer()
        }
        scheduler.onReadoutTick = { [weak self] in self?.refreshReadout() }
        capture.onStatusChange = { [weak self] s in self?.status = s }
        capture.onRunningChange = { [weak self] running in
            guard let self else { return }
            self.scheduler.captureRunning = running
            self.updateActivity()
            if running { self.engine.stopSilenceFeed() } else { self.engine.startSilenceFeed() }
            self.refreshReadout()
        }
        capture.onSampleRateChange = { [weak self] _ in self?.updateAnalyzer() }
        capture.onNowPlayingChange = { [weak self] t in self?.live.nowPlaying = t }
        live.nowPlaying = capture.spotify.nowPlaying
        power.onChange = { [weak self] in
            guard let self else { return }
            self.scheduler.suspended = self.power.suspended
            self.applySettings()
        }
        settings.objectWillChange
            .sink { [weak self] _ in self?.scheduleApply() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.status == .permissionDenied { self?.capture.retryPermission() }
        }

        wallpaper.model = self
        if let ctx {
            let v = SpectrumMetalView(role: .window, ctx: ctx, snapshot: engine.snapshot)
            v.plotInsets = MainLayout.plotInsets
            windowView = v
            scheduler.add(v)
        }
        engine.start()
        applySettings()
        capture.reevaluate()
    }

    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyScheduled = false
            self?.applySettings()
        }
    }

    // MARK: - Policy

    private func computeLevels() {
        let economy = settings.economyOnBattery && power.prefersEconomy
        switch settings.quality {
        case .auto:
            windowLevel = economy ? .economy : .high
            wallpaperLevel = economy ? .economy : .medium
        case .high: windowLevel = .high; wallpaperLevel = .high
        case .medium: windowLevel = .medium; wallpaperLevel = .medium
        case .economy: windowLevel = .economy; wallpaperLevel = .economy
        }
    }

    static func fps(_ level: QualityLevel, wallpaper: Bool) -> Double {
        if level == .economy { return 20 }
        return wallpaper ? 30 : 60
    }

    func fftSizes(for level: QualityLevel) -> [Int] {
        let n = settings.fftSize
        switch level {
        case .high:
            return settings.multiResolution ? [n, max(n / 4, 1024), max(n / 16, 512)] : [n]
        case .medium:
            let m = min(n, 16384)
            return settings.multiResolution ? [m, max(m / 4, 1024)] : [min(n, 8192)]
        case .economy:
            return [4096]
        }
    }

    static func displayBins(_ level: QualityLevel) -> Int {
        switch level {
        case .high: return 512
        case .medium: return 384
        case .economy: return 256
        }
    }

    /// Precision follows the most demanding visible view.
    /// Prevents App Nap from throttling timers and the main queue only while a
    /// visible spectrum is actually animated; released as soon as it rests.
    private var activity: NSObjectProtocol?

    private func updateActivity() {
        let needed = capture.isRunning && scheduler.demand.0
        if needed && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Visualisation audio en temps réel")
        } else if !needed, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    func updateAnalyzer() {
        updateActivity()
        let windowActive = (windowView?.isOnScreen ?? false) && !scheduler.suspended
        let level = windowActive ? windowLevel : wallpaperLevel
        let fps = max(scheduler.demand.1, 20)
        let sr = capture.sampleRate
        let cfg = AnalyzerConfiguration(sampleRate: sr, fftSizes: fftSizes(for: level), window: settings.window,
                                        displayBins: Self.displayBins(level), hop: Int((sr / fps).rounded()),
                                        truePeak: settings.truePeak)
        if cfg != engine.configuration { engine.setConfiguration(cfg) }
        let sizes = cfg.fftSizes.map { "\($0)" }.joined(separator: "/")
        analysisDescription = "FFT \(sizes) · \(Int(sr)) Hz · \(Int(fps)) i/s · \(level.label)"
    }

    func applySettings() {
        computeLevels()
        let s = settings
        engine.attack = s.attackMS / 1000
        engine.release = s.releaseMS / 1000
        engine.peakHoldTime = 1.0
        if engine.snapshot.scale != s.scale { engine.setScale(s.scale) }

        if let v = windowView {
            var st = v.renderer.style
            st.mode = s.mode
            st.theme = s.theme
            st.fluidity = Float(s.fluidity)
            st.opacity = 1
            st.showHold = s.peakHold
            st.scale = s.scale
            st.quality = RenderQuality.profile(windowLevel, wallpaper: false)
            st.heightScale = 0.92
            v.renderer.style = st
            v.targetFPS = Self.fps(windowLevel, wallpaper: false)
            v.updateDrawableSize()
        }
        wallpaper.apply(settings: s, level: wallpaperLevel)
        capture.demoMode = s.demoMode
        updateAnalyzer()
        scheduler.requestFrame()
    }

    // MARK: - Read-outs

    /// Text is only refreshed when somebody can read it (window visible or wallpaper text shown).
    var textVisible: Bool {
        let s = settings
        let wallpaperText = s.wallpaperEnabled && (s.wallpaperShowFrequency || s.wallpaperShowNote || s.wallpaperShowTitle)
            && (wallpaper.view?.isOnScreen ?? false)
        return (windowView?.isOnScreen ?? false) || wallpaperText
    }

    func refreshReadout() {
        if !textVisible && readout.hasSignal == false { return }
        let snap = engine.snapshot
        snap.lock.lock()
        var r = Readout()
        r.hasSignal = !snap.isSilent && capture.isRunning
        // Quantised to the displayed precision: SwiftUI only redraws when the text changes.
        func q(_ v: Float) -> Float { (v * 10).rounded() / 10 }
        r.peaks = snap.peaks.prefix(snap.peakCount).map {
            Peak(frequency: ($0.frequency * 100).rounded() / 100, levelDB: q($0.levelDB))
        }
        r.rmsDB = q(snap.rmsDB)
        r.samplePeakDB = q(snap.samplePeakDB)
        r.truePeakDB = q(snap.truePeakDB)
        snap.lock.unlock()
        if !r.hasSignal { r.peaks = [] }
        if !textVisible { r = Readout() }
        if r != live.readout { live.readout = r }
    }

    func shutdown() {
        capture.shutdown()
        engine.stopSilenceFeed()
        engine.stop()
    }
}
