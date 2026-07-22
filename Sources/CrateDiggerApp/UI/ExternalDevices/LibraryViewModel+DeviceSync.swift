import AppKit
import CrateDiggerCore
import Foundation

/// Pre-Transfer to Device: bake conversions into a local staging tree while the
/// device is unplugged, then SYNC copies the tree over at mount time. The
/// staging tree mirrors the device layout exactly, so sync is a dumb,
/// restartable copy-if-absent loop — and every staged byte dies the moment it
/// has served its purpose.
extension LibraryViewModel {

    /// nonisolated: the sync loop calls this from a detached task — without it,
    /// the @MainActor class would pin this static to the main actor.
    nonisolated static func modificationDate(of url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
    }

    // MARK: - Staging (device offline)

    /// Queue tracks for an unplugged device. Convert-mode profiles bake now
    /// (staging tree mirrors the device layout, Cnvrt OLED narrates); copy-mode
    /// profiles just record entries — zero local bytes.
    @MainActor
    func stageForSync(
        profile: ExternalDeviceProfile,
        tracks rawTracks: [LoadedTrack],
        presentingFrom host: NSViewController
    ) {
        let existing = syncQueueStore.load(profileID: profile.id)
        let queuedPaths = Set(existing.map { $0.track.track.fileURL.path })
        let tracks = rawTracks.filter { !queuedPaths.contains($0.track.fileURL.path) }
        guard !tracks.isEmpty else {
            appAlert = .info(
                title: "Already queued",
                message: "Every selected track is already waiting to sync to \(profile.name)."
            )
            return
        }

        Task { @MainActor in
            let stagingRoot = syncQueueStore.stagingDirectory(for: profile.id)
            let hydrated = await tracksWithHydratedArtwork(tracks)
            let reserved = Set(existing.map {
                stagingRoot.appendingPathComponent($0.destinationRelativePath)
                    .standardizedFileURL.resolvingSymlinksInPath().path
            })
            let plans = ExternalDeviceTransferPlanner().planTransfers(
                tracks: hydrated,
                profile: profile,
                mountedAt: stagingRoot,
                reservedDestinationPaths: reserved
            )
            guard !plans.isEmpty else {
                appAlert = .info(
                    title: "Nothing to queue",
                    message: "CrateDigger could not plan any transfers for \(profile.name)."
                )
                return
            }

            let trackByPath = Dictionary(
                hydrated.map { ($0.track.fileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let rootPrefix = stagingRoot.standardizedFileURL.path + "/"
            func relative(_ url: URL) -> String {
                let p = url.standardizedFileURL.path
                return p.hasPrefix(rootPrefix) ? String(p.dropFirst(rootPrefix.count)) : url.lastPathComponent
            }
            func entry(for plan: PlannedExternalDeviceTransfer, staged: Bool) -> DeviceSyncQueueEntry? {
                guard let track = trackByPath[plan.sourceURL.path] else { return nil }
                return DeviceSyncQueueEntry(
                    track: track,
                    destinationRelativePath: relative(plan.destinationURL),
                    isStaged: staged,
                    sourceModifiedAt: Self.modificationDate(of: plan.sourceURL)
                )
            }

            let newEntries: [DeviceSyncQueueEntry]
            if plans.first?.action == .convert {
                try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                if let problem = probeFreeDiskSpace(
                    stagingRoot,
                    sourceTracks: hydrated,
                    insufficientSpaceMessageFormat: "Staging these conversions needs ~%.1f GB but this Mac only has %.1f GB free."
                ) {
                    appAlert = problem
                    return
                }
                let service: ConversionService
                do {
                    service = try ConversionService(ffmpegExecutableURL: customFFmpegExecutableURL())
                } catch {
                    appAlert = .error(
                        title: "Couldn't stage conversions",
                        message: "ffmpeg wasn't found. Install it with Homebrew (brew install ffmpeg) or set a custom path in Preferences."
                    )
                    return
                }
                let preset = profile.transferSettings.conversionPreset ?? .genericAAC
                let jobs = plans.compactMap(\.conversionJob)
                let outcome = await runConversionQueue(service: service, jobs: jobs, preset: preset)
                newEntries = plans
                    .filter { outcome.succeededDestinationPaths.contains($0.destinationURL.path) }
                    .compactMap { entry(for: $0, staged: true) }
                let failed = plans.count - newEntries.count
                presentSummary(
                    report: ConversionReport(
                        title: failed == 0 ? "Staged for \(profile.name)" : "Staged with errors",
                        statusLine: "\(newEntries.count) track\(newEntries.count == 1 ? "" : "s") ready to sync"
                            + (failed > 0 ? " · \(failed) failed" : ""),
                        details: outcome.report.details,
                        tone: failed == 0 ? .success : .warning,
                        showsDetailsButton: outcome.report.showsDetailsButton
                    ),
                    presentingFrom: host
                )
            } else {
                // Copy-mode: entries only — sync copies straight from source,
                // so nothing is ever duplicated onto this Mac.
                newEntries = plans.compactMap { entry(for: $0, staged: false) }
                appAlert = .info(
                    title: "Queued for \(profile.name)",
                    message: "\(newEntries.count) track\(newEntries.count == 1 ? "" : "s") will copy over next time you press SYNC."
                )
            }

            guard !newEntries.isEmpty else { return }
            syncQueueStore.save(existing + newEntries, profileID: profile.id)
            refreshSyncQueueCounts()
        }
    }

    // MARK: - Sync (device mounted)

    /// Manual SYNC: copy every queued entry onto the mounted device, skipping
    /// files already there, deleting each staged file the moment its copy
    /// lands. Restartable by construction — failures stay queued.
    @MainActor
    func syncQueuedTransfers(profileID: UUID) {
        guard let host = presentationHostViewController else { return }
        guard !isConversionRunning, deviceSyncProgress?.isRunning != true else { return }
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return }
        let entries = syncQueueStore.load(profileID: profileID)
        guard !entries.isEmpty else { return }
        guard let device = mountedDevices.first(where: { deviceProfile(for: $0)?.id == profileID }) else {
            appAlert = .info(
                title: "Device not connected",
                message: "\(profile.name) isn't mounted. Connect it, then press SYNC."
            )
            return
        }

        Task { @MainActor in
            guard let mountedRoot = await resolveMountedRoot(for: &profile, presentingFrom: host) else { return }
            if let problem = probeDestinationWritability(
                mountedRoot,
                createFailureTitle: "Can't write to device",
                createFailureMessage: "CrateDigger could not write to \(mountedRoot.path). Confirm the device is mounted and writable.",
                notWritableTitle: "Device isn't writable",
                notWritableMessage: "CrateDigger cannot write into \(mountedRoot.path). Check the device lock switch or macOS Files & Folders access.",
                probeFilenamePrefix: ".cratedigger-sync-probe-"
            ) {
                appAlert = problem
                return
            }

            // Free-space preflight on the actual bytes to copy (staged or source).
            let fm = FileManager.default
            let bytesNeeded: Int64 = entries.reduce(0) { sum, entry in
                let url = entry.isStaged
                    ? syncQueueStore.stagedFileURL(for: entry, profileID: profileID)
                    : entry.track.track.fileURL
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                return sum + size
            }
            let free = ((try? mountedRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity).map(Int64.init) ?? .max
            guard bytesNeeded < free else {
                appAlert = .error(
                    title: "Not enough space on \(profile.name)",
                    message: String(
                        format: "This sync needs ~%.1f GB but the device has %.1f GB available.",
                        Double(bytesNeeded) / 1e9, Double(free) / 1e9
                    )
                )
                return
            }

            oledView = .devices
            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profile.name,
                currentRelativePath: entries.first?.destinationRelativePath,
                completed: 0, total: entries.count, failed: 0, isRunning: true
            )

            let profileName = profile.name
            let preset = profile.transferSettings.conversionPreset
            let ffmpegURL = customFFmpegExecutableURL()
            let total = entries.count

            let outcome: (synced: Int, skipped: Int, failed: Int, lines: [String]) =
                await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) { [weak self] in
                        let store = DeviceSyncQueueStore()
                        let fm = FileManager.default
                        var synced = 0, skipped = 0, failed = 0
                        var lines: [String] = []
                        var remaining = entries
                        var service: ConversionService?

                        for (i, entry) in entries.enumerated() {
                            let destination = mountedRoot.appendingPathComponent(entry.destinationRelativePath)
                            let stagedURL = store.stagedFileURL(for: entry, profileID: profileID)
                            let sourceURL = entry.track.track.fileURL
                            do {
                                if fm.fileExists(atPath: destination.path) {
                                    skipped += 1
                                    lines.append("[skip] \(entry.destinationRelativePath) — already on device")
                                } else {
                                    let copyFrom: URL
                                    if entry.isStaged {
                                        // Staleness guard: source edited since baking → re-bake
                                        // in place (ffmpeg -y overwrites the stale file). A
                                        // missing source is fine — the bake stands on its own.
                                        if fm.fileExists(atPath: sourceURL.path),
                                           Self.modificationDate(of: sourceURL) != entry.sourceModifiedAt,
                                           let preset {
                                            if service == nil {
                                                service = try? ConversionService(ffmpegExecutableURL: ffmpegURL)
                                            }
                                            if let service {
                                                _ = service.enqueue(
                                                    [ConversionJob(sourceURL: sourceURL, destinationURL: stagedURL,
                                                                   metadata: entry.track.metadata)],
                                                    preset: preset
                                                )
                                                let results = service.runQueuedJobs(maxConcurrentWorkers: 1) { _, _, _ in }
                                                guard results.first?.status == .completed else {
                                                    throw NSError(
                                                        domain: "CrateDigger.DeviceSync", code: 1,
                                                        userInfo: [NSLocalizedDescriptionKey: "Re-bake failed (source changed since staging)"])
                                                }
                                            }
                                        }
                                        guard fm.fileExists(atPath: stagedURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Staged file missing — remove from queue and re-add"])
                                        }
                                        copyFrom = stagedURL
                                    } else {
                                        guard fm.fileExists(atPath: sourceURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: "Source file missing"])
                                        }
                                        copyFrom = sourceURL
                                    }
                                    let dir = destination.deletingLastPathComponent()
                                    if !fm.fileExists(atPath: dir.path) {
                                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                                    }
                                    try fm.copyItem(at: copyFrom, to: destination)
                                    synced += 1
                                    lines.append("[ok] \(entry.destinationRelativePath)")
                                }
                                // Done (copied or already there): staged bytes are trash now.
                                store.removeStagedFile(for: entry, profileID: profileID)
                                remaining.removeAll { $0.id == entry.id }
                                store.save(remaining, profileID: profileID)
                            } catch {
                                failed += 1
                                lines.append("[FAILED] \(entry.destinationRelativePath)\n    \(error.localizedDescription)")
                            }

                            let done = i + 1
                            let failedSoFar = failed
                            let nextPath = done < total ? entries[done].destinationRelativePath : nil
                            Task { @MainActor [weak self] in
                                self?.deviceSyncProgress = DeviceSyncProgressSnapshot(
                                    profileName: profileName,
                                    currentRelativePath: nextPath,
                                    completed: done, total: total, failed: failedSoFar,
                                    isRunning: done < total
                                )
                            }
                        }

                        if remaining.isEmpty { store.remove(profileID: profileID) }
                        continuation.resume(returning: (synced, skipped, failed, lines))
                    }
                }

            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profileName, currentRelativePath: nil,
                completed: outcome.synced + outcome.skipped, total: total,
                failed: outcome.failed, isRunning: false
            )
            refreshSyncQueueCounts()
            invalidateDeviceCatalog(for: device)
            if case .device(let path) = currentSource, path == device.volumeURL.path {
                refreshLibrary()   // re-walk + refresh the saved catalog now
            }

            let tone: StatusTone = outcome.failed == 0 ? .success : (outcome.synced == 0 ? .error : .warning)
            presentSummary(
                report: ConversionReport(
                    title: outcome.failed == 0 ? "Synced to \(profileName)" : "Sync finished with errors",
                    statusLine: "\(outcome.synced) synced"
                        + (outcome.skipped > 0 ? ", \(outcome.skipped) already on device" : "")
                        + (outcome.failed > 0 ? ", \(outcome.failed) failed" : ""),
                    details: outcome.lines.joined(separator: "\n"),
                    tone: tone,
                    showsDetailsButton: !outcome.lines.isEmpty
                ),
                presentingFrom: host
            )
        }
    }

    // MARK: - Queue management

    /// PENDING badge test — only meaningful while browsing an offline device.
    func isPendingSync(_ trackID: UUID) -> Bool {
        guard case .offlineDevice = currentSource else { return false }
        return pendingSyncTrackIDs.contains(trackID)
    }

    /// Drop queued tracks (and their staged bytes) from the offline device
    /// being browsed, then rebuild its view.
    @MainActor
    func removeFromSyncQueue(trackIDs: Set<UUID>) {
        guard case .offlineDevice(let profileID) = currentSource else { return }
        var entries = syncQueueStore.load(profileID: profileID)
        let doomed = entries.filter { trackIDs.contains($0.track.track.id) }
        guard !doomed.isEmpty else { return }
        for entry in doomed {
            syncQueueStore.removeStagedFile(for: entry, profileID: profileID)
        }
        entries.removeAll { trackIDs.contains($0.track.track.id) }
        if entries.isEmpty {
            syncQueueStore.remove(profileID: profileID)   // wipes staging dir + JSON
        } else {
            syncQueueStore.save(entries, profileID: profileID)
        }
        refreshSyncQueueCounts()
        selectSource(.offlineDevice(profileID: profileID))   // rebuild index + badges
    }
}
