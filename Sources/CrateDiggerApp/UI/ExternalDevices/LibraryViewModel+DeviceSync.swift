import AppKit
import CrateDiggerCore
import Foundation

/// Pre-Transfer to Device: queue tracks for a device that isn't plugged in,
/// then SYNC writes them at mount time. Queuing never converts — that is a
/// separate, explicit step (CONVERT NOW), which bakes into a local staging tree
/// laid out exactly like the device so the sync itself stays a dumb, restartable
/// copy-if-absent loop. Anything left unbaked is converted on the way over
/// instead. Every staged byte dies the moment it has served its purpose.
extension LibraryViewModel {

    /// nonisolated: the sync loop calls this from a detached task — without it,
    /// the @MainActor class would pin this static to the main actor.
    nonisolated static func modificationDate(of url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
    }

    // MARK: - Staging (device offline)

    /// Queue tracks for an unplugged device.
    ///
    /// Queuing is bookkeeping and nothing else — no ffmpeg, no staged bytes, no
    /// waiting. It used to bake convert-mode profiles on the spot, which spent
    /// minutes and gigabytes committing to a format before you had a chance to
    /// look at the list or change your mind about it. The bake is now yours to
    /// order: CONVERT NOW on the strip, or automatically as part of SYNC.
    @MainActor
    func stageForSync(profile: ExternalDeviceProfile, tracks rawTracks: [LoadedTrack]) {
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

        let stagingRoot = syncQueueStore.stagingDirectory(for: profile.id)
        let reserved = Set(existing.map {
            stagingRoot.appendingPathComponent($0.destinationRelativePath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        })
        // Planned against the staging tree because that is where a bake would
        // land; the same relative path is what gets written on the device.
        let plans = ExternalDeviceTransferPlanner().planTransfers(
            tracks: tracks,
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
            tracks.map { ($0.track.fileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rootPrefix = stagingRoot.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String {
            let p = url.standardizedFileURL.path
            return p.hasPrefix(rootPrefix) ? String(p.dropFirst(rootPrefix.count)) : url.lastPathComponent
        }
        // Every entry starts unbaked. `sourceModifiedAt` is stamped at bake
        // time, so it stays at .distantPast until then and can't make a fresh
        // bake look stale.
        let newEntries: [DeviceSyncQueueEntry] = plans.compactMap { plan in
            guard let track = trackByPath[plan.sourceURL.path] else { return nil }
            return DeviceSyncQueueEntry(
                track: track,
                destinationRelativePath: relative(plan.destinationURL),
                isStaged: false,
                sourceModifiedAt: .distantPast
            )
        }
        guard !newEntries.isEmpty else { return }

        syncQueueStore.save(existing + newEntries, profileID: profile.id)
        refreshSyncQueueCounts()
        // Queuing while browsing this offline device: rebuild the view so the
        // rows and badges reflect what is now waiting.
        if case .offlineDevice(let pid) = currentSource, pid == profile.id {
            selectSource(currentSource)
        }

        let n = newEntries.count
        let noun = "\(n) track\(n == 1 ? "" : "s")"
        appAlert = .info(
            title: "Queued for \(profile.name)",
            message: profile.transferSettings.mode == .convertDuringTransfer
                ? "\(noun) queued. Nothing has been converted yet — press CONVERT NOW to bake them at the current settings (\(profile.transferSettings.summary)), or just press SYNC and it happens on the way over."
                : "\(noun) queued. They copy over as-is the next time you press SYNC."
        )
    }

    /// A bake is frozen at the settings it was made with — changing the format in
    /// Preferences ▸ Devices doesn't touch files already converted. This throws
    /// those bakes away and leaves the entries queued, so the next CONVERT NOW
    /// (or SYNC) remakes them at the current settings. The queue keeps its order
    /// and nothing has to be re-planned.
    @MainActor
    func restageWithCurrentSettings(trackIDs: Set<UUID>) {
        guard case .offlineDevice(let profileID) = currentSource else { return }
        var entries = syncQueueStore.load(profileID: profileID)
        var changed = false
        for i in entries.indices where trackIDs.contains(entries[i].track.track.id) && entries[i].isStaged {
            syncQueueStore.removeStagedFile(for: entries[i], profileID: profileID)
            entries[i].isStaged = false
            entries[i].sourceModifiedAt = .distantPast
            changed = true
        }
        guard changed else { return }
        syncQueueStore.save(entries, profileID: profileID)
        refreshSyncQueueCounts()
        showOLEDNotice("RE-CONVERT QUEUED")
    }

    /// True when any of these queued tracks carries staged (baked) bytes —
    /// i.e. dropping the bake would actually change something. Copy-mode queues
    /// stage nothing, so it isn't offered there.
    func canRestageSyncEntries(trackIDs: Set<UUID>) -> Bool {
        guard case .offlineDevice(let profileID) = currentSource else { return false }
        return syncQueueStore.load(profileID: profileID)
            .contains { trackIDs.contains($0.track.track.id) && $0.isStaged }
    }

    // MARK: - Convert on demand (device still offline)

    /// CONVERT NOW: bake every unbaked entry into the staging tree with the
    /// profile's *current* settings, so the eventual sync is a plain copy.
    ///
    /// Purely optional — the sync converts anything still raw on its way over.
    /// Its point is timing: you can spend the ffmpeg minutes now, while the
    /// device is in a drawer, instead of standing over the cable later.
    @MainActor
    func convertQueuedTransfers(profileID: UUID) {
        guard let host = presentationHostViewController else { return }
        guard !isConversionRunning, deviceSyncProgress?.isRunning != true else { return }
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              // Folder-art devices carry the cover as a cover.jpg sidecar the
              // sync writes onto the device, so the baked files hold none.
              let preset = profile.transferSettings.conversionPreset(embeddingArtwork: !profile.usesFolderCoverArt)
        else { return }

        let entries = syncQueueStore.load(profileID: profileID)
        let unbaked = entries.enumerated().filter { !$0.element.isStaged }
        guard !unbaked.isEmpty else { return }

        let stagingRoot = syncQueueStore.stagingDirectory(for: profileID)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        if let problem = probeFreeDiskSpace(
            stagingRoot,
            sourceTracks: unbaked.map(\.element.track),
            insufficientSpaceMessageFormat: "Converting these needs ~%.1f GB of staging space but this Mac only has %.1f GB free."
        ) {
            appAlert = problem
            return
        }

        let service: ConversionService
        do {
            service = try ConversionService(ffmpegExecutableURL: customFFmpegExecutableURL())
        } catch {
            appAlert = .error(
                title: "Couldn't convert",
                message: "ffmpeg wasn't found. Install it with Homebrew (brew install ffmpeg) or set a custom path in Preferences."
            )
            return
        }

        Task { @MainActor in
            // Artwork rides the queue as a hash, so the bytes have to come back
            // before ffmpeg can embed them.
            let hydrated = await tracksWithHydratedArtwork(unbaked.map(\.element.track))
            let metadataByPath = Dictionary(
                hydrated.map { ($0.track.fileURL.path, $0.metadata) },
                uniquingKeysWith: { first, _ in first }
            )
            let jobs = unbaked.map { _, entry in
                ConversionJob(
                    sourceURL: entry.track.track.fileURL,
                    destinationURL: stagingRoot.appendingPathComponent(entry.destinationRelativePath),
                    metadata: metadataByPath[entry.track.track.fileURL.path] ?? entry.track.metadata
                )
            }
            let outcome = await runConversionQueue(service: service, jobs: jobs, preset: preset)

            // Re-read rather than write back the pre-bake snapshot: a long bake
            // gives you plenty of time to queue more, and those additions must
            // survive it.
            var current = syncQueueStore.load(profileID: profileID)
            var bakedIDs: [UUID: Date] = [:]
            for (offset, (_, entry)) in unbaked.enumerated()
            where outcome.succeededDestinationPaths.contains(jobs[offset].destinationURL.path) {
                bakedIDs[entry.id] = Self.modificationDate(of: entry.track.track.fileURL)
            }
            for i in current.indices {
                guard let modified = bakedIDs[current[i].id] else { continue }
                current[i].isStaged = true
                current[i].sourceModifiedAt = modified
            }
            let baked = bakedIDs.count
            syncQueueStore.save(current, profileID: profileID)
            refreshSyncQueueCounts()

            let failed = jobs.count - baked
            presentSummary(
                report: ConversionReport(
                    title: failed == 0 ? "Converted for \(profile.name)" : "Converted with errors",
                    statusLine: "\(baked) track\(baked == 1 ? "" : "s") ready to copy"
                        + " · \(profile.transferSettings.summary)"
                        + (failed > 0 ? " · \(failed) failed" : ""),
                    details: outcome.report.details,
                    tone: failed == 0 ? .success : .warning,
                    showsDetailsButton: outcome.report.showsDetailsButton
                ),
                presentingFrom: host
            )
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
                // Entries already on the device are skipped by the loop below,
                // so counting them here false-failed a mostly-synced queue.
                let destination = mountedRoot.appendingPathComponent(entry.destinationRelativePath)
                guard !fm.fileExists(atPath: destination.path) else { return sum }
                let url = entry.isStaged
                    ? syncQueueStore.stagedFileURL(for: entry, profileID: profileID)
                    : entry.track.track.fileURL
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                return sum + size
            }
            let free = mountedRoot.volumeFreeBytes ?? .max
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
            let preset = profile.transferSettings
                .conversionPreset(embeddingArtwork: !profile.usesFolderCoverArt)
            let ffmpegURL = customFFmpegExecutableURL()
            let total = entries.count

            // Entries nobody pre-converted get converted on the way over, so
            // their artwork bytes have to be back before ffmpeg runs — the queue
            // stores art by hash. Baked entries already carry theirs.
            var metadataByPath: [String: ConversionMetadata] = [:]
            if preset != nil {
                let raw = entries.filter { !$0.isStaged }.map(\.track)
                if !raw.isEmpty {
                    metadataByPath = Dictionary(
                        await tracksWithHydratedArtwork(raw)
                            .map { ($0.track.fileURL.path, $0.metadata) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
            }

            let outcome: (synced: Int, skipped: Int, failed: Int, lines: [String]) =
                await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) { [weak self] in
                        let store = DeviceSyncQueueStore()
                        let fm = FileManager.default
                        var synced = 0, skipped = 0, failed = 0
                        var lines: [String] = []
                        var service: ConversionService?

                        // Checkpointing, rather than a full queue rewrite per
                        // entry (which re-encoded the whole JSON n times for an
                        // n-track sync). Re-reading the queue at each checkpoint
                        // also preserves anything staged *while* this sync runs
                        // — writing back a pre-loop snapshot silently dropped it.
                        var doneIDs = Set<UUID>()
                        let checkpointEvery = 25
                        func persistQueue() {
                            guard !doneIDs.isEmpty else { return }
                            let left = store.load(profileID: profileID)
                                .filter { !doneIDs.contains($0.id) }
                            if left.isEmpty {
                                store.remove(profileID: profileID)
                            } else {
                                store.save(left, profileID: profileID)
                            }
                        }

                        for (i, entry) in entries.enumerated() {
                            let destination = mountedRoot.appendingPathComponent(entry.destinationRelativePath)
                            let stagedURL = store.stagedFileURL(for: entry, profileID: profileID)
                            let sourceURL = entry.track.track.fileURL
                            do {
                                if fm.fileExists(atPath: destination.path) {
                                    skipped += 1
                                    lines.append("[skip] \(entry.destinationRelativePath) — already on device")
                                } else {
                                    /// One ffmpeg run, shared service. Throws with the
                                    /// caller's reason so the failure line names it.
                                    func convert(to output: URL, metadata: ConversionMetadata,
                                                 failure: String) throws {
                                        guard let preset else {
                                            throw NSError(domain: "CrateDigger.DeviceSync", code: 4,
                                                          userInfo: [NSLocalizedDescriptionKey: failure])
                                        }
                                        if service == nil {
                                            service = try? ConversionService(ffmpegExecutableURL: ffmpegURL)
                                        }
                                        guard let service else {
                                            throw NSError(domain: "CrateDigger.DeviceSync", code: 5,
                                                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg wasn't found"])
                                        }
                                        _ = service.enqueue(
                                            [ConversionJob(sourceURL: sourceURL, destinationURL: output,
                                                           metadata: metadata)],
                                            preset: preset
                                        )
                                        let results = service.runQueuedJobs(maxConcurrentWorkers: 1) { _, _, _ in }
                                        guard results.first?.status == .completed else {
                                            throw NSError(domain: "CrateDigger.DeviceSync", code: 1,
                                                          userInfo: [NSLocalizedDescriptionKey: failure])
                                        }
                                    }

                                    let dir = destination.deletingLastPathComponent()
                                    if !fm.fileExists(atPath: dir.path) {
                                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                                    }

                                    if entry.isStaged {
                                        // Staleness guard: source edited since baking → re-bake
                                        // in place (ffmpeg -y overwrites the stale file). A
                                        // missing source is fine — the bake stands on its own.
                                        if fm.fileExists(atPath: sourceURL.path),
                                           Self.modificationDate(of: sourceURL) != entry.sourceModifiedAt,
                                           preset != nil {
                                            try convert(to: stagedURL, metadata: entry.track.metadata,
                                                        failure: "Re-bake failed (source changed since staging)")
                                        }
                                        guard fm.fileExists(atPath: stagedURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Staged file missing — remove from queue and re-add"])
                                        }
                                        try fm.copyItem(at: stagedURL, to: destination)
                                    } else {
                                        guard fm.fileExists(atPath: sourceURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: "Source file missing"])
                                        }
                                        if preset != nil {
                                            // Queued but never pre-converted: ffmpeg writes it
                                            // straight onto the device, no staging round-trip.
                                            try convert(
                                                to: destination,
                                                metadata: metadataByPath[sourceURL.path] ?? entry.track.metadata,
                                                failure: "Conversion failed"
                                            )
                                        } else {
                                            try fm.copyItem(at: sourceURL, to: destination)
                                        }
                                    }
                                    synced += 1
                                    lines.append("[ok] \(entry.destinationRelativePath)")
                                }
                                // Done (copied or already there): staged bytes are trash now.
                                store.removeStagedFile(for: entry, profileID: profileID)
                                doneIDs.insert(entry.id)
                                if doneIDs.count % checkpointEvery == 0 { persistQueue() }
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

                        persistQueue()
                        continuation.resume(returning: (synced, skipped, failed, lines))
                    }
                }

            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profileName, currentRelativePath: nil,
                completed: outcome.synced + outcome.skipped, total: total,
                failed: outcome.failed, isRunning: false
            )
            await writeFolderCoverArt(
                profileID: profileID,
                folderTracks: entries.map {
                    (mountedRoot.appendingPathComponent($0.destinationRelativePath)
                        .deletingLastPathComponent(), $0.track)
                }
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

    /// PENDING badge test. Queue membership is a property of the file, not of
    /// where you happen to be browsing — a track waiting for the iPod reads as
    /// waiting in your library too.
    func isPendingSync(_ loaded: LoadedTrack) -> Bool {
        guard !pendingSyncPaths.isEmpty else { return false }
        return pendingSyncPaths.contains(loaded.track.fileURL.path)
    }

    /// Orange-dot tests. Both read precomputed sets — see `recomputePendingSyncMarks`.
    func hasPendingSync(_ album: Album) -> Bool { pendingSyncAlbumIDs.contains(album.id) }
    func hasPendingSync(_ artist: Artist) -> Bool { pendingSyncArtistIDs.contains(artist.id) }

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

    // MARK: - Queue visibility (the browser's device strip)

    /// The device whose contents you're looking at, mounted or not.
    var browsedDeviceProfile: ExternalDeviceProfile? {
        switch currentSource {
        case .offlineDevice(let profileID):
            return prefs.savedExternalDeviceProfiles.first { $0.id == profileID }
        case .device(let volumePath):
            return mountedDevices
                .first { $0.volumeURL.path == volumePath }
                .flatMap { deviceProfile(for: $0) }
        default:
            return nil
        }
    }

    /// Devices with something waiting, fullest queue first.
    var queuedDeviceProfiles: [ExternalDeviceProfile] {
        prefs.savedExternalDeviceProfiles
            .filter { (syncQueueCounts[$0.id] ?? 0) > 0 }
            .sorted { (syncQueueCounts[$0.id] ?? 0) > (syncQueueCounts[$1.id] ?? 0) }
    }

    /// The queued entries themselves, for the Patch Bay's device lists. Reads
    /// the store, so call it on appear — never from a view body.
    func syncQueueEntries(profileID: UUID) -> [DeviceSyncQueueEntry] {
        syncQueueStore.load(profileID: profileID)
    }

    /// What's waiting for a given device. `.empty` until something is queued.
    func syncQueueSummary(profileID: UUID) -> DeviceSyncQueueSummary {
        syncQueueSummaries[profileID] ?? .empty
    }

    /// True when the device is plugged in now, so SYNC can actually run.
    func isDeviceConnected(profileID: UUID) -> Bool {
        mountedDevices.contains { deviceProfile(for: $0)?.id == profileID }
    }

    /// Drop a device's whole queue, staged bytes included.
    func clearSyncQueue(profileID: UUID) {
        syncQueueStore.remove(profileID: profileID)   // JSON + staging tree
        refreshSyncQueueCounts()
        // Only the offline view is built *from* the queue, so only it needs
        // rebuilding — re-selecting any other source would scroll you away.
        if case .offlineDevice(let browsing) = currentSource, browsing == profileID {
            selectSource(.offlineDevice(profileID: profileID))
        }
        showOLEDNotice("QUEUE CLEARED")
    }

}
