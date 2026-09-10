import AVFoundation
import CoreAudio
import Foundation

/// Why an Ambient engine could not start. The text is shown to the listener.
public enum AmbientEngineError: LocalizedError, Equatable {
    case couldNotUseDevice(name: String, status: OSStatus)
    case noSignal(name: String)
    case audioFormat
    case couldNotCombine(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .couldNotUseDevice(let name, let status):
            return "\(name) could not be opened (Core Audio error \(status))."
        case .noSignal(let name):
            return "\(name) is not delivering any audio."
        case .audioFormat:
            return "The audio format for Ambient could not be set up."
        case .couldNotCombine(let status):
            return "macOS would not combine the microphone and the output (Core Audio error \(status)). Try the Split engine."
        }
    }
}

// MARK: - Engine A: Split

/// Two `AVAudioEngine`s, one per device. The mic engine's sink node downmixes
/// to mono, resamples to the output's rate when the two differ, and writes an
/// `AmbientRingBuffer`; the output engine's source node reads it, then the low
/// cut, then the device the music plays through.
///
/// The ring is the delay: its target fill is `delaySeconds` at the output rate.
/// It also absorbs the drift between two unrelated clocks, which is what lets
/// a laptop mic feed Bluetooth headphones at all.
@MainActor
public final class SplitAmbientEngine: AmbientEngine {
    public var onConfigurationChange: (@MainActor () -> Void)?

    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var ring: AmbientRingBuffer?
    private var feeder: MicFeeder?
    private var lowCut: AVAudioUnitEQ?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func start(_ config: AmbientEngineConfig) throws {
        stop()

        let input = AVAudioEngine()
        try AmbientAudio.pin(input.inputNode, to: config.input)
        let inputFormat = input.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AmbientEngineError.noSignal(name: config.input.name)
        }

        let output = AVAudioEngine()
        try AmbientAudio.pin(output.outputNode, to: config.output)
        let outputRate = output.outputNode.outputFormat(forBus: 0).sampleRate
        guard outputRate > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1) else {
            throw AmbientEngineError.audioFormat
        }

        // One second of room: the longest delay setting is a small part of it,
        // and overflow only happens if the output stalls.
        let ring = AmbientRingBuffer(capacityFrames: Int(outputRate),
                                     targetFrames: Int(outputRate * config.delaySeconds))
        ring.gain = config.gain
        let feeder = try MicFeeder(inputFormat: inputFormat, outputRate: outputRate, ring: ring)

        let sink = Self.makeSink(feeding: feeder)
        input.attach(sink)
        input.connect(input.inputNode, to: sink, format: inputFormat)

        let source = Self.makeSource(reading: ring, format: mono)
        let lowCut = AmbientAudio.makeLowCut(enabled: config.lowCut)
        output.attach(source)
        output.attach(lowCut)
        output.connect(source, to: lowCut, format: mono)
        output.connect(lowCut, to: output.mainMixerNode, format: mono)

        do {
            output.prepare()
            try output.start()
            input.prepare()
            try input.start()
        } catch {
            input.stop()
            output.stop()
            throw error
        }

        inputEngine = input
        outputEngine = output
        self.ring = ring
        self.feeder = feeder
        self.lowCut = lowCut
        // Only after both are running: pinning a device can itself post a
        // configuration change, which must not trigger a rebuild of this start.
        observers = [input, output].map { engine in
            AmbientAudio.observeConfigurationChange(of: engine) { [weak self] in self?.onConfigurationChange?() }
        }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        inputEngine?.stop()
        outputEngine?.stop()
        inputEngine = nil
        outputEngine = nil
        ring = nil
        feeder = nil
        lowCut = nil
    }

    public func setGain(_ gain: Float) { ring?.gain = gain }

    public func setLowCut(_ enabled: Bool) { lowCut?.bands.first?.bypass = !enabled }

    // The render blocks run on Core Audio's IO threads. Built in nonisolated
    // functions so they can never be inferred to belong to the main actor.

    private nonisolated static func makeSink(feeding feeder: MicFeeder) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, bufferList in
            feeder.consume(bufferList, frameCount: Int(frameCount))
            return noErr
        }
    }

    private nonisolated static func makeSource(reading ring: AmbientRingBuffer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                ring.read(into: data, frameCount: Int(frameCount))
            }
            return noErr
        }
    }
}

/// The mic side of the split engine, on the input IO thread: downmix to mono,
/// resample when the rates differ, write the ring. Buffers are allocated once.
final class MicFeeder: @unchecked Sendable {
    private static let maxFrames: AVAudioFrameCount = 8192

    private let ring: AmbientRingBuffer
    private let mono: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let converted: AVAudioPCMBuffer?

    init(inputFormat: AVAudioFormat, outputRate: Double, ring: AmbientRingBuffer) throws {
        guard let monoIn = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: Self.maxFrames) else {
            throw AmbientEngineError.audioFormat
        }
        self.ring = ring
        self.mono = mono

