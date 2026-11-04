import AppKit
import Metal
import QuartzCore
import SpectreCore

// MARK: - CPU sampling

enum CPUClock {
    /// User + system CPU time of this process, in seconds.
    static func processTime() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
             + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func wakeups() -> (interrupt: UInt64, idle: UInt64) {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return (0, 0) }
        return (info.ri_interrupt_wkups, info.ri_pkg_idle_wkups)
    }

    static func energyNanojoules() -> UInt64 {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? info.ri_energy_nj : 0
    }
}

/// Measures one phase of activity (CPU %, frames/s, wake-ups/s).
final class PhaseMeter {
    private let t0 = CACurrentMediaTime()
    private let c0 = CPUClock.processTime()
    private let w0 = CPUClock.wakeups()
    private let e0 = CPUClock.energyNanojoules()
    private let f0: UInt64

    init(frames: UInt64) { f0 = frames }

    func finish(frames: UInt64) -> (cpu: Double, fps: Double, wakeups: Double, watts: Double, seconds: Double) {
        let dt = CACurrentMediaTime() - t0
        let cpu = (CPUClock.processTime() - c0) / dt * 100
        let w = CPUClock.wakeups()
        let wake = Double((w.interrupt - w0.interrupt)) / dt
        let e = CPUClock.energyNanojoules()
        let watts = e > e0 ? Double(e - e0) / 1e9 / dt : 0
        return (cpu, Double(frames - f0) / dt, wake, watts, dt)
    }
}

// MARK: - Offscreen rendering helpers

enum Offscreen {
    static func makeTarget(_ ctx: RenderContext, width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.colorFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        return ctx.device.makeTexture(descriptor: d)!
    }

    static func pass(_ tex: MTLTexture) -> MTLRenderPassDescriptor {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        return rp
    }

    static func readPixels(_ ctx: RenderContext, _ tex: MTLTexture) -> [UInt8] {
        if let cb = ctx.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
        bytes.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        }
        return bytes
    }

    static func writePNG(_ bgra: [UInt8], width: Int, height: Int, to url: URL) {
        let data = Data(bgra) as CFData
        guard let provider = CGDataProvider(data: data),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Simple image statistics used to validate the art direction automatically.
    static func stats(_ bgra: [UInt8], width: Int, height: Int) -> String {
        var sumL = 0.0, bright = 0, maxSat = 0.0, n = 0
        var corner = 0.0, cornerN = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                let b = Double(bgra[i]) / 255, g = Double(bgra[i + 1]) / 255, r = Double(bgra[i + 2]) / 255
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sumL += l
                let mx = max(r, g, b), mn = min(r, g, b)
                if mx > 0.92 { bright += 1 }
                if mx > 0.25 { maxSat = max(maxSat, (mx - mn) / mx) }
                if y < height / 8 && x < width / 8 { corner += l; cornerN += 1 }
                n += 1
                x += 2
            }
            y += 2
        }
        return String(format: "luminance moyenne %.3f · fond (coin) %.3f · pixels quasi blancs %.4f %% · saturation max %.2f",
                      sumL / Double(n), corner / Double(max(cornerN, 1)), Double(bright) / Double(n) * 100, maxSat)
    }
}

// MARK: - Snapshots (every mode × theme × test signal)

