import CoreMedia
import Foundation
import ScreenCaptureKit

/// Fallback for macOS 13.0 – 14.1: ScreenCaptureKit audio filtered on Spotify.
/// Needs the Screen Recording permission. Video is reduced to 2×2 px at 1 fps.
final class ScreenCaptureAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private let engine: AnalysisEngine
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Spectre.sck.audio", qos: .userInteractive)
    private var mixBuffer = [Float](repeating: 0, count: 8192)
    let sampleRate: Double = 48000
    private(set) var isRunning = false
    var onError: ((String) -> Void)?

    init(engine: AnalysisEngine) { self.engine = engine }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start(bundleID: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }),
              let display = content.displays.first else {
            throw NSError(domain: "Spectre", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spotify introuvable pour ScreenCaptureKit"])
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        isRunning = true
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        s.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard list.count > 0 else { return }
            if list.count == 1 {
                let b = list[0]
                guard let d = b.mData else { return }
                let ch = max(Int(b.mNumberChannels), 1)
                let frames = Int(b.mDataByteSize) / (4 * ch)
                let p = d.assumingMemoryBound(to: Float.self)
                if ch == 1 { engine.ingestMono(p, frames: frames) } else { engine.ingestInterleaved(p, channels: ch, frames: frames) }
                return
            }
            // Non-interleaved: average the channels (mono = L+R).
            let frames = min(Int(list[0].mDataByteSize) / 4, mixBuffer.count)
            let gain = 1 / Float(list.count)
            mixBuffer.withUnsafeMutableBufferPointer { mix in
                for i in 0..<frames { mix[i] = 0 }
                for b in list {
                    guard let d = b.mData else { continue }
                    let p = d.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { mix[i] += p[i] * gain }
                }
                engine.ingestMono(mix.baseAddress!, frames: frames)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }
}
