import Foundation

/// The converting side of a device run. ffmpeg runs a batch of jobs in
/// parallel (`ConversionService`), and never onto the device: every job
/// writes into a staging folder on the Mac, and the finished files go to the
/// device through the door afterwards. The executor decides around the batch:
/// `stagedJobs` before it (what is held back, where each job writes),
/// `finishConverted` after it (which staged files land, why the rest failed,
/// which deletions were earned). The caller runs ffmpeg in between, and owns
/// the staging folder: it makes it, and removes it however the run ends.
extension DeviceTransferExecutor {
    /// The reason a copy is held back when the Mac has no room to stage it.
    public static let stagingSpaceReason = "Not enough free space on this Mac to convert it"
    /// Room left on the Mac after the staged files.
    public static let stagingSpaceMargin: Int64 = 64 * 1024 * 1024

    /// A conversion's output size, guessed from its source: uncompressed PCM
    /// runs to about twice a lossless source, so 2.5 times; anything else the
    /// source plus 10%. Only ever used to refuse early.
    public static func estimatedConvertedBytes(sourceBytes: Int64, format: OutputFormat) -> Int64 {
        let factor = (format == .wav || format == .aiff) ? 2.5 : 1.10
        return Int64(Double(sourceBytes) * factor)
    }

    /// The jobs for a converting run, each writing into `stagingRoot` on the Mac.
    public struct StagedJobs: Sendable {
        /// What to hand ffmpeg, in plan order.
        public var jobs: [ConversionJob] = []
        /// Each planned copy's staged file (a job's destination), by destination path.
        public var staged: [String: URL] = [:]
        /// Copies not run, with why, by destination path.
        public var heldBack: [String: String] = [:]

        public init() {}
    }

    /// The conversion jobs for `plan`, checked right before the batch: a
    /// destination the write policy refuses, or one whose file exists and was
    /// not cleared for overwriting, is held back before an encode is spent on
    /// it; so is every copy past what the Mac has room to stage
    /// (`stagingBytesAvailable`, nil when unknown, against
    /// `estimatedBytes`). Each job writes to `stagingRoot/<n>/<name>`: one
    /// folder per copy, so two destinations sharing a name never meet, and
    /// the real extension last, as ffmpeg picks its muxer from it. Nothing is
    /// created on the device or on the Mac (a job makes its own folder).
    ///
    /// `slices`: Record Divider jobs by destination path; their copy runs
    /// that job's cut of the source instead of the whole file.
    public func stagedJobs(
        for plan: DeviceTransferFilePlan,
        stagingRoot: URL,
        slices: [String: ConversionJob] = [:],
        stagingBytesAvailable: Int64? = nil,
        estimatedBytes: (DeviceTransferFilePlan.Copy) -> Int64 = { _ in 0 }
    ) -> StagedJobs {
        var result = StagedJobs()
        var budget = stagingBytesAvailable.map { $0 - Self.stagingSpaceMargin }
        for (index, copy) in plan.copies.enumerated() {
            let path = copy.destinationURL.path
            do {
                try door.checkAudioDestination(copy.destinationURL)
            } catch {
                result.heldBack[path] = error.localizedDescription
                continue
            }
            if !copy.overwrites, exists(copy.destinationURL) {
                result.heldBack[path] = Self.appearedReason
                continue
            }
            if let left = budget {
                let need = estimatedBytes(copy)
                guard need <= left else {
                    result.heldBack[path] = Self.stagingSpaceReason
                    continue
                }
                budget = left - need
            }
            let stagedURL = stagingRoot
                .appendingPathComponent(String(index), isDirectory: true)
                .appendingPathComponent(copy.destinationURL.lastPathComponent)
            result.staged[path] = stagedURL
            let slice = slices[path]
            result.jobs.append(ConversionJob(
                sourceURL: slice?.sourceURL ?? copy.source.track.fileURL,
                destinationURL: stagedURL,
                metadata: slice?.metadata ?? copy.source.metadata,
                startSeconds: slice?.startSeconds,
                endSeconds: slice?.endSeconds
            ))
        }
        return result
    }

    /// After the batch: each completed staged file put on the device through
    /// the door, then the deletions the plan earned. An album's old files go
    /// only when every one of its copies landed, and none go after a cancel
    /// (`wasCancelled`, or `isCancelled` turning true while this runs). A
    /// cancel also stops the copies that have not started: what is on the
    /// device stays, what is only staged is dropped with the staging folder.
    ///
    /// - `succeeded`: the job destinations (staged paths) that completed.
    /// - `reasons`: why the others failed, by staged path; a job with none
    ///   reads "Could not be converted".
    /// - `name`: what a detail line calls the copy.
    public func finishConverted(
        _ plan: DeviceTransferFilePlan,
        jobs: StagedJobs,
        succeeded: Set<String>,
        reasons: [String: String],
        wasCancelled: Bool,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in },
        name: (DeviceTransferFilePlan.Copy) -> String = { $0.source.track.fileURL.lastPathComponent }
    ) -> Outcome {
        var outcome = Outcome()
        outcome.wasCancelled = wasCancelled
        Self.listUnplanned(plan, in: &outcome)
        let total = plan.copies.count
        for (index, copy) in plan.copies.enumerated() {
            let path = copy.destinationURL.path
            var reason = jobs.heldBack[path]
            if reason == nil, let stagedURL = jobs.staged[path] {
                if !succeeded.contains(stagedURL.path) {
                    reason = reasons[stagedURL.path] ?? "Could not be converted"
                } else if isCancelled() {
                    outcome.wasCancelled = true
                    reason = "Cancelled"
                } else {
                    do {
                        try write(copy, from: { _ in stagedURL })
                    } catch {
                        reason = error.localizedDescription
                    }
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
            onProgress(index + 1, total)
        }
        if isCancelled() { outcome.wasCancelled = true }
        runDeletions(plan, after: &outcome, isCancelled: isCancelled)
        return outcome
    }
}
