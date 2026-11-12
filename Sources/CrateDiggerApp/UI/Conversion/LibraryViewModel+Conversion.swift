import AppKit
import CrateDiggerCore
import Foundation

extension LibraryViewModel {

    // MARK: - Public entry

    /// Kick off a conversion batch. Resolves the output destination,
    /// optionally presents the per-album review sheet, runs the
    /// ConversionService, then presents the summary sheet.
    @MainActor
    func runConversion(selection: ConversionOptionsSelection, presentingFrom host: NSViewController) {
        guard !isConversionRunning else {
            AppLog.conversion.warning("Conversion already in progress; ignoring new request")
            return
        }

        let service: ConversionService
        do {
            service = try ConversionService(ffmpegExecutableURL: customFFmpegExecutableURL())
        } catch {
            AppLog.conversion.error("Could not initialize ConversionService: \(String(describing: error), privacy: .public)")
            appAlert = .error(
                title: "Couldn't start conversion",
                message: "ffmpeg wasn't found in the app bundle or on your system PATH. Install ffmpeg with Homebrew (brew install ffmpeg), or set a custom path under CrateDigger > Preferences once that screen is available."
            )
            return
        }

        // A "send to device" hand-off owns the queue + destination for this run.
        let deviceTransfer = pendingDeviceConversion
        let queuedTracks = deviceTransfer?.tracks ?? tracksForBatchScope(selection.batchScope)
        guard !queuedTracks.isEmpty else {
            appAlert = .info(
                title: "Nothing to convert",
                message: "No tracks matched the chosen scope. Load a folder, pick an album, then try again."
            )
            return
        }

        Task { @MainActor in
            let sourceTracks = await tracksWithHydratedArtwork(queuedTracks)

            let destinationRoot: URL
            if let deviceTransfer {
                destinationRoot = deviceTransfer.destinationRoot
            } else if let resolved = await resolveOutputDestination(presentingFrom: host) {
                destinationRoot = resolved
            } else {
                AppLog.conversion.notice("User cancelled output-destination selection")
                return
            }

            let preset = makeAdHocPreset(from: selection)
            let templateConfig = FolderTemplateConfig(
                preset: selection.templatePreset,
                tokenOrder: selection.tokenOrder,
                separators: selection.separators
            )

            // Preflight per-album review when the user explicitly asked for it.
            var reviewedFolders: [AlbumFolderKey: String] = [:]
            if selection.folderStructureMode == .metadataTemplate,
               selection.applyMode == .reviewPerAlbumPreflight {
                let rows = buildAlbumFolderReviewRows(
                    tracks: sourceTracks,
                    templateConfig: templateConfig
                )
                guard let reviewed = await presentAlbumFolderReview(rows: rows, presentingFrom: host) else {
                    AppLog.conversion.notice("User cancelled album-folder review")
                    return
                }
                reviewedFolders = reviewed
            }

            // A device run compares with what the device holds and asks about
            // albums that differ, in place of the two prompts below.
            if let deviceTransfer {
                await runDeviceConversion(
                    deviceTransfer,
                    selection: selection,
                    service: service,
                    sourceTracks: sourceTracks,
                    reviewedFolders: reviewedFolders,
                    presentingFrom: host
                )
                return
            }

            var jobs = planConversionJobs(
                tracks: sourceTracks,
                preset: preset,
                destinationRoot: destinationRoot,
                folderMode: selection.folderStructureMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedFolders
            )

            // Version guard: a planned album folder that already holds audio
            // NOT written by this batch is another pressing of the same
            // release. Interleaving two rips in one folder corrupts both —
            // never do it silently. metadataTemplate only: that's the mode
            // with album folders (and folder-name overrides) to redirect.
            if selection.folderStructureMode == .metadataTemplate {
                let conflicts = versionFolderConflicts(jobs: jobs, tracks: sourceTracks)
                if !conflicts.isEmpty {
                    switch await presentVersionConflictPrompt(conflicts: conflicts, presentingFrom: host) {
                    case .cancel:
                        AppLog.conversion.notice("User cancelled at version-conflict prompt")
                        return
                    case .merge:
                        break   // deliberate merge — the collision prompt below still guards file overwrites
                    case .versionFolders:
                        for conflict in conflicts {
                            reviewedFolders[conflict.key] = OutputPathPlanner.nextAvailableVersionFolderName(
                                for: conflict.existingFolder
                            )
                        }
                        jobs = planConversionJobs(
                            tracks: sourceTracks,
                            preset: preset,
                            destinationRoot: destinationRoot,
                            folderMode: selection.folderStructureMode,
                            templateConfig: templateConfig,
                            reviewedAlbumFolders: reviewedFolders
                        )
                    }
                }
            }

            guard !jobs.isEmpty else {
                appAlert = .info(
                    title: "Nothing to convert",
                    message: "All tracks resolved to the same destination paths and were skipped."
                )
                return
            }

            if let problem = validateBatchPreflight(
                destinationRoot: destinationRoot,
                sourceTracks: sourceTracks,
                outputFormat: selection.outputFormat
            ) {
                appAlert = problem
                return
            }

            // Collision handling: some outputs already exist on disk. Ask once for
            // the whole batch rather than silently duplicating or overwriting.
            let existing = jobs.filter { FileManager.default.fileExists(atPath: $0.destinationURL.path) }
            var finalJobs = jobs
            if !existing.isEmpty {
                switch await presentCollisionPrompt(
                    existingCount: existing.count,
                    totalCount: jobs.count,
                    destinationRoot: destinationRoot,
                    presentingFrom: host
                ) {
                case .cancel:
                    AppLog.conversion.notice("User cancelled at destination-collision prompt")
                    return
                case .overwrite:
                    finalJobs = jobs   // canonical paths; ffmpeg -y replaces them
                case .skip:
                    let existingKeys = Set(existing.map(\.destinationURL.path))
                    finalJobs = jobs.filter { !existingKeys.contains($0.destinationURL.path) }
                    guard !finalJobs.isEmpty else {
                        appAlert = .info(
                            title: "Nothing to convert",
                            message: "Every track already exists in the destination — nothing new to add."
                        )
                        return
                    }
                }
            }

            // Persist the user's selection for next launch. (A device run's
            // settings belong to the device and never reach this point.)
            prefs.saveLastConversionSelection(selection)

            let outcome = await runConversionQueue(service: service, jobs: finalJobs, preset: preset)
            // Folder Art: a cover.jpg in each album folder something landed
            // in, never over one already there, and never in a folder that is
            // not one album's (Core decides: `conversionCovers`).
            if selection.writesFolderCoverArt {
                let planner = OutputPathPlanner()
                let albumKeys = planner.albumFolderKeys(for: sourceTracks)
                let albumBySource = Dictionary(
                    sourceTracks.map { ($0.track.fileURL.path, albumKeys[$0.track.id] ?? planner.albumFolderKey(for: $0)) },
                    uniquingKeysWith: { first, _ in first }
                )
                func landing(_ job: ConversionJob) -> FolderCoverArtWriter.ConversionLanding? {
                    albumBySource[job.sourceURL.path].map {
                        FolderCoverArtWriter.ConversionLanding(
                            folder: job.destinationURL.deletingLastPathComponent(),
                            album: $0,
                            artwork: job.metadata?.artwork
                        )
                    }
                }
                let covers = FolderCoverArtWriter.conversionCovers(
                    landed: finalJobs
                        .filter { outcome.succeededDestinationPaths.contains($0.destinationURL.path) }
                        .compactMap(landing),
                    planned: finalJobs.compactMap(landing),
                    destinationRoot: destinationRoot,
                    folderMode: selection.folderStructureMode,
                    hasCover: { FolderCoverArtWriter.hasCover(in: $0) }
                )
                // The folder's name only: the log is not the place for a home path.
                writeFolderCoverArt(covers, for: destinationRoot.lastPathComponent, door: nil)
            }
            presentSummary(report: outcome.report, presentingFrom: host)
        }
    }

