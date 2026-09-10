import AudioToolbox
import CoreAudio
import Foundation
import os

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

// Why raw HAL units and not AVAudioEngine: merely touching
// `AVAudioEngine.inputNode` opens the *system default* mic before the node can
// be pointed anywhere else. Probed on a UGREEN Bluetooth receiver that is the
// default input: its output dropped to 8 kHz call mode at that step, the node
// still read 8 kHz after being pinned to the MacBook mic, and a start took 21 s
// or never returned. A HAL unit is told its device before it initialises and
// never touches the default (probed: the receiver stayed at 44.1 kHz).

// MARK: - Engine A: Split

/// Two HAL units, one per device. The mic unit captures mono at the mic's own
/// rate into an `AmbientRingBuffer`; the output unit reads the ring at that same
/// rate and lets the HAL convert to the output device, so there is no
/// resampler of ours in the path. The ring is the delay, and absorbs the drift
/// between two unrelated clocks.
@MainActor
public final class SplitAmbientEngine: AmbientEngine {
    public var onConfigurationChange: (@MainActor () -> Void)?

    private var context: AmbientRenderContext?
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var watch: AmbientDeviceWatch?

    public init() {}

    public func start(_ config: AmbientEngineConfig) throws {
        stop()
        guard let micRate = AudioOutputManager().nominalSampleRate(deviceID: config.input.id) else {
            throw AmbientEngineError.noSignal(name: config.input.name)
        }
        // One second of room; the longest delay setting is a small part of it.
        let ring = AmbientRingBuffer(capacityFrames: Int(micRate),
                                     targetFrames: Int(micRate * config.delaySeconds))
        let context = AmbientRenderContext(sampleRate: micRate, gain: config.gain, lowCut: config.lowCut, ring: ring)
        self.context = context

        do {
            let input = try HALUnit.makeInput(device: config.input, rate: micRate, context: context,
                                              callback: micCaptureCallback)
            inputUnit = input
            outputUnit = try HALUnit.makeOutput(device: config.output, rate: micRate, context: context,
                                                callback: ringPlaybackCallback)
            try HALUnit.check(AudioOutputUnitStart(outputUnit!), config.output.name)
            try HALUnit.check(AudioOutputUnitStart(input), config.input.name)
        } catch {
            stop()
            throw error
        }

        watch = AmbientDeviceWatch(devices: [config.input.id, config.output.id], rateOf: config.input.id) { [weak self] in
            self?.onConfigurationChange?()
        }
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        HALUnit.dispose(inputUnit)
        HALUnit.dispose(outputUnit)
        inputUnit = nil
        outputUnit = nil
        // Only once both units are gone can no IO callback still reach it.
        context = nil
    }

    public func setGain(_ gain: Float) { context?.setGain(gain) }

    public func setLowCut(_ enabled: Bool) { context?.setLowCut(enabled) }
}

// MARK: - Engine B: Combined

/// One full-duplex HAL unit on a private aggregate of the mic and the output,
/// with the output as the clock and drift compensation on the mic. Each IO
/// cycle pulls the mic and writes the output in the same callback, so there is
/// no ring; the delay setting becomes the device's buffer size.
///
/// On some hardware it sounds better than Split. It is also the one more likely
/// to fail when a Bluetooth device renegotiates, which is why it is a choice
/// and not the default.
@MainActor
public final class CombinedAmbientEngine: AmbientEngine {
    public var onConfigurationChange: (@MainActor () -> Void)?

