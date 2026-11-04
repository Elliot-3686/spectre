import AppKit
import CoreAudio
import SpectreCore

/// State machine of the capture: waits for Spotify, starts/stops the tap when
/// Spotify plays/pauses or when nobody looks at the spectrum, reconnects
/// automatically. Everything is driven by notifications and Core Audio
/// property listeners — never by polling.
final class CaptureController {
    enum Status: Equatable {
        case idle
        case waitingForSpotify
        case spotifyPaused
        case capturing
        case permissionDenied
        case demo
        case error(String)

        var message: String {
            switch self {
            case .idle: return "En pause"
            case .waitingForSpotify: return "En attente de Spotify…"
            case .spotifyPaused: return "Spotify est en pause"
            case .capturing: return "Analyse de Spotify"
            case .permissionDenied: return "Autorisation audio refusée"
            case .demo: return "Mode démo (signal de synthèse)"
            case let .error(m): return "Erreur de capture : \(m)"
            }
        }
    }

    enum Backend: String { case processTap = "Core Audio process tap", screenCaptureKit = "ScreenCaptureKit", demo = "Démo" }

    private let engine: AnalysisEngine
    let spotify = SpotifyMonitor()

    private(set) var status: Status = .idle { didSet { if status != oldValue { onStatusChange?(status) } } }
    private(set) var isRunning = false { didSet { if isRunning != oldValue { onRunningChange?(isRunning) } } }
    private(set) var sampleRate: Double = 48000 { didSet { if sampleRate != oldValue { onSampleRateChange?(sampleRate) } } }
    private(set) var backend: Backend?

    var onStatusChange: ((Status) -> Void)?
    var onRunningChange: ((Bool) -> Void)?
    var onSampleRateChange: ((Double) -> Void)?
    var onNowPlayingChange: ((String?) -> Void)?

    /// Somebody is looking at a spectrum (window or wallpaper visible, screen unlocked).
    var demand = false { didSet { if demand != oldValue { reevaluate() } } }
    var demoMode = false { didSet { if demoMode != oldValue { reevaluate() } } }

    private var tapObject: AnyObject?
    private var sck: ScreenCaptureAudio?
    private var demo: DemoSource?
    private var listeners: [CAListener] = []
    private var processListeners: [CAListener] = []
    private var permissionRequested = false
    private var sckStarting = false