    /// Write the format, art and folder layout the user just used back onto
    /// the device profile, so the next transfer to it defaults to the same
    /// pattern. Called on both exits from a device route — a completed send
    /// and a cancel — since the panel tells the user those rows belong to the
    /// device. The art mode and the folder-art switch are stored as chosen
    /// (Strip chosen for an iPod is stored as Strip): the device review
    /// compares against them, so they must be what the cockpit showed. The
    /// transfer mode stays the device's: the cockpit has no row for it.
    func persistSelectionToDevice(_ selection: ConversionOptionsSelection, profileID: UUID) {
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return }
        var settings = selection.deviceTransferSettings(over: profile.transferSettings)
        settings.mode = profile.transferSettings.mode
        profile.transferSettings = settings
        prefs.upsertExternalDeviceProfile(profile)
    }
}

// MARK: - Device settings ↔ cockpit selection

extension ConversionOptionsSelection {
    /// This selection with a device's format, art and folder layout on it, so
    /// the CNVRT cockpit shows (and applies) what the device is set up for.
    /// Scope and the folder-review switch stay the user's.
    func seeded(from settings: ExternalDeviceTransferSettings) -> ConversionOptionsSelection {
        var selection = self
        selection.outputFormat = settings.outputFormat
        selection.bitrate = settings.bitrateKbps
        selection.sampleRate = settings.sampleRateHz
        // A device profile stores no depth or FLAC level, so don't let the
        // last archival pick ride along onto a player: keep the source's.
        selection.bitDepth = nil
        selection.flacCompressionLevel = nil
        selection.artworkMode = settings.artworkMode
        selection.artworkMaxDimension = settings.artworkMaxDimension
        selection.writesFolderCoverArt = settings.writesFolderCoverArt
        selection.folderStructureMode = settings.folderStructureMode
        selection.templatePreset = settings.templateConfig.preset
        selection.tokenOrder = FolderTokenOrder.normalize(settings.templateConfig.tokenOrder)
        selection.separators = settings.templateConfig.separators
        return selection
    }

    /// The settings a device run from the cockpit writes with: `base` (the
    /// device's own) with this selection's format, art and folder layout, the
    /// inverse of `seeded(from:)`. What the cockpit has no row for (the
    /// compatibility profile) stays the device's. Always a convert run, since
    /// that is what the cockpit does.
    func deviceTransferSettings(over base: ExternalDeviceTransferSettings) -> ExternalDeviceTransferSettings {
        var settings = base
        settings.mode = .convertDuringTransfer
        settings.outputFormat = outputFormat
        settings.bitrateKbps = bitrate
        settings.sampleRateHz = sampleRate
        settings.artworkMode = artworkMode
        settings.artworkMaxDimension = artworkMaxDimension
        settings.writesFolderCoverArt = writesFolderCoverArt
        settings.folderStructureMode = folderStructureMode
        settings.templateConfig = FolderTemplateConfig(
            preset: templatePreset,
            tokenOrder: FolderTokenOrder.normalize(tokenOrder),
            separators: separators
        )
        return settings
    }
}

extension LibraryViewModel {

    // MARK: - Version-folder conflicts (second pressing of an existing album)

    struct VersionFolderConflict {
        let key: AlbumFolderKey
        let existingFolder: URL
    }

    private enum VersionConflictResolution { case versionFolders, merge, cancel }

