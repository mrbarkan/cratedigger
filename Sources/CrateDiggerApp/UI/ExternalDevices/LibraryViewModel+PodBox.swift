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

    // MARK: - Busy

    /// One truth for "a device is being written": a send or convert run
    /// (through its catalog patch and session finish), SYNC, Clean Up Mac
    /// Files and FIX ART. Every device writer checks it before it starts, and
    /// both Eject paths do. A new device writer (artist pictures, playlists)
    /// sets its own flag and joins it here.
    var isDeviceBusy: Bool {
        isConversionRunning || deviceSyncProgress?.isRunning == true || isCleaningDeviceFiles || isFixingDeviceArt
    }

    /// The alert a refused start shows.
    @MainActor
    func showDeviceBusyAlert(_ action: String) {
        appAlert = .info(title: "A device is busy",
                         message: "\(action) once the current transfer, sync, cleanup or FIX ART has finished.")
    }

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
    /// The journal is the app's one instance for this profile
    /// (`DeviceWriteJournal.shared`), loaded off the main actor.
    @MainActor
    func makeTransferDoor(for profile: ExternalDeviceProfile, device: MountedDevice,
                          musicFolder: URL) async -> DeviceTransferDoor? {
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
        let journal = await Self.sharedJournal(for: profile.id)
        return DeviceTransferDoor(volumeRoot: device.volumeURL, expectedVolumeUUID: device.volumeUUID,
                                  policy: policy, journal: journal)
    }

    /// The profile's one journal, loaded (on first use) off the main actor.
    nonisolated static func sharedJournal(for profileID: UUID) async -> DeviceWriteJournal {
        await Task.detached(priority: .userInitiated) { DeviceWriteJournal.shared(profileID: profileID) }.value
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

    // MARK: - Finishing a session

    /// Called by every device write path right after `patchDeviceCatalog`.
    /// On FAT and exFAT, removes the proven macOS `._` twins in the folders
    /// the session wrote or deleted in (through the executor: re-proven at
    /// the moment of deletion, a copy kept on the Mac), then returns the
    /// lines the summary ends with: what was cleaned, and what to do next on
    /// the device. It never fails the transfer; a problem is one line.
    @MainActor
    func finishDeviceSession(device: MountedDevice, profile: ExternalDeviceProfile,
                             written: [URL], deleted: [URL], changes: DeviceWriteChanges) async -> [String] {
        let firmware = firmware(for: device)
        // Only once the owner has turned this device's automatic cleanup on
        // (checks M3 and M4); prevention needs no switch.
        let sweeps = DeviceSessionFinish.sweepsAfterTransfer(capabilities: capabilities(for: device),
                                                             preferences: profile.podBoxPreferences)
            && DeviceSessionGate.allows(.sweep, trigger: .userAction, matchedByUUID: isMatchedByUUID(device, profile))
        let policy = devicePolicy(for: profile, firmware: firmware)
        let volume = device.volumeURL
        let uuid = device.volumeUUID
        let profileID = profile.id
        let result = await Task.detached(priority: .userInitiated) { () -> DeviceSessionFinish.Result in
            let executor = DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy,
                                              journal: DeviceWriteJournal.shared(profileID: profileID))
            return DeviceSessionFinish.finish(written: written, deleted: deleted, changes: changes,
                                              firmware: firmware, sweeps: sweeps, volumeRoot: volume,
                                              executor: executor)
        }.value
        if result.removed > 0 {
            AppLog.conversion.notice("Removed \(result.removed) Mac metadata file(s) after the transfer to \(profile.name, privacy: .public)")
        }
        return result.lines
    }

    /// `report` with the session's closing lines and an Eject key for `device`.
    @MainActor
    func deviceReport(_ report: ConversionReport, nextSteps: [String], device: MountedDevice) -> ConversionReport {
        var finished = report
        finished.nextSteps = nextSteps
        finished.eject = { [weak self] in self?.ejectDevice(device) }
        return finished
    }

    // MARK: - Clean Up Mac Files

    /// Plan (a scan on DEVICES), confirm with the counts, remove through the
    /// executor (a transfer on DEVICES), report, offer Eject. Only ever
    /// started by the user: nothing here runs at mount. `scope` nil is the
    /// whole volume; otherwise exactly these folders, each listed on its own.
    /// `scopeNames` are the folders as the confirmation lists them.
    @MainActor
    func cleanUpMacFiles(device: MountedDevice, scope: [URL]?, scopeNames: [String] = []) {
        guard let profile = deviceProfile(for: device) else {
            appAlert = .error(title: "Nothing was cleaned up",
                              message: "\(device.name) has no device profile. Add it in Preferences > Devices first.")
            return
        }
        guard DeviceSessionGate.allows(.sweep, trigger: .userAction, matchedByUUID: isMatchedByUUID(device, profile))
        else {
            appAlert = .error(title: "Nothing was cleaned up", message: "Cleaning up \(device.name) is not allowed now.")
            return
        }
        guard !isDeviceBusy else { return showDeviceBusyAlert("Clean up Mac files") }
        isCleaningDeviceFiles = true
        let scanJob = beginBusyJob(.scan, on: .devices)
        let volume = device.volumeURL
        Task { @MainActor in
            let plan = await Task.detached(priority: .userInitiated) {
                AppleDoubleSweeper().plan(volumeRoot: volume, scope: scope)
            }.value
            endBusyJob(scanJob, .completed)
            isCleaningDeviceFiles = false
            if let refusal = plan.refusal {
                appAlert = .info(title: "Nothing to clean up on \(device.name)",
                                 message: "Its file system (\(refusal)) keeps no Mac metadata files.")
                return
            }
            guard !plan.candidates.isEmpty else {
                appAlert = .info(title: DeviceCleanupSummary.nothingFound,
                                 message: DeviceCleanupSummary.nothingFoundDetail(deviceName: device.name,
                                                                                  leftAlone: plan.leftAlone))
                return
            }
            let text = DeviceCleanupSummary.confirmation(plan, deviceName: device.name, folders: scopeNames)
            appAlert = .actionable(title: text.title, message: text.message, actionTitle: "Remove") { [weak self] in
                self?.removeMacFiles(plan, device: device, profile: profile)
            }
        }
    }

    /// Clean Up Mac Files in This Folder: exactly the folders the selected
    /// tracks are in and the disc folders directly in them
    /// (`AppleDoubleSweeper.cleanupFolders`), never an ancestor.
    @MainActor
    func cleanUpMacFiles(device: MountedDevice, inFolders folders: [URL]) {
        let names = folders.map { DeviceWritePolicy.relativePath(of: $0, under: device.volumeURL) ?? $0.path }
        Task { @MainActor in
            let scope = await Task.detached(priority: .userInitiated) {
                AppleDoubleSweeper.withDiscFolders(folders)
            }.value
            cleanUpMacFiles(device: device, scope: scope, scopeNames: names)
        }
    }

    /// The folders an album's tracks are in on a browsed device, a disc
    /// folder standing for its album folder. Empty for an album with no tracks.
    func deviceFolders(of album: Album) -> [URL] {
        AppleDoubleSweeper.cleanupFolders(forTrackFolders: album.tracks.map { $0.track.fileURL.deletingLastPathComponent() })
    }

    @MainActor
    private func removeMacFiles(_ plan: AppleDoubleSweepPlan, device: MountedDevice, profile: ExternalDeviceProfile) {
        // Its own busy state, not isDeviceTransferRunning: the Patch Bay's
        // Cancel key has nothing to stop here.
        guard !isDeviceBusy else { return showDeviceBusyAlert("Clean up Mac files") }
        isCleaningDeviceFiles = true
        let job = beginBusyJob(.transfer, on: .devices)
        let firmware = firmware(for: device)
        let policy = devicePolicy(for: profile, firmware: firmware)
        let volume = device.volumeURL
        let uuid = device.volumeUUID
        let profileID = profile.id
        Task { @MainActor in
            let outcomes = await Task.detached(priority: .userInitiated) { () -> [DeviceFileOutcome] in
                DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy,
                                   journal: DeviceWriteJournal.shared(profileID: profileID))
                    .apply(plan.operations, sessionID: UUID())
            }.value
            let removed = outcomes.filter { $0 == .deleted }.count
            let refused = outcomes.count - removed - outcomes.filter { $0 == .alreadyGone }.count
            endBusyJob(job, removed == 0 && refused > 0 ? .failed : .completed)
            isCleaningDeviceFiles = false
            AppLog.conversion.notice("Clean Up Mac Files on \(device.name, privacy: .public): removed \(removed), refused \(refused)")

            let lines = [DeviceCleanupSummary.result(removed: removed, refused: refused, leftAlone: plan.leftAlone)]
                + PodBoxNextSteps.after(removed > 0 ? .cleanup : [], firmware: firmware)
            appAlert = .actionable(title: "Cleaned up \(device.name)", message: lines.joined(separator: " "),
                                   actionTitle: "Eject", cancelTitle: "OK") { [weak self] in
                self?.ejectDevice(device)
            }
        }
    }

    // MARK: - Eject

    /// Unmounts and ejects `device` off the main thread. Every write session
    /// has saved its journal by the time its summary offers this (each record
    /// is flushed as it is written). A failure shows the system's own words.
    @MainActor
    func ejectDevice(_ device: MountedDevice) {
        guard !isDeviceBusy else { return showDeviceBusyAlert("Eject \(device.name)") }
        let volume = device.volumeURL
        Task { @MainActor in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                appAlert = .error(title: "Couldn't eject \(device.name)", message: failure)
            } else {
                showOLEDNotice("EJECTED")
            }
        }
    }
}