enum SnapshotTool {
    static func run(outputDirectory: String) -> Int32 {
        guard let ctx = RenderContext.shared else {
            print("ERREUR : Metal indisponible")
            return 2
        }
        print("GPU : \(ctx.device.name)")
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sr = 48000.0
        let n = Int(sr * 2.5)
        let signals: [(String, [Float])] = [
            ("silence", [Float](repeating: 0, count: Int(sr * 1.5))),
            ("sinus100", SignalGenerator.sine(frequency: 100, amplitude: 0.5, sampleRate: sr, count: n)),
            ("bruitrose", SignalGenerator.pinkNoise(count: n, amplitude: 0.12)),
            ("balayage", SignalGenerator.logSweep(from: 20, to: 20000, duration: 4, sampleRate: sr, amplitude: 0.4)),
            ("accord", SignalGenerator.sum([
                SignalGenerator.chord([55, 110, 220, 261.63, 329.63, 440, 1318.5, 3520, 7040], amplitude: 0.06, sampleRate: sr, count: n),
                SignalGenerator.pinkNoise(count: n, amplitude: 0.03),
            ])),
        ]
        var jobs: [(VisualMode, ThemeKind, String, [Float])] = []
        for mode in VisualMode.allCases { for s in signals { jobs.append((mode, .sobre, s.0, s.1)) } }
        for theme in [ThemeKind.monochrome, .braise] {
            for mode in VisualMode.allCases { for s in signals where s.0 == "accord" || s.0 == "bruitrose" { jobs.append((mode, theme, s.0, s.1)) } }
        }
        var statsText = "# Statistiques des captures\n\n"
        let w = 1280, h = 720
        for (mode, theme, name, signal) in jobs {
            let engine = AnalysisEngine(configuration: AnalyzerConfiguration(sampleRate: sr, fftSizes: [32768, 8192, 2048], hop: 800))
            let renderer = SpectrumRenderer(ctx: ctx)
            var st = VisualStyle()
            st.mode = mode
            st.theme = theme
            st.fluidity = 0.6
            st.showHold = true
            st.quality = RenderQuality.profile(.high, wallpaper: false)
            st.plotL = 0.03; st.plotR = 0.97; st.plotB = 0.05; st.plotT = 0.95
            st.heightScale = 0.9
            renderer.style = st
            let tex = Offscreen.makeTarget(ctx, width: w, height: h)
            let base = CACurrentMediaTime()
            var frame = 0
            signal.withUnsafeBufferPointer { buf in
                engine.processSynchronously(buf.baseAddress!, count: buf.count) {
                    frame += 1
                    renderer.draw(snapshot: engine.snapshot, passDescriptor: Offscreen.pass(tex), drawable: nil,
                                  size: CGSize(width: w, height: h), pixelScale: 1, now: base + Double(frame) / 60)
                }
            }
            frame += 1
            renderer.draw(snapshot: engine.snapshot, passDescriptor: Offscreen.pass(tex), drawable: nil,
                          size: CGSize(width: w, height: h), pixelScale: 1, now: base + Double(frame) / 60, waitUntilCompleted: true)
            let px = Offscreen.readPixels(ctx, tex)
            let file = "\(mode.rawValue)_\(theme.rawValue)_\(name).png"
            Offscreen.writePNG(px, width: w, height: h, to: dir.appendingPathComponent(file))
            let line = "- \(file) : \(Offscreen.stats(px, width: w, height: h))"
            statsText += line + "\n"
            print(line)
        }
        try? statsText.write(to: dir.appendingPathComponent("stats.md"), atomically: true, encoding: .utf8)
        return 0
    }
}

// MARK: - Benchmark (analysis CPU + GPU cost of each mode)

