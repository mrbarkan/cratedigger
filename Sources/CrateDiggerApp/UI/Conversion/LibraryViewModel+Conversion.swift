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

        let sourceTracks = tracksForBatchScope(selection.batchScope)
        guard !sourceTracks.isEmpty else {
            appAlert = .info(
                title: "Nothing to convert",
                message: "No tracks matched the chosen scope. Load a folder, pick an album, then try again."
            )
            return
        }

        Task { @MainActor in
            guard let destinationRoot = await resolveOutputDestination(presentingFrom: host) else {
                AppLog.conversion.notice("User cancelled output-destination selection")
                return
            }

            let preset = makeAdHocPreset(from: selection)
            let templateConfig = FolderTemplateConfig(
                preset: selection.templatePreset,
                tokenOrder: selection.tokenOrder
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

            let jobs = planConversionJobs(
                tracks: sourceTracks,
                preset: preset,
                destinationRoot: destinationRoot,
                folderMode: selection.folderStructureMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedFolders
            )

            guard !jobs.isEmpty else {
                appAlert = .info(
                    title: "Nothing to convert",
                    message: "All tracks resolved to the same destination paths and were skipped."
                )
                return
            }

            // Persist the user's selection for next launch.
            prefs.saveLastConversionSelection(PersistedConversionSelection(selection))

            let report = await runConversionQueue(service: service, jobs: jobs, preset: preset)
            presentSummary(report: report, presentingFrom: host)
        }
    }

    @MainActor
    func cancelConversion() {
        conversionTask?.cancel()
    }

    // MARK: - Implementation

    private func customFFmpegExecutableURL() -> URL? {
        guard let path = prefs.customFFmpegPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    @MainActor
    private func tracksForBatchScope(_ scope: ConversionBatchScope) -> [LoadedTrack] {
        switch scope {
        case .selectedTracks:
            // V1 semantics: "selected tracks" = the currently selected album's
            // tracks. Multi-track selection isn't a UI concept yet; this is the
            // most useful default a user will reach for from the Cnvrt key.
            return visibleTracks
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
        let bitrate = isLossless(selection.outputFormat) ? nil : selection.bitrate
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

    private func isLossless(_ format: OutputFormat) -> Bool {
        switch format {
        case .alac, .flac, .wav, .aiff:
            return true
        case .mp3, .aac, .ogg, .opus:
            return false
        }
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
            let plan = planner.planDestination(
                for: track,
                preset: preset,
                destinationRoot: destinationRoot,
                sourceRoot: sourceRoot,
                folderMode: folderMode,
                templateConfig: templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders,
                reservedDestinationPaths: reserved
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

    @MainActor
    private func runConversionQueue(
        service: ConversionService,
        jobs: [ConversionJob],
        preset: ConversionPreset
    ) async -> ConversionReport {
        let total = jobs.count
        oledView = .conversion
        conversionProgress = ConversionProgressSnapshot(
            jobsCompleted: 0,
            jobsTotal: total,
            currentFilename: jobs.first?.sourceURL.lastPathComponent,
            isRunning: true
        )

        AppLog.conversion.info("Starting batch of \(total, privacy: .public) jobs as \(preset.outputFormat.rawValue, privacy: .public)")

        let results: [ConversionExecutionResult] = await withCheckedContinuation { continuation in
            let task = Task.detached(priority: .userInitiated) {
                _ = service.enqueue(jobs, preset: preset)
                let outcomes = service.runQueuedJobs(maxConcurrentWorkers: nil) { result, completed, totalCount in
                    Task { @MainActor in
                        let nextFilename: String?
                        if completed < jobs.count {
                            nextFilename = jobs[completed].sourceURL.lastPathComponent
                        } else {
                            nextFilename = nil
                        }
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: completed,
                            jobsTotal: totalCount,
                            currentFilename: nextFilename,
                            isRunning: completed < totalCount
                        )
                    }
                    if result.status == .failed {
                        AppLog.conversion.error("Job failed: \(result.log, privacy: .public)")
                    } else if let warning = result.warning {
                        AppLog.conversion.warning("Job warning: \(warning, privacy: .public)")
                    }
                }
                continuation.resume(returning: outcomes)
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
        let failed = results.filter { $0.status == .failed }.count
        let warnings = results.compactMap { $0.warning }.count
        AppLog.conversion.info("Batch finished: \(succeeded, privacy: .public) ok, \(failed, privacy: .public) failed, \(warnings, privacy: .public) with warnings")

        let title: String
        let statusLine: String
        let tone: StatusTone
        if failed == 0 {
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
        return ConversionReport(
            title: title,
            statusLine: statusLine,
            details: details,
            tone: tone,
            showsDetailsButton: !details.isEmpty
        )
    }

    private func formatConversionDetails(jobs: [ConversionJob], results: [ConversionExecutionResult]) -> String {
        var lines: [String] = []
        for (index, result) in results.enumerated() {
            let filename = index < jobs.count ? jobs[index].sourceURL.lastPathComponent : "(unknown)"
            let prefix: String
            switch result.status {
            case .completed: prefix = "ok"
            case .failed:    prefix = "FAILED"
            case .running:   prefix = "running"
            case .queued:    prefix = "queued"
            }
            var line = "[\(prefix)] \(filename)"
            if let warning = result.warning, !warning.isEmpty {
                line += " — \(warning)"
            }
            if result.status == .failed {
                line += "\n    \(result.log.split(separator: "\n").last.map(String.init) ?? result.log)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func presentSummary(report: ConversionReport, presentingFrom host: NSViewController) {
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

/// JSON-safe codable mirror of `ConversionOptionsSelection` so we can persist
/// the user's last-used choices through PreferencesStore. Decoders read this
/// back; the conversion entry seeds defaults from it on next launch.
struct PersistedConversionSelection: Codable {
    let batchScopeRaw: Int
    let outputFormat: String
    let bitrate: Int?
    let sampleRate: Int?
    let artworkMaxDimension: Int?
    let folderStructureMode: String
    let applyMode: String
    let templatePreset: String
    let tokenOrder: [String]

    init(_ selection: ConversionOptionsSelection) {
        batchScopeRaw = selection.batchScope.rawValue
        outputFormat = selection.outputFormat.rawValue
        bitrate = selection.bitrate
        sampleRate = selection.sampleRate
        artworkMaxDimension = selection.artworkMaxDimension
        folderStructureMode = selection.folderStructureMode.rawValue
        applyMode = selection.applyMode.rawValue
        templatePreset = selection.templatePreset.rawValue
        tokenOrder = selection.tokenOrder.map { $0.rawValue }
    }

    func materialize() -> ConversionOptionsSelection? {
        guard let scope = ConversionBatchScope(rawValue: batchScopeRaw) else { return nil }
        guard let format = OutputFormat(rawValue: outputFormat) else { return nil }
        guard let folderMode = FolderStructureMode(rawValue: folderStructureMode) else { return nil }
        guard let apply = TemplateApplyMode(rawValue: applyMode) else { return nil }
        guard let preset = TemplatePreset(rawValue: templatePreset) else { return nil }
        let tokens = tokenOrder.compactMap { FolderToken(rawValue: $0) }
        return ConversionOptionsSelection(
            batchScope: scope,
            outputFormat: format,
            bitrate: bitrate,
            sampleRate: sampleRate,
            artworkMaxDimension: artworkMaxDimension,
            folderStructureMode: folderMode,
            applyMode: apply,
            templatePreset: preset,
            tokenOrder: tokens.isEmpty ? preset.defaultTokenOrder : tokens
        )
    }
}
