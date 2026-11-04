import AudioToolbox
import CoreAudio
import Foundation

/// Captures ONLY Spotify's audio with a Core Audio process tap (macOS 14.2+).
/// The tap is `unmuted`: what you hear is neither modified nor delayed.
/// The IO block runs on the HAL real-time thread: lock-free copy, no allocation.
@available(macOS 14.2, *)
final class ProcessTapCapture {
    private let engine: AnalysisEngine
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var processes: [AudioObjectID] = []
    private(set) var sampleRate: Double = 48000
    private(set) var channels: Int = 1
    private(set) var isRunning = false

    init(engine: AnalysisEngine) { self.engine = engine }

    deinit { stop() }

    func start(processes: [AudioObjectID]) throws {
        stop()
        guard !processes.isEmpty else { return }
        self.processes = processes

        let desc = CATapDescription(monoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "Spectre – Spotify"
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Création du tap audio Spotify")
        tapID = tap

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CA.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt), "Lecture du format du tap")
        sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
        channels = max(Int(fmt.mChannelsPerFrame), 1)

        let outputUID = CA.string(CA.defaultOutputDevice(), kAudioDevicePropertyDeviceUID) ?? ""
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spectre Tap",
            kAudioAggregateDeviceUIDKey: "com.elliot.spectre.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        if !outputUID.isEmpty {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg), "Création du périphérique agrégé")
        aggregateID = agg

        let engine = self.engine
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            // HAL real-time thread: no locks, no allocation, no Objective-C.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard list.count > 0 else { return }
            let buffer = list[0]
            guard let data = buffer.mData else { return }
            let ch = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = data.assumingMemoryBound(to: Float.self)
            if ch == 1 { engine.ingestMono(p, frames: frames) } else { engine.ingestInterleaved(p, channels: ch, frames: frames) }
        }
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, block), "Création du callback audio")
        procID = proc
        try check(AudioDeviceStart(agg, proc), "Démarrage de la capture")
        isRunning = true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }
}

/// System audio-capture permission (TCC "kTCCServiceAudioCapture").
/// macOS has no public preflight API for it; we use the same TCC entry points
/// as Apple's sample tools, loaded dynamically, and fall back gracefully.
enum AudioCapturePermission {
    enum Status { case unknown, authorized, denied }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { completion(true); return }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        fn(service, nil) { granted in DispatchQueue.main.async { completion(granted) } }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    static let fallbackSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
