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

        guard !isDeviceBusy else {
            AppLog.conversion.warning("Transfer requested while a device is busy")
            return showDeviceBusyAlert("Send to the device")
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

        // Device not mounted → stage for later instead of prompting for a folder.
        let isMounted = mountedDevices.contains { deviceProfile(for: $0)?.id == profile.id }
        guard isMounted else {
            stageForSync(profile: profile, tracks: tracks)
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
                let routedBefore = pendingDeviceConversion
                let alreadyQueued = routedBefore.flatMap {
                    $0.profileID == resolved.id && $0.destinationRoot == destinationRoot ? $0.tracks : nil
                }
                // Sending a second selection to the same device adds to the queue.
                // Replacing it silently threw away everything picked so far, which
                // is the whole point of filling the cockpit before pressing Go.
                let queued = alreadyQueued ?? []
                let known = Set(queued.map(\.track.fileURL.path))
                // Route *before* seeding: `conversionSelection` only saves itself
                // as the user's own last selection while no device is routed, so
                // seeding first would persist the iPod's format as theirs.
                pendingDeviceConversion = PendingDeviceConversion(
                    profileID: resolved.id,
                    deviceName: resolved.name,
                    destinationRoot: destinationRoot,
                    tracks: queued + tracks.filter { !known.contains($0.track.fileURL.path) }
                )

                // Seed the cockpit only on the first hand-off — a second one would
                // save the already-device-seeded selection as "before device" and
                // lose the user's own settings when the run restores them.
                if alreadyQueued == nil {
                    // Re-routing straight from one device to another: the old
                    // device keeps what was tuned for it, and "before device"
                    // must still mean the user's own settings, not the previous
                    // device's.
                    if let previous = routedBefore, previous.profileID != resolved.id {
                        persistSelectionToDevice(conversionSelection, profileID: previous.profileID)
                    }
                    if conversionSelectionBeforeDevice == nil {
                        conversionSelectionBeforeDevice = conversionSelection
                    }
                    // The art mode comes from the device too: a Rockbox
                    // profile stores Strip (it gets a cover.jpg instead).
                    conversionSelection = conversionSelection.seeded(from: resolved.transferSettings)
                }
                oledView = .conversion
            }
        }
    }

    // MARK: - Folder cover art (cover.jpg sidecars)

    /// Write one `cover.jpg` per album folder this transfer wrote into, when
    /// the device's folder-art switch is on. Returns the number of covers
    /// written (0 when it is off, so callers can wire this in unconditionally).
    ///
    /// `landings` is one entry per written file: the folder it landed in and
    /// the artwork of the track that produced it. Hydration is the caller's
    /// job for paths that don't already carry the bytes — see
    /// `writeFolderCoverArt(profileID:folderTracks:)`.
    @MainActor
    @discardableResult
    func writeFolderCoverArt(profileID: UUID?, landings: [(folder: URL, artwork: ArtworkAsset?)],
                             door: DeviceTransferDoor) async -> Int {
        guard let profileID,
              let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              profile.usesFolderCoverArt
        else { return 0 }
        return writeFolderCoverArt(landings: landings, for: profile.name, door: door)
    }

    /// The writing itself, for a caller that already decided covers are
    /// wanted: a device run whose plan only lists cover folders when the
    /// run's switch is on. `destinationName` only names the destination in
    /// the log, so it is a device name, never a path.
    @MainActor
    @discardableResult
    func writeFolderCoverArt(landings: [(folder: URL, artwork: ArtworkAsset?)], for destinationName: String,
                             door: DeviceTransferDoor) -> Int {
        var covers: [URL: ArtworkAsset] = [:]
        for landing in landings {
            guard let artwork = landing.artwork, !artwork.data.isEmpty else { continue }
            if covers[landing.folder] == nil { covers[landing.folder] = artwork }   // an album has one cover
        }
        return writeFolderCoverArt(covers, for: destinationName, door: door)
    }

    /// Writes covers already decided, one per folder, replacing any there.
    /// `door`: a device run's, so every cover on a device goes through the
    /// write door; nil for an ordinary conversion's destination folder.
    @MainActor
    @discardableResult
    func writeFolderCoverArt(_ covers: [URL: ArtworkAsset], for destinationName: String,
                             door: DeviceTransferDoor?) -> Int {
        guard !covers.isEmpty else { return 0 }
        let writer = door.map { door in
            FolderCoverArtWriter(preparer: artworkService, writeData: { try door.writeCover($0, to: $1) })
        } ?? FolderCoverArtWriter(preparer: artworkService)
        let written = writer.write(covers)
        AppLog.conversion.notice("Wrote \(written) cover.jpg sidecar(s) for \(destinationName, privacy: .public)")
        return written
    }

    /// Same, for the copy and sync paths: they hold tracks + destination paths
    /// rather than conversion jobs, and their artwork is usually still just a
    /// hash, so hydrate before writing.
    @MainActor
    @discardableResult
    func writeFolderCoverArt(profileID: UUID, folderTracks: [(folder: URL, track: LoadedTrack)],
                             door: DeviceTransferDoor) async -> Int {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              profile.usesFolderCoverArt, !folderTracks.isEmpty
        else { return 0 }
        // One hydration for the batch, then match art back by source path —
        // zipping by index would misalign the moment a track drops out.
        let hydrated = await tracksWithHydratedArtwork(folderTracks.map(\.track))
        let artByPath = Dictionary(
            hydrated.compactMap { track in track.metadata.artwork.map { ($0, track.track.fileURL.path) } }
                .map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return await writeFolderCoverArt(
            profileID: profileID,
            landings: folderTracks.map { ($0.folder, artByPath[$0.track.track.fileURL.path]) },
            door: door
        )
    }

    // MARK: - FIX ART (repair a device that's already full)

    /// The mounted device being browsed, with its profile — the target for FIX ART.
    var browsedMountedDevice: (profile: ExternalDeviceProfile, device: MountedDevice)? {
        guard case .device(let volumePath) = currentSource,
              let device = mountedDevices.first(where: { $0.volumeURL.path == volumePath }),
              let profile = deviceProfile(for: device)
        else { return nil }
        return (profile, device)
    }

    var canFixDeviceAlbumArt: Bool { browsedMountedDevice != nil && !isDeviceBusy }

    /// Write a `cover.jpg` beside every album already on the device, taken from
    /// the tracks sitting there. Repairs everything transferred before folder
    /// art existed, without touching the audio files.
    @MainActor
    func fixDeviceAlbumArt() {
        guard let (profile, device) = browsedMountedDevice else { return }
        guard !isDeviceBusy else { return showDeviceBusyAlert("Fix the art") }
        let root = ExternalDeviceTransferPlanner().destinationRoot(for: profile, mountedAt: device.volumeURL)
        isFixingDeviceArt = true
        oledView = .devices
        showOLEDNotice("FIXING ART")
        let deviceName = profile.name

        Task { @MainActor in
            // Every cover goes through the write door, like a transfer's.
            guard let door = await makeTransferDoor(for: profile, device: device, musicFolder: root) else {
                isFixingDeviceArt = false
                return
            }
            // All of it off the main actor: the walk is a deep read of a USB
            // volume and each cover is a decode + JPEG encode. Its own
            // ArtworkService — nothing is shared with the app's, so nothing
            // crosses actors.
            let outcome = await Task.detached(priority: .userInitiated) { () -> (albums: Int, covers: Int) in
                let artwork = ArtworkService()
                let files = FolderCoverArtWriter.representativeAudioFiles(under: root)
                var covers: [URL: ArtworkAsset] = [:]
                for (folder, file) in files {
                    if let asset = await artwork.resolveArtwork(trackURL: file) {
                        covers[folder] = asset
                    }
                }
                let writer = FolderCoverArtWriter(preparer: artwork, writeData: { try door.writeCover($0, to: $1) })
                return (files.count, writer.write(covers))
            }.value

            isFixingDeviceArt = false
            AppLog.conversion.notice("FIX ART wrote \(outcome.covers) of \(outcome.albums) covers")
            // FIX ART changes art only, never which files are on the device,
            // so there is nothing for a patch to add or remove. But the
            // catalog records each track's art size, which is what a
            // transfer's review compares; left as it was, every album given a
            // cover would read as differing in art. So it is dropped (the
            // one write that still drops it: every transfer, SYNC included,
            // patches instead) and walked again now if the device is on screen.
            if outcome.covers > 0 {
                invalidateDeviceCatalog(for: device)
                if case .device(let path) = currentSource, path == device.volumeURL.path {
                    refreshLibrary()
                }
            }
            appAlert = .error(
                title: outcome.covers > 0 ? "Album art fixed" : "No covers written",
                message: outcome.covers > 0
                    ? "Wrote cover.jpg into \(outcome.covers) of \(outcome.albums) album folder\(outcome.albums == 1 ? "" : "s") on \(deviceName)."
                    : "Found \(outcome.albums) album folder\(outcome.albums == 1 ? "" : "s") on \(deviceName), but none of their tracks carry artwork to copy out."
            )
        }
    }

    // MARK: - Copy path

    /// Copy originals to a mounted copy-mode device: only what it doesn't
    /// have. Albums already there are skipped, missing tracks fill in their
    /// album's folder, and albums that differ are asked about once in the
    /// review sheet. Copies run first, then the deletions a Replace earned,
    /// then the album covers, then the catalog is patched.
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
            // The catalog reviewed and patched must be the volume written to.
            guard let device = mountedDevice(for: resolved, at: mountedRoot) else { return }
            guard let catalog = await currentDeviceCatalog(for: device) else {
                appAlert = .error(
                    title: "Couldn't read \(resolved.name)",
                    message: "CrateDigger could not see what is already on the device, so nothing was sent. Check that it is still connected and send again."
                )
                return
            }
            guard let (plan, review, answers) = await reviewedDevicePlan(
                tracks: sourceTracks,
                profile: resolved,
                mountedRoot: mountedRoot,
                catalog: catalog,
                presentingFrom: host
            ) else { return }

            guard !plan.copies.isEmpty || !plan.deletions.isEmpty || !plan.unplanned.isEmpty else {
                // Nothing to write is a finished send: its answers stand.
                rememberDeviceAnswers(answers, of: review, profileID: resolved.id)
                appAlert = .info(
                    title: "Nothing to transfer",
                    message: "\(resolved.name) needs nothing from this selection: "
                        + DeviceTransferSummary.statusLine(for: plan, outcome: .init()) + "."
                )
                return
            }

            // Only what will be written counts against the free space; what
            // a Replace frees is not credited, so the check stays conservative.
            let destinationRoot = ExternalDeviceTransferPlanner().destinationRoot(for: resolved, mountedAt: mountedRoot)
            if let problem = validateDeviceTransferPreflight(
                destinationRoot: destinationRoot,
                deviceName: resolved.name,
                sourceTracks: plan.copies.map(\.source)
            ) {
                appAlert = problem
                return
            }
            guard let door = await makeTransferDoor(for: resolved, device: device, musicFolder: destinationRoot) else { return }
            // The scan and the sheet can take a while; another job may have
            // started on the conversion channel meanwhile.
            guard !isDeviceBusy else {
                appAlert = .error(
                    title: "Another transfer is running",
                    message: "Nothing was sent to \(resolved.name). Send again once it finishes."
                )
                return
            }
            // Busy from here until the catalog is patched: the copies'
            // progress ends before the deletions, covers and patch do.
            isDeviceTransferRunning = true
            defer { isDeviceTransferRunning = false }
            rememberDeviceAnswers(answers, of: review, profileID: resolved.id)

            let (report, outcome, endJob) = await runCopyTransferQueue(plan: plan, deviceName: resolved.name, door: door)

            // A cover only where something actually landed, and never over
            // one a Gaps fill found there.
            let covers = await writeFolderCoverArt(
                profileID: resolved.id,
                folderTracks: plan.coverFolders(after: outcome.written, hasCover: { FolderCoverArtWriter.hasCover(in: $0) })
                    .map { (folder: $0.key, track: $0.value) },
                door: door
            )
            await patchDeviceCatalog(
                for: device,
                adding: outcome.written.map {
                    DeviceCatalogStore.writtenTrack(
                        source: $0.source,
                        destination: $0.destinationURL,
                        preset: nil,
                        writesFolderCoverArt: resolved.usesFolderCoverArt
                    )
                },
                removingPaths: outcome.removedPaths
            )
            let nextSteps = await finishDeviceSession(
                device: device, profile: resolved,
                written: outcome.written.map(\.destinationURL), deleted: outcome.deleted,
                changes: outcome.changes(coversWritten: covers)
            )
            // The busy job spans the covers, the patch and the cleanup too.
            endJob()
            presentSummary(report: deviceReport(report, nextSteps: nextSteps, device: device), presentingFrom: host)
        }
    }

    // MARK: - Mounted root

    @MainActor
    func resolveMountedRoot(
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

    /// Writability and free space, both found out without writing to the
    /// device: the transfer's first write is its first byte there.
    private func validateDeviceTransferPreflight(
        destinationRoot: URL,
        deviceName: String,
        sourceTracks: [LoadedTrack]
    ) -> AppAlert? {
        if let writability = deviceWritabilityProblem(destinationRoot, deviceName: deviceName) {
            return writability
        }
        return probeFreeDiskSpace(
            destinationRoot,
            sourceTracks: sourceTracks,
            insufficientSpaceMessageFormat: "This transfer needs ~%.1f GB but the device has %.1f GB available."
        )
    }

    /// Runs a reviewed plan's byte copies, then its deletions, through Core's
    /// `DeviceTransferExecutor` and the write door, with progress on CNVRT.
    @MainActor
    private func runCopyTransferQueue(
        plan: DeviceTransferFilePlan,
        deviceName: String,
        door: DeviceTransferDoor
    ) async -> (report: ConversionReport, outcome: DeviceTransferExecutor.Outcome, endJob: () -> Void) {
        let copies = plan.copies
        let total = copies.count
        oledView = .conversion
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0,
            jobsTotal: total,
            currentFilename: copies.first?.source.track.fileURL.lastPathComponent,
            isRunning: true
        )
        // Drawn on CNVRT, where the app already shows a copy transfer.
        let busyJob = beginBusyJob(.transfer, on: .conversion)

        let outcome = await withCheckedContinuation { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // The library file itself: the door copies its data only.
                let outcome = DeviceTransferExecutor(door: door).run(
                    plan,
                    source: { $0.source.track.fileURL },
                    isCancelled: { Task.isCancelled },
                    onProgress: { completed, total in
                        Task { @MainActor in
                            // A hop landing after the job ended must not
                            // mark it running again: the device would read
                            // as busy until relaunch.
                            guard self.conversionProgress.isRunning else { return }
                            self.conversionProgress = ConversionProgressSnapshot(
                                jobsCompleted: completed,
                                jobsTotal: total,
                                currentFilename: completed < total
                                    ? copies[completed].source.track.fileURL.lastPathComponent : nil,
                                // Still running after the last copy: the
                                // deletions, covers, patch and cleanup follow.
                                isRunning: true
                            )
                        }
                    }
                )
                continuation.resume(returning: outcome)
            }
            self.conversionTask = task
        }

        conversionTask = nil
        let failed = DeviceTransferSummary.failedCount(for: plan, outcome: outcome)
        // Called by the caller once the covers, patch and session finish are done.
        let endJob = { [weak self] in
            guard let self else { return }
            self.conversionProgress = ConversionProgressSnapshot(
                jobsCompleted: total, jobsTotal: total, currentFilename: nil, isRunning: false)
            self.endBusyJob(busyJob, .copyTransfer(wasCancelled: outcome.wasCancelled,
                                                   succeeded: outcome.written.count, failed: failed))
        }

        let title: String
        let tone: StatusTone
        if failed == 0 {
            title = "Sent to \(deviceName)"
            tone = .success
        } else if outcome.written.isEmpty {
            title = "Transfer failed"
            tone = .error
        } else {
            title = "Transfer finished with errors"
            tone = .warning
        }

        let report = ConversionReport(
            title: title,
            statusLine: DeviceTransferSummary.statusLine(for: plan, outcome: outcome),
            details: outcome.lines.joined(separator: "\n"),
            tone: tone,
            showsDetailsButton: !outcome.lines.isEmpty
        )
        return (report, outcome, endJob)
    }
}
