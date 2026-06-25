import AVFoundation
import Accelerate
import MediaToolbox

/// Captures real per-channel peak levels from an `AVPlayerItem`'s audio via an
/// `MTAudioProcessingTap`, so the VU meter reflects the actual signal instead of
/// an animation.
///
/// Usage: build an `AVAudioMix` with `makeAudioMix(forTrack:)`, assign it to the
/// item's `audioMix`, then read `currentPeaks()` (0...1 linear) — safe from any
/// thread. The tap's process callback runs on a real-time audio thread, so the
/// peaks are stored behind a lock and the math is kept cheap (vDSP).
public final class AudioLevelTap {
    private let store = AudioTapLevelStore()

    public init() {}

    /// Latest linear peak per channel (0...1).
    public func currentPeaks() -> (left: Double, right: Double) {
        let snap = store.snapshot()
        return (Double(snap.left), Double(snap.right))
    }

    /// Clear the stored levels (e.g. when switching tracks).
    public func reset() { store.update(left: 0, right: 0) }

    /// An audio mix wired to a fresh tap for `track`. Assign the result to
    /// `AVPlayerItem.audioMix`. Returns nil if the tap can't be created.
    public func makeAudioMix(forTrack track: AVAssetTrack) -> AVAudioMix? {
        guard let tap = makeTap() else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    private func makeTap() -> MTAudioProcessingTap? {
        // The store is retained for the tap's lifetime and released in finalize,
        // so the audio thread always has a valid pointer.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(store).toOpaque()),
            init: levelTapInit,
            finalize: levelTapFinalize,
            prepare: nil,
            unprepare: nil,
            process: levelTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else { return nil }
        return tap
    }
}

/// Thread-safe holder for the latest L/R peaks: written on the audio thread,
/// read on the main thread.
final class AudioTapLevelStore {
    private let lock = NSLock()
    private var left: Float = 0
    private var right: Float = 0

    func update(left: Float, right: Float) {
        lock.lock(); self.left = left; self.right = right; lock.unlock()
    }

    func snapshot() -> (left: Float, right: Float) {
        lock.lock(); defer { lock.unlock() }
        return (left, right)
    }
}

// MARK: - C tap callbacks
// These are file-scope functions with no captured context, so Swift converts
// them to the `@convention(c)` function pointers MTAudioProcessingTap expects.

private func levelTapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    // Hand the retained store pointer through to per-callback storage.
    tapStorageOut.pointee = clientInfo
}

private func levelTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<AudioTapLevelStore>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func levelTapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let store = Unmanaged<AudioTapLevelStore>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var peaks: [Float] = []
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard totalSamples > 0 else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        if channels == 1 {
            // Non-interleaved: one channel per buffer.
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(totalSamples))
            peaks.append(peak)
        } else {
            // Interleaved: stride through each channel.
            let frames = totalSamples / channels
            guard frames > 0 else { continue }
            for c in 0..<channels {
                var peak: Float = 0
                vDSP_maxmgv(samples + c, vDSP_Stride(channels), &peak, vDSP_Length(frames))
                peaks.append(peak)
            }
        }
    }

    let left = peaks.first ?? 0
    let right = peaks.count > 1 ? peaks[1] : left
    store.update(left: left, right: right)
}
