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
                            reviewedFolders[conflict.key] = nextAvailableVersionFolderName(for: conflict.existingFolder)
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
                jobs: jobs,
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

            // Persist the user's selection for next launch.
            prefs.saveLastConversionSelection(selection)

            let report = await runConversionQueue(service: service, jobs: finalJobs, preset: preset).report
            if let deviceTransfer {
                // Remember any format/folder tweaks on the device profile, then
                // restore the user's normal conversion selection.
                persistSelectionToDevice(selection, profileID: deviceTransfer.profileID)
            }
            clearPendingDeviceConversion()
            presentSummary(
                report: deviceTransfer.map { deviceReport(report, deviceName: $0.deviceName) } ?? report,
                presentingFrom: host
            )
        }
    }

    /// Write the format + folder layout the user just used back onto the device
    /// profile, so the next transfer to it defaults to the same pattern.
    private func persistSelectionToDevice(_ selection: ConversionOptionsSelection, profileID: UUID) {
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return }
        var settings = profile.transferSettings
        settings.outputFormat = selection.outputFormat
        settings.bitrateKbps = selection.bitrate
        settings.sampleRateHz = selection.sampleRate
        settings.artworkMaxDimension = selection.artworkMaxDimension
        settings.folderStructureMode = selection.folderStructureMode
        settings.templateConfig = FolderTemplateConfig(
            preset: selection.templatePreset,
            tokenOrder: FolderTokenOrder.normalize(selection.tokenOrder),
            separators: selection.separators
        )
        profile.transferSettings = settings
        prefs.upsertExternalDeviceProfile(profile)
    }

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
        let keyBySourcePath = Dictionary(
            tracks.map { ($0.track.fileURL.path, planner.albumFolderKey(for: $0)) },
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

    /// "1997 OK Computer" → "1997 OK Computer [2]", bumping until no folder
    /// with that name exists beside the original.
    private func nextAvailableVersionFolderName(for existingFolder: URL) -> String {
        let base = existingFolder.lastPathComponent
        let parent = existingFolder.deletingLastPathComponent()
        var n = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent("\(base) [\(n)]").path) {
            n += 1
        }
        return "\(base) [\(n)]"
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

    /// Reword a conversion summary as a device transfer ("… written" → "… sent to
    /// <device>") when the run was a send-to-device hand-off.
    private func deviceReport(_ report: ConversionReport, deviceName: String) -> ConversionReport {
        ConversionReport(
            title: report.tone == .success ? "Sent to \(deviceName)" : report.title,
            statusLine: report.statusLine.replacingOccurrences(of: "written", with: "sent to \(deviceName)"),
            details: report.details,
            tone: report.tone,
            showsDetailsButton: report.showsDetailsButton
        )
    }

    /// Block obvious failure modes before we hand off to ffmpeg. Returns an
    /// alert to present, or nil to proceed.
    private func validateBatchPreflight(
        jobs: [ConversionJob],
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

        let values = try? destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = (values?.volumeAvailableCapacityForImportantUsage)
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        guard available > 0 else { return nil }

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
        case .selectedTracks:
            // V1 semantics: "selected tracks" = the currently selected album's
            // tracks. Multi-track selection isn't a UI concept yet; this is the
            // most useful default a user will reach for from the Cnvrt key.
            return visibleTracks
        case .currentAlbum:
            return selectedAlbum?.tracks ?? []
        case .allLoadedTracks:
            return index.allTracks
        }
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

    private func makeAdHocPreset(from selection: ConversionOptionsSelection) -> ConversionPreset {
        let bitrate = selection.outputFormat.isLossless ? nil : selection.bitrate
        return ConversionPreset(
            id: "user_\(selection.outputFormat.rawValue)_\(bitrate ?? 0)",
            name: "User selection",
            outputFormat: selection.outputFormat,
            bitrateKbps: bitrate,
            sampleRateHz: selection.sampleRate,
            channels: nil,
            constantBitrate: false,
            deviceProfile: .generic,
            tagMode: .auto,
            artworkMode: selection.artworkMaxDimension == nil ? .preserve : .compatReembed,
            artworkMaxDimension: selection.artworkMaxDimension
        )
    }

    private func buildAlbumFolderReviewRows(
        tracks: [LoadedTrack],
        templateConfig: FolderTemplateConfig
    ) -> [AlbumFolderReviewRow] {
        let planner = OutputPathPlanner()
        var seen = Set<AlbumFolderKey>()
        var rows: [AlbumFolderReviewRow] = []
        for track in tracks {
            let key = planner.albumFolderKey(for: track)
            guard seen.insert(key).inserted else { continue }
            let proposed = planner.buildOutputSubpath(for: track, templateConfig: templateConfig)
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
        reviewedAlbumFolders: [AlbumFolderKey: String]
    ) -> [ConversionJob] {
        let planner = OutputPathPlanner()
        var reserved = Set<String>()
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
                        avoidExistingFiles: false
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
                avoidExistingFiles: false
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
    }

    @MainActor
    func runConversionQueue(
        service: ConversionService,
        jobs: [ConversionJob],
        preset: ConversionPreset
    ) async -> ConversionQueueOutcome {
        let total = jobs.count
        oledView = .conversion
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0,
            jobsTotal: total,
            currentFilename: jobs.first?.sourceURL.lastPathComponent,
            isRunning: true
        )

        AppLog.conversion.info("Starting batch of \(total, privacy: .public) jobs as \(preset.outputFormat.rawValue, privacy: .public)")

        activeConversionService = service
        defer { activeConversionService = nil }

        let (results, succeededPaths): ([ConversionExecutionResult], Set<String>) = await withCheckedContinuation { continuation in
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
                continuation.resume(returning: (outcomes, paths))
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
            succeededDestinationPaths: succeededPaths
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
    var isConversionRunning: Bool {
        conversionProgress.isRunning
    }
}
