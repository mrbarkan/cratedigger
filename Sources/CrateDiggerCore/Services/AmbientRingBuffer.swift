import Foundation
import os

/// Mono audio handed from the microphone's thread to the output's.
///
/// It holds `targetFrames` of slack, which is the delay the listener picked,
/// and keeps it there even though the mic and the headphones run on two clocks
/// that never quite agree:
///
/// - Nothing plays until the target has buffered (priming).
/// - An underrun plays what there is, pads silence, and primes again rather
///   than stuttering frame by frame.
/// - A write that outruns the capacity drops the oldest audio.
/// - A fill that runs far past the target skips back to it, so a mic clock
///   that is slightly fast cannot make the delay creep up over an afternoon.
///
/// `underruns` and `skippedFrames` count the audible consequences, so how
/// clean Ambient sounds can be measured rather than guessed.
public final class AmbientRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let targetFrames: Int
    // ponytail: os_unfair_lock on both audio threads; the deployment target
    // predates Mutex. Critical sections are a couple of memcpys. Upgrade to a
    // lock-free SPSC ring if Instruments ever shows contention here.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readIndex = 0
    private var fill = 0
    private var priming = true
    private var underrunCount = 0
    private var skippedCount = 0

    public init(capacityFrames: Int, targetFrames: Int) {
        capacity = max(1, capacityFrames)
        self.targetFrames = min(max(0, targetFrames), capacity)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public var fillFrames: Int { withLock { fill } }

    /// Times the output ran dry mid-stream, each an audible gap. The silence
    /// while the delay first fills is by design and not counted.
    public var underruns: Int { withLock { underrunCount } }

    /// Frames thrown away, on overflow or catching up with a fast mic clock.
    public var skippedFrames: Int { withLock { skippedCount } }

    public func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        withLock {
            var source = samples
            var count = frameCount
            if count > capacity {                // only the newest can fit
                skippedCount += count - capacity
                source += count - capacity
                count = capacity
            }
            let overflow = fill + count - capacity
            if overflow > 0 { drop(overflow) }

            var writeIndex = (readIndex + fill) % capacity
            var remaining = count
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                (storage + writeIndex).update(from: source, count: chunk)
                source += chunk
                remaining -= chunk
                writeIndex = (writeIndex + chunk) % capacity
            }
            fill += count
        }
    }

    public func read(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        withLock {
            if priming {
                guard fill >= targetFrames else {
                    out.update(repeating: 0, count: frameCount)
                    return
                }
                priming = false
            }

            // ponytail: drift is corrected by skipping whole frames, which can
            // click under heavy drift. Adaptive resampling is the upgrade.
            if fill > targetFrames * 2 + frameCount {
                drop(fill - targetFrames - frameCount)
            }

            let available = min(fill, frameCount)
            var copied = 0
            while copied < available {
                let chunk = min(available - copied, capacity - readIndex)
                (out + copied).update(from: storage + readIndex, count: chunk)
                copied += chunk
                readIndex = (readIndex + chunk) % capacity
            }
            fill -= available

            if available < frameCount {
                (out + available).update(repeating: 0, count: frameCount - available)
                priming = true
                underrunCount += 1
            }
        }
    }

    private func drop(_ frames: Int) {
        let count = min(frames, fill)
        readIndex = (readIndex + count) % capacity
        fill -= count
        skippedCount += count
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}
