import Foundation

/// The converting side of a device run. ffmpeg runs a batch of jobs in
/// parallel (`ConversionService`), so the executor cannot wrap each write the
/// way `run` does. It decides around the batch instead: `partialJobs` before
/// it (what is held back, where each job writes), `finishConverted` after it
/// (which partials become files, why the rest failed, which deletions were
/// earned). The caller only runs ffmpeg in between.
extension DeviceTransferExecutor {
    /// The jobs for a converting run, each writing to its destination's
    /// hidden partial, by destination path.
    public struct PartialJobs: Sendable {
        /// What to hand ffmpeg, in plan order.
        public var jobs: [ConversionJob] = []
        /// Each planned copy's partial (a job's destination), by destination path.
        public var partials: [String: URL] = [:]
        /// Copies not run, with why, by destination path.
        public var heldBack: [String: String] = [:]
        /// The outermost folder a job's write creates (ffmpeg's runner makes
        /// it), by destination path; removed again when the job fails and
        /// the folder is still empty.
        public var newFolders: [String: URL] = [:]

        public init() {}
    }

    /// The conversion jobs for `plan`, checked against the device right
    /// before the batch: a copy whose destination exists and was not cleared
    /// for overwriting is held back with `appearedReason` before an encode is
    /// spent on it. A partial left over from an interrupted run is removed;
    /// no folder is created (the job makes its own when it runs). Partials
    /// keep the real extension, as ffmpeg picks its muxer from it.
    ///
    /// `slices`: Record Divider jobs by destination path; their copy runs
    /// that job's cut of the source instead of the whole file.
    public func partialJobs(
        for plan: DeviceTransferFilePlan,
        slices: [String: ConversionJob] = [:]
    ) -> PartialJobs {
        var result = PartialJobs()
        for copy in plan.copies {
            let path = copy.destinationURL.path
            if !copy.overwrites, fileManager.fileExists(atPath: path) {
                result.heldBack[path] = Self.appearedReason
                continue
            }
            let partial: URL
            do {
                partial = try clearPartial(for: copy.destinationURL, keepingExtension: true)
            } catch {
                result.heldBack[path] = error.localizedDescription
                continue
            }
            result.partials[path] = partial
            if let created = firstMissingFolder(for: copy.destinationURL) { result.newFolders[path] = created }
            let slice = slices[path]
            result.jobs.append(ConversionJob(
                sourceURL: slice?.sourceURL ?? copy.source.track.fileURL,
                destinationURL: partial,
                metadata: slice?.metadata ?? copy.source.metadata,
                startSeconds: slice?.startSeconds,
                endSeconds: slice?.endSeconds
            ))
        }
        return result
    }

    /// After the batch: each completed partial renamed onto its destination
    /// (`finish`), every other partial removed along with any folder its job
    /// created that is still empty, then the deletions the plan earned. An
    /// album's old files go only when every one of its copies landed, and
    /// none go after a cancel (`wasCancelled`, or `isCancelled` turning true
    /// while this runs). Completed files are kept either way.
    ///
    /// - `succeeded`: the job destinations (partial paths) that completed.
    /// - `reasons`: why the others failed, by partial path; a job with none
    ///   reads "Could not be converted".
    /// - `name`: what a detail line calls the copy.
    public func finishConverted(
        _ plan: DeviceTransferFilePlan,
        jobs: PartialJobs,
        succeeded: Set<String>,
        reasons: [String: String],
        wasCancelled: Bool,
        isCancelled: () -> Bool = { false },
        name: (DeviceTransferFilePlan.Copy) -> String = { $0.source.track.fileURL.lastPathComponent }
    ) -> Outcome {
        var outcome = Outcome()
        outcome.wasCancelled = wasCancelled
        for track in plan.unplanned {
            outcome.lines.append(
                "[FAILED] \(track.track.fileURL.lastPathComponent)\n    No place on the device could be planned for it"
            )
        }
        var emptied: [(folder: URL, top: URL)] = []
        for copy in plan.copies {
            let path = copy.destinationURL.path
            var reason = jobs.heldBack[path]
            if reason == nil, let partial = jobs.partials[path] {
                if succeeded.contains(partial.path) {
                    do {
                        try finish(partial, onto: copy.destinationURL, overwrites: copy.overwrites)
                    } catch {
                        reason = error.localizedDescription
                    }
                } else {
                    discardPartial(partial)
                    reason = reasons[partial.path] ?? "Could not be converted"
                }
                if reason != nil, let top = jobs.newFolders[path] {
                    emptied.append((copy.destinationURL.deletingLastPathComponent(), top))
                }
            } else if reason == nil {
                reason = "Could not be converted"
            }
            if let reason {
                outcome.failed.append(Failure(copy: copy, reason: reason))
                outcome.lines.append("[FAILED] \(name(copy))\n    \(reason)")
            } else {
                outcome.written.append(copy)
                outcome.lines.append("[ok] \(name(copy)) -> \(path)")
            }
        }
        // Once every rename is done: a folder holding a landed file stays.
        for (folder, top) in emptied { removeEmptyFolders(from: folder, upTo: top) }
        if isCancelled() { outcome.wasCancelled = true }
        runDeletions(plan, after: &outcome, isCancelled: isCancelled)
        return outcome
    }
}
