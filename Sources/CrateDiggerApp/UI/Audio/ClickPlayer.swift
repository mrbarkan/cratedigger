import AVFoundation
import CrateDiggerCore
import Foundation

/// Synthesizes and plays short procedural "click" buffers so the chassis
/// reads as skeuomorphic hardware. One AVAudioEngine + a small mixer of
/// AVAudioPlayerNodes (round-robin) so rapid presses can overlap.
///
/// Three voices:
/// - `.key`  — soft click for regular KeyButtons (~45 ms)
/// - `.firm` — chunkier thunk for primary / display-mode buttons (~80 ms)
/// - `.tick` — sharp tick for steppers and toggles (~22 ms)
final class ClickPlayer {

    enum Variant {
        case key
        case firm
        case tick
    }

    static let shared = ClickPlayer()

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let voiceCount = 4
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoiceIndex = 0
    private var buffers: [Variant: AVAudioPCMBuffer] = [:]
    private var didStart = false
    private let queue = DispatchQueue(label: "com.cratedigger.app.clicks")

    private init() {
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            // Fall back to whatever the engine offers; still usable.
            self.format = engine.mainMixerNode.outputFormat(forBus: 0)
            return
        }
        self.format = monoFormat
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
            voices.append(node)
        }
        engine.mainMixerNode.outputVolume = 0.55
        prepareBuffers()
    }

    func play(_ variant: Variant) {
        guard PreferencesStore.shared.clickSoundsEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.startIfNeeded()
            guard let buffer = self.buffers[variant], !self.voices.isEmpty else { return }
            let voice = self.voices[self.nextVoiceIndex % self.voices.count]
            self.nextVoiceIndex = (self.nextVoiceIndex + 1) % self.voices.count
            voice.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !voice.isPlaying { voice.play() }
        }
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        do {
            try engine.start()
            didStart = true
        } catch {
            AppLog.ui.warning("Click engine failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private func prepareBuffers() {
        buffers[.key]  = synthClick(durationMS: 45, bodyHz: 1_700, lowHz:  0,   noise: 0.45, decayBody: 65,  decayClick: 280, gain: 0.55)
        buffers[.firm] = synthClick(durationMS: 95, bodyHz:   620, lowHz: 110, noise: 0.55, decayBody: 38,  decayClick: 220, gain: 0.85)
        buffers[.tick] = synthClick(durationMS: 22, bodyHz: 3_400, lowHz:  0,   noise: 0.6,  decayBody: 110, decayClick: 480, gain: 0.40)
    }

    private func synthClick(
        durationMS: Int,
        bodyHz: Double,
        lowHz: Double,
        noise: Double,
        decayBody: Double,
        decayClick: Double,
        gain: Double
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(Double(durationMS) * sampleRate / 1000.0)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        let twoPi = 2 * Double.pi
        // Linear attack ramp in the first ~0.5 ms keeps the transient sharp
        // without producing a click-on-click DC pop.
        let attackSamples = max(1.0, 0.0005 * sampleRate)

        // Pre-roll a tiny amount of seeded noise per buffer so playback is
        // deterministic enough to sound consistent button-to-button.
        var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let attack: Double = Double(frame) < attackSamples
                ? Double(frame) / attackSamples
                : 1.0
            let bodyEnv = attack * exp(-decayBody * t)
            let clickEnv = exp(-decayClick * t)

            // xorshift64 for a fast deterministic noise source
            rngState ^= rngState << 13
            rngState ^= rngState >> 7
            rngState ^= rngState << 17
            let normalized = (Double(rngState & 0xFFFF) / 65535.0) * 2.0 - 1.0

            let body  = sin(twoPi * bodyHz * t) * bodyEnv * 0.55
            let low   = lowHz > 0 ? sin(twoPi * lowHz * t) * bodyEnv * 0.4 : 0.0
            let click = normalized * clickEnv * noise
            let sample = (body + low + click) * gain
            channelData[frame] = Float(max(-1.0, min(1.0, sample)))
        }
        return buffer
    }
}
