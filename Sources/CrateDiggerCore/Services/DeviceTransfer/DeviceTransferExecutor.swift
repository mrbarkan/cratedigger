import Foundation

/// Runs a `DeviceTransferFilePlan` against the device: every copy first, then
/// the deletions of the albums whose copies all succeeded, so an interrupted
/// or failing transfer never leaves an album with neither its old files nor
/// its new ones.
///
/// The catalog the plan came from can be stale (another program changed the
/// device), so the file system is checked right before every write: a file
/// found at a destination the plan did not clear for overwriting fails that
/// one item, and an old file already gone when its deletion comes is not a
/// failure. How a file is written is the caller's: a byte copy here, an
/// ffmpeg run for a converting path.
///
/// Synchronous on purpose: callers run it off the main actor.
public struct DeviceTransferExecutor {
    /// The failure reason when a file appeared at a destination after the review.
    public static let appearedReason = "A file appeared at this name"

    public struct Failure: Hashable, Sendable {
        public let copy: DeviceTransferFilePlan.Copy
        public let reason: String

        public init(copy: DeviceTransferFilePlan.Copy, reason: String) {
            self.copy = copy
            self.reason = reason
        }
    }

    public struct DeletionFailure: Hashable, Sendable {
        public let url: URL
        public let reason: String

        public init(url: URL, reason: String) {
            self.url = url
            self.reason = reason
        }
    }

    /// What a run did, in plan order.
    public struct Outcome: Sendable {
        public var written: [DeviceTransferFilePlan.Copy] = []
        public var failed: [Failure] = []
        public var deleted: [URL] = []
        /// Old files that were already gone when their deletion came.
        public var alreadyGone: [URL] = []
        public var failedDeletions: [DeletionFailure] = []
        /// One detail line per item, for the summary's details.
        public var lines: [String] = []
        public var wasCancelled = false

        public init() {}

        /// Paths no longer on the device: the catalog drops them.
        public var removedPaths: Set<String> {
            Set((deleted + alreadyGone).map(\.path))
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies, then deletions. `copy` writes `copy.source` to
    /// `copy.destinationURL`; its folder exists and the destination is free
    /// when it is called. `onProgress` gets (copies done, copies in the plan).
    public func run(
        _ plan: DeviceTransferFilePlan,
        copy: (DeviceTransferFilePlan.Copy) throws -> Void,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = runCopies(plan, copy: copy, isCancelled: isCancelled, onProgress: onProgress)
        runDeletions(plan, after: &outcome)
        return outcome
    }

    /// The copy half, for a caller that writes the copies its own way (a
    /// batch of conversion jobs) and records them in an `Outcome` itself.
    public func runCopies(
        _ plan: DeviceTransferFilePlan,
        copy: (DeviceTransferFilePlan.Copy) throws -> Void,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = Outcome()
        for track in plan.unplanned {
            outcome.lines.append(
                "[FAILED] \(track.track.fileURL.lastPathComponent)\n    No place on the device could be planned for it"
            )
        }

        let total = plan.copies.count
        for (index, item) in plan.copies.enumerated() {
            let name = item.source.track.fileURL.lastPathComponent
            if isCancelled() {
                outcome.wasCancelled = true
                outcome.failed.append(Failure(copy: item, reason: "Cancelled"))
                outcome.lines.append("[FAILED] \(name)\n    Cancelled")
            } else {
                do {
                    try prepareDestination(of: item)
                    try copy(item)
                    outcome.written.append(item)
                    outcome.lines.append("[ok] \(name) -> \(item.destinationURL.path)")
                } catch {
                    let reason = error.localizedDescription
                    outcome.failed.append(Failure(copy: item, reason: reason))
                    outcome.lines.append("[FAILED] \(name)\n    \(reason)")
                }
            }
            onProgress(index + 1, total)
        }
        return outcome
    }

    /// The deletion half: the plan's deletions minus those of any album with
    /// a failed copy in `outcome`.
    public func runDeletions(_ plan: DeviceTransferFilePlan, after outcome: inout Outcome) {
        for url in plan.deletions(afterFailing: outcome.failed.map(\.copy)) {
            guard fileManager.fileExists(atPath: url.path) else {
                // Removed behind the app's back: the album is still replaced.
                outcome.alreadyGone.append(url)
                outcome.lines.append("[gone] \(url.path)\n    Already removed from the device")
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                outcome.deleted.append(url)
                outcome.lines.append("[removed] \(url.path)")
            } catch {
                let reason = error.localizedDescription
                outcome.failedDeletions.append(DeletionFailure(url: url, reason: reason))
                outcome.lines.append("[FAILED] could not remove \(url.path)\n    \(reason)")
            }
        }
    }

    /// The folder exists, and the destination is free: removed when the plan
    /// overwrites it, a failure when a file appeared there since the review.
    private func prepareDestination(of item: DeviceTransferFilePlan.Copy) throws {
        let destination = item.destinationURL
        let folder = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        guard item.overwrites else {
            throw NSError(
                domain: "CrateDigger.DeviceTransfer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: Self.appearedReason]
            )
        }
        try fileManager.removeItem(at: destination)
    }
}