    private var context: AmbientRenderContext?
    private var unit: AudioUnit?
    private var aggregateID: AudioDeviceID?
    private var watch: AmbientDeviceWatch?

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
            let manager = AudioOutputManager()
            guard let rate = manager.nominalSampleRate(deviceID: device.id)
                    ?? manager.nominalSampleRate(deviceID: config.output.id) else {
                throw AmbientEngineError.noSignal(name: config.input.name)
            }
            Self.setBufferDuration(config.delaySeconds, rate: rate, deviceID: device.id)
            let context = AmbientRenderContext(sampleRate: rate, gain: config.gain, lowCut: config.lowCut, ring: nil)
            self.context = context
            let unit = try HALUnit.makeDuplex(device: device, rate: rate, context: context, callback: duplexCallback)
            self.unit = unit
            try HALUnit.check(AudioOutputUnitStart(unit), config.input.name)
        } catch {
            stop()
            throw error
        }

        watch = AmbientDeviceWatch(devices: [config.input.id, config.output.id], rateOf: config.input.id) { [weak self] in
            self?.onConfigurationChange?()
        }
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        HALUnit.dispose(unit)
        unit = nil
        context = nil
        if let aggregateID { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = nil
    }

    public func setGain(_ gain: Float) { context?.setGain(gain) }

    public func setLowCut(_ enabled: Bool) { context?.setLowCut(enabled) }

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
    private static func setBufferDuration(_ seconds: Double, rate: Double, deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(max(32, min(4096, (rate * seconds).rounded())))
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }
}

// MARK: - IO callbacks (Core Audio's real-time threads)

/// Split, mic side: render the mic into scratch, then into the ring.
private let micCaptureCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frameCount, _ in
    Unmanaged<AmbientRenderContext>.fromOpaque(refCon).takeUnretainedValue()
        .captureMic(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
}

/// Split, output side: read the ring, low cut and gain, same sound to every channel.
private let ringPlaybackCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let ioData else { return noErr }
    Unmanaged<AmbientRenderContext>.fromOpaque(refCon).takeUnretainedValue()
        .playRing(into: UnsafeMutableAudioBufferListPointer(ioData), frameCount: Int(frameCount))
    return noErr
}

/// Combined: pull the mic from the same unit in the output's own callback.
private let duplexCallback: AURenderCallback = { refCon, flags, timeStamp, _, frameCount, ioData in
    guard let ioData else { return noErr }
    Unmanaged<AmbientRenderContext>.fromOpaque(refCon).takeUnretainedValue()
        .passThrough(flags: flags, timeStamp: timeStamp,
                     into: UnsafeMutableAudioBufferListPointer(ioData), frameCount: Int(frameCount))
    return noErr
}

/// What the IO callbacks share: the ring (Split only), the gain and the low
/// cut behind one lock, and preallocated scratch. The callbacks reach it
/// through an unretained pointer, so the engine keeps it alive until its units
/// are disposed.
final class AmbientRenderContext: @unchecked Sendable {
    static let maxFrames = 8192

    let ring: AmbientRingBuffer?
    /// Set once, before the unit initialises.
    var inputUnit: AudioUnit?

    private let scratch: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var lowCut: AmbientLowCutFilter
    private var gain: Float

    init(sampleRate: Double, gain: Float, lowCut: Bool, ring: AmbientRingBuffer?) {
        self.ring = ring
        self.gain = gain
        var filter = AmbientLowCutFilter(sampleRate: sampleRate)
        filter.isEnabled = lowCut
        self.lowCut = filter
        scratch = .allocate(capacity: Self.maxFrames)
        scratch.initialize(repeating: 0, count: Self.maxFrames)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        scratch.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func setGain(_ value: Float) {
        os_unfair_lock_lock(lock)
        gain = value
        os_unfair_lock_unlock(lock)
    }

    func setLowCut(_ enabled: Bool) {
        os_unfair_lock_lock(lock)
        lowCut.isEnabled = enabled
        os_unfair_lock_unlock(lock)
    }

    func captureMic(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
                    bus: UInt32, frameCount: UInt32) -> OSStatus {
        guard let inputUnit, let ring else { return noErr }
        let frames = min(Int(frameCount), Self.maxFrames)
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                                         mData: UnsafeMutableRawPointer(scratch)))
        let status = AudioUnitRender(inputUnit, flags, timeStamp, bus, UInt32(frames), &list)
        guard status == noErr else { return status }
        ring.write(scratch, frameCount: frames)
        return noErr
    }

    func playRing(into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let ring, let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        ring.read(into: first, frameCount: frameCount)
        shape(first, frameCount: frameCount)
        copyToOtherChannels(first, buffers: buffers, frameCount: frameCount)
    }

    func passThrough(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
                     into buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let inputUnit, let first = buffers.first?.mData else { return }
        let samples = first.assumingMemoryBound(to: Float.self)
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4),
                                                         mData: first))
        if AudioUnitRender(inputUnit, flags, timeStamp, 1, UInt32(frameCount), &list) != noErr {
            samples.update(repeating: 0, count: frameCount)
        }
        shape(samples, frameCount: frameCount)
        copyToOtherChannels(samples, buffers: buffers, frameCount: frameCount)
    }

    /// Low cut, then level.
    private func shape(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        os_unfair_lock_lock(lock)
        lowCut.process(samples, frameCount: frameCount)
        if gain != 1 {
            for index in 0..<frameCount { samples[index] *= gain }
        }
        os_unfair_lock_unlock(lock)
    }

    private func copyToOtherChannels(_ samples: UnsafeMutablePointer<Float>,
                                     buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for buffer in buffers.dropFirst() {
            buffer.mData?.assumingMemoryBound(to: Float.self).update(from: samples, count: frameCount)
        }
    }
}

