import Foundation

/// ISO 266 1/3-octave bands, 20 Hz – 20 kHz (31 bands).
public enum ISOBands {
    public static let count = 31
    public static let nominalCenters: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]
    /// Exact base-2 centres: 1000 · 2^((i − 17) / 3).
    public static let exactCenters: [Double] = (0..<31).map { 1000 * pow(2, Double($0 - 17) / 3) }

    public static func label(_ i: Int) -> String {
        let f = nominalCenters[i]
        if f >= 1000 {
            let k = f / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k).replacingOccurrences(of: ".", with: ",")
        }
        return f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f).replacingOccurrences(of: ".", with: ",")
    }
}

/// Equal-tempered note naming.
public struct NoteDescription: Equatable, Sendable {
    public var name: String      // "A"
    public var octave: Int       // 4
    public var cents: Int        // −50 … +50
    public var midi: Int

    public var noteName: String { "\(name)\(octave)" }
    /// "A4 +3 cents"
    public var label: String { "\(noteName) \(cents >= 0 ? "+" : "−")\(abs(cents)) cents" }
}

public enum MusicalNote {
    public static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    public static func describe(frequency: Double, a4: Double = 440) -> NoteDescription? {
        guard frequency.isFinite, frequency > 0 else { return nil }
        let midiExact = 69 + 12 * log2(frequency / a4)
        let midi = Int(midiExact.rounded())
        var cents = Int(((midiExact - Double(midi)) * 100).rounded())
        if cents == -50 { cents = 50 }
        let pitchClass = ((midi % 12) + 12) % 12
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return NoteDescription(name: names[pitchClass], octave: octave, cents: cents, midi: midi)
    }
}

/// Time smoothing of a spectrum (fast attack, slow release) + peak hold.
/// Works in dB. No allocation in `update`.
public final class SpectrumSmoother {
    public let count: Int
    public let smoothed: FloatBuffer
    public let hold: FloatBuffer
    private let holdAge: FloatBuffer

    public var attack: Double = 0.015     // seconds
    public var release: Double = 0.30     // seconds
    public var holdTime: Double = 1.0     // seconds
    public var holdFall: Float = 15       // dB / second

    public init(count: Int, floor: Float = -200) {
        self.count = count
        smoothed = FloatBuffer(count, value: floor)
        hold = FloatBuffer(count, value: floor)
        holdAge = FloatBuffer(count, value: 0)
    }

    public func update(_ input: UnsafePointer<Float>, dt: Double) {
        let a = Float(1 - exp(-dt / max(attack, 1e-4)))
        let r = Float(1 - exp(-dt / max(release, 1e-4)))
        let fall = holdFall * Float(dt)
        let ht = Float(holdTime)
        let s = smoothed.pointer, h = hold.pointer, age = holdAge.pointer
        let fdt = Float(dt)
        for i in 0..<count {
            let x = max(input[i], -200)
            let cur = s[i]
            s[i] = cur + (x - cur) * (x > cur ? a : r)
            if s[i] >= h[i] {
                h[i] = s[i]; age[i] = 0
            } else {
                age[i] += fdt
                // During silence the held peaks fall 6× faster so that everything
                // reaches rest (and rendering stops) quickly.
                if age[i] > ht { h[i] = max(h[i] - (x <= -199 ? fall * 6 : fall), s[i]) }
            }
        }
    }

    public func reset(to value: Float = -200) {
        smoothed.fill(value); hold.fill(value); holdAge.fill(0)
    }

    /// True once everything has decayed below `floor`.
    public func isAtRest(below floor: Float) -> Bool {
        let s = smoothed.pointer, h = hold.pointer
        for i in 0..<count where s[i] > floor || h[i] > floor { return false }
        return true
    }
}

/// Mapping dBFS → normalised height used by every visual.
public struct SpectrumScale: Equatable, Sendable {
    public var floorDB: Float = -90
    public var ceilingDB: Float = 0
    /// Display tilt in dB/octave around 1 kHz (pink noise looks flat at +3).
    public var slopeDBPerOctave: Float = 3

    public init(floorDB: Float = -90, ceilingDB: Float = 0, slopeDBPerOctave: Float = 3) {
        self.floorDB = floorDB
        self.ceilingDB = ceilingDB
        self.slopeDBPerOctave = slopeDBPerOctave
    }

    @inline(__always)
    public func normalized(_ db: Float, tilt: Float) -> Float {
        let v = (db + tilt - floorDB) / (ceilingDB - floorDB)
        return min(max(v, 0), 1)
    }

    public func tilts(for frequencies: [Double]) -> [Float] {
        frequencies.map { Float(log2($0 / 1000)) * slopeDBPerOctave }
    }

    /// Inverse (for the hover read-out and the dB axis).
    public func db(forNormalized v: Float, tilt: Float) -> Float {
        v * (ceilingDB - floorDB) + floorDB - tilt
    }
}
