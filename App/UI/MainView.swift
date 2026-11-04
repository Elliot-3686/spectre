import AppKit
import SwiftUI
import SpectreCore

enum MainLayout {
    static let plotInsets = NSEdgeInsets(top: 104, left: 50, bottom: 30, right: 18)
    static let frequencyTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    static let ink = Color(white: 0.93)
}

enum Fmt {
    static let fr = Locale(identifier: "fr_FR")

    static func hz(_ f: Double) -> String {
        let digits = f < 1000 ? 2 : (f < 10000 ? 1 : 0)
        return f.formatted(.number.precision(.fractionLength(digits)).locale(fr)) + " Hz"
    }

    static func shortHz(_ f: Double) -> String {
        f >= 1000 ? (f / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(fr)) + "k" : "\(Int(f))"
    }

    static func db(_ v: Float, unit: String = "dBFS") -> String {
        guard v > -199 else { return "−∞ \(unit)" }
        let s = abs(Double(v)).formatted(.number.precision(.fractionLength(1)).locale(fr))
        return (v < -0.05 ? "−" : "") + s + " " + unit
    }

    static func note(_ f: Double) -> String { MusicalNote.describe(frequency: f)?.label ?? "" }
}

/// Hosts the shared SpectrumMetalView instance owned by AppModel.
struct MetalHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let v = model.windowView {
                    MetalHost(view: v)
                } else {
                    Color(red: 0.03, green: 0.035, blue: 0.045)
                    Text("Metal n'est pas disponible sur cette machine.").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                AxesOverlay(mode: settings.mode, scale: settings.scale, size: geo.size)
                    .allowsHitTesting(false)
                if let p = hover {
                    HoverReadout(model: model, mode: settings.mode, location: p, size: geo.size)
                        .allowsHitTesting(false)
                }
                ReadoutView(model: model)
                    .padding(.leading, 56).padding(.top, 34)
                    .allowsHitTesting(false)
                VStack(alignment: .trailing, spacing: 10) {
                    ControlsBar(settings: settings, openSettings: openSettings)
                    PeaksList(readout: model.readout).allowsHitTesting(false)
                }
                .padding(.top, 30).padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                StatusOverlay(model: model, settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(p): hover = p
                case .ended: hover = nil
                }
            }
        }
        .background(Color(red: 0.03, green: 0.035, blue: 0.045))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Read-outs

struct ReadoutView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let r = model.readout
        let dominant = r.peaks.first
        VStack(alignment: .leading, spacing: 3) {
            Text(dominant.map { Fmt.hz($0.frequency) } ?? "—")
                .font(.system(size: 34, weight: .ultraLight))
                .monospacedDigit()
            HStack(spacing: 14) {
                Text(dominant.map { Fmt.note($0.frequency) } ?? " ")
                Text(dominant.map { Fmt.db($0.levelDB) } ?? " ")
                Text("RMS " + Fmt.db(r.rmsDB))
                if model.settings.truePeak { Text("crête vraie " + Fmt.db(r.truePeakDB, unit: "dBTP")) }
            }
            .font(.system(size: 12, weight: .light))
            .monospacedDigit()
            .opacity(0.8)
            if let np = model.nowPlaying {
                Text(np).font(.system(size: 11, weight: .light)).opacity(0.6).lineLimit(1)
            }
        }
        .foregroundColor(MainLayout.ink)
        .opacity(r.hasSignal ? 0.62 : 0)
        .animation(.easeInOut(duration: 0.6), value: r.hasSignal)
    }
}

