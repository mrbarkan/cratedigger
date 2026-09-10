import Foundation
import CoreAudio

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public final class AudioOutputManager: Sendable {
    public init() {}

    public func getOutputDevices() -> [AudioOutputDevice] {
        var deviceList: [AudioOutputDevice] = []

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        for id in deviceIDs {
            // Check if device has output channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            var streamSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
            guard status == noErr && streamSize > 0 else { continue }

            // Retrieve device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            // CoreAudio returns a +1-retained CFString; take it through an
            // Unmanaged box (passing &CFString directly is the unsafe-pointer warning).
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameUnmanaged: Unmanaged<CFString>?
            status = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameUnmanaged)
            guard status == noErr, let nameCF = nameUnmanaged?.takeRetainedValue() else { continue }

            // Retrieve device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidUnmanaged: Unmanaged<CFString>?
            status = AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uidUnmanaged)
            guard status == noErr, let uidCF = uidUnmanaged?.takeRetainedValue() else { continue }

            let deviceName = nameCF as String
            let deviceUID = uidCF as String

            deviceList.append(AudioOutputDevice(uid: deviceUID, name: deviceName))
        }

        return deviceList
    }

    // MARK: - Device IDs & sample rates (DoP path)

    public func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// nil (or unknown) UID means "system default output" — mirroring how a
    /// nil `audioOutputDeviceUniqueID` behaves on AVPlayer.
    public func deviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid else { return defaultOutputDeviceID() }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return defaultOutputDeviceID()
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return defaultOutputDeviceID()
        }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &deviceUID) == noErr,
               let value = deviceUID?.takeRetainedValue() as String?, value == uid {
                return id
            }
        }
        return defaultOutputDeviceID()
    }

    /// Flattened from AudioValueRange: a discrete rate has min == max; a true
    /// range contributes both endpoints (good enough for "supports 176.4k?").
    public func availableSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        var rates: Set<Double> = []
        for range in ranges {
            rates.insert(range.mMinimum)
            rates.insert(range.mMaximum)
        }
        return rates.sorted()
    }

    public func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    @discardableResult
    public func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Double>.size), &value) == noErr
    }
}
