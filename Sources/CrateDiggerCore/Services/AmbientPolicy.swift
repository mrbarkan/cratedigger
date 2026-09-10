import CoreAudio
import Foundation

/// How a device is connected, as far as Ambient cares.
public enum AudioTransport: Equatable, Sendable {
    case builtIn, bluetooth, usb, other

    public init(coreAudioTransportType: UInt32) {
        switch coreAudioTransportType {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        default: self = .other
        }
    }
}

/// One audio device, reduced to what Ambient decides with.
public struct AudioDeviceSummary: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    /// The Mac's own speakers: Ambient would feed the mic straight back into them.
    public let isBuiltInSpeaker: Bool

    public init(id: AudioDeviceID, uid: String, name: String, transport: AudioTransport,
                isBuiltInSpeaker: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isBuiltInSpeaker = isBuiltInSpeaker
    }

    /// `'ispk'`: the data source a built-in output reports while it drives the
    /// internal speakers.
    static let internalSpeakerDataSource: UInt32 = 0x6973_706B

    // ponytail: only an explicit 'ispk' counts. A built-in speaker that reports
    // no data source slips through; that beats refusing a headphone jack we
    // could not probe. Add a model or name check if such a Mac turns up.
    public static func isBuiltInSpeaker(transport: AudioTransport, outputDataSource: UInt32?) -> Bool {
        transport == .builtIn && outputDataSource == internalSpeakerDataSource
    }
}

public enum AmbientVerdict: Equatable, Sendable {
    case ok
    /// The output is the Mac's speakers, which would howl.
    case blockedBySpeakers
    /// The mic belongs to the Bluetooth headset the music is playing through,
    /// and opening it drops that headset to call-quality audio.
    case needsCallModeApproval
}

/// Whether a mic and an output make a sensible pair. Pure, so every rule that
/// protects a listener's ears is covered by a test.
public enum AmbientPolicy {
    public static func verdict(input: AudioDeviceSummary, output: AudioDeviceSummary,
                               approvedCallModeUIDs: Set<String>) -> AmbientVerdict {
        if output.isBuiltInSpeaker { return .blockedBySpeakers }
        if input.transport == .bluetooth, output.transport == .bluetooth,
           isSameDevice(input, output), !approvedCallModeUIDs.contains(input.uid) {
            return .needsCallModeApproval
        }
        return .ok
    }

    // ponytail: Bluetooth devices show up as "<address>:input" and
    // "<address>:output" (probed on a UGREEN receiver), or as one object for
    // both. Name equality is the fallback, so two identically named headsets
    // would warn needlessly, which is harmless.
    static func isSameDevice(_ a: AudioDeviceSummary, _ b: AudioDeviceSummary) -> Bool {
        baseUID(a.uid) == baseUID(b.uid) || a.name == b.name
    }

    private static func baseUID(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }
}
