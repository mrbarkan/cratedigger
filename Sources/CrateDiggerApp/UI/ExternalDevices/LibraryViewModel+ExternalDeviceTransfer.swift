import AppKit
import CrateDiggerCore
import Foundation

/// An in-flight "send to device (convert)" hand-off to the CNVRT Patch Bay: the
/// device folder becomes the conversion destination and these tracks its queue,
/// overriding the normal saved-output-destination + batch-scope for this one run.
struct PendingDeviceConversion {
    let profileID: UUID
    let deviceName: String
    let destinationRoot: URL
    let tracks: [LoadedTrack]
}

extension LibraryViewModel {
    /// Send tracks to a saved device. Copy-mode devices copy originals straight to
    /// the device; convert-mode devices hand off to the CNVRT Patch Bay with the
    /// device's music folder preset as the destination, where the user picks the
    /// format/folder and hits Go. Grabs the key window as the host for the
    /// mounted-root panel / summary sheet.
    @MainActor
    func transferToDevice(profileID: UUID, tracks rawTracks: [LoadedTrack]) {
        guard let host = presentationHostViewController else { return }

        guard !isConversionRunning else {
            AppLog.conversion.warning("Transfer requested while conversion/transfer is already running")
            return
        }

        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else {
            appAlert = .error(
                title: "Device profile missing",
                message: "The selected device profile could not be found. Open Preferences > Devices and choose the device again."
            )
            return
        }

        // No artwork hydration here: copy-mode transfers move the original files
        // untouched, and convert-mode hands off to runConversion, which hydrates
        // its own queue.
        let tracks = rawTracks
        guard !tracks.isEmpty else {
            appAlert = .info(
                title: "Nothing to transfer",
                message: "No tracks matched the chosen scope. Load a library and select an album or track first."
            )
            return
        }

        switch profile.transferSettings.mode {
        case .copyOriginals:
            runExternalDeviceCopy(profile: profile, tracks: tracks, presentingFrom: host)

        case .convertDuringTransfer:
            Task { @MainActor in
                var resolved = profile
                guard let mountedRoot = await resolveMountedRoot(for: &resolved, presentingFrom: host) else {
                    AppLog.conversion.notice("User cancelled device root selection")
                    return
                }
                let destinationRoot = ExternalDeviceTransferPlanner().destinationRoot(for: resolved, mountedAt: mountedRoot)

                // Hand off to the CNVRT cockpit: the device folder becomes this
                // run's destination and the selected tracks its queue. Seed the
                // cockpit with the device's saved format + folder layout so files
                // land in the device's folder pattern (e.g. AlbumArtist/Album)
                // rather than dumped flat into the music folder. The user can tweak
                // inline before hitting Go; the pre-device selection is restored
                // after the run.
                conversionSelectionBeforeDevice = conversionSelection
                conversionSelection = seededConversionSelection(from: resolved.transferSettings)

                pendingDeviceConversion = PendingDeviceConversion(
                    profileID: resolved.id,
                    deviceName: resolved.name,
                    destinationRoot: destinationRoot,
                    tracks: tracks
                )
                oledView = .conversion
            }
        }
    }

    /// Project a device's saved format + folder layout onto the current conversion
    /// selection, so the CNVRT cockpit reflects (and applies) the device's pattern.
    private func seededConversionSelection(from settings: ExternalDeviceTransferSettings) -> ConversionOptionsSelection {
        var selection = conversionSelection
        selection.outputFormat = settings.outputFormat
        selection.bitrate = settings.bitrateKbps
        selection.sampleRate = settings.sampleRateHz
        selection.artworkMaxDimension = settings.artworkMaxDimension
        selection.folderStructureMode = settings.folderStructureMode
        selection.templatePreset = settings.templateConfig.preset
        selection.tokenOrder = FolderTokenOrder.normalize(settings.templateConfig.tokenOrder)
        return selection
    }

    // MARK: - Copy path

    @MainActor
    private func runExternalDeviceCopy(
        profile: ExternalDeviceProfile,
        tracks sourceTracks: [LoadedTrack],
        presentingFrom host: NSViewController
    ) {
        Task { @MainActor in
            var resolved = profile
            guard let mountedRoot = await resolveMountedRoot(for: &resolved, presentingFrom: host) else {
                AppLog.conversion.notice("User cancelled device root selection")
                return
            }

            let planner = ExternalDeviceTransferPlanner()
            let destinationRoot = planner.destinationRoot(for: resolved, mountedAt: mountedRoot)
            let plans = planner.planTransfers(tracks: sourceTracks, profile: resolved, mountedAt: mountedRoot)

            guard !plans.isEmpty else {
                appAlert = .info(
                    title: "Nothing to transfer",
                    message: "CrateDigger could not build any transfer jobs for the selected device."
                )
                return
            }

            if let problem = validateDeviceTransferPreflight(destinationRoot: destinationRoot, sourceTracks: sourceTracks) {
                appAlert = problem
                return
            }

            let report = await runCopyTransferQueue(plans: plans, deviceName: resolved.name)
            presentSummary(report: report, presentingFrom: host)
        }
    }