// MARK: - HAL units

enum HALUnit {
    static func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else { throw AmbientEngineError.couldNotUseDevice(name: name, status: status) }
    }

    /// Capture only: input on, output off, device set before initialising, which
    /// is what keeps it off the system default mic. Mono client format at the
    /// device's own rate (the HAL does not resample input).
    static func makeInput(device: AudioDeviceSummary, rate: Double, context: AmbientRenderContext,
                          callback: @escaping AURenderCallback) throws -> AudioUnit {
        let unit = try make(device.name)
        do {
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), device.name)
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), device.name)
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, device.name)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format(rate: rate, channels: 1), device.name)
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                    AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()),
                    device.name)
            context.inputUnit = unit
            try check(AudioUnitInitialize(unit), device.name)
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Playback only. Stereo client format at `rate`; the HAL converts to the
    /// device's rate.
    static func makeOutput(device: AudioDeviceSummary, rate: Double, context: AmbientRenderContext,
                           callback: @escaping AURenderCallback) throws -> AudioUnit {
        let unit = try make(device.name)
        do {
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, device.name)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format(rate: rate, channels: 2), device.name)
            try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                    AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()),
                    device.name)
            try check(AudioUnitInitialize(unit), device.name)
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Input and output on one device, mono in and stereo out at its rate.
    static func makeDuplex(device: AudioDeviceSummary, rate: Double, context: AmbientRenderContext,
                           callback: @escaping AURenderCallback) throws -> AudioUnit {
        let unit = try make(device.name)
        do {
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), device.name)
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, device.name)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format(rate: rate, channels: 1), device.name)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format(rate: rate, channels: 2), device.name)
            try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                    AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()),
                    device.name)
            context.inputUnit = unit
            try check(AudioUnitInitialize(unit), device.name)
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    static func dispose(_ unit: AudioUnit?) {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static func make(_ name: String) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AmbientEngineError.audioFormat }
        var instance: AudioUnit?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else {
            throw AmbientEngineError.couldNotUseDevice(name: name, status: status)
        }
        return instance
    }

    private static func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                               _ element: AudioUnitElement, _ value: T, _ name: String) throws {
        var value = value
        try check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), name)
    }

    /// 32-bit float, non-interleaved (one buffer per channel).
    private static func format(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                        | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
}

// MARK: - Device watch

/// Reports, on the main actor, when a device an engine runs on dies or the
/// mic's sample rate changes (its client format is fixed to that rate). The
/// output's rate is not watched: the HAL converts to it by itself.
@MainActor
final class AmbientDeviceWatch {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(devices: [AudioDeviceID], rateOf mic: AudioDeviceID, onChange: @escaping @MainActor () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        for id in Set(devices) {
            register(id, kAudioDevicePropertyDeviceIsAlive, block)
        }
        register(mic, kAudioDevicePropertyNominalSampleRate, block)
    }

    func cancel() {
        for (id, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        registrations = []
    }

    private func register(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
            registrations.append((id, address, block))
        }
    }
}
