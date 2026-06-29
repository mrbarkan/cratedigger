import Foundation

/// A mounted external storage volume the user can browse and transfer to —
/// a USB drive, SD card, or a Rockbox iPod (which mounts as plain Mass Storage,
/// not the Apple iPod database). Audio CDs are handled separately by
/// `CDRipperService`.
public struct MountedDevice: Sendable, Identifiable, Hashable {
    public let id: String        // volume path — stable while mounted
    public let name: String      // volume name (display)
    public let volumeURL: URL    // e.g. /Volumes/IPOD

    public init(name: String, volumeURL: URL) {
        self.id = volumeURL.path
        self.name = name
        self.volumeURL = volumeURL
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
            .volumeIsInternalKey, .volumeIsBrowsableKey
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
            devices.append(MountedDevice(name: name, volumeURL: url))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
