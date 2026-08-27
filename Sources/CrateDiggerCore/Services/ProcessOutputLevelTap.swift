import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Real VU levels for audio the app plays but can't tap at the item level.
///
/// `AudioLevelTap` hangs an `MTAudioProcessingTap` off an `AVPlayerItem`'s audio
/// track, which covers local files — but **HLS has no `AVAssetTrack`**, so
/// `audioMix` is silently ignored and the meters sit flat. Every YouTube stream
/// resolves to HLS (`StreamResolver.formatSelector` prefers `m3u8` because the
/// progressive URLs 403 AVPlayer), so radio had no meters at all.
///
/// This taps one level lower instead: a CoreAudio **process tap** on our own
/// process, so it measures whatever CrateDigger actually sends to the hardware —
/// HLS included, and the WebView engine's audio too. Levels are post-volume and
/// post-EQ by construction.
///
/// macOS 14.4+ (`AudioHardwareCreateProcessTap`). Older systems get a tap that
/// starts successfully and reports silence, which is what they did before.
public final class ProcessOutputLevelTap: @unchecked Sendable {
    private let store = AudioTapLevelStore()
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    public init() {}

    deinit { stop() }

    /// Latest linear-RMS levels mapped onto the meter scale (0...1), matching
    /// what `AVPlayerEngine.currentLevels` returns for local files.
    public func currentLevels() -> (left: Double, right: Double) {
        let snap = store.snapshot()
        return (PlaybackMeterScale.position(fromLinear: Double(snap.left)),
                PlaybackMeterScale.position(fromLinear: Double(snap.right)))
    }

    public func currentBands() -> [Double] {
        store.snapshotBands().map(Double.init)
    }

    /// Idempotent. Silently no-ops if the tap can't be built (pre-14.4, or
    /// CoreAudio refuses) — a dead meter is not worth failing playback over.
    public func start() {
        guard #available(macOS 14.4, *), ioProcID == nil else { return }
        guard let outputUID = defaultOutputDeviceUID() else { return }

        let description = CATapDescription(stereoMixdownOfProcesses: [processAudioObjectID()])
        description.isPrivate = true      // not published to other apps
        description.muteBehavior = .unmuted   // measure, never silence playback
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return }

        // The tap needs a device to be clocked by; a private aggregate over the
        // current default output does that without appearing in any device list.
        // ponytail: built once at start. Switching the default output device
        // mid-stream stops the meter until the next stream — rebuild on
        // kAudioHardwarePropertyDefaultOutputDevice if that becomes a complaint.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CrateDigger Meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            stop()
            return
        }

        let store = self.store
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, _, _ in
            measure(input, into: store)
        }
        guard status == noErr, let ioProcID, AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            stop()
            return
        }
    }

    /// Idempotent teardown. Leaving the aggregate device alive would keep an IO
    /// thread (and the tap) running for the rest of the session.
    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            if #available(macOS 14.4, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
        store.update(left: 0, right: 0)
        store.updateBands([Float](repeating: 0, count: SpectrumProcessor.bandCount))
    }

    // MARK: - CoreAudio lookups

    private func processAudioObjectID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String? : nil
    }
}

/// RMS per channel + spectrum from one IO cycle of the tap. Runs on CoreAudio's
/// real-time thread, so it stays vDSP-cheap and writes behind the store's lock —
/// same contract as `levelTapProcess` in `AudioLevelTap`.
private func measure(_ bufferList: UnsafePointer<AudioBufferList>, into store: AudioTapLevelStore) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))

    var levels: [Float] = []
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard total > 0 else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        if channels == 1 {
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(total))
            levels.append(rms)
        } else {
            let frames = total / channels
            guard frames > 0 else { continue }
            for c in 0..<channels {
                var rms: Float = 0
                vDSP_rmsqv(samples + c, vDSP_Stride(channels), &rms, vDSP_Length(frames))
                levels.append(rms)
            }
        }
    }
    guard !levels.isEmpty else { return }
    store.update(left: levels[0], right: levels.count > 1 ? levels[1] : levels[0])

    if let first = buffers.first, let data = first.mData {
        let channels = max(Int(first.mNumberChannels), 1)
        let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        if total > 0 {
            let samples = data.assumingMemoryBound(to: Float.self)
            store.updateBands(store.spectrum.compute(samples: samples, stride: channels, count: total / channels))
        }
    }
}
