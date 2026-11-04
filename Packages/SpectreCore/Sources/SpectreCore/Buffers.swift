import CSpectreRing
import Foundation

/// Fixed-size, manually managed float storage with a stable pointer.
/// Used everywhere in the hot paths so that no Swift array copy-on-write
/// or ARC traffic can ever trigger an allocation.
public final class FloatBuffer {
    public let count: Int
    public let pointer: UnsafeMutablePointer<Float>

    public init(_ count: Int, value: Float = 0) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: value, count: max(count, 1))
    }

    deinit { pointer.deallocate() }

    public subscript(index: Int) -> Float {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }

    public func fill(_ value: Float) { pointer.update(repeating: value, count: count) }

    /// Allocating copy — tests and UI only, never in the real-time path.
    public var array: [Float] { Array(UnsafeBufferPointer(start: pointer, count: count)) }

    public func copy(from source: UnsafePointer<Float>, count n: Int? = nil) {
        pointer.update(from: source, count: min(n ?? count, count))
    }
}

/// Swift face of the lock-free C ring buffer.
public final class AudioRingBuffer: @unchecked Sendable {
    public let raw: OpaquePointer

    public init(capacity: Int) {
        raw = spsc_create(UInt32(capacity))
    }

    deinit { spsc_destroy(raw) }

    public var available: Int { Int(spsc_available(raw)) }
    public var dropped: UInt64 { spsc_dropped(raw) }

    /// Real-time safe. Returns true when the consumer must be signalled.
    @inline(__always)
    public func write(_ source: UnsafePointer<Float>, count: Int, threshold: Int) -> Bool {
        spsc_write(raw, source, UInt32(count), UInt32(threshold)) != 0
    }

    @inline(__always)
    public func writeInterleavedMix(_ source: UnsafePointer<Float>, channels: Int, frames: Int, threshold: Int) -> Bool {
        spsc_write_interleaved_mix(raw, source, UInt32(channels), UInt32(frames), UInt32(threshold)) != 0
    }

    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        Int(spsc_read(raw, destination, UInt32(count)))
    }

    @discardableResult
    public func skip(_ count: Int) -> Int { Int(spsc_skip(raw, UInt32(count))) }

    public func clearNotify() { spsc_clear_notify(raw) }
    public func reset() { spsc_reset(raw) }
}