enum BenchmarkTool {
    static func run(reportPath: String) -> Int32 {
        var out = "# Banc d'essai Spectre\n\n"
        out += "Machine : \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) cœurs\n\n"
        let sr = 48000.0
        let music = SignalGenerator.sum([
            SignalGenerator.pinkNoise(count: Int(sr * 6), amplitude: 0.05),
            SignalGenerator.chord([55, 110, 220, 277.18, 329.63, 880, 1760, 3520], amplitude: 0.07, sampleRate: sr, count: Int(sr * 6)),
        ])

        out += "## Analyse (CPU, 1 cœur)\n\n| Profil | FFT | i/s | µs / trame | % d'un cœur |\n|---|---|---|---|---|\n"
        let profiles: [(String, [Int], Int, Double)] = [
            ("Haut (fenêtre)", [32768, 8192, 2048], 512, 60),
            ("Moyen (fond d'écran)", [16384, 4096], 384, 30),
            ("Économie", [4096], 256, 20),
        ]
        for (name, sizes, bins, fps) in profiles {
            let engine = AnalysisEngine(configuration: AnalyzerConfiguration(sampleRate: sr, fftSizes: sizes, displayBins: bins, hop: Int(sr / fps)))
            var frames = 0
            let t0 = CACurrentMediaTime()
            music.withUnsafeBufferPointer { engine.processSynchronously($0.baseAddress!, count: $0.count) { frames += 1 } }
            let us = (CACurrentMediaTime() - t0) * 1e6 / Double(max(frames, 1))
            out += String(format: "| %@ | %@ | %.0f | %.1f | %.2f %% |\n", name, sizes.map(String.init).joined(separator: "/"), fps, us, us * fps / 1e4)
        }

        guard let ctx = RenderContext.shared else {
            out += "\nMetal indisponible : pas de mesure GPU.\n"
            try? out.write(toFile: reportPath, atomically: true, encoding: .utf8)
            print(out)
            return 0
        }
        out += "\n## Rendu (GPU : \(ctx.device.name))\n\n"
        out += "| Mode | Contexte | Pixels | GPU ms / image | i/s | Occupation GPU | CPU encodage µs |\n|---|---|---|---|---|---|---|\n"
        let contexts: [(String, QualityLevel, Bool, Int, Int)] = [
            ("Fenêtre, Haut", .high, false, 2240, 1280),
            ("Fond d'écran, Moyen", .medium, true, 2560, 1440),
            ("Fond d'écran, Économie", .economy, true, 1728, 1117),
        ]
        for mode in VisualMode.allCases {
            for (cname, level, wallpaper, w, h) in contexts {
                let engine = AnalysisEngine(configuration: AnalyzerConfiguration(sampleRate: sr, fftSizes: [16384, 4096], displayBins: AppModel.displayBins(level), hop: 800))
                let r = SpectrumRenderer(ctx: ctx)
                var st = VisualStyle()
                st.mode = mode
                st.quality = RenderQuality.profile(level, wallpaper: wallpaper)
                st.heightScale = wallpaper ? 0.55 : 0.92
                r.style = st
                let tex = Offscreen.makeTarget(ctx, width: w, height: h)
                var gpu = 0.0, cpu = 0.0, count = 0
                let base = CACurrentMediaTime()
                var frame = 0
                music.withUnsafeBufferPointer { buf in
                    engine.processSynchronously(buf.baseAddress!, count: min(buf.count, Int(sr * 4))) {
                        frame += 1
                        let c0 = CACurrentMediaTime()
                        r.draw(snapshot: engine.snapshot, passDescriptor: Offscreen.pass(tex), drawable: nil,
                               size: CGSize(width: w, height: h), pixelScale: 2 * Float(st.quality.renderScale),
                               now: base + Double(frame) / 60, waitUntilCompleted: true)
                        if frame > 30 {
                            cpu += (CACurrentMediaTime() - c0)
                            gpu += r.lastGPUTimeMS
                            count += 1
                        }
                    }
                }
                let fps = AppModel.fps(level, wallpaper: wallpaper)
                let g = gpu / Double(max(count, 1))
                out += String(format: "| %@ | %@ | %d×%d | %.2f | %.0f | %.1f %% | %.0f |\n",
                              mode.label, cname, w, h, g, fps, g * fps / 10, cpu / Double(max(count, 1)) * 1e6)
            }
        }
        out += "\nCPU encodage = temps mur de `draw()` y compris l'attente GPU (borne haute).\n"
        try? out.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print(out)
        return 0
    }
}

// MARK: - Live measurement of the real app (CI and diagnostics)

final class MeasurementRun {
    private weak var delegate: AppDelegate?
    private let seconds: Double
    private let reportPath: String
    private var report = "# Consommation mesurée (app complète, mode démo)\n\n| Phase | CPU process | Images/s | Réveils/s | Énergie (W, estimée par macOS) |\n|---|---|---|---|---|\n"

    init(delegate: AppDelegate, seconds: Double, reportPath: String) {
        self.delegate = delegate
        self.seconds = seconds
        self.reportPath = reportPath
    }

