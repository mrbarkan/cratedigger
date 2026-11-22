import Foundation

/// A mounted external storage volume the user can browse and transfer to —
/// a USB drive, SD card, or a Rockbox iPod (which mounts as plain Mass Storage,
/// not the Apple iPod database). Audio CDs are handled separately by
/// `CDRipperService`.
public struct MountedDevice: Sendable, Identifiable, Hashable {
    public let id: String          // volume path — stable while mounted
    public let name: String        // volume name (display)
    public let volumeURL: URL      // e.g. /Volumes/IPOD
    public let volumeUUID: String? // stable across remounts/renames when available

    public init(name: String, volumeURL: URL, volumeUUID: String? = nil) {
        self.id = volumeURL.path
        self.name = name
        self.volumeURL = volumeURL
        self.volumeUUID = volumeUUID
    }

    /// Stable key for the persisted catalog — survives renames/path changes when
    /// the volume reports a UUID, else falls back to the name.
    public var catalogKey: String { volumeUUID ?? name }

    /// The mounted volume `url` lies on: the volume itself, or one whose path
    /// followed by a separator starts `url`'s path, compared without case as a
    /// FAT or exFAT volume does (`/Volumes/IPOD 2` is not on `/Volumes/IPOD`).
    /// The deepest match wins when volumes nest. nil when none holds it.
    public static func containing(_ url: URL, in devices: [MountedDevice]) -> MountedDevice? {
        func key(_ url: URL) -> String {
            let path = url.standardizedFileURL.path.lowercased()
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let target = key(url)
        return devices
            .filter { device in
                let volume = key(device.volumeURL)
                return target == volume || target.hasPrefix(volume == "/" ? "/" : volume + "/")
            }
            .max { key($0.volumeURL).count < key($1.volumeURL).count }
    }
}

public extension MountedDevice {
    /// The mounted device `url` lies on, when that device belongs to a saved
    /// profile (`ExternalDeviceProfile.match`); nil for a file on the Mac or
    /// on a volume no profile names. What a writer outside the device door
    /// (an ordinary conversion pointed at a device, a library action on a
    /// browsed device) asks before it writes there.
    static func profileDevice(holding url: URL, in devices: [MountedDevice],
                              profiles: [ExternalDeviceProfile]) -> MountedDevice? {
        guard let device = containing(url, in: devices),
              ExternalDeviceProfile.match(device, in: profiles) != nil
        else { return nil }
        return device
    }
}

/// Detects mounted removable/ejectable volumes (excluding the internal boot
/// disk and network shares) so they can appear as Sources.
public struct DeviceDetectionService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func detectDevices() -> [MountedDevice] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeUUIDStringKey
        ]
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var devices: [MountedDevice] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            let isInternal = values.volumeIsInternal ?? false
            let browsable = values.volumeIsBrowsable ?? true
            guard removable, !isInternal, browsable else { continue }
            let name = values.volumeName ?? url.lastPathComponent
            devices.append(MountedDevice(name: name, volumeURL: url, volumeUUID: values.volumeUUIDString))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
