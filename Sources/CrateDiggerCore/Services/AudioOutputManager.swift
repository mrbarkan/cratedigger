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
}