    func start() {
        guard let d = delegate, let model = d.model else { return }
        model.settings.demoMode = true
        model.settings.wallpaperEnabled = true
        phase("Fenêtre (60 i/s) + fond d'écran (30 i/s), musique", warmup: 5, length: seconds * 0.4) { [self] in
            d.closeMainWindow()
            phase("Fond d'écran seul (30 i/s), musique", warmup: 4, length: seconds * 0.3) { [self] in
                model.settings.demoMode = false
                phase("Spotify absent / en pause (repos)", warmup: 5, length: seconds * 0.3) { [self] in
                    report += "\nAnalyse : \(model.analysisDescription) · coût moyen \(String(format: "%.0f", model.engine.averageFrameMicros)) µs/trame\n"
                    model.settings.wallpaperEnabled = false
                    try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
                    print(report)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func phase(_ name: String, warmup: Double, length: Double, then next: @escaping () -> Void) {
        guard let model = delegate?.model else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [self] in
            let meter = PhaseMeter(frames: model.scheduler.framesDrawn)
            let views = [model.windowView, model.wallpaper.view]
            let f0 = views.map { $0?.framesDrawn ?? 0 }
            let d0 = views.map { $0?.drawSeconds ?? 0 }
            let t0 = CACurrentMediaTime()
            let s0 = model.engine.samplesProcessed, a0 = model.engine.framesPublished, dr0 = model.engine.ring.dropped
            DispatchQueue.main.asyncAfter(deadline: .now() + length) { [self] in
                let r = meter.finish(frames: model.scheduler.framesDrawn)
                let dt = CACurrentMediaTime() - t0
                var detail = String(format: "audio %.0f éch/s, analyses %.1f/s, pertes %llu ;",
                                    Double(model.engine.samplesProcessed - s0) / dt, Double(model.engine.framesPublished - a0) / dt,
                                    model.engine.ring.dropped - dr0)
                for (i, label) in ["fenêtre", "fond"].enumerated() {
                    guard let v = views[i] else { continue }
                    let n = Double(v.framesDrawn - f0[i])
                    detail += String(format: " %@ %.1f i/s (%.2f ms/draw)", label, n / dt, n > 0 ? (v.drawSeconds - d0[i]) / n * 1000 : 0)
                }
                report += String(format: "| %@ | %.2f %% | %.1f — %@ | %.0f | %.3f |\n", name, r.cpu, r.fps, detail, r.wakeups, r.watts)
                next()
            }
        }
    }
}

enum Diagnostics {
    static func run(model: AppModel, seconds: Double, completion: @escaping (String) -> Void) {
        let meter = PhaseMeter(frames: model.scheduler.framesDrawn)
        // Precision self-test on a private analyzer (does not disturb the live one).
        var precision = ""
        let cfg = AnalyzerConfiguration(sampleRate: 48000, fftSizes: [32768, 8192, 2048], hop: 800)
        for f in [50.37, 440.21, 1000.0, 4999.7, 15013.3] {
            let a = SpectrumAnalyzer(configuration: cfg)
            let s = SignalGenerator.sine(frequency: f, amplitude: 0.5, sampleRate: 48000, count: 32768 + 4800)
            s.withUnsafeBufferPointer { _ = a.process($0.baseAddress!, count: $0.count) }
            let p = a.result.dominant
            precision += String(format: "  %.2f Hz → %.4f Hz (%.3f dBFS)\n", f, p?.frequency ?? 0, p?.levelDB ?? -200)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let r = meter.finish(frames: model.scheduler.framesDrawn)
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            var text = "Spectre — diagnostic\n"
            text += "macOS \(os)\n"
            text += "Capture : \(model.status.message) · \(model.capture.backend?.rawValue ?? "—") · \(Int(model.capture.sampleRate)) Hz\n"
            text += "Process tap disponible : \(CaptureController.supportsProcessTap ? "oui" : "non (ScreenCaptureKit)")\n"
            text += "Analyse : \(model.analysisDescription) · \(String(format: "%.0f", model.engine.averageFrameMicros)) µs/trame\n"
            text += String(format: "CPU (process) : %.2f %% · %.1f images/s · %.0f réveils/s · %.3f W estimés\n", r.cpu, r.fps, r.wakeups, r.watts)
            text += "Qualité : fenêtre \(model.windowLevel.label), fond d'écran \(model.wallpaperLevel.label)\n"
            text += "Batterie : \(model.power.onBattery ? "oui" : "non") · économie d'énergie : \(model.power.lowPowerMode ? "oui" : "non")\n"
            text += "Précision (sinus de synthèse) :\n" + precision
            completion(text)
        }
    }
}