    static var supportsProcessTap: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    init(engine: AnalysisEngine) {
        self.engine = engine
        spotify.onChange = { [weak self] in
            guard let self else { return }
            self.onNowPlayingChange?(self.spotify.nowPlaying)
            self.reevaluate()
        }
        if #available(macOS 14.2, *) {
            if let l = CAListener(object: CA.system, selector: kAudioHardwarePropertyProcessObjectList, handler: { [weak self] in
                self?.refreshProcessListeners()
                self?.reevaluate()
            }) { listeners.append(l) }
            if let l = CAListener(object: CA.system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, handler: { [weak self] in
                self?.restartTap()
            }) { listeners.append(l) }
            refreshProcessListeners()
        }
    }

    // MARK: - Decision

    func reevaluate() {
        if demoMode {
            stopReal()
            if demand {
                if demo == nil { demo = DemoSource(engine: engine) }
                if demo?.isRunning == false {
                    sampleRate = demo!.sampleRate
                    engine.flush()
                    demo?.start()
                }
                backend = .demo
                isRunning = true
            } else {
                demo?.stop()
                isRunning = false
            }
            status = .demo
            return
        }
        demo?.stop()

        guard spotify.isRunning || spotifyProcesses().count > 0 else {
            stopReal(); status = .waitingForSpotify; return
        }
        guard spotifyIsPlaying else {
            stopReal(); status = .spotifyPaused; return
        }
        guard demand else {
            stopReal(); status = .idle; return
        }

        if Self.supportsProcessTap {
            switch AudioCapturePermission.status() {
            case .denied:
                stopReal(); status = .permissionDenied; return
            case .unknown where !permissionRequested:
                permissionRequested = true
                AudioCapturePermission.request { [weak self] granted in
                    if !granted { self?.status = .permissionDenied }
                    self?.reevaluate()
                }
                return
            default: break
            }
            startTapIfNeeded()
        } else {
            startSCKIfNeeded()
        }
    }

    private var spotifyIsPlaying: Bool {
        switch spotify.state {
        case .playing: return true
        case .paused, .stopped: return false
        case .unknown:
            // No notification yet: ask Core Audio whether Spotify is producing sound.
            if #available(macOS 14.2, *) {
                let procs = spotifyProcesses()
                if procs.isEmpty { return false }
                return procs.contains { CA.isRunningOutput($0) }
            }
            return spotify.isRunning
        }
    }

    private func spotifyProcesses() -> [AudioObjectID] {
        if #available(macOS 14.2, *) { return CA.processObjects(bundlePrefix: SpotifyMonitor.bundleID) }
        return []
    }

    // MARK: - Process tap

    private func startTapIfNeeded() {
        guard #available(macOS 14.2, *) else { return }
        let procs = spotifyProcesses()
        guard !procs.isEmpty else {
            stopReal(); status = .waitingForSpotify; return
        }
        let tap = (tapObject as? ProcessTapCapture) ?? ProcessTapCapture(engine: engine)
        tapObject = tap
        if tap.isRunning && Set(tap.processes) == Set(procs) {
            status = .capturing
            return
        }
        do {
            engine.flush()
            try tap.start(processes: procs)
            sampleRate = tap.sampleRate
            backend = .processTap
            isRunning = true
            status = .capturing
        } catch {
            tap.stop()
            isRunning = false
            // The tap fails with a permission error when access was refused.
            if AudioCapturePermission.status() == .denied {
                status = .permissionDenied
            } else {
                status = .error("\(error)")
            }
        }
    }

    private func restartTap() {
        guard #available(macOS 14.2, *), let tap = tapObject as? ProcessTapCapture, tap.isRunning else { return }
        tap.stop()
        isRunning = false
        reevaluate()
    }

    private func refreshProcessListeners() {
        guard #available(macOS 14.2, *) else { return }
        processListeners = spotifyProcesses().compactMap { obj in
            CAListener(object: obj, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in self?.reevaluate() }
        }
    }

    // MARK: - ScreenCaptureKit fallback

    private func startSCKIfNeeded() {
        if sck?.isRunning == true { status = .capturing; return }
        guard !sckStarting else { return }
        if !ScreenCaptureAudio.hasPermission {
            if !permissionRequested {
                permissionRequested = true
                _ = ScreenCaptureAudio.requestPermission()
            }
            if !ScreenCaptureAudio.hasPermission { status = .permissionDenied; return }
        }
        let s = sck ?? ScreenCaptureAudio(engine: engine)
        s.onError = { [weak self] msg in
            self?.isRunning = false
            self?.status = .error(msg)
        }
        sck = s
        sckStarting = true
        engine.flush()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await s.start(bundleID: SpotifyMonitor.bundleID)
                self.sampleRate = s.sampleRate
                self.backend = .screenCaptureKit
                self.isRunning = true
                self.status = .capturing
            } catch {
                self.status = .error(error.localizedDescription)
            }
            self.sckStarting = false
        }
    }

    // MARK: - Stop

    private func stopReal() {
        if #available(macOS 14.2, *), let tap = tapObject as? ProcessTapCapture { tap.stop() }
        sck?.stop()
        if demo?.isRunning != true { isRunning = false }
    }

    func shutdown() {
        stopReal()
        demo?.stop()
        isRunning = false
    }

    func openPermissionSettings() {
        if !NSWorkspace.shared.open(AudioCapturePermission.settingsURL) {
            NSWorkspace.shared.open(AudioCapturePermission.fallbackSettingsURL)
        }
    }

    /// Lets the user retry after granting the permission in System Settings.
    func retryPermission() {
        permissionRequested = false
        reevaluate()
    }
}
