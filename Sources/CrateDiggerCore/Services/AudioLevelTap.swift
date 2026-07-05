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

    /// Latest linear RMS level per channel (0...1).
    public func currentPeaks() -> (left: Double, right: Double) {
        let snap = store.snapshot()
        return (Double(snap.left), Double(snap.right))
    }

    /// Latest log-spaced frequency-band magnitudes (0...1) for the spectrum meter.
    public func currentBands() -> [Double] {
        store.snapshotBands().map(Double.init)
    }

    /// Clear the stored levels + spectrum (e.g. when switching tracks).
    public func reset() {
        store.update(left: 0, right: 0)
        store.updateBands([Float](repeating: 0, count: SpectrumProcessor.bandCount))
    }

    /// Enable/disable the in-path EQ and set its per-band gains (dB).
    public func setEQ(enabled: Bool, gains: [Double]) {
        store.equalizer.update(enabled: enabled, gainsDB: gains)
    }

    /// Linear makeup gain (≥1) applied in-path so the volume fader can push above
    /// unity (0 dB). 1.0 = no boost. Applied post-EQ, before the meters measure,
    /// so the VU reflects the boosted signal.
    public func setMasterGain(_ gain: Double) {
        store.setMasterGain(Float(max(0, gain)))
    }

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

/// Thread-safe holder for the latest L/R RMS levels: written on the audio
/// thread, read on the main thread.
final class AudioTapLevelStore {
    private let lock = NSLock()
    private var left: Float = 0
    private var right: Float = 0
    private var bands = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
    private var masterGain: Float = 1

    /// Owned here so the audio thread always has a valid, preallocated FFT + EQ.
    let spectrum = SpectrumProcessor()
    let equalizer = EqualizerProcessor()

    func setMasterGain(_ g: Float) { lock.lock(); masterGain = g; lock.unlock() }
    func gainValue() -> Float { lock.lock(); defer { lock.unlock() }; return masterGain }

    func update(left: Float, right: Float) {
        lock.lock(); self.left = left; self.right = right; lock.unlock()
    }

    func snapshot() -> (left: Float, right: Float) {
        lock.lock(); defer { lock.unlock() }
        return (left, right)
    }

    func updateBands(_ b: [Float]) {
        lock.lock(); bands = b; lock.unlock()
    }

    func snapshotBands() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return bands
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

    // Apply the EQ in place FIRST so playback — and the meters below — reflect it.
    if store.equalizer.isEnabled {
        var channelIndex = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let chans = max(Int(buffer.mNumberChannels), 1)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard total > 0 else { continue }
            let s = data.assumingMemoryBound(to: Float.self)
            if chans == 1 {
                store.equalizer.processInPlace(s, stride: 1, frames: total, channel: channelIndex)
                channelIndex += 1
            } else {
                let frames = total / chans
                for c in 0..<chans {
                    store.equalizer.processInPlace(s + c, stride: chans, frames: frames, channel: channelIndex)
                    channelIndex += 1
                }
            }
        }
    }

    // Volume makeup gain (>1 = boost above unity) applied in-place AFTER the EQ
    // and BEFORE the meters, so both what you hear and the VU reflect it.
    var gain = store.gainValue()
    if gain != 1 {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard total > 0 else { continue }
            let s = data.assumingMemoryBound(to: Float.self)
            vDSP_vsmul(s, 1, &gain, s, 1, vDSP_Length(total))
        }
    }

    // RMS, not peak: modern loud masters keep peaks pinned near 1.0, so a
    // peak-driven bar sat at the top barely moving. RMS tracks perceived
    // loudness and actually breathes with the music (vDSP_rmsqv costs the
    // same as the old vDSP_maxmgv scan).
    var levels: [Float] = []
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard totalSamples > 0 else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        if channels == 1 {
            // Non-interleaved: one channel per buffer.
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(totalSamples))
            levels.append(rms)
        } else {
            // Interleaved: stride through each channel.
            let frames = totalSamples / channels
            guard frames > 0 else { continue }
            for c in 0..<channels {
                var rms: Float = 0
                vDSP_rmsqv(samples + c, vDSP_Stride(channels), &rms, vDSP_Length(frames))
                levels.append(rms)
            }
        }
    }

    let left = levels.first ?? 0
    let right = levels.count > 1 ? levels[1] : left
    store.update(left: left, right: right)

    // Spectrum from channel 0 (interleaved → stride by channel count).
    if let first = buffers.first, let data = first.mData {
        let channels = max(Int(first.mNumberChannels), 1)
        let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        if total > 0 {
            let samples = data.assumingMemoryBound(to: Float.self)
            let bands = store.spectrum.compute(samples: samples, stride: channels, count: total / channels)
            store.updateBands(bands)
        }
    }
}
