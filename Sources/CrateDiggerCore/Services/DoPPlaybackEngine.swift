import AVFoundation
import Foundation

/// Bit-perfect DSD playback via DoP: memory-maps a DSF, packs DoP frames in the
/// render callback, and feeds them through an AVAudioSourceNode wired STRAIGHT
/// to the output node at the DoP frame rate. Nothing on this path may modify
/// samples — volume, EQ, and master gain are deliberate no-ops (a corrupted
/// marker stream degrades to noise on the DAC). Stereo LSB-first DSF only;
/// anything else is the PCM decode path's job (DSDOutputPolicy enforces this).
final class DoPPlaybackEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?

    private let outputManager = AudioOutputManager()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var timeTimer: Timer?
    private var outputDeviceUID: String?

    private var info: DSFInfo?
    private var mapped: Data?
    /// Playback position in DoP frames (16 DSD bits per frame per channel).
    /// Written by the render thread and seek; reads/writes go through the lock,
    /// held only for the copy.
    private let cursorLock = NSLock()
    private var frameCursor: Int64 = 0
    private var isPlaying = false

    private var totalFrames: Int64 {
        guard let info else { return 0 }
        return info.dataByteCountPerChannel / 2
    }

    var currentTimeSeconds: Double {
        guard let info else { return 0 }
        cursorLock.lock(); defer { cursorLock.unlock() }
        return Double(frameCursor) / info.dopFrameRateHz
    }

    var durationSeconds: Double { info?.durationSeconds ?? 0 }

    func replaceCurrentItem(url: URL) {
        stopEngine()
        do {
            let info = try DSFFile.readInfo(url: url)
            guard info.channelCount == 2, info.lsbFirst else {
                throw DSFReadError.malformedHeader
            }
            self.mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            self.info = info
            cursorLock.lock(); frameCursor = 0; cursorLock.unlock()
            DispatchQueue.main.async { self.onItemReady?() }
        } catch {
            self.info = nil
            self.mapped = nil
            DispatchQueue.main.async {
                self.onItemFailed?("DSD native load failed: \(error.localizedDescription)")
            }
        }
    }

    func play() {
        guard let info, mapped != nil else { return }
        if audioEngine == nil {
            do { try buildEngine(frameRate: info.dopFrameRateHz) } catch {
                onItemFailed?("DSD native output failed: \(error.localizedDescription)")
                return
            }
        }
        isPlaying = true
        startTimeTimer()
    }

    func pause() {
        isPlaying = false
        timeTimer?.invalidate()
        timeTimer = nil
    }

    func seek(toSeconds seconds: Double) {
        guard let info else { return }
        let target = Int64((seconds * info.dopFrameRateHz).rounded())
        cursorLock.lock()
        frameCursor = max(0, min(target, totalFrames))
        cursorLock.unlock()
    }

    /// Bit-perfect: the volume knob must not scale DoP samples.
    func setVolume(_ volume: Double) {}

    func setOutputDeviceUID(_ uid: String?) {
        outputDeviceUID = uid
        // Rebuild on the new device if we were already rendering.
        if audioEngine != nil {
            let wasPlaying = isPlaying
            stopEngine()
            isPlaying = wasPlaying
            if wasPlaying { play() }
        }
    }

    var currentLevels: (left: Double, right: Double) {
        guard let info, let mapped else { return (0, 0) }
        cursorLock.lock(); let frame = frameCursor; cursorLock.unlock()
        let window = info.blockSizeBytes
        func level(channel: Int) -> Double {
            let start = channelByteOffset(channelByteIndex: frame * 2, channel: channel, info: info)
            guard start >= 0, start + window <= mapped.count else { return 0 }
            let amplitude = DSDLevelMeter.amplitude(of: mapped[start..<start + window])
            return PlaybackMeterScale.position(fromLinear: amplitude)
        }
        return (level(channel: 0), level(channel: 1))
    }

    var currentSpectrum: [Double] { [] }

    // MARK: - Engine plumbing

    private func buildEngine(frameRate: Double) throws {
        // Lock the DEVICE to the DoP rate first — any SRC destroys the markers.
        if let deviceID = outputManager.deviceID(forUID: outputDeviceUID) {
            outputManager.setNominalSampleRate(frameRate, deviceID: deviceID)
        }
        let engine = AVAudioEngine()
        if let deviceID = outputManager.deviceID(forUID: outputDeviceUID),
           let audioUnit = engine.outputNode.audioUnit {
            var mutableID = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &mutableID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frameRate,
                                         channels: 2, interleaved: false) else {
            throw DSFReadError.malformedHeader
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, buffers in
            self?.render(frameCount: Int(frameCount), buffers: buffers) ?? noErr
        }
        engine.attach(node)
        // Straight to the output node — no mixer, nothing touches the samples.
        engine.connect(node, to: engine.outputNode, format: format)
        try engine.start()
        audioEngine = engine
        sourceNode = node
    }

    private func stopEngine() {
        timeTimer?.invalidate()
        timeTimer = nil
        isPlaying = false
        if let engine = audioEngine {
            engine.stop()
            if let node = sourceNode { engine.detach(node) }
        }
        audioEngine = nil
        sourceNode = nil
    }

    /// DSF interleaves fixed-size per-channel blocks: [ch0 4096][ch1 4096]….
    private func channelByteOffset(channelByteIndex: Int64, channel: Int, info: DSFInfo) -> Int {
        let block = Int64(info.blockSizeBytes)
        let blockIndex = channelByteIndex / block
        let within = channelByteIndex % block
        return Int(info.dataOffset
            + blockIndex * block * Int64(info.channelCount)
            + Int64(channel) * block
            + within)
    }

    private func render(frameCount: Int, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard abl.count >= 2,
              let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        guard isPlaying, let info, let mapped else {
            for i in 0..<frameCount { left[i] = 0; right[i] = 0 }
            return noErr
        }
        cursorLock.lock()
        var frame = frameCursor
        cursorLock.unlock()
        let total = totalFrames
        var reachedEnd = false
        mapped.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<frameCount {
                let marker = DoPPacker.markers[Int(frame & 1)]
                if frame >= total {
                    // Idle with valid markers over DSD silence so the DAC holds
                    // its DoP lock instead of clicking out to PCM.
                    let silence = DoPPacker.float(fromWord: DoPPacker.word(
                        marker: marker, older: 0x69, newer: 0x69, lsbFirst: false))
                    left[i] = silence
                    right[i] = silence
                    reachedEnd = true
                    frame += 1
                    continue
                }
                let byteIndex = frame * 2
                let l0 = bytes[channelByteOffset(channelByteIndex: byteIndex, channel: 0, info: info)]
                let l1 = bytes[channelByteOffset(channelByteIndex: byteIndex + 1, channel: 0, info: info)]
                let r0 = bytes[channelByteOffset(channelByteIndex: byteIndex, channel: 1, info: info)]
                let r1 = bytes[channelByteOffset(channelByteIndex: byteIndex + 1, channel: 1, info: info)]
                left[i] = DoPPacker.float(fromWord: DoPPacker.word(
                    marker: marker, older: l0, newer: l1, lsbFirst: info.lsbFirst))
                right[i] = DoPPacker.float(fromWord: DoPPacker.word(
                    marker: marker, older: r0, newer: r1, lsbFirst: info.lsbFirst))
                frame += 1
            }
        }
        cursorLock.lock()
        frameCursor = min(frame, total)
        cursorLock.unlock()
        if reachedEnd {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
                self.onItemEnded?()
            }
        }
        return noErr
    }

    private func startTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onPeriodicTime?(self.currentTimeSeconds, self.durationSeconds)
        }
    }

    deinit {
        timeTimer?.invalidate()
        audioEngine?.stop()
    }
}