    /// Planned album folders that already contain audio files NOT written by
    /// this batch — i.e. a different rip of the same release already lives
    /// there. Keyed by tag-derived AlbumFolderKey so the folder-name override
    /// (`reviewedAlbumFolders`) can redirect the whole album.
    private func versionFolderConflicts(
        jobs: [ConversionJob],
        tracks: [LoadedTrack]
    ) -> [VersionFolderConflict] {
        let fileManager = FileManager.default
        let planner = OutputPathPlanner()
        let batchDestinations = Set(jobs.map { $0.destinationURL.standardizedFileURL.path })
        let albumKeys = planner.albumFolderKeys(for: tracks)
        let keyBySourcePath = Dictionary(
            tracks.map { ($0.track.fileURL.path, albumKeys[$0.track.id] ?? planner.albumFolderKey(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        var seenFolders = Set<String>()
        var conflicts: [VersionFolderConflict] = []
        for job in jobs {
            let folder = job.destinationURL.deletingLastPathComponent().standardizedFileURL
            guard seenFolders.insert(folder.path).inserted,
                  let key = keyBySourcePath[job.sourceURL.path],
                  fileManager.fileExists(atPath: folder.path),
                  let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }

            let holdsForeignAudio = contents.contains { url in
                LibraryScanService.defaultSupportedExtensions.contains(url.pathExtension.lowercased())
                    && !batchDestinations.contains(url.standardizedFileURL.path)
            }
            if holdsForeignAudio {
                conflicts.append(VersionFolderConflict(key: key, existingFolder: folder))
            }
        }
        return conflicts
    }

    @MainActor
    private func presentVersionConflictPrompt(
        conflicts: [VersionFolderConflict],
        presentingFrom host: NSViewController
    ) async -> VersionConflictResolution {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = conflicts.count == 1
                ? "This album already exists in the destination"
                : "\(conflicts.count) albums already exist in the destination"
            let names = conflicts.prefix(4).map { $0.existingFolder.lastPathComponent }.joined(separator: "\n")
            let more = conflicts.count > 4 ? "\n…and \(conflicts.count - 4) more" : ""
            alert.informativeText = names + more
                + "\n\nNew Version Folder keeps each rip separate (e.g. “Album [2]”), so the two versions never mix. Merge writes into the existing folder."
            alert.addButton(withTitle: "New Version Folder")   // .alertFirstButtonReturn
            alert.addButton(withTitle: "Merge Into Existing")   // .alertSecondButtonReturn
            alert.addButton(withTitle: "Cancel")                // .alertThirdButtonReturn

            let resolve: (NSApplication.ModalResponse) -> VersionConflictResolution = { response in
                switch response {
                case .alertFirstButtonReturn: return .versionFolders
                case .alertSecondButtonReturn: return .merge
                default: return .cancel
                }
            }

            if let window = host.view.window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: resolve($0)) }
            } else {
                continuation.resume(returning: resolve(alert.runModal()))
            }
        }
    }

    private enum CollisionResolution { case skip, overwrite, cancel }

    /// One prompt for the whole batch when some outputs already exist. Skip
    /// (default) fills in only what's missing — a safe re-run/merge; Overwrite
    /// replaces; Cancel bails.
    @MainActor
    private func presentCollisionPrompt(
        existingCount: Int,
        totalCount: Int,
        destinationRoot: URL,
        presentingFrom host: NSViewController
    ) async -> CollisionResolution {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = existingCount == totalCount
                ? "These tracks already exist in the destination"
                : "\(existingCount) of \(totalCount) tracks already exist in the destination"
            alert.informativeText = "In \(destinationRoot.path)\n\nSkip keeps the existing files and converts only what's missing. Overwrite replaces them."
            alert.addButton(withTitle: "Skip Existing")   // .alertFirstButtonReturn
            alert.addButton(withTitle: "Overwrite")        // .alertSecondButtonReturn
            alert.addButton(withTitle: "Cancel")           // .alertThirdButtonReturn

            let resolve: (NSApplication.ModalResponse) -> CollisionResolution = { response in
                switch response {
                case .alertFirstButtonReturn: return .skip
                case .alertSecondButtonReturn: return .overwrite
                default: return .cancel
                }
            }

            if let window = host.view.window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: resolve($0)) }
            } else {
                continuation.resume(returning: resolve(alert.runModal()))
            }
        }
    }

    // MARK: - Device runs (convert mode, mounted)

    /// A send-to-device run from the cockpit. The cockpit's selection is the
    /// truth for it: the device review plans with the device's settings as
    /// that selection sets them, so what it compares is what the run writes.
    /// Only what the device lacks is converted; albums that differ are asked
    /// about once. Conversions run first, then the deletions a Replace earned
    /// (an album's old files stay when any of its new ones failed), then the
    /// album covers, then the catalog patch.
    ///
    /// Record Divider recordings are not reviewed: the review compares whole
    /// tracks, and each of these becomes several files. Their slices are
    /// planned as before; one whose file is already on the device is left
    /// there and counted as already there, never overwritten or renamed.
    @MainActor
    private func runDeviceConversion(
        _ pending: PendingDeviceConversion,
        selection: ConversionOptionsSelection,
        service: ConversionService,
        sourceTracks: [LoadedTrack],
        reviewedFolders: [AlbumFolderKey: String],
        presentingFrom host: NSViewController
    ) async {
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == pending.profileID }) else {
            appAlert = .error(
                title: "Device profile missing",
                message: "The device profile could not be found. Open Preferences > Devices and choose the device again."
            )
            return
        }
        guard let mountedRoot = await resolveMountedRoot(for: &profile, presentingFrom: host) else {
            AppLog.conversion.notice("User cancelled device root selection")
            return
        }
        // The catalog reviewed and patched must be the volume written to.
        guard let device = mountedDevice(for: profile, at: mountedRoot) else { return }

        var runProfile = profile
        runProfile.transferSettings = selection.deviceTransferSettings(over: profile.transferSettings)
        let settings = runProfile.transferSettings
        let musicFolder = ExternalDeviceTransferPlanner().destinationRoot(for: runProfile, mountedAt: mountedRoot)
        if musicFolder.standardizedFileURL.path != pending.destinationRoot.standardizedFileURL.path {
            AppLog.conversion.notice("Device music folder moved since the hand-off; sending to \(musicFolder.path, privacy: .public)")
        }
        // The device's kind decides how art is prepared, as on every other
        // device path, so what lands matches what the review predicted.
        let preset = makeAdHocPreset(from: selection, deviceProfile: settings.deviceProfile)

        let divided = sourceTracks.filter { $0.recordMarkers?.isEmpty == false }
        let whole = sourceTracks.filter { $0.recordMarkers?.isEmpty != false }

        guard let catalog = await currentDeviceCatalog(for: device) else {
            appAlert = .error(
                title: "Couldn't read \(profile.name)",
                message: "CrateDigger could not see what is already on the device, so nothing was sent. Check that it is still connected and send again."
            )
            return
        }
        guard let (reviewed, review, answers) = await reviewedDevicePlan(
            tracks: whole,
            profile: runProfile,
            mountedRoot: mountedRoot,
            catalog: catalog,
            presentingFrom: host,
            reviewedAlbumFolders: reviewedFolders
        ) else { return }

        // Record Divider slices, at their natural paths beside the plan's,
        // named as the device can hold them (as the review names its own).
        let sliceJobs = planConversionJobs(
            tracks: divided,
            preset: preset,
            destinationRoot: musicFolder,
            folderMode: settings.folderStructureMode,
            templateConfig: settings.templateConfig,
            reviewedAlbumFolders: reviewedFolders,
            reservedDestinationPaths: Set(reviewed.copies.map {
                $0.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
            })
        ).map { job in
            ConversionJob(sourceURL: job.sourceURL,
                          destinationURL: ExternalDeviceTransferPlanner.deviceSafeURL(job.destinationURL, under: musicFolder),
                          metadata: job.metadata, startSeconds: job.startSeconds, endSeconds: job.endSeconds)
        }
        let slices = await Task.detached(priority: .userInitiated) {
            DeviceRecordSlices(jobs: sliceJobs, of: divided)
        }.value
        let plan = slices.merged(into: reviewed, writesFolderCoverArt: settings.writesFolderCoverArt)
        // The tracks this run took off the device queue. Ones sent to the
        // device while the walk or the sheet was up stay queued for the next.
        let taken = Set(pending.tracks.map(\.track.fileURL.path))

        guard !plan.copies.isEmpty || !plan.deletions.isEmpty || !plan.unplanned.isEmpty else {
            // Nothing is missing: the send is done, so the cockpit stays on
            // the device without these tracks, as after a send, and its
            // answers stand.
            rememberDeviceAnswers(answers, of: review, profileID: profile.id)
            persistSelectionToDevice(selection, profileID: profile.id)
            removeFromPendingDeviceQueue(taken, profileID: profile.id)
            appAlert = .info(
                title: "Nothing to transfer",
                message: "\(profile.name) needs nothing from this selection: "
                    + DeviceTransferSummary.statusLine(for: plan, outcome: .init()) + "."
            )
            return
        }

        // Only what will be written counts against the free space; what a
        // Replace frees is not credited, so the check stays conservative.
        // Found out without writing to the device.
        var seenSources: Set<String> = []
        let sizedSources = plan.copies.map(\.source).filter { seenSources.insert($0.track.fileURL.path).inserted }
        if let problem = deviceWritabilityProblem(musicFolder, deviceName: profile.name)
            ?? probeFreeDiskSpace(
                musicFolder,
                sourceTracks: sizedSources,
                estimateFactor: (selection.outputFormat == .wav || selection.outputFormat == .aiff) ? 2.5 : 1.10,
                insufficientSpaceMessageFormat: "This batch needs ~%.1f GB on the device but only %.1f GB is available."
            ) {
            appAlert = problem
            return
        }
        guard let door = makeTransferDoor(for: runProfile, device: device, musicFolder: musicFolder) else { return }
        // The scan and the sheet can take a while; another job may have
        // started on the conversion channel meanwhile.
        guard !isConversionRunning else {
            appAlert = .error(
                title: "Another transfer is running",
                message: "Nothing was sent to \(profile.name). Send again once it finishes."
            )
            return
        }
        // Busy from here until the catalog is patched: the conversions'
        // progress ends before the renames, deletions, covers and patch do.
        isDeviceTransferRunning = true
        defer { isDeviceTransferRunning = false }
        // Cancel is live from the moment the run reads as busy: a press while
        // the partial jobs are still being planned must not be dropped. The
        // service holds the flag, so its queue never dispatches after it.
        activeConversionService = service
        defer { activeConversionService = nil }
        rememberDeviceAnswers(answers, of: review, profileID: profile.id)

        // ffmpeg never writes onto the device: it converts into a staging
        // folder on this Mac, and the finished files go over through the
        // write door. Core decides what is held back now (a refused path, a
        // file that appeared, no room to stage it) and what lands afterwards.
        // The staging folder goes however the run ends.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateDigger-DeviceSend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let outputFormat = preset.outputFormat
        let staged = await Task.detached(priority: .userInitiated) { () -> DeviceTransferExecutor.StagedJobs in
            let fm = FileManager.default
            return DeviceTransferExecutor(door: door).stagedJobs(
                for: plan,
                stagingRoot: stagingRoot,
                slices: slices.jobs,
                stagingBytesAvailable: fm.temporaryDirectory.volumeFreeBytes,
                estimatedBytes: { copy in
                    let size = ((try? fm.attributesOfItem(atPath: copy.source.track.fileURL.path))?[.size]
                        as? NSNumber)?.int64Value ?? 0
                    return DeviceTransferExecutor.estimatedConvertedBytes(sourceBytes: size, format: outputFormat)
                }
            )
        }.value
        let ran = staged.jobs.isEmpty
            ? nil
            : await runConversionQueue(service: service, jobs: staged.jobs, preset: preset, endsBusyJob: false)

        // Cancel stays live through the copies and deletions: a press after
        // the last job was dispatched still stops every deletion and every
        // copy not started. The queue let go of the service when it
        // finished, so hold it again.
        activeConversionService = service
        let succeeded = ran?.succeededDestinationPaths ?? []
        let failureReasons = ran?.failureReasons ?? [:]
        let wasCancelled = (ran?.wasCancelled ?? false) || service.isCancelled
        let sliceDestinations = Set(slices.jobs.keys)
        // The copies to the device show on CNVRT like the encodes before them.
        let copies = plan.copies
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0, jobsTotal: copies.count,
            currentFilename: copies.first?.destinationURL.lastPathComponent, isRunning: true
        )
        let outcome = await Task.detached(priority: .userInitiated) {
            DeviceTransferExecutor(door: door).finishConverted(
                plan,
                jobs: staged,
                succeeded: succeeded,
                reasons: failureReasons,
                wasCancelled: wasCancelled,
                isCancelled: { service.isCancelled },
                onProgress: { completed, total in
                    Task { @MainActor in
                        guard self.conversionProgress.isRunning else { return }
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: completed, jobsTotal: total,
                            currentFilename: completed < total ? copies[completed].destinationURL.lastPathComponent : nil,
                            isRunning: completed < total
                        )
                    }
                },
                name: { copy in
                    sliceDestinations.contains(copy.destinationURL.path)
                        ? copy.destinationURL.lastPathComponent
                        : copy.source.track.fileURL.lastPathComponent
                }
            )
        }.value
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: copies.count, jobsTotal: copies.count, currentFilename: nil, isRunning: false
        )
        let cancelledCount = outcome.failed.filter { $0.reason == ConversionQueueOutcome.cancelledReason }.count
        endBusyJob(ran?.busyJob, .conversion(
            succeeded: outcome.written.count,
            failed: outcome.failed.count - cancelledCount,
            cancelled: cancelledCount
        ))

        // A cover only where something actually landed, and never over one
        // a Gaps fill found there. The plan lists cover folders only when the
        // run's Folder Art switch is on, which may not be stored on the
        // device yet (it is saved below).
        let covers = writeFolderCoverArt(
            landings: plan.coverFolders(after: outcome.written, hasCover: { FolderCoverArtWriter.hasCover(in: $0) })
                .map { (folder: $0.key, artwork: $0.value.metadata.artwork) },
            for: profile.name,
            door: door
        )
        await patchDeviceCatalog(
            for: device,
            adding: outcome.written.map {
                DeviceCatalogStore.writtenTrack(
                    source: $0.source,
                    destination: $0.destinationURL,
                    preset: preset,
                    writesFolderCoverArt: runProfile.usesFolderCoverArt
                )
            },
            removingPaths: outcome.removedPaths
        )

        let nextSteps = await finishDeviceSession(
            device: device, profile: runProfile,
            written: outcome.written.map(\.destinationURL), deleted: outcome.deleted,
            changes: outcome.changes(coversWritten: covers)
        )

        // Remember any format/folder tweaks on the device profile and stay
        // routed to it: the next album you send needs no setup.
        persistSelectionToDevice(selection, profileID: profile.id)
        removeFromPendingDeviceQueue(taken, profileID: profile.id)
        presentSummary(report: deviceReport(deviceSendReport(plan: plan, outcome: outcome, deviceName: profile.name),
                                            nextSteps: nextSteps, device: device),
                       presentingFrom: host)
    }

    /// The summary of a device send, worded like the copy path's.
    private func deviceSendReport(
        plan: DeviceTransferFilePlan,
        outcome: DeviceTransferExecutor.Outcome,
        deviceName: String
    ) -> ConversionReport {
        let failed = DeviceTransferSummary.failedCount(for: plan, outcome: outcome)
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
        return ConversionReport(
            title: title,
            statusLine: DeviceTransferSummary.statusLine(for: plan, outcome: outcome),
            details: outcome.lines.joined(separator: "\n"),
            tone: tone,
            showsDetailsButton: !outcome.lines.isEmpty
        )
    }

    /// Block obvious failure modes before we hand off to ffmpeg. Returns an
    /// alert to present, or nil to proceed.
    private func validateBatchPreflight(
        destinationRoot: URL,
        sourceTracks: [LoadedTrack],
        outputFormat: OutputFormat
    ) -> AppAlert? {
        if let writabilityProblem = probeDestinationWritability(
            destinationRoot,
            createFailureTitle: "Can't write to destination",
            createFailureMessage: "CrateDigger could not create the destination folder \(destinationRoot.path). Pick another folder under Preferences > General.",
            notWritableTitle: "Destination isn't writable",
            notWritableMessage: "CrateDigger doesn't have permission to write into \(destinationRoot.path). Choose a different folder under Preferences > General, or grant Files & Folders access in System Settings.",
            probeFilenamePrefix: ".cratedigger-write-probe-"
        ) {
            return writabilityProblem
        }
        if let spaceProblem = probeFreeDiskSpace(
            destinationRoot,
            sourceTracks: sourceTracks,
            // Uncompressed PCM output typically runs ~2x a lossless source;
            // 2.5x is a safe ceiling. Everything else: source total + 10%.
            estimateFactor: (outputFormat == .wav || outputFormat == .aiff) ? 2.5 : 1.10,
            insufficientSpaceMessageFormat: "This batch needs ~%.1f GB on the destination volume but only %.1f GB is available. Free up space or pick a different output folder."
        ) {
            return spaceProblem
        }
        return nil
    }

    /// Shared destination-writability probe used by both conversion and external
    /// device transfer. Creates the folder if missing, then writes and removes a
    /// tiny probe file. Callers supply their own alert copy.
    func probeDestinationWritability(
        _ destinationRoot: URL,
        createFailureTitle: String,
        createFailureMessage: String,
        notWritableTitle: String,
        notWritableMessage: String,
        probeFilenamePrefix: String
    ) -> AppAlert? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationRoot.path) {
            do {
                try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            } catch {
                AppLog.conversion.error("Could not create destination root \(destinationRoot.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return .error(title: createFailureTitle, message: createFailureMessage)
            }
        }

        let probe = destinationRoot
            .appendingPathComponent("\(probeFilenamePrefix)\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? fm.removeItem(at: probe)
            return nil
        } catch {
            AppLog.conversion.error("Destination not writable \(destinationRoot.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .error(title: notWritableTitle, message: notWritableMessage)
        }
    }

    /// Shared free-space probe. Sums source bytes, compares against the
    /// destination volume's available capacity scaled by `estimateFactor`
    /// (default: source total + 10% headroom), and returns a caller-supplied
    /// alert message when there isn't enough room.
    func probeFreeDiskSpace(
        _ destinationRoot: URL,
        sourceTracks: [LoadedTrack],
        estimateFactor: Double = 1.10,
        insufficientSpaceMessageFormat: String
    ) -> AppAlert? {
        let totalSourceBytes: Int64 = sourceTracks.reduce(0) { running, track in
            let attrs = try? FileManager.default.attributesOfItem(atPath: track.track.fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return running + size
        }
        guard totalSourceBytes > 0 else { return nil }

        guard let available = destinationRoot.volumeFreeBytes, available > 0 else { return nil }

        let estimatedNeed = Int64(Double(totalSourceBytes) * estimateFactor)
        guard available < estimatedNeed else { return nil }

        let needGB = Double(estimatedNeed) / 1_000_000_000
        let availGB = Double(available) / 1_000_000_000
        return .error(
            title: "Not enough free space",
            message: String(format: insufficientSpaceMessageFormat, needGB, availGB)
        )
    }

    @MainActor
    func cancelConversion() {
        // A Secure Mode rip's read phase runs before any conversion exists.
        secureRipCancellation?.cancel()
        activeConversionService?.cancel()
        conversionTask?.cancel()
        AppLog.conversion.notice("User requested conversion cancellation")
    }

    // MARK: - Implementation

    func customFFmpegExecutableURL() -> URL? {
        guard let path = prefs.customFFmpegPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Refill artwork bytes that were dropped when tracks were decoded from a
    /// `.cdlib` (the crate stores only the hash). Without this, re-embedding a
    /// compatible cover during conversion/transfer fails with
    /// `couldNotDecodeImage` on empty data and silently falls back to copying
    /// the source art stream.
    ///
    /// Bytes are re-read from each track's own file/folder when they aren't
    /// cached in memory — the disk cache holds thumbnails, which must never be
    /// re-embedded (see `ArtworkService.hydrated`).
    @MainActor
    func tracksWithHydratedArtwork(_ tracks: [LoadedTrack]) async -> [LoadedTrack] {
        var hydrated: [LoadedTrack] = []
        hydrated.reserveCapacity(tracks.count)
        for track in tracks {
            guard let art = track.metadata.artwork, art.data.isEmpty else {
                hydrated.append(track)
                continue
            }
            var metadata = track.metadata
            metadata.artwork = await artworkService.hydrated(art, trackURL: track.track.fileURL)
            hydrated.append(LoadedTrack(track: track.track, metadata: metadata, recordMarkers: track.recordMarkers))
        }
        return hydrated
    }

    @MainActor
    func tracksForBatchScope(_ scope: ConversionBatchScope) -> [LoadedTrack] {
        switch scope {
        case .queue:     return convertQueue
        case .prep:      return prepCrateTracks
        case .selection: return selectedTracksForCrateAdd()
        }
    }

    /// Add to the convert queue, skipping anything already in it, and point the
    /// cockpit at the queue so the addition is visible where it landed.
    @MainActor
    func addToConvertQueue(_ tracks: [LoadedTrack]) {
        let known = Set(convertQueue.map { $0.track.fileURL.path })
        let fresh = tracks.filter { !known.contains($0.track.fileURL.path) }
        guard !fresh.isEmpty else {
            showOLEDNotice("ALREADY QUEUED")
            return
        }
        convertQueue += fresh
        conversionSelection.batchScope = .queue
        showOLEDNotice("QUEUED \(convertQueue.count) TRK")
    }

    @MainActor
    func clearConvertQueue() {
        guard !convertQueue.isEmpty else { return }
        convertQueue = []
        showOLEDNotice("QUEUE CLEARED")
    }

    @MainActor
    private func resolveOutputDestination(presentingFrom host: NSViewController) async -> URL? {
        if let bookmark = prefs.savedOutputDestinationBookmark,
           let (refreshed, resolved) = PreferencesStore.refreshBookmarkIfStale(bookmark) {
            if refreshed != bookmark {
                prefs.savedOutputDestinationBookmark = refreshed
            }
            return resolved.url
        }
        return await promptForOutputDestination(presentingFrom: host)
    }

    @MainActor
    private func promptForOutputDestination(presentingFrom host: NSViewController) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose where converted files go"
        panel.prompt = "Choose"

        return await withCheckedContinuation { continuation in
            if let window = host.view.window {
                panel.beginSheetModal(for: window) { response in
                    let url = response == .OK ? panel.url : nil
                    if let url {
                        if let data = try? PreferencesStore.makeBookmark(for: url) {
                            self.prefs.savedOutputDestinationBookmark = data
                        }
                    }
                    continuation.resume(returning: url)
                }
            } else {
                let response = panel.runModal()
                let url = response == .OK ? panel.url : nil
                if let url, let data = try? PreferencesStore.makeBookmark(for: url) {
                    self.prefs.savedOutputDestinationBookmark = data
                }
                continuation.resume(returning: url)
            }
        }
    }

    /// `deviceProfile`: a device run passes its device's, which decides how
    /// re-embedded art is prepared (the legacy-safe iPod caps it at 600 px).
    func makeAdHocPreset(
        from selection: ConversionOptionsSelection,
        deviceProfile: DeviceProfile = .generic
    ) -> ConversionPreset {
        // Normalized, so a knob the format ignores (a bitrate under FLAC, a
        // 44.1 kHz rate under Opus) never reaches ffmpeg.
        let encoding = selection.encoding.normalized()
        return ConversionPreset(
            id: "user_\(encoding.format.rawValue)_\(encoding.bitrateKbps ?? 0)",
            name: "User selection",
            outputFormat: encoding.format,
            bitrateKbps: encoding.bitrateKbps,
            sampleRateHz: encoding.sampleRateHz,
            channels: nil,
            constantBitrate: false,
            deviceProfile: deviceProfile,
            tagMode: .auto,
            artworkMode: selection.artworkMode,
            artworkMaxDimension: selection.artworkMaxDimension,
            bitDepth: encoding.bitDepth,
            flacCompressionLevel: encoding.flacCompressionLevel
        )
    }

    private func buildAlbumFolderReviewRows(
        tracks: [LoadedTrack],
        templateConfig: FolderTemplateConfig
    ) -> [AlbumFolderReviewRow] {
        let planner = OutputPathPlanner()
        let albumKeys = planner.albumFolderKeys(for: tracks)
        var seen = Set<AlbumFolderKey>()
        var rows: [AlbumFolderReviewRow] = []
        for track in tracks {
            let key = albumKeys[track.track.id] ?? planner.albumFolderKey(for: track)
            guard seen.insert(key).inserted else { continue }
            let proposed = planner.buildOutputSubpath(
                for: track, templateConfig: templateConfig, albumKey: key
            )
            let label = [key.artistBucket, key.album, key.year]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            rows.append(AlbumFolderReviewRow(
                key: key,
                albumLabel: label.isEmpty ? "Unknown Album" : label,
                proposedSubpath: proposed
            ))
        }
        return rows.sorted { $0.albumLabel.localizedCaseInsensitiveCompare($1.albumLabel) == .orderedAscending }
    }

    @MainActor
    private func presentAlbumFolderReview(
        rows: [AlbumFolderReviewRow],
        presentingFrom host: NSViewController
    ) async -> [AlbumFolderKey: String]? {
        await withCheckedContinuation { continuation in
            let controller = AlbumFolderReviewSheetController(rows: rows)
            var resumed = false
            controller.onDecision = { [weak controller] reviewed in
                guard !resumed else { return }
                resumed = true
                controller?.dismiss(nil)
                continuation.resume(returning: reviewed)
            }
            host.presentAsSheet(controller)
        }
    }

    private func planConversionJobs(
        tracks: [LoadedTrack],
        preset: ConversionPreset,
        destinationRoot: URL,
        folderMode: FolderStructureMode,
        templateConfig: FolderTemplateConfig,
        reviewedAlbumFolders: [AlbumFolderKey: String],
        reservedDestinationPaths: Set<String> = []
    ) -> [ConversionJob] {
        let planner = OutputPathPlanner()
        let albumKeys = planner.albumFolderKeys(for: tracks)
        var reserved = reservedDestinationPaths
        var jobs: [ConversionJob] = []

        // Use the deepest common ancestor of source files as the source root
        // for sourceRelative mode. With multiple library folders, this still
        // produces a sensible relative subpath for files that share an ancestor.
        let sourceRoot = commonAncestorDirectory(for: tracks.map { $0.track.fileURL })

        for track in tracks {
            // Record Divider: a track with markers expands into one job per kept
            // track, each cutting its slice from the shared source file.
            let recordPlans = RecordTrackPlanner.trackPlans(for: track)
            if !recordPlans.isEmpty {
                for recordPlan in recordPlans {
                    let plan = planner.planDestination(
                        for: track,
                        preset: preset,
                        destinationRoot: destinationRoot,
                        sourceRoot: sourceRoot,
                        folderMode: folderMode,
                        templateConfig: templateConfig,
                        reviewedAlbumFolders: reviewedAlbumFolders,
                        reservedDestinationPaths: reserved,
                        baseNameOverride: recordPlan.baseName,
                        avoidExistingFiles: false,
                        albumKey: albumKeys[track.track.id]
                    )
                    reserved.insert(plan.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)
                    jobs.append(ConversionJob(
                        sourceURL: track.track.fileURL,
                        destinationURL: plan.destinationURL,
                        metadata: recordPlan.metadata,
                        startSeconds: recordPlan.startSeconds,
                        endSeconds: recordPlan.endSeconds
                    ))
                }
                continue
            }

            let plan = planner.planDestination(
                for: track,
                preset: preset,
                destinationRoot: destinationRoot,
                sourceRoot: sourceRoot,
                folderMode: folderMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders,
                reservedDestinationPaths: reserved,
                avoidExistingFiles: false,
                albumKey: albumKeys[track.track.id]
            )
            reserved.insert(plan.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)
            jobs.append(ConversionJob(
                sourceURL: track.track.fileURL,
                destinationURL: plan.destinationURL,
                metadata: track.metadata
            ))
        }
        return jobs
    }

    private func commonAncestorDirectory(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var commonComponents = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var n = 0
            while n < commonComponents.count, n < parts.count, commonComponents[n] == parts[n] {
                n += 1
            }
            commonComponents = Array(commonComponents.prefix(n))
            if commonComponents.isEmpty { return nil }
        }
        if commonComponents.isEmpty { return nil }
        return URL(fileURLWithPath: "/" + commonComponents.dropFirst().joined(separator: "/"))
    }

    struct ConversionQueueOutcome {
        let report: ConversionReport
        /// Destination paths of jobs that completed — lets device-sync staging
        /// record exactly which bakes are real.
        let succeededDestinationPaths: Set<String>
        /// Why each job that did not complete failed, by destination path:
        /// `cancelledReason`, or the last line of ffmpeg's log.
        let failureReasons: [String: String]
        /// Some job was cancelled, or Cancel was pressed at all (after the
        /// last job was dispatched, nothing reports it).
        let wasCancelled: Bool
        /// The batch's busy job when the caller ends it (`endsBusyJob: false`).
        let busyJob: BusyJobID?

        static let cancelledReason = "Cancelled"
    }

    /// `endsBusyJob`: false for a caller with more to do after the batch (a
    /// device run's renames and deletions); it ends `busyJob` itself.
    @MainActor
    func runConversionQueue(
        service: ConversionService,
        jobs: [ConversionJob],
        preset: ConversionPreset,
        endsBusyJob: Bool = true
    ) async -> ConversionQueueOutcome {
        let total = jobs.count
        oledView = .conversion
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0,
            jobsTotal: total,
            currentFilename: jobs.first?.sourceURL.lastPathComponent,
            isRunning: true
        )
        // Covers the Patch Bay convert and the device pre-convert alike: both
        // really are conversions, drawn on CNVRT.
        let busyJob = beginBusyJob(
            .convert, on: .conversion,
            labels: .conversion(sourceExtensions: jobs.map { $0.sourceURL.pathExtension },
                                target: preset.outputFormat),
            lossless: preset.outputFormat.isLossless
        )

        AppLog.conversion.info("Starting batch of \(total, privacy: .public) jobs as \(preset.outputFormat.rawValue, privacy: .public)")

        activeConversionService = service
        defer { activeConversionService = nil }

        let (results, succeededPaths, failureReasons): ([ConversionExecutionResult], Set<String>, [String: String]) = await withCheckedContinuation { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let queued = service.enqueue(jobs, preset: preset)
                // Parallel workers finish in any order, so name the file that
                // actually just finished — keyed by its queued ID, not by count.
                let filenameByID = Dictionary(uniqueKeysWithValues: queued.map {
                    ($0.id, $0.job.sourceURL.lastPathComponent)
                })
                let outcomes = service.runQueuedJobs(maxConcurrentWorkers: nil) { result, completed, totalCount in
                    Task { @MainActor in
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: completed,
                            jobsTotal: totalCount,
                            currentFilename: completed < totalCount ? filenameByID[result.queuedID] : nil,
                            isRunning: completed < totalCount
                        )
                    }
                    if result.status == .failed && !result.wasCancelled {
                        AppLog.conversion.error("Job failed: \(result.log, privacy: .public)")
                    } else if let warning = result.warning {
                        AppLog.conversion.warning("Job warning: \(warning, privacy: .public)")
                    }
                }
                // Which destinations really landed — staging records only these.
                let succeededIDs = Set(outcomes.filter { $0.status == .completed }.map(\.queuedID))
                let paths = Set(queued.filter { succeededIDs.contains($0.id) }
                    .map { $0.job.destinationURL.path })
                let destinationByID = Dictionary(uniqueKeysWithValues: queued.map {
                    ($0.id, $0.job.destinationURL.path)
                })
                var reasons: [String: String] = [:]
                for outcome in outcomes where outcome.status != .completed {
                    guard let path = destinationByID[outcome.queuedID] else { continue }
                    let lastLine = outcome.log.split(separator: "\n").last.map(String.init) ?? outcome.log
                    reasons[path] = outcome.wasCancelled
                        ? ConversionQueueOutcome.cancelledReason
                        : (lastLine.isEmpty ? "Could not be converted" : lastLine)
                }
                continuation.resume(returning: (outcomes, paths, reasons))
            }
            self.conversionTask = task
        }

        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: results.count,
            jobsTotal: total,
            currentFilename: nil,
            isRunning: false
        )
        conversionTask = nil

        let succeeded = results.filter { $0.status == .completed }.count
        let cancelled = results.filter { $0.wasCancelled }.count
        let failed = results.filter { $0.status == .failed }.count - cancelled
        let warnings = results.compactMap { $0.warning }.count
        if endsBusyJob {
            endBusyJob(busyJob, .conversion(succeeded: succeeded, failed: failed, cancelled: cancelled))
        }
        AppLog.conversion.info("Batch finished: \(succeeded, privacy: .public) ok, \(failed, privacy: .public) failed, \(cancelled, privacy: .public) cancelled, \(warnings, privacy: .public) with warnings")

        let title: String
        let statusLine: String
        let tone: StatusTone
        if cancelled > 0 {
            // A deliberate cancel isn't a failure — report it neutrally.
            title = "Conversion cancelled"
            statusLine = "Cancelled — \(succeeded) converted, \(cancelled) skipped"
                + (failed > 0 ? ", \(failed) failed" : "")
            tone = failed > 0 ? .warning : .info
        } else if failed == 0 {
            title = "Conversion complete"
            statusLine = "\(succeeded) file\(succeeded == 1 ? "" : "s") written"
            tone = .success
        } else if succeeded == 0 {
            title = "Conversion failed"
            statusLine = "\(failed) job\(failed == 1 ? "" : "s") could not be converted"
            tone = .error
        } else {
            title = "Conversion finished with errors"
            statusLine = "\(succeeded) succeeded, \(failed) failed"
            tone = .warning
        }
        let details = formatConversionDetails(jobs: jobs, results: results)
        return ConversionQueueOutcome(
            report: ConversionReport(
                title: title,
                statusLine: statusLine,
                details: details,
                tone: tone,
                showsDetailsButton: !details.isEmpty
            ),
            succeededDestinationPaths: succeededPaths,
            failureReasons: failureReasons,
            wasCancelled: cancelled > 0 || service.isCancelled,
            busyJob: endsBusyJob ? nil : busyJob
        )
    }

    private func formatConversionDetails(jobs: [ConversionJob], results: [ConversionExecutionResult]) -> String {
        var lines: [String] = []
        for (index, result) in results.enumerated() {
            let filename = index < jobs.count ? jobs[index].sourceURL.lastPathComponent : "(unknown)"
            let prefix: String
            switch result.status {
            case .completed: prefix = "ok"
            case .failed:    prefix = result.wasCancelled ? "cancelled" : "FAILED"
            case .running:   prefix = "running"
            case .queued:    prefix = "queued"
            }
            var line = "[\(prefix)] \(filename)"
            if let warning = result.warning, !warning.isEmpty {
                line += " — \(warning)"
            }
            if result.status == .failed && !result.wasCancelled {
                line += "\n    \(result.log.split(separator: "\n").last.map(String.init) ?? result.log)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The cockpit's go key

    /// The device queue the key is armed on, or nil when it is the crate queue's
    /// turn. An armed device that no longer has anything waiting resolves to nil
    /// rather than to a dead key — a finished sync empties its own queue.
    /// A route (a disc to rip, or a device hand-off) outranks both.
    @MainActor
    var patchBayDeviceQueue: ExternalDeviceProfile? {
        guard !cockpitIsRouted,
              let id = armedDeviceQueueID,
              let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == id }),
              !syncQueueSummary(profileID: id).isEmpty
        else { return nil }
        return profile
    }

    /// Arm a queue: a device's, or the crate queue with nil. The QUEUE tab's
    /// headers and the device strip's SETTINGS key both come through here.
    @MainActor
    func armQueue(deviceID: UUID?) {
        armedDeviceQueueID = deviceID
    }

    @MainActor
    var patchBayGoAction: PatchBayGoAction {
        let armed = patchBayDeviceQueue
        return PatchBayGoAction.resolve(
            hasPendingDisc: pendingCDRip != nil,
            pendingDeviceName: pendingDeviceConversion?.deviceName,
            armedDeviceName: armed?.name,
            armedDeviceIsConnected: armed.map { isDeviceConnected(profileID: $0.id) } ?? false
        )
    }

    /// Nothing to press when the run it names has no work in it.
    @MainActor
    var patchBayGoEnabled: Bool {
        guard !isConversionRunning, deviceSyncProgress?.isRunning != true else { return false }
        switch patchBayGoAction {
        case .convert, .sendToDevice:
            return !conversionQueueTracks.isEmpty
        case .ripDisc:
            return !conversionQueueTracks.isEmpty && !cdIdentityPending
        case .syncToDevice:
            return true   // patchBayDeviceQueue is non-empty by construction
        case .preConvertForDevice:
            guard let profile = patchBayDeviceQueue else { return false }
            return syncQueueSummary(profileID: profile.id).pendingConversionCount > 0
        }
    }

    /// Run whatever the key says.
    @MainActor
    func runPatchBayGo() {
        guard patchBayGoEnabled else { return }
        switch patchBayGoAction {
        case .convert, .sendToDevice:
            triggerConversionFromPatchBay()
        case .ripDisc:
            guard let disc = pendingCDRip else { return }
            ripCD(info: disc)
        case .syncToDevice:
            guard let profile = patchBayDeviceQueue else { return }
            syncQueuedTransfers(profileID: profile.id)
        case .preConvertForDevice:
            guard let profile = patchBayDeviceQueue else { return }
            convertQueuedTransfers(profileID: profile.id)
        }
    }

    @MainActor
    func presentSummary(report: ConversionReport, presentingFrom host: NSViewController) {
        let summary = ConversionSummarySheetController(report: report)
        summary.onClose = { [weak summary] in
            summary?.dismiss(nil)
        }
        host.presentAsSheet(summary)
    }
}

