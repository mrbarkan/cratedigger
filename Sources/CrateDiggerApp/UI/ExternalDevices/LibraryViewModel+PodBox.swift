import AppKit
import CrateDiggerCore
import Foundation

/// PodBox and the device write door, wired. Mounting a device only reads it
/// (spec invariant I6): the firmware probe is the one thing a mount does.
/// The decisions are Core's (`DeviceFirmwareProbe`, `DeviceCapabilities`,
/// `DeviceWritePolicy`, `DeviceSessionGate`); this keeps the results and
/// hands them to the views.
extension LibraryViewModel {
    /// Posted whenever `deviceFirmware` changes, for Preferences ▸ Devices,
    /// which is not a view of the model.
    static let deviceFirmwareChangedNotification = Notification.Name("CrateDiggerDeviceFirmwareChanged")

    // MARK: - Firmware

    /// Probes every mounted device off the main actor and keeps what each
    /// one's `.rockbox` folder says, dropping entries for devices that went.
    /// The probe opens files for reading only and holds no handle past its
    /// return; nothing is written and nothing is saved.
    @MainActor
    func refreshDeviceFirmware() {
        let devices = mountedDevices
        let mountedIDs = Set(devices.map(\.id))
        let kept = deviceFirmware.filter { mountedIDs.contains($0.key) }
        if kept.count != deviceFirmware.count { deviceFirmware = kept }
        guard !devices.isEmpty else { return }
        let probed = devices.filter { device in
            DeviceSessionGate.allows(.probe, trigger: .mount,
                                     matchedByUUID: deviceProfile(for: device).map { isMatchedByUUID(device, $0) } ?? false)
        }
        Task { @MainActor in
            let found = await Task.detached(priority: .utility) { () -> [MountedDevice.ID: DeviceFirmware] in
                var result: [MountedDevice.ID: DeviceFirmware] = [:]
                for device in probed {
                    result[device.id] = DeviceFirmwareProbe.probe(volumeRoot: device.volumeURL)
                }
                return result
            }.value
            // Only devices still mounted now: one may have gone during the probe.
            let stillMounted = Set(mountedDevices.map(\.id))
            var next = deviceFirmware.filter { stillMounted.contains($0.key) }
            for device in probed where stillMounted.contains(device.id) {
                next[device.id] = found[device.id]
            }
            if next != deviceFirmware { deviceFirmware = next }
        }
    }

    func firmware(for device: MountedDevice) -> DeviceFirmware? {
        deviceFirmware[device.id]
    }

    /// What may be offered for `device`: from its probe and its file system
    /// (`statfs`'s type name, "msdos", "exfat", "apfs").
    func capabilities(for device: MountedDevice) -> DeviceCapabilities {
        DeviceCapabilities(firmware: firmware(for: device),
                           fileSystem: AppleDoubleSweeper.systemFileSystemType(device.volumeURL))
    }

    /// The mounted device a saved profile belongs to right now, if any.
    func mountedDevice(forProfileID id: UUID) -> MountedDevice? {
        mountedDevices.first { deviceProfile(for: $0)?.id == id }
    }

    // MARK: - Policy and identity

    /// The write policy for `profile`: its music folder, relative to the
    /// volume, and the playlist folder PodBox's config names. Roles beyond
    /// audio, covers and temps stay off until a later phase enables them.
    func devicePolicy(for profile: ExternalDeviceProfile, firmware: DeviceFirmware?) -> DeviceWritePolicy {
        DeviceWritePolicy(musicSubpath: musicSubpath(for: profile),
                          playlistDirectory: firmware?.config.playlistDirectory ?? "Playlists")
    }

    /// The profile's music folder relative to its volume. The profile stores
    /// it relative to its own root, which may itself sit below the volume
    /// root (an SD card chosen at a subfolder), so the root's own place on the
    /// volume comes first.
    func musicSubpath(for profile: ExternalDeviceProfile) -> String {
        let subpath = ExternalDeviceProfile.normalizedSubpath(profile.musicDirectorySubpath)
        guard let rootPath = profile.rootDisplayPath,
              let device = MountedDevice.containing(URL(fileURLWithPath: rootPath, isDirectory: true), in: mountedDevices),
              let rootOnVolume = DeviceWritePolicy.relativePath(of: URL(fileURLWithPath: rootPath, isDirectory: true),
                                                                under: device.volumeURL)
        else { return subpath }
        return [rootOnVolume, subpath].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// True only when both the profile and the volume carry a UUID and they
    /// agree: a profile matched by name or mount path could be another iPod.
    func isMatchedByUUID(_ device: MountedDevice, _ profile: ExternalDeviceProfile) -> Bool {
        guard let deviceUUID = device.volumeUUID, let profileUUID = profile.volumeUUID else { return false }
        return deviceUUID == profileUUID
    }

    // MARK: - The write door

    /// The door one user-started transfer to `device` writes through: the
    /// volume (its UUID checked again before every write), the policy for
    /// the music folder the run writes into, and this profile's journal.
    /// nil, with an alert, when the music folder is not on that volume or the
    /// session gate refuses (it never does for a user action today, but the
    /// gate is where that decision lives).
    @MainActor
    func makeTransferDoor(for profile: ExternalDeviceProfile, device: MountedDevice,
                          musicFolder: URL) -> DeviceTransferDoor? {
        guard DeviceSessionGate.allows(.transferAudio, trigger: .userAction,
                                       matchedByUUID: isMatchedByUUID(device, profile)) else {
            appAlert = .error(title: "Nothing was sent to \(profile.name)",
                              message: "CrateDigger only writes to a device when you ask it to.")
            return nil
        }
        guard let subpath = DeviceWritePolicy.relativePath(of: musicFolder, under: device.volumeURL) else {
            appAlert = .error(title: "Nothing was sent to \(profile.name)",
                              message: "Its music folder is not on \(device.name). Open Preferences > Devices and choose the device again.")
            return nil
        }
        let policy = DeviceWritePolicy(musicSubpath: subpath,
                                       playlistDirectory: firmware(for: device)?.config.playlistDirectory ?? "Playlists")
        return DeviceTransferDoor(volumeRoot: device.volumeURL, expectedVolumeUUID: device.volumeUUID,
                                  policy: policy, journal: DeviceWriteJournal(profileID: profile.id))
    }

    /// Whether `folder` on a device can be written, found out without writing
    /// to it: the volume is not mounted read-only, and the deepest folder on
    /// the way to `folder` that exists accepts writes. (The old probe wrote a
    /// file onto the device to find out.)
    func deviceWritabilityProblem(_ folder: URL, deviceName: String) -> AppAlert? {
        var existing = folder.standardizedFileURL
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            existing = existing.deletingLastPathComponent()
        }
        let readOnly = (try? existing.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        if readOnly == true || !FileManager.default.isWritableFile(atPath: existing.path) {
            return .error(
                title: "\(deviceName) isn't writable",
                message: "CrateDigger cannot write into \(folder.path). Check the device lock switch, cable mode, or macOS Files & Folders access."
            )
        }
        return nil
    }
}
