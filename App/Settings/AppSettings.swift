import Foundation
import ServiceManagement
import SpectreCore

enum QualityChoice: String, CaseIterable, Identifiable {
    case auto, high, medium, economy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatique"
        case .high: return "Haut"
        case .medium: return "Moyen"
        case .economy: return "Économie"
        }
    }
}

/// Persistent user settings (UserDefaults). Every change is applied live.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Visual (window)
    @Published var mode: VisualMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var theme: ThemeKind { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var fluidity: Double { didSet { d.set(fluidity, forKey: "fluidity") } }
    @Published var peakHold: Bool { didSet { d.set(peakHold, forKey: "peakHold") } }

    // Analysis
    @Published var fftSize: Int { didSet { d.set(fftSize, forKey: "fftSize") } }
    @Published var multiResolution: Bool { didSet { d.set(multiResolution, forKey: "multiResolution") } }
    @Published var window: WindowKind { didSet { d.set(window.rawValue, forKey: "window") } }
    @Published var attackMS: Double { didSet { d.set(attackMS, forKey: "attackMS") } }
    @Published var releaseMS: Double { didSet { d.set(releaseMS, forKey: "releaseMS") } }
    @Published var slope: Double { didSet { d.set(slope, forKey: "slope") } }
    @Published var floorDB: Double { didSet { d.set(floorDB, forKey: "floorDB") } }
    @Published var truePeak: Bool { didSet { d.set(truePeak, forKey: "truePeak") } }

    // Energy
    @Published var quality: QualityChoice { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var economyOnBattery: Bool { didSet { d.set(economyOnBattery, forKey: "economyOnBattery") } }

    // Wallpaper
    @Published var wallpaperEnabled: Bool { didSet { d.set(wallpaperEnabled, forKey: "wallpaperEnabled") } }
    @Published var wallpaperScreen: String { didSet { d.set(wallpaperScreen, forKey: "wallpaperScreen") } }
    @Published var wallpaperMode: VisualMode { didSet { d.set(wallpaperMode.rawValue, forKey: "wallpaperMode") } }
    @Published var wallpaperTheme: ThemeKind { didSet { d.set(wallpaperTheme.rawValue, forKey: "wallpaperTheme") } }
    @Published var wallpaperOpacity: Double { didSet { d.set(wallpaperOpacity, forKey: "wallpaperOpacity") } }
    @Published var wallpaperShowFrequency: Bool { didSet { d.set(wallpaperShowFrequency, forKey: "wallpaperShowFrequency") } }
    @Published var wallpaperShowNote: Bool { didSet { d.set(wallpaperShowNote, forKey: "wallpaperShowNote") } }
    @Published var wallpaperShowTitle: Bool { didSet { d.set(wallpaperShowTitle, forKey: "wallpaperShowTitle") } }

    // General
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
        }
    }
    @Published var loginItemError: String?
    @Published var demoMode = false

    init() {
        d.register(defaults: [
            "mode": VisualMode.liquid.rawValue, "theme": ThemeKind.sobre.rawValue, "fluidity": 0.6, "peakHold": true,
            "fftSize": 32768, "multiResolution": true, "window": WindowKind.hann.rawValue,
            "attackMS": 15.0, "releaseMS": 300.0, "slope": 3.0, "floorDB": -90.0, "truePeak": false,
            "quality": QualityChoice.auto.rawValue, "economyOnBattery": true,
            "wallpaperEnabled": false, "wallpaperScreen": "", "wallpaperMode": VisualMode.liquid.rawValue,
            "wallpaperTheme": ThemeKind.sobre.rawValue, "wallpaperOpacity": 0.9,
            "wallpaperShowFrequency": true, "wallpaperShowNote": true, "wallpaperShowTitle": true,
        ])
        mode = VisualMode(rawValue: d.string(forKey: "mode") ?? "") ?? .liquid
        theme = ThemeKind(rawValue: d.string(forKey: "theme") ?? "") ?? .sobre
        fluidity = d.double(forKey: "fluidity")
        peakHold = d.bool(forKey: "peakHold")
        fftSize = d.integer(forKey: "fftSize")
        multiResolution = d.bool(forKey: "multiResolution")
        window = WindowKind(rawValue: d.string(forKey: "window") ?? "") ?? .hann
        attackMS = d.double(forKey: "attackMS")
        releaseMS = d.double(forKey: "releaseMS")
        slope = d.double(forKey: "slope")
        floorDB = d.double(forKey: "floorDB")
        truePeak = d.bool(forKey: "truePeak")
        quality = QualityChoice(rawValue: d.string(forKey: "quality") ?? "") ?? .auto
        economyOnBattery = d.bool(forKey: "economyOnBattery")
        wallpaperEnabled = d.bool(forKey: "wallpaperEnabled")
        wallpaperScreen = d.string(forKey: "wallpaperScreen") ?? ""
        wallpaperMode = VisualMode(rawValue: d.string(forKey: "wallpaperMode") ?? "") ?? .liquid
        wallpaperTheme = ThemeKind(rawValue: d.string(forKey: "wallpaperTheme") ?? "") ?? .sobre
        wallpaperOpacity = d.double(forKey: "wallpaperOpacity")
        wallpaperShowFrequency = d.bool(forKey: "wallpaperShowFrequency")
        wallpaperShowNote = d.bool(forKey: "wallpaperShowNote")
        wallpaperShowTitle = d.bool(forKey: "wallpaperShowTitle")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        fftSize = min(max(fftSize, 2048), 32768)
    }

    var scale: SpectrumScale {
        SpectrumScale(floorDB: Float(floorDB), ceilingDB: 0, slopeDBPerOctave: Float(slope))
    }
}