// MARK: - Storage helpers

extension LibraryViewModel {
    /// A job is writing on the conversion channel, or a device send is
    /// still finishing (deletions, covers, catalog patch) after its last write.
    var isConversionRunning: Bool {
        conversionProgress.isRunning || isDeviceTransferRunning
    }

    /// Whether Cancel has a job to stop: anything on the conversion channel
    /// except a device SYNC, which has no cancel. Read by the Patch Bay's
    /// Cancel key and File > Cancel Conversion.
    var canCancelConversion: Bool {
        isConversionRunning && deviceSyncProgress?.isRunning != true
    }

    /// The relative output path the current settings would write for one track,
    /// resolved through the same planner the conversion uses so the queue view
    /// shows the real destination rather than a guess. Nil when the format can't
    /// be resolved yet.
    /// The album keys of everything in the convert queue, reconciled together.
    /// Read once per queue render and handed to `plannedOutputName(for:albumKey:)`,
    /// so the preview names the folder the batch will really write to.
    var conversionQueueAlbumKeys: [UUID: AlbumFolderKey] {
        OutputPathPlanner().albumFolderKeys(for: conversionQueueTracks)
    }

    func plannedOutputName(for track: LoadedTrack, albumKey: AlbumFolderKey? = nil) -> String? {
        let selection = conversionSelection
        let templateConfig = FolderTemplateConfig(
            preset: selection.templatePreset,
            tokenOrder: selection.tokenOrder,
            separators: selection.separators
        )
        let planner = OutputPathPlanner()
        let ext = selection.outputFormat.fileExtension
        let base = track.track.fileURL.deletingPathExtension().lastPathComponent

        switch selection.folderStructureMode {
        case .metadataTemplate:
            let folder = planner.buildOutputSubpath(
                for: track, templateConfig: templateConfig, albumKey: albumKey
            )
            return folder.isEmpty ? "\(base).\(ext)" : "\(folder)/\(base).\(ext)"
        case .flat, .sourceRelative:
            return "\(base).\(ext)"
        }
    }

}
