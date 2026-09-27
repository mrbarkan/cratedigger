import Foundation

/// What the conversion cockpit's go key actually does — and therefore what it
/// says.
///
/// Four different runs end up under that one key, and they all used to read
/// CONVERT. The device ones are the confusing pair: the device strip offers
/// SYNC NOW for a queue while the cockpit, one press away, offers CONVERT for
/// the same tracks with settings that don't even apply to them (a device
/// converts with its own profile, not the rows above the key). One name per
/// press, decided here.
public enum PatchBayGoAction: Equatable, Sendable {
    /// The crate queue, with the settings above.
    case convert
    /// RIP in the disc bar routed the cockpit at an audio CD: the disc's
    /// tracks are the queue and the settings above are the rip's. The key
    /// doesn't carry the disc's title (an album name overflows it); the
    /// cockpit's Scope row names the disc.
    case ripDisc
    /// A "send to device" hand-off owns the cockpit.
    case sendToDevice(deviceName: String)
    /// The device being browsed has a queue and is plugged in: copy it over.
    case syncToDevice(deviceName: String)
    /// Same queue, device unplugged: bake it now so the sync is a plain copy.
    case preConvertForDevice(deviceName: String)

    public var label: String {
        switch self {
        case .convert:                        return "CONVERT"
        case .ripDisc:                        return "RIP CD"
        case .sendToDevice(let name):         return "SEND TO \(name.uppercased())"
        case .syncToDevice(let name):         return "SYNC TO \(name.uppercased())"
        case .preConvertForDevice(let name):  return "PRE-CONVERT FOR \(name.uppercased())"
        }
    }

    /// True when the run is about a device rather than the crate queue — the
    /// arm readout names the device queue instead of the crate one.
    public var isDeviceRun: Bool {
        switch self {
        case .convert, .ripDisc:                                  return false
        case .sendToDevice, .syncToDevice, .preConvertForDevice: return true
        }
    }

    /// A route (a disc to rip, or a device hand-off) outranks everything — it
    /// *is* the cockpit while it lasts. The view model keeps the two routes
    /// mutually exclusive, so their order here only has to be deterministic.
    /// Otherwise the key runs whichever queue is armed in the QUEUE tab, and
    /// the crate queue is what "nothing armed" means.
    ///
    /// `armedDeviceName` is nil unless that device actually has something
    /// waiting, so an armed device whose queue has drained (a finished sync
    /// empties it) hands the key back to the crate queue rather than leaving
    /// it pointed at nothing.
    public static func resolve(
        hasPendingDisc: Bool = false,
        pendingDeviceName: String?,
        armedDeviceName: String?,
        armedDeviceIsConnected: Bool
    ) -> PatchBayGoAction {
        if hasPendingDisc { return .ripDisc }
        if let pending = pendingDeviceName { return .sendToDevice(deviceName: pending) }
        guard let armed = armedDeviceName else { return .convert }
        return armedDeviceIsConnected
            ? .syncToDevice(deviceName: armed)
            : .preConvertForDevice(deviceName: armed)
    }
}
