import AudioToolbox
import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    var description: String {
        switch self {
        case let .status(what, s): return "\(what) (OSStatus \(s) \(fourCC(s)))"
        }
    }
}

func fourCC(_ s: OSStatus) -> String {
    let n = UInt32(bitPattern: s)
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
    return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? "'\(String(chars))'" : ""
}

@inline(__always)
func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw CoreAudioError.status(what, s) }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default d: T) -> T {
        var addr = address(selector)
        var v = d
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr else { return d }
        return v
    }

    static func defaultOutputDevice() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    /// Core Audio process objects belonging to Spotify (main app + helpers).
    @available(macOS 14.2, *)
    static func processObjects(bundlePrefix: String) -> [AudioObjectID] {
        objectList(system, kAudioHardwarePropertyProcessObjectList).filter { obj in
            guard let bid = string(obj, kAudioProcessPropertyBundleID) else { return false }
            return bid.hasPrefix(bundlePrefix)
        }
    }

    @available(macOS 14.2, *)
    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        value(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
    }
}

/// Keeps a Core Audio property listener alive and removes it on deinit.
final class CAListener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.queue = queue
        addr = CA.address(selector)
        block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr else { return nil }
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block) }
}