        if inputFormat.sampleRate == outputRate {
            converter = nil
            converted = nil
        } else {
            let capacity = AVAudioFrameCount((Double(Self.maxFrames) * outputRate / inputFormat.sampleRate).rounded(.up)) + 64
            guard let monoOut = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
                  let converter = AVAudioConverter(from: monoIn, to: monoOut),
                  let converted = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: capacity) else {
                throw AmbientEngineError.audioFormat
            }
            self.converter = converter
            self.converted = converted
        }
    }

    func consume(_ list: UnsafePointer<AudioBufferList>, frameCount: Int) {
        let frames = min(frameCount, Int(Self.maxFrames))
        guard frames > 0, let out = mono.floatChannelData?[0] else { return }
        out.update(repeating: 0, count: frames)

        // ponytail: averages the first two channels. An interface with more
        // inputs contributes only its first pair; add a channel picker if
        // someone plugs in an 8-channel interface and wants input 5.
        var used = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard used < 2, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let interleaved = max(1, Int(buffer.mNumberChannels))
            for channel in 0..<min(interleaved, 2 - used) {
                for frame in 0..<frames { out[frame] += data[frame * interleaved + channel] }
                used += 1
            }
        }
        if used > 1 {
            let scale = 1 / Float(used)
            for frame in 0..<frames { out[frame] *= scale }
        }

        guard let converter, let converted else {
            ring.write(out, frameCount: frames)
            return
        }
        mono.frameLength = AVAudioFrameCount(frames)
        converted.frameLength = 0
        // ponytail: the input block allocates a small closure context per IO
        // cycle, on the mic thread only. Hoist it if Instruments shows glitches.
        var handedOver = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if handedOver {
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return self.mono
        }
        if error == nil, converted.frameLength > 0, let data = converted.floatChannelData?[0] {
            ring.write(data, frameCount: Int(converted.frameLength))
        }
    }
}

// MARK: - Engine B: Combined

/// One `AVAudioEngine` on a private aggregate of the mic and the output, with
/// the output as the clock and drift compensation on the mic. macOS does the
/// resampling; the delay setting becomes the device's IO buffer size.
///
/// Less code in the audio path than Split, and on some hardware it sounds
/// better. It is also the one more likely to fail when a Bluetooth device
/// renegotiates, which is why it is a choice and not the default.
@MainActor
public final class CombinedAmbientEngine: AmbientEngine {
    public var onConfigurationChange: (@MainActor () -> Void)?

    private var engine: AVAudioEngine?
    private var aggregateID: AudioDeviceID?
    private var lowCut: AVAudioUnitEQ?
    private var observer: NSObjectProtocol?

    public init() {}

    public func start(_ config: AmbientEngineConfig) throws {
        stop()

        // A device that is both mic and output (a USB interface) needs no
        // aggregate; macOS refuses to aggregate a device with itself anyway.
        let device: AudioDeviceSummary
        if config.input.uid == config.output.uid {
            device = config.output
        } else {
            let id = try Self.createAggregate(inputUID: config.input.uid, outputUID: config.output.uid)
            aggregateID = id
            device = AudioDeviceSummary(id: id, uid: "", name: "Ambient", transport: .other)
        }

        do {
            Self.setBufferDuration(config.delaySeconds, deviceID: device.id)
            let engine = AVAudioEngine()
            try AmbientAudio.pin(engine.inputNode, to: device)
            try AmbientAudio.pin(engine.outputNode, to: device)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AmbientEngineError.noSignal(name: config.input.name)
            }

            let lowCut = AmbientAudio.makeLowCut(enabled: config.lowCut)
            engine.attach(lowCut)
            engine.connect(engine.inputNode, to: lowCut, format: inputFormat)
            engine.connect(lowCut, to: engine.mainMixerNode, format: inputFormat)
            self.engine = engine
            self.lowCut = lowCut
            setGain(config.gain)

            engine.prepare()
            try engine.start()
            observer = AmbientAudio.observeConfigurationChange(of: engine) { [weak self] in
                self?.onConfigurationChange?()
            }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        lowCut = nil
        if let aggregateID { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = nil
    }

    /// The mixer's volume stops at unity, so boost above it rides the EQ's
    /// global gain (which reaches +24 dB).
    public func setGain(_ gain: Float) {
        engine?.mainMixerNode.outputVolume = min(1, gain)
        lowCut?.globalGain = gain > 1 ? min(24, 20 * log10(gain)) : 0
    }

    public func setLowCut(_ enabled: Bool) { lowCut?.bands.first?.bypass = !enabled }

    private static func createAggregate(inputUID: String, outputUID: String) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: CoreAudioAmbientDevices.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "CrateDigger Ambient",
            // Private: invisible to other apps, and gone when this process is.
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1]
            ]
        ]
        var id = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { throw AmbientEngineError.couldNotCombine(status: status) }
        return id
    }

    /// Best effort: a device that rejects the size keeps its own, and Ambient
    /// still runs, just at that device's latency.
    private static func setBufferDuration(_ seconds: Double, deviceID: AudioDeviceID) {
        guard let rate = AudioOutputManager().nominalSampleRate(deviceID: deviceID) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(max(32, min(4096, (rate * seconds).rounded())))
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }
}

// MARK: - Shared

enum AmbientAudio {
    /// Point an engine's input or output node at a specific device. Must run
    /// before the node's format is read or the engine is started.
    static func pin(_ node: AVAudioIONode, to device: AudioDeviceSummary) throws {
        guard let unit = node.audioUnit else {
            throw AmbientEngineError.couldNotUseDevice(name: device.name, status: -1)
        }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AmbientEngineError.couldNotUseDevice(name: device.name, status: status)
        }
    }

    /// A high-pass at 120 Hz: fridge hum, fan drone and footsteps out, voices
    /// and doorbells through. Bypassed rather than removed when off, so the
    /// switch never touches the graph.
    static func makeLowCut(enabled: Bool) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        if let band = eq.bands.first {
            band.filterType = .highPass
            band.frequency = 120
            band.bypass = !enabled
        }
        return eq
    }

    @MainActor
    static func observeConfigurationChange(of engine: AVAudioEngine,
                                           _ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
