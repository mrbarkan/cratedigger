import CoreAudio
import Foundation

/// The live device list for Ambient, read from Core Audio on every call so an
/// unplugged mic is never answered from a stale cache.
public final class CoreAudioAmbientDevices: AmbientDeviceProviding {

    /// Prefix of the private aggregate `CombinedAmbientEngine` creates. It is
    /// visible to this process while it exists and must never be offered as a
    /// mic or mistaken for the output.
    static let aggregateUIDPrefix = "com.cratedigger.ambient."

    private var listener: AudioObjectPropertyListenerBlock?

    public init() {}

    deinit {
        guard let listener else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    public func inputs() -> [AudioDeviceSummary] { summaries(scope: kAudioObjectPropertyScopeInput) }
    public func allInputs() -> [AudioDeviceSummary] { inputs() }
    public func outputs() -> [AudioDeviceSummary] { summaries(scope: kAudioObjectPropertyScopeOutput) }

    public func input(uid: String?) -> AudioDeviceSummary? {
        find(uid: uid, in: inputs(), defaultSelector: kAudioHardwarePropertyDefaultInputDevice)
    }

    public func output(uid: String?) -> AudioDeviceSummary? {
        find(uid: uid, in: outputs(), defaultSelector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Calls `handler` on the main queue whenever a device appears or goes away.
    /// One handler; a second call replaces the first.
    public func observeDeviceChanges(_ handler: @escaping () -> Void) {
        var address = Self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let listener {
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener)
        }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
            listener = block
        }
    }

    // MARK: - Core Audio

    private func find(uid: String?, in devices: [AudioDeviceSummary],
                      defaultSelector: AudioObjectPropertySelector) -> AudioDeviceSummary? {
        if let uid { return devices.first { $0.uid == uid } }
        guard let defaultID: AudioDeviceID = Self.value(AudioObjectID(kAudioObjectSystemObject), defaultSelector)
        else { return nil }
        return devices.first { $0.id == defaultID }
    }

    private func summaries(scope: AudioObjectPropertyScope) -> [AudioDeviceSummary] {
        Self.deviceIDs().compactMap { id in
            guard Self.streamCount(id, scope: scope) > 0,
                  let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(Self.aggregateUIDPrefix),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            let transport = AudioTransport(coreAudioTransportType: Self.value(id, kAudioDevicePropertyTransportType) ?? 0)
            let dataSource: UInt32? = scope == kAudioObjectPropertyScopeOutput
                ? Self.value(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
                : nil
            return AudioDeviceSummary(
                id: id, uid: uid, name: name, transport: transport,
                isBuiltInSpeaker: AudioDeviceSummary.isBuiltInSpeaker(transport: transport, outputDataSource: dataSource)
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                       alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        // Core Audio hands back a +1 CFString.
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
