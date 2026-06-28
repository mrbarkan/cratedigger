import AppKit
import CrateDiggerCore
import Foundation

extension LibraryViewModel {
    @MainActor
    func runExternalDeviceTransfer(
        selection: ExternalDeviceTransferSelection,
        presentingFrom host: NSViewController
    ) {
        guard !isConversionRunning else {
            AppLog.conversion.warning("Transfer requested while conversion/transfer is already running")
            return
        }

        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == selection.profileID }) else {
            appAlert = .error(
                title: "Device profile missing",
                message: "The selected device profile could not be found. Open Preferences > Devices and choose the device again."
            )
            return
        }

        let sourceTracks = tracksForBatchScope(selection.batchScope)
        guard !sourceTracks.isEmpty else {
            appAlert = .info(
                title: "Nothing to transfer",
                message: "No tracks matched the chosen scope. Load a library and select an album or track first."
            )
            return
        }

        Task { @MainActor in
            guard let mountedRoot = await resolveMountedRoot(for: &profile, presentingFrom: host) else {
                AppLog.conversion.notice("User cancelled device root selection")
                return
            }

            let planner = ExternalDeviceTransferPlanner()
            let destinationRoot = planner.destinationRoot(for: profile, mountedAt: mountedRoot)
            let plans = planner.planTransfers(
                tracks: sourceTracks,
                profile: profile,
                mountedAt: mountedRoot
            )

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

            switch profile.transferSettings.mode {
            case .copyOriginals:
                let report = await runCopyTransferQueue(
                    plans: plans,
                    deviceName: profile.name
                )
                presentSummary(report: report, presentingFrom: host)

            case .convertDuringTransfer:
                guard let preset = profile.transferSettings.conversionPreset else {
                    appAlert = .error(
                        title: "Transfer profile incomplete",
                        message: "This device is set to convert during transfer, but CrateDigger could not build a conversion preset for it."
                    )
                    return
                }

                let service: ConversionService
                do {
                    service = try ConversionService(ffmpegExecutableURL: customFFmpegExecutableURL())
                } catch {
                    AppLog.conversion.error("Could not initialize ConversionService for device transfer: \(String(describing: error), privacy: .public)")
                    appAlert = .error(
                        title: "Couldn't start transfer",
                        message: "ffmpeg wasn't found in the app bundle or on your system PATH. Install ffmpeg or set a custom path under Preferences > Advanced."
                    )
                    return
                }

                let jobs = plans.compactMap(\.conversionJob)
                let conversionReport = await runConversionQueue(
                    service: service,
                    jobs: jobs,
                    preset: preset
                )
                presentSummary(
                    report: deviceTransferReport(from: conversionReport, deviceName: profile.name),
                    presentingFrom: host
                )
            }
        }
    }

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

    private func deviceTransferReport(from report: ConversionReport, deviceName: String) -> ConversionReport {
        let title: String
        switch report.tone {
        case .success:
            title = "Transfer complete"
        case .warning:
            title = "Transfer finished with errors"
        case .error:
            title = "Transfer failed"
        case .neutral, .info:
            title = "Transfer summary"
        }

        return ConversionReport(
            title: title,
            statusLine: report.statusLine.replacingOccurrences(of: "written", with: "transferred to \(deviceName)"),
            details: report.details,
            tone: report.tone,
            showsDetailsButton: report.showsDetailsButton
        )
    }
}
