import Foundation

/// Runs a `DeviceTransferFilePlan` against the device: every copy first, then
/// the deletions of the albums whose copies all succeeded, so an interrupted
/// or failing transfer never leaves an album with neither its old files nor
/// its new ones.
///
/// It never touches the device itself. Every byte goes through a
/// `DeviceTransferDoor`, which checks the volume and the write policy, writes
/// through a flushed `.cdtmp` beside the destination renamed onto it (so
/// nothing is ever half-written under a final name), copies data only (so
/// macOS leaves no `._` twin on FAT), records the write in the device's
/// journal, and removes again a folder a failed write created and left empty.
///
/// The catalog the plan came from can be stale (another program changed the
/// device), so the destination is checked again before anything is spent on
/// a copy, and the door's rename refuses a file that appeared at a
/// destination the plan did not clear for overwriting: that one item fails
/// and the file is left alone. An old file already gone when its deletion
/// comes is not a failure. Where a copy's bytes come from is the caller's: a
/// file in the library, a staged bake, or a conversion run into a staging
/// folder on the Mac (`stagedJobs` and `finishConverted` for a batch). ffmpeg
/// never writes onto the device.
///
/// Synchronous on purpose: callers run it off the main actor.
public struct DeviceTransferExecutor {
    /// The failure reason when a file appeared at a destination after the review.
    public static let appearedReason = DeviceTransferDoor.appearedReason
    /// The detail line for an album whose old files a cancel kept.
    public static let cancelledDeletionReason = "Old files kept: cancelled"

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
        /// Albums whose copies all landed but whose old files a cancel kept.
        public var deletionsSkipped: [DeviceAlbumIdentity] = []
        /// One detail line per item, for the summary's details.
        public var lines: [String] = []
        public var wasCancelled = false

        public init() {}

        /// Paths no longer on the device: the catalog drops them.
        public var removedPaths: Set<String> {
            Set((deleted + alreadyGone).map(\.path))
        }
    }

    public let door: DeviceTransferDoor
    let fileManager: FileManager

    public init(door: DeviceTransferDoor, fileManager: FileManager = .default) {
        self.door = door
        self.fileManager = fileManager
    }

    // MARK: - Running a plan

    /// Copies, then deletions. `source` returns the file on the Mac whose
    /// bytes go to the copy's destination; it may make that file first (a
    /// conversion into staging), and is only called once the destination is
    /// known to be free. `onProgress` gets (copies done, copies in the plan).
    /// A cancel stops the remaining copies and every deletion.
    public func run(
        _ plan: DeviceTransferFilePlan,
        source: (DeviceTransferFilePlan.Copy) throws -> URL,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = runCopies(plan, source: source, isCancelled: isCancelled, onProgress: onProgress)
        runDeletions(plan, after: &outcome, isCancelled: isCancelled)
        return outcome
    }

    /// The copy half. A caller that writes its copies its own way records
    /// them in an `Outcome` itself, then calls `runDeletions`.
    public func runCopies(
        _ plan: DeviceTransferFilePlan,
        source: (DeviceTransferFilePlan.Copy) throws -> URL,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = Outcome()
        Self.listUnplanned(plan, in: &outcome)

        let total = plan.copies.count
        for (index, item) in plan.copies.enumerated() {
            let name = item.source.track.fileURL.lastPathComponent
            if isCancelled() {
                outcome.wasCancelled = true
                outcome.failed.append(Failure(copy: item, reason: "Cancelled"))
                outcome.lines.append("[FAILED] \(name)\n    Cancelled")
            } else {
                do {
                    try write(item, from: source)
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
        // A cancel that landed during the last copy still counts.
        if isCancelled() { outcome.wasCancelled = true }
        return outcome
    }

    /// The deletion half: the plan's deletions minus those of any album with
    /// a failed copy in `outcome`. After a cancel (in `outcome`, or one that
    /// lands between albums here) no more old files are removed; each album
    /// whose old files stay gets a line saying so. Each deletion goes through
    /// the door as a `.userReplace`: the audio policy, then `unlink`.
    public func runDeletions(
        _ plan: DeviceTransferFilePlan,
        after outcome: inout Outcome,
        isCancelled: () -> Bool = { false }
    ) {
        let allowed = Set(plan.deletions(afterFailing: outcome.failed.map(\.copy)).map(\.path))
        for album in Self.albumOrder(of: plan) {
            let urls = (plan.deletionsByAlbum[album] ?? []).filter { allowed.contains($0.path) }
            guard !urls.isEmpty else { continue }
            if outcome.wasCancelled || isCancelled() {
                outcome.wasCancelled = true
                outcome.deletionsSkipped.append(album)
                let folder = urls[0].deletingLastPathComponent().path
                outcome.lines.append(
                    "[kept] \(folder)\n    \(Self.cancelledDeletionReason) (\(urls.count) \(urls.count == 1 ? "file" : "files"))"
                )
                continue
            }
            for url in urls {
                do {
                    if try door.removeReplacedAudio(at: url) {
                        outcome.deleted.append(url)
                        outcome.lines.append("[removed] \(url.path)")
                    } else {
                        // Removed behind the app's back: the album is still replaced.
                        outcome.alreadyGone.append(url)
                        outcome.lines.append("[gone] \(url.path)\n    Already removed from the device")
                    }
                } catch {
                    let reason = error.localizedDescription
                    outcome.failedDeletions.append(DeletionFailure(url: url, reason: reason))
                    outcome.lines.append("[FAILED] could not remove \(url.path)\n    \(reason)")
                }
            }
        }
    }

    // MARK: - One write

    /// One copy: refuse a destination that appeared since the review before
    /// spending anything on it, get the bytes from `source`, then hand them
    /// to the door, which writes them through a temp renamed into place and
    /// refuses the rename if a file appeared meanwhile. A write that fails
    /// leaves no temp and no folder it created.
    public func write(
        _ item: DeviceTransferFilePlan.Copy,
        from source: (DeviceTransferFilePlan.Copy) throws -> URL
    ) throws {
        try door.checkAudioDestination(item.destinationURL)
        if !item.overwrites, exists(item.destinationURL) {
            throw DeviceTransferDoorError.appeared
        }
        let file = try source(item)
        try door.copyAudio(from: file, to: item.destinationURL, overwrites: item.overwrites)
    }

    // MARK: - Helpers

    /// `lstat`, so a dangling symlink at the name still counts as taken.
    func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    static func listUnplanned(_ plan: DeviceTransferFilePlan, in outcome: inout Outcome) {
        for track in plan.unplanned {
            outcome.lines.append(
                "[FAILED] \(track.track.fileURL.lastPathComponent)\n    No place on the device could be planned for it"
            )
        }
    }

    /// Albums in the order their deletions run (`DeviceTransferFilePlan.deletions`).
    private static func albumOrder(of plan: DeviceTransferFilePlan) -> [DeviceAlbumIdentity] {
        var seen: Set<DeviceAlbumIdentity> = []
        var order: [DeviceAlbumIdentity] = []
        for url in plan.deletions {
            guard let album = plan.deletionsByAlbum.first(where: { $0.value.contains(url) })?.key,
                  seen.insert(album).inserted else { continue }
            order.append(album)
        }
        return order
    }
}
