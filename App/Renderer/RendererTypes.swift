import Foundation
import SpectreCore

/// Mirrors `FrameUniforms` in Shaders.metal (28 floats, scalars only).
struct FrameUniforms {
    var viewW: Float = 0, viewH: Float = 0
    var time: Float = 0, dt: Float = 0
    var columns: Float = 0, mode: Float = 0
    var opacity: Float = 1, layerCount: Float = 4
    var glow: Float = 1, trailStrength: Float = 0
    var fluidity: Float = 0.6, dither: Float = 1
    var plotL: Float = 0, plotB: Float = 0, plotR: Float = 1, plotT: Float = 1
    var vignette: Float = 0.22, crest: Float = 1
    var spectroHead: Float = 0, spectroWidth: Float = 1
    var bandCount: Float = 31, showHold: Float = 0
    var pointSize: Float = 2, particleCount: Float = 0
    var pixelScale: Float = 1, heightScale: Float = 0.92
    var trailDecay: Float = 0.9, surfaceAlpha: Float = 1
}

/// Mirrors `SimUniforms` in Shaders.metal (16 floats).
struct SimUniforms {
    var dt: Float = 0, columns: Float = 0, fluidity: Float = 0, substeps: Float = 1
    var bypass: Float = 0, blur: Float = 1, sandCount: Float = 0, duneColumns: Float = 0
    var gravity: Float = 1.8, time: Float = 0, kick: Float = 0, grainHeight: Float = 0
    var head: Float = 0, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

enum VisualMode: String, CaseIterable, Codable, Identifiable {
    case liquid, sand, curve, bars, spectrogram
    var id: String { rawValue }

    var label: String {
        switch self {
        case .liquid: return "Liquide"
        case .sand: return "Sable"
        case .curve: return "Courbe"
        case .bars: return "Tiers d'octave"
        case .spectrogram: return "Spectrogramme"
        }
    }

    var symbol: String {
        switch self {
        case .liquid: return "drop"
        case .sand: return "aqi.medium"
        case .curve: return "waveform.path.ecg"
        case .bars: return "chart.bar"
        case .spectrogram: return "square.stack.3d.forward.dottedline"
        }
    }

    var shaderMode: Float {
        switch self {
        case .liquid: return 0
        case .sand: return 1
        case .curve: return 2
        case .bars: return 3
        case .spectrogram: return 4
        }
    }
}

enum QualityLevel: String, CaseIterable, Codable, Identifiable {
    case high, medium, economy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "Haut"
        case .medium: return "Moyen"
        case .economy: return "Économie"
        }
    }
}

/// Everything that varies with the quality level (GPU side).
struct RenderQuality: Equatable {
    var layers: Int
    var glow: Float
    var trails: Bool
    var trailDivisor: Int
    var particles: Int
    var renderScale: CGFloat
    var spectroWidth: Int

    static func profile(_ level: QualityLevel, wallpaper: Bool) -> RenderQuality {
        switch level {
        case .high:
            return RenderQuality(layers: 4, glow: 1, trails: true, trailDivisor: 2,
                                 particles: wallpaper ? 12000 : 20000,
                                 renderScale: wallpaper ? 0.75 : 1, spectroWidth: 720)
        case .medium:
            return RenderQuality(layers: 3, glow: 0.6, trails: true, trailDivisor: 4,
                                 particles: 8000, renderScale: wallpaper ? 0.5 : 0.75, spectroWidth: 480)
        case .economy:
            return RenderQuality(layers: 2, glow: 0, trails: false, trailDivisor: 4,
                                 particles: 3000, renderScale: 0.5, spectroWidth: 320)
        }
    }
}

/// Visual parameters of one view (window or wallpaper).
struct VisualStyle: Equatable {
    var mode: VisualMode = .liquid
    var theme: ThemeKind = .sobre
    var fluidity: Float = 0.6
    var opacity: Float = 1
    var showHold = false
    var scale = SpectrumScale()
    var quality = RenderQuality.profile(.high, wallpaper: false)
    /// Plot rectangle in normalised view coordinates (y up).
    var plotL: Float = 0, plotB: Float = 0, plotR: Float = 1, plotT: Float = 1
    var heightScale: Float = 0.92
}
