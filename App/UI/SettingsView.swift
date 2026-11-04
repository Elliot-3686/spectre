import SwiftUI
import SpectreCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var runDiagnostics: () -> Void

    var body: some View {
        Form {
            Section("Visuel") {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(VisualMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Thème", selection: $settings.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Fluidité / Précision") {
                    HStack {
                        Text("Brut").font(.caption).foregroundColor(.secondary)
                        Slider(value: $settings.fluidity, in: 0...1)
                        Text("Liquide").font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle("Maintien des crêtes (peak hold)", isOn: $settings.peakHold)
                Text("Les valeurs affichées (Hz, note, dB, pics) viennent toujours de la FFT brute, jamais de la simulation visuelle.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Analyse") {
                Picker("Taille FFT (graves)", selection: $settings.fftSize) {
                    ForEach([2048, 4096, 8192, 16384, 32768], id: \.self) { Text("\($0) points").tag($0) }
                }
                Toggle("Multi-résolution (longues fenêtres pour les graves, courtes pour les aigus)", isOn: $settings.multiResolution)
                Picker("Fenêtre", selection: $settings.window) {
                    ForEach(WindowKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Attaque") {
                    HStack { Slider(value: $settings.attackMS, in: 1...100); Text("\(Int(settings.attackMS)) ms").monospacedDigit().frame(width: 60, alignment: .trailing) }
                }
                LabeledContent("Relâchement") {
                    HStack { Slider(value: $settings.releaseMS, in: 20...2000); Text("\(Int(settings.releaseMS)) ms").monospacedDigit().frame(width: 60, alignment: .trailing) }
                }
                Picker("Pente d'affichage", selection: $settings.slope) {
                    Text("0 dB/oct (brut)").tag(0.0)
                    Text("+3 dB/oct (bruit rose à plat)").tag(3.0)
                    Text("+4,5 dB/oct").tag(4.5)
                }
                Picker("Plancher", selection: $settings.floorDB) {
                    ForEach([-60.0, -70, -80, -90, -100, -120], id: \.self) { Text("\(Int($0)) dBFS").tag($0) }
                }
                Toggle("Crête vraie (true peak, suréchantillonnage ×4)", isOn: $settings.truePeak)
                LabeledContent("En cours", value: model.analysisDescription)
                    .font(.caption)
            }

            Section("Énergie") {
                Picker("Qualité", selection: $settings.quality) {
                    ForEach(QualityChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Mode économie automatique sur batterie / mode économie d'énergie", isOn: $settings.economyOnBattery)
                LabeledContent("Fenêtre", value: "\(model.windowLevel.label) · \(Int(AppModel.fps(model.windowLevel, wallpaper: false))) i/s max")
                LabeledContent("Fond d'écran", value: "\(model.wallpaperLevel.label) · \(Int(AppModel.fps(model.wallpaperLevel, wallpaper: true))) i/s max")
                Text("Rien n'est calculé quand Spotify est en pause, silencieux, que l'écran est verrouillé ou en veille, ou que le fond d'écran est caché.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Fond d'écran") {
                Toggle("Afficher le spectre en fond d'écran", isOn: $settings.wallpaperEnabled)
                Picker("Écran", selection: $settings.wallpaperScreen) {
                    Text("Écran principal").tag("")
                    ForEach(WallpaperController.screens(), id: \.id) { s in Text(s.name).tag(s.id) }
                }
                Picker("Mode", selection: $settings.wallpaperMode) {
                    ForEach(VisualMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Thème", selection: $settings.wallpaperTheme) {
                    ForEach(ThemeKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Opacité") { Slider(value: $settings.wallpaperOpacity, in: 0.2...1) }
                Toggle("Afficher la fréquence", isOn: $settings.wallpaperShowFrequency)
                Toggle("Afficher la note", isOn: $settings.wallpaperShowNote)
                Toggle("Afficher le titre du morceau", isOn: $settings.wallpaperShowTitle)
            }

            Section("Général") {
                Toggle("Lancer Spectre à l'ouverture de session", isOn: $settings.launchAtLogin)
                if let e = settings.loginItemError {
                    Text(e).font(.caption).foregroundColor(.orange)
                }
                Toggle("Mode démo (signal de synthèse, sans Spotify)", isOn: $settings.demoMode)
                LabeledContent("Capture", value: model.status.message)
                HStack {
                    Spacer()
                    Button("Diagnostic…", action: runDiagnostics)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560)
    }
}
