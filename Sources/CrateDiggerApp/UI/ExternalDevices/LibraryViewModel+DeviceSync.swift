import AppKit
import CrateDiggerCore
import Foundation

/// Pre-Transfer to Device: queue tracks for a device that isn't plugged in,
/// then SYNC writes them at mount time. Both go through the device review
/// (`LibraryViewModel+DeviceReview`): queuing against the device's last-known
/// catalog, SYNC against the device itself. Queuing never converts; that is a
/// separate, explicit step (CONVERT NOW), which bakes into a local staging tree
/// laid out like the device, so SYNC can copy the bake. Anything left unbaked
/// is converted on the way over instead. Every staged byte dies the moment it
/// has served its purpose, and SYNC is restartable: failures stay queued.
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
    /// Queuing is bookkeeping and nothing else: no ffmpeg, no staged bytes. It
    /// used to bake convert-mode profiles on the spot, which spent minutes and
    /// gigabytes committing to a format before you had a chance to look at the
    /// list or change your mind about it. The bake is now yours to order:
    /// CONVERT NOW on the strip, or automatically as part of SYNC.
    ///
    /// What is queued goes through the same review as a send to a mounted
    /// device, against the device's last-known catalog: tracks it already
    /// has are not queued, missing ones are filed into its album's folder, and
    /// albums that differ are asked about in the review sheet, their answers
    /// stored on the entries for SYNC. A device never scanned has no catalog,
    /// so everything queues as new and SYNC sorts it out against the device.
    @MainActor
    func stageForSync(profile: ExternalDeviceProfile, tracks rawTracks: [LoadedTrack]) {
        guard let host = presentationHostViewController else { return }
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

        // Planned against the staging tree, because that is where a bake
        // lands; the same relative path is what SYNC writes on the device.
        let stagingRoot = syncQueueStore.stagingDirectory(for: profile.id)
        let key = catalogKey(for: profile)
        let deviceRoot = profile.rootDisplayPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

        Task { @MainActor in
            // The device is away, so its saved catalog stands in for it,
            // moved onto the staging tree the review plans against.
            let catalog = await Task.detached(priority: .userInitiated) { () -> [LoadedTrack] in
                guard let deviceRoot, let saved = DeviceCatalogStore().load(key: key) else { return [] }
                return DeviceSyncQueuePlanner.catalog(saved, rebasedFrom: deviceRoot, onto: stagingRoot)
            }.value
            guard let (plan, review, answers) = await reviewedDevicePlan(
                tracks: tracks,
                profile: profile,
                mountedRoot: stagingRoot,
                catalog: catalog,
                presentingFrom: host,
                // The catalog is the device here; the staging tree's bakes
                // are not, so a name one uses is never asked about now.
                fileManager: DeviceSyncQueuePlanner.catalogOnlyFileManager(stagingRoot: stagingRoot)
            ) else { return }

            // Re-read rather than add to the snapshot: more may have been
            // queued while the sheet was up.
            let current = syncQueueStore.load(profileID: profile.id)
            let newEntries = DeviceSyncQueuePlanner.entries(
                for: plan,
                stagingRoot: stagingRoot,
                decisions: answers,
                kinds: review.differenceKinds,
                queued: current
            )
            rememberDeviceAnswers(answers, of: review, profileID: profile.id)
            if !newEntries.isEmpty {
                syncQueueStore.save(current + newEntries, profileID: profile.id)
                refreshSyncQueueCounts()
                // Queuing while browsing this offline device: rebuild the view
                // so the rows and badges reflect what is now waiting.
                if case .offlineDevice(let pid) = currentSource, pid == profile.id {
                    selectSource(currentSource)
                }
            }
            appAlert = queuedAlert(newEntries: newEntries.count, plan: plan, profile: profile)
        }
    }

    /// What queuing did: how many tracks wait, and what was not queued
    /// because the device already has it, its album was left alone, or no
    /// place could be planned for it.
    private func queuedAlert(newEntries n: Int, plan: DeviceTransferFilePlan, profile: ExternalDeviceProfile) -> AppAlert {
        var notQueued: [String] = []
        if plan.skippedPresent > 0 { notQueued.append("\(plan.skippedPresent) already on \(profile.name)") }
        if plan.leftAlone > 0 { notQueued.append("\(plan.leftAlone) album\(plan.leftAlone == 1 ? "" : "s") left alone") }
        if !plan.unplanned.isEmpty { notQueued.append("\(plan.unplanned.count) with no place on the device") }
        let notQueuedLine = notQueued.isEmpty ? "" : " Not queued: " + notQueued.joined(separator: " · ") + "."

        guard n > 0 else {
            return .info(
                title: "Nothing to queue",
                message: "\(profile.name) needs nothing from this selection." + notQueuedLine
            )
        }
        let noun = "\(n) track\(n == 1 ? "" : "s")"
        return .info(
            title: "Queued for \(profile.name)",
            message: (profile.transferSettings.mode == .convertDuringTransfer
                ? "\(noun) queued. Nothing has been converted yet: press CONVERT NOW to bake them at the current settings (\(profile.transferSettings.summary)), or just press SYNC and it happens on the way over."
                : "\(noun) queued. They copy over as they are the next time you press SYNC.")
                + notQueuedLine
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
              // The profile's art mode decides what the baked files hold; a
              // folder cover is written onto the device by the sync itself.
              let preset = profile.transferSettings.conversionPreset
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

    /// Manual SYNC: write the queue onto the mounted device, through the same
    /// review as a send to it. The device is the truth now: the queue is
    /// compared with its catalog (scanned first when there is none), answers
    /// stored when queuing are used while their album still differs, and the
    /// sheet asks only about albums that differ and carry no answer. Cancel
    /// it and nothing happens. Then every copy runs (a current bake copied, a
    /// stale or missing one and an unbaked entry converted on the way, a
    /// copy-mode entry copied), each through a hidden partial renamed into
    /// place, then the deletions of the albums whose copies all landed, the
    /// covers, and the catalog patch. An entry leaves the queue, staged bytes
    /// and all, once its file lands or the review finds it needs none
    /// (already there, left alone); failures stay queued, so SYNC is
    /// restartable.
    @MainActor
    func syncQueuedTransfers(profileID: UUID) {
        guard let host = presentationHostViewController else { return }
        guard !isConversionRunning, deviceSyncProgress?.isRunning != true else { return }
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return }
        let entries = syncQueueStore.load(profileID: profileID)
        guard !entries.isEmpty else { return }
        guard mountedDevices.contains(where: { deviceProfile(for: $0)?.id == profileID }) else {
            appAlert = .info(
                title: "Device not connected",
                message: "\(profile.name) isn't mounted. Connect it, then press SYNC."
            )
            return
        }

        Task { @MainActor in
            guard let mountedRoot = await resolveMountedRoot(for: &profile, presentingFrom: host) else { return }
            // The catalog reviewed and patched must be the volume written to.
            guard let device = mountedDevice(for: profile, at: mountedRoot) else { return }
            guard let catalog = await currentDeviceCatalog(for: device) else {
                appAlert = .error(
                    title: "Couldn't read \(profile.name)",
                    message: "CrateDigger could not see what is already on the device, so nothing was synced. Check that it is still connected and press SYNC again."
                )
                return
            }
            guard let (plan, review, answers) = await reviewedDevicePlan(
                tracks: entries.map(\.track),
                profile: profile,
                mountedRoot: mountedRoot,
                catalog: catalog,
                presentingFrom: host,
                alreadyDecided: DeviceSyncQueuePlanner.storedDecisions(for: entries)
            ) else { return }

            // The plan covers the queue as it was when SYNC was pressed. If
            // an entry left it since (cleared, removed), writing it anyway
            // would be wrong, and dropping its copy alone could let a Replace
            // delete old files nothing replaced.
            let live = Set(syncQueueStore.load(profileID: profileID).map(\.id))
            guard entries.allSatisfy({ live.contains($0.id) }) else {
                appAlert = .info(
                    title: "The queue changed",
                    message: "Tracks left the queue for \(profile.name) while SYNC was getting ready, so nothing was written. Press SYNC again."
                )
                return
            }

            let entryBySource = Dictionary(
                entries.map { ($0.track.track.fileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let written = Set(plan.copies.map(\.source.track.fileURL.path))
            let unplanned = Set(plan.unplanned.map(\.track.fileURL.path))
            // Already there, or left alone: these leave the queue unwritten.
            let settled = entries.filter {
                !written.contains($0.track.track.fileURL.path) && !unplanned.contains($0.track.track.fileURL.path)
            }

            guard !plan.copies.isEmpty || !plan.deletions.isEmpty || !plan.unplanned.isEmpty else {
                // Nothing to write is a finished sync: its answers stand.
                rememberDeviceAnswers(answers, of: review, profileID: profileID)
                dropSettledEntries(settled, profileID: profileID)
                appAlert = .info(
                    title: "Nothing to sync",
                    message: "\(profile.name) needs nothing from the queue: "
                        + DeviceTransferSummary.statusLine(for: plan, outcome: .init())
                        + ". Those tracks have left the queue."
                )
                return
            }

            // Where each copy's bytes come from, decided once: it sizes the
            // free-space check and tells the loop what to do.
            let preset = profile.transferSettings.conversionPreset
            let store = syncQueueStore
            let sources = await Task.detached(priority: .userInitiated) {
                Self.syncSources(for: plan, entryBySource: entryBySource, store: store,
                                 profileID: profileID, converts: preset != nil)
            }.value

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
            // Only what will be written counts: a bake's own size, else the
            // source's. What a Replace frees is not credited, so the check
            // stays conservative.
            let free = mountedRoot.volumeFreeBytes ?? .max
            guard sources.bytesNeeded < free else {
                appAlert = .error(
                    title: "Not enough space on \(profile.name)",
                    message: String(
                        format: "This sync needs ~%.1f GB but the device has %.1f GB available.",
                        Double(sources.bytesNeeded) / 1e9, Double(free) / 1e9
                    )
                )
                return
            }
            // The scan and the sheet can take a while; another job may have
            // started meanwhile.
            guard !isConversionRunning, deviceSyncProgress?.isRunning != true else {
                appAlert = .error(
                    title: "Another transfer is running",
                    message: "Nothing was synced to \(profile.name). Press SYNC again once it finishes."
                )
                return
            }
            // Busy from here until the catalog is patched: the copies'
            // progress ends before the deletions, covers and patch do.
            isDeviceTransferRunning = true
            defer { isDeviceTransferRunning = false }
            rememberDeviceAnswers(answers, of: review, profileID: profileID)

            // SYNC reads as running from here until the catalog is patched,
            // deletions and covers included: that is what keeps ⌘. and the
            // Patch Bay's Cancel off it (it has no cancel) and its busy job
            // from reading as abandoned.
            let total = plan.copies.count
            oledView = .devices
            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profile.name,
                currentRelativePath: plan.copies.first.map { Self.devicePath($0.destinationURL, under: mountedRoot) },
                completed: 0, total: total, failed: 0, isRunning: true
            )
            let busyJob = beginBusyJob(.transfer, on: .devices)

            // What gets converted needs its artwork bytes back first: the
            // queue stores art by hash.
            var metadataByPath: [String: ConversionMetadata] = [:]
            let converting = plan.copies.filter { sources.bySource[$0.source.track.fileURL.path] == .convert }
            if !converting.isEmpty {
                metadataByPath = Dictionary(
                    await tracksWithHydratedArtwork(converting.map(\.source))
                        .map { ($0.track.fileURL.path, $0.metadata) },
                    uniquingKeysWith: { first, _ in first }
                )
            }

            // An answer given in the sheet is kept on any entry whose copy
            // fails, so the next SYNC doesn't ask again.
            let kinds = review.differenceKinds
            var answeredBySource: [String: DeviceStoredDecision] = [:]
            for copy in plan.copies {
                if let answer = answers[copy.album] {
                    answeredBySource[copy.source.track.fileURL.path] = DeviceStoredDecision(answer, for: kinds[copy.album])
                }
            }

            let profileName = profile.name
            let job = QueuedSyncJob(
                plan: plan,
                entryBySource: entryBySource,
                sources: sources.bySource,
                settledIDs: Set(settled.map(\.id)),
                answeredBySource: answeredBySource,
                profileID: profileID,
                mountedRoot: mountedRoot,
                preset: preset,
                ffmpegURL: customFFmpegExecutableURL(),
                metadataByPath: metadataByPath
            )
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.runQueuedSync(job) { completed, failed in
                    let next = completed < total
                        ? Self.devicePath(plan.copies[completed].destinationURL, under: mountedRoot) : nil
                    Task { @MainActor in
                        // A late hop must not revive a finished sync.
                        guard self.deviceSyncProgress?.isRunning == true else { return }
                        self.deviceSyncProgress = DeviceSyncProgressSnapshot(
                            profileName: profileName,
                            currentRelativePath: next,
                            completed: completed, total: total, failed: failed,
                            isRunning: true
                        )
                    }
                }
            }.value

            let failed = DeviceTransferSummary.failedCount(for: plan, outcome: outcome)
            endBusyJob(busyJob, .sync(failed: failed, total: total))

            // A cover only where something actually landed, and never over
            // one a Gaps fill found there.
            await writeFolderCoverArt(
                profileID: profileID,
                folderTracks: plan.coverFolders(after: outcome.written, hasCover: { FolderCoverArtWriter.hasCover(in: $0) })
                    .map { (folder: $0.key, track: $0.value) }
            )
            await patchDeviceCatalog(
                for: device,
                adding: outcome.written.map {
                    DeviceCatalogStore.writtenTrack(
                        source: $0.source,
                        destination: $0.destinationURL,
                        preset: preset,
                        writesFolderCoverArt: profile.usesFolderCoverArt
                    )
                },
                removingPaths: outcome.removedPaths
            )
            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profileName, currentRelativePath: nil,
                completed: total, total: total, failed: failed, isRunning: false
            )
            refreshSyncQueueCounts()

            let title: String
            let tone: StatusTone
            if failed == 0 {
                title = "Synced to \(profileName)"
                tone = .success
            } else if outcome.written.isEmpty {
                title = "Sync failed"
                tone = .error
            } else {
                title = "Sync finished with errors"
                tone = .warning
            }
            presentSummary(
                report: ConversionReport(
                    title: title,
                    statusLine: DeviceTransferSummary.statusLine(for: plan, outcome: outcome),
                    details: outcome.lines.joined(separator: "\n"),
                    tone: tone,
                    showsDetailsButton: !outcome.lines.isEmpty
                ),
                presentingFrom: host
            )
        }
    }

    /// Entries the review settled without writing (already there, left
    /// alone): out of the queue, staged bytes with them.
    @MainActor
    private func dropSettledEntries(_ settled: [DeviceSyncQueueEntry], profileID: UUID) {
        guard !settled.isEmpty else { return }
        for entry in settled { syncQueueStore.removeStagedFile(for: entry, profileID: profileID) }
        let ids = Set(settled.map(\.id))
        let left = syncQueueStore.load(profileID: profileID).filter { !ids.contains($0.id) }
        if left.isEmpty {
            syncQueueStore.remove(profileID: profileID)
        } else {
            syncQueueStore.save(left, profileID: profileID)
        }
        refreshSyncQueueCounts()
    }

    /// `url` relative to the device root, for progress and detail lines.
    nonisolated private static func devicePath(_ url: URL, under root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Each copy's source (`DeviceSyncQueuePlanner.source`), by source path,
    /// and the bytes they will write. Stats local files, so off the main actor.
    nonisolated private static func syncSources(
        for plan: DeviceTransferFilePlan,
        entryBySource: [String: DeviceSyncQueueEntry],
        store: DeviceSyncQueueStore,
        profileID: UUID,
        converts: Bool
    ) -> (bySource: [String: DeviceSyncQueuePlanner.SyncSource], bytesNeeded: Int64) {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var bySource: [String: DeviceSyncQueuePlanner.SyncSource] = [:]
        var bytes: Int64 = 0
        for copy in plan.copies {
            let path = copy.source.track.fileURL.path
            guard let entry = entryBySource[path] else { continue }
            let staged = store.stagedFileURL(for: entry, profileID: profileID)
            let source = DeviceSyncQueuePlanner.source(
                for: entry,
                stagedURL: staged,
                destination: copy.destinationURL,
                converts: converts,
                stagedFileExists: fm.fileExists(atPath: staged.path),
                sourceModifiedAt: fm.fileExists(atPath: path) ? modificationDate(of: entry.track.track.fileURL) : nil
            )
            bySource[path] = source
            switch source {
            case .staged: bytes += size(staged)
            case .convert, .copy: bytes += size(entry.track.track.fileURL)
            case .unavailable: break
            }
        }
        return (bySource, bytes)
    }

    /// Everything the sync loop needs, gathered on the main actor.
    struct QueuedSyncJob: Sendable {
        let plan: DeviceTransferFilePlan
        let entryBySource: [String: DeviceSyncQueueEntry]
        let sources: [String: DeviceSyncQueuePlanner.SyncSource]
        /// Entries the review settled without a write; they leave the queue.
        let settledIDs: Set<UUID>
        /// Sheet answers to keep on entries that stay queued.
        let answeredBySource: [String: DeviceStoredDecision]
        let profileID: UUID
        let mountedRoot: URL
        let preset: ConversionPreset?
        let ffmpegURL: URL?
        let metadataByPath: [String: ConversionMetadata]
    }

    /// The sync loop: each copy written to a hidden partial and renamed into
    /// place (`DeviceTransferExecutor`), its entry out of the queue and its
    /// staged bytes deleted once it lands, then the deletions of the albums
    /// whose copies all landed. The queue is rewritten at checkpoints, read
    /// fresh each time so entries queued during the sync survive it.
    /// `onProgress` gets (copies done, failures so far). Writes to the
    /// device, so callers run it off the main actor.
    nonisolated private static func runQueuedSync(
        _ job: QueuedSyncJob,
        onProgress: (Int, Int) -> Void
    ) -> DeviceTransferExecutor.Outcome {
        let store = DeviceSyncQueueStore()
        let fm = FileManager.default
        let executor = DeviceTransferExecutor(fileManager: fm)
        let profileID = job.profileID
        var outcome = DeviceTransferExecutor.Outcome()
        var service: ConversionService?

        // Checkpointing, rather than a full queue rewrite per entry (which
        // re-encoded the whole JSON n times for an n-track sync).
        var doneIDs = job.settledIDs
        let checkpointEvery = 25
        func persistQueue() {
            let left = store.load(profileID: profileID)
                .filter { !doneIDs.contains($0.id) }
                .map { entry -> DeviceSyncQueueEntry in
                    var kept = entry
                    if let answer = job.answeredBySource[entry.track.track.fileURL.path] {
                        kept.decision = answer.decision
                        kept.decisionKind = answer.kind
                    }
                    return kept
                }
            if left.isEmpty {
                store.remove(profileID: profileID)
            } else {
                store.save(left, profileID: profileID)
            }
        }
        for entry in job.entryBySource.values where job.settledIDs.contains(entry.id) {
            store.removeStagedFile(for: entry, profileID: profileID)
        }

        /// One ffmpeg run into `output`, judged by its own result. `runSingle`,
        /// never enqueue + runQueuedJobs: the service lives for the whole
        /// loop, and its queue would re-run every earlier job each time.
        func convert(_ source: URL, to output: URL, metadata: ConversionMetadata) throws {
            guard let preset = job.preset else { throw syncError("This device copies files as they are") }
            if service == nil { service = try? ConversionService(ffmpegExecutableURL: job.ffmpegURL) }
            guard let service else { throw syncError("ffmpeg wasn't found") }
            let result = service.runSingle(
                ConversionJob(sourceURL: source, destinationURL: output, metadata: metadata),
                preset: preset
            )
            guard result.status == .completed else {
                let detail = result.log.split(whereSeparator: \.isNewline).last.map(String.init)
                throw syncError(detail.map { "Conversion failed: \($0)" } ?? "Conversion failed")
            }
        }

        for track in job.plan.unplanned {
            outcome.lines.append(
                "[FAILED] \(track.track.fileURL.lastPathComponent)\n    No place on the device could be planned for it"
            )
        }
        for (index, copy) in job.plan.copies.enumerated() {
            let sourcePath = copy.source.track.fileURL.path
            let name = devicePath(copy.destinationURL, under: job.mountedRoot)
            do {
                guard let entry = job.entryBySource[sourcePath],
                      let source = job.sources[sourcePath]
                else { throw syncError("Not in the queue any more") }
                if case .unavailable(let reason) = source { throw syncError(reason) }
                // The executor's own write: the appeared-file check, the
                // folder made only now, a hidden partial renamed into place,
                // and nothing left behind when it fails. ffmpeg picks its
                // muxer from the extension, so a converting write keeps it.
                try executor.write(copy, keepingExtension: source == .convert) { _, target in
                    switch source {
                    case .staged:
                        try fm.copyItem(at: store.stagedFileURL(for: entry, profileID: profileID), to: target)
                    case .copy:
                        try fm.copyItem(at: entry.track.track.fileURL, to: target)
                    case .convert:
                        try convert(entry.track.track.fileURL, to: target,
                                    metadata: job.metadataByPath[sourcePath] ?? entry.track.metadata)
                    case .unavailable:
                        break   // thrown above
                    }
                }
                outcome.written.append(copy)
                outcome.lines.append("[ok] \(name)")
                // Landed: its staged bytes are trash now.
                store.removeStagedFile(for: entry, profileID: profileID)
                doneIDs.insert(entry.id)
                if doneIDs.count % checkpointEvery == 0 { persistQueue() }
            } catch {
                outcome.failed.append(.init(copy: copy, reason: error.localizedDescription))
                outcome.lines.append("[FAILED] \(name)\n    \(error.localizedDescription)")
            }
            onProgress(index + 1, outcome.failed.count)
        }

        // Old files go only for albums whose every copy landed.
        executor.runDeletions(job.plan, after: &outcome)
        persistQueue()
        return outcome
    }

    nonisolated private static func syncError(_ reason: String) -> NSError {
        NSError(domain: "CrateDigger.DeviceSync", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
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