    // MARK: - Mounted root

    @MainActor
    private func resolveMountedRoot(
        for profile: inout ExternalDeviceProfile,
        presentingFrom host: NSViewController
    ) async -> URL? {
        if let bookmark = profile.rootBookmark,
           let (refreshed, resolved) = PreferencesStore.refreshBookmarkIfStale(bookmark) {
            if refreshed != bookmark || profile.rootDisplayPath != resolved.url.path {
                profile.rootBookmark = refreshed
                profile.rootDisplayPath = resolved.url.path
                profile.updatedAt = Date()
                prefs.upsertExternalDeviceProfile(profile)
            }
            return resolved.url
        }

        guard let chosen = await promptForMountedDeviceRoot(profileName: profile.name, presentingFrom: host) else {
            return nil
        }

        if let bookmark = try? PreferencesStore.makeBookmark(for: chosen) {
            profile.rootBookmark = bookmark
            profile.rootDisplayPath = chosen.path
            profile.updatedAt = Date()
            prefs.upsertExternalDeviceProfile(profile)
        }
        return chosen
    }

    @MainActor
    private func promptForMountedDeviceRoot(
        profileName: String,
        presentingFrom host: NSViewController
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose \(profileName) root"
        panel.message = "Select the mounted device root, such as /Volumes/IPOD or the SD card volume."
        panel.prompt = "Choose"

        return await withCheckedContinuation { continuation in
            if let window = host.view.window {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                continuation.resume(returning: panel.runModal() == .OK ? panel.url : nil)
            }
        }
    }

    private func validateDeviceTransferPreflight(
        destinationRoot: URL,
        sourceTracks: [LoadedTrack]
    ) -> AppAlert? {
        if let writability = probeDestinationWritability(
            destinationRoot,
            createFailureTitle: "Can't write to device",
            createFailureMessage: "CrateDigger could not create \(destinationRoot.path). Confirm the device is mounted and writable.",
            notWritableTitle: "Device isn't writable",
            notWritableMessage: "CrateDigger cannot write into \(destinationRoot.path). Check the device lock switch, cable mode, or macOS Files & Folders access.",
            probeFilenamePrefix: ".cratedigger-device-probe-"
        ) {
            return writability
        }
        return probeFreeDiskSpace(
            destinationRoot,
            sourceTracks: sourceTracks,
            insufficientSpaceMessageFormat: "This transfer needs ~%.1f GB but the device has %.1f GB available."
        )
    }

    @MainActor
    private func runCopyTransferQueue(
        plans: [PlannedExternalDeviceTransfer],
        deviceName: String
    ) async -> ConversionReport {
        let total = plans.count
        oledView = .conversion
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0,
            jobsTotal: total,
            currentFilename: plans.first?.sourceURL.lastPathComponent,
            isRunning: true
        )

        let outcome = await withCheckedContinuation { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                var succeeded = 0
                var failed = 0
                var lines: [String] = []

                for (index, plan) in plans.enumerated() {
                    if Task.isCancelled {
                        failed += 1
                        lines.append("[FAILED] \(plan.sourceURL.lastPathComponent)\n    Cancelled")
                    } else {
                        do {
                            let directory = plan.destinationURL.deletingLastPathComponent()
                            if !fileManager.fileExists(atPath: directory.path) {
                                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                            }
                            try fileManager.copyItem(at: plan.sourceURL, to: plan.destinationURL)
                            succeeded += 1
                            lines.append("[ok] \(plan.sourceURL.lastPathComponent) -> \(plan.destinationURL.path)")
                        } catch {
                            failed += 1
                            lines.append("[FAILED] \(plan.sourceURL.lastPathComponent)\n    \(error.localizedDescription)")
                        }
                    }

                    let completed = index + 1
                    Task { @MainActor in
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: completed,
                            jobsTotal: total,
                            currentFilename: completed < total ? plans[completed].sourceURL.lastPathComponent : nil,
                            isRunning: completed < total
                        )
                    }
                }

                continuation.resume(returning: (succeeded, failed, lines))
            }
            self.conversionTask = task
        }

        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: total,
            jobsTotal: total,
            currentFilename: nil,
            isRunning: false
        )
        conversionTask = nil

        let title: String
        let statusLine: String
        let tone: StatusTone
        if outcome.1 == 0 {
            title = "Transfer complete"
            statusLine = "\(outcome.0) file\(outcome.0 == 1 ? "" : "s") copied to \(deviceName)"
            tone = .success
        } else if outcome.0 == 0 {
            title = "Transfer failed"
            statusLine = "\(outcome.1) file\(outcome.1 == 1 ? "" : "s") could not be copied"
            tone = .error
        } else {
            title = "Transfer finished with errors"
            statusLine = "\(outcome.0) copied, \(outcome.1) failed"
            tone = .warning
        }

        return ConversionReport(
            title: title,
            statusLine: statusLine,
            details: outcome.2.joined(separator: "\n"),
            tone: tone,
            showsDetailsButton: !outcome.2.isEmpty
        )
    }
}