struct PeaksList: View {
    let readout: Readout

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(readout.peaks.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 10) {
                    Text("\(i + 1)").opacity(0.5)
                    Text(Fmt.hz(p.frequency)).frame(width: 96, alignment: .trailing)
                    Text(Fmt.note(p.frequency)).frame(width: 104, alignment: .leading)
                    Text(Fmt.db(p.levelDB, unit: "dB")).frame(width: 62, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
        .foregroundColor(MainLayout.ink)
        .opacity(readout.hasSignal ? 0.45 : 0)
        .animation(.easeInOut(duration: 0.6), value: readout.hasSignal)
    }
}

struct ControlsBar: View {
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Visuel", selection: $settings.mode) {
                ForEach(VisualMode.allCases) { m in
                    Image(systemName: m.symbol).help(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Menu {
                ForEach(ThemeKind.allCases, id: \.self) { t in
                    Button(t.label) { settings.theme = t }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Thème : \(settings.theme.label)")
            HStack(spacing: 4) {
                Image(systemName: "scope").font(.system(size: 10)).help("Précision")
                Slider(value: $settings.fluidity, in: 0...1).frame(width: 90)
                Image(systemName: "drop").font(.system(size: 10)).help("Fluidité")
            }
            .help("Fluidité / Précision du visuel (les valeurs affichées restent celles de la FFT brute)")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Réglages")
        }
        .controlSize(.small)
        .opacity(0.75)
    }
}

// MARK: - Axes

struct AxesOverlay: View {
    let mode: VisualMode
    let scale: SpectrumScale
    let size: CGSize

    var body: some View {
        Canvas { ctx, sz in
            let ins = MainLayout.plotInsets
            let x0 = ins.left, x1 = sz.width - ins.right
            let yTop = ins.top, yBottom = sz.height - ins.bottom
            let line = GraphicsContext.Shading.color(.white.opacity(0.055))
            let label = Color.white.opacity(0.32)
            let font = Font.system(size: 9.5, weight: .regular, design: .monospaced)
            func logPos(_ f: Double) -> Double { log(f / 20) / log(1000) }

            if mode == .spectrogram {
                for f in MainLayout.frequencyTicks {
                    let y = yBottom - logPos(f) * (yBottom - yTop)
                    var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
                    ctx.stroke(p, with: line, lineWidth: 0.5)
                    ctx.draw(Text(Fmt.shortHz(f)).font(font).foregroundColor(label), at: CGPoint(x: x0 - 6, y: y), anchor: .trailing)
                }
                ctx.draw(Text("temps →").font(font).foregroundColor(label), at: CGPoint(x: x1, y: yBottom + 14), anchor: .trailing)
                return
            }
            for f in MainLayout.frequencyTicks {
                let x = x0 + logPos(f) * (x1 - x0)
                var p = Path(); p.move(to: CGPoint(x: x, y: yTop)); p.addLine(to: CGPoint(x: x, y: yBottom))
                ctx.stroke(p, with: line, lineWidth: 0.5)
                ctx.draw(Text(Fmt.shortHz(f)).font(font).foregroundColor(label), at: CGPoint(x: x, y: yBottom + 13), anchor: .center)
            }
            let plotH = (yBottom - yTop) * 0.92
            var db: Float = 0
            while db >= scale.floorDB + 0.1 {
                let v = scale.normalized(db, tilt: 0)
                let y = yBottom - CGFloat(v) * plotH
                var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
                ctx.stroke(p, with: line, lineWidth: 0.5)
                ctx.draw(Text(db == 0 ? "0" : "−\(Int(-db))").font(font).foregroundColor(label), at: CGPoint(x: x0 - 6, y: y), anchor: .trailing)
                db -= 20
            }
            let slopeText = Double(scale.slopeDBPerOctave).formatted(.number.precision(.fractionLength(0...1)).locale(Fmt.fr))
            let note = scale.slopeDBPerOctave == 0 ? "dBFS" : "dBFS à 1 kHz · pente +\(slopeText) dB/oct"
            ctx.draw(Text(note).font(font).foregroundColor(label.opacity(0.7)), at: CGPoint(x: x0 + 4, y: yTop - 8), anchor: .leading)
        }
    }
}

struct HoverReadout: View {
    let model: AppModel
    let mode: VisualMode
    let location: CGPoint
    let size: CGSize

    var body: some View {
        let ins = MainLayout.plotInsets
        let x0 = ins.left, x1 = size.width - ins.right, yTop = ins.top, yBottom = size.height - ins.bottom
        let inside = location.x >= x0 && location.x <= x1 && location.y >= yTop && location.y <= yBottom
        let u = mode == .spectrogram ? (yBottom - location.y) / (yBottom - yTop) : (location.x - x0) / (x1 - x0)
        let f = 20 * pow(1000, Double(min(max(u, 0), 1)))
        let level = model.engine.snapshot.rawLevel(at: f)
        ZStack(alignment: .topLeading) {
            if inside {
                Path { p in
                    if mode == .spectrogram {
                        p.move(to: CGPoint(x: x0, y: location.y)); p.addLine(to: CGPoint(x: x1, y: location.y))
                    } else {
                        p.move(to: CGPoint(x: location.x, y: yTop)); p.addLine(to: CGPoint(x: location.x, y: yBottom))
                    }
                }
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.hz(f))
                    Text(Fmt.note(f)).opacity(0.7)
                    Text(level.map { Fmt.db($0) } ?? "—").opacity(0.7)
                }
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundColor(MainLayout.ink.opacity(0.75))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35)))
                .offset(x: min(location.x + 10, size.width - 130), y: max(location.y - 58, yTop))
            }
        }
    }
}

// MARK: - Status

struct StatusOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            switch model.status {
            case .waitingForSpotify:
                card(title: "En attente de Spotify",
                     text: "Lancez l'app Spotify de bureau : Spectre s'y connectera automatiquement.") {
                    Button("Ouvrir Spotify") { openSpotify() }
                    Button("Mode démo") { settings.demoMode = true }
                }
            case .spotifyPaused:
                card(title: "Spotify est en pause", text: "Lancez un morceau pour voir son spectre.") {
                    Button("Mode démo") { settings.demoMode = true }
                }
            case .permissionDenied:
                card(title: "Spectre n'a pas accès au son de Spotify",
                     text: "Ouvrez Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système, puis autorisez Spectre (section « Audio système uniquement »). Seul le son de Spotify est analysé ; rien n'est enregistré.") {
                    Button("Ouvrir les Réglages") { model.capture.openPermissionSettings() }
                    Button("Réessayer") { model.capture.retryPermission() }
                }
            case let .error(msg):
                card(title: "La capture a échoué", text: msg) {
                    Button("Réessayer") { model.capture.retryPermission() }
                }
            case .demo:
                VStack {
                    Spacer()
                    Button("Quitter le mode démo") { settings.demoMode = false }
                        .buttonStyle(.borderless).font(.system(size: 11, weight: .light)).opacity(0.5)
                        .padding(.bottom, 36)
                }
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.status)
    }

    private func card<B: View>(title: String, text: String, @ViewBuilder buttons: () -> B) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 17, weight: .light))
            Text(text).font(.system(size: 12, weight: .light)).multilineTextAlignment(.center).opacity(0.7)
                .frame(maxWidth: 420)
            HStack(spacing: 10) { buttons() }.controlSize(.small).padding(.top, 4)
        }
        .foregroundColor(MainLayout.ink)
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
        .transition(.opacity)
    }

    private func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyMonitor.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://www.spotify.com/download/mac/") {
            NSWorkspace.shared.open(web)
        }
    }
}
