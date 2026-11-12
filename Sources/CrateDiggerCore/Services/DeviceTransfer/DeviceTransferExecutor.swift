import Darwin
import Foundation

/// Runs a `DeviceTransferFilePlan` against the device: every copy first, then
/// the deletions of the albums whose copies all succeeded, so an interrupted
/// or failing transfer never leaves an album with neither its old files nor
/// its new ones.
///
/// Nothing is ever half-written under a final name. Each write goes to a
/// hidden partial file beside its destination and is renamed onto it
/// (`rename(2)`, which replaces a file being overwritten in one step) only
/// once it is complete; a write that fails leaves the destination as it was,
/// old file included. A partial left behind by a crash is removed before the
/// same name is written again.
///
/// The catalog the plan came from can be stale (another program changed the
/// device), so the file system is checked again right before each rename: a
/// file found at a destination the plan did not clear for overwriting fails
/// that one item and is left alone. An old file already gone when its
/// deletion comes is not a failure. How a file is written is the caller's: a
/// byte copy here, an ffmpeg run for a converting path (which uses
/// `preparePartial` and `finish` directly).
///
/// Synchronous on purpose: callers run it off the main actor.
public struct DeviceTransferExecutor {
    /// The failure reason when a file appeared at a destination after the review.
    public static let appearedReason = "A file appeared at this name"
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

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Partial files

    /// The hidden file a write to `destination` goes to before it is renamed
    /// into place. The leading dot keeps it out of the library scanner (which
    /// skips hidden files) and Rockbox's file browser (which hides dot files).
    /// A copy also gets a non-audio extension (`.01 So What.flac.cdpart`), so
    /// nothing that lists audio by extension picks it up. A conversion keeps
    /// the real extension last (`.cdpart.01 So What.mp3`), because ffmpeg
    /// picks its muxer from it.
    public static func partialURL(for destination: URL, keepingExtension: Bool) -> URL {
        let folder = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        return folder.appendingPathComponent(keepingExtension ? ".cdpart.\(name)" : ".\(name).cdpart")
    }

    /// Readies `destination`'s folder and partial file: the folder is created
    /// when missing, and a partial left over from an interrupted run is
    /// removed. Returns where to write.
    public func preparePartial(for destination: URL, keepingExtension: Bool) throws -> URL {
        let folder = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let partial = Self.partialURL(for: destination, keepingExtension: keepingExtension)
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        return partial
    }

    /// Moves a complete partial onto its destination. Unless `overwrites`,
    /// a file found at the destination now fails this item (the partial is
    /// removed, the file left alone); otherwise `rename(2)` replaces it in
    /// one step. A failed rename removes the partial too.
    public func finish(_ partial: URL, onto destination: URL, overwrites: Bool) throws {
        if !overwrites, fileManager.fileExists(atPath: destination.path) {
            discardPartial(partial)
            throw Self.error(Self.appearedReason)
        }
        guard Darwin.rename(partial.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            discardPartial(partial)
            throw Self.error("Could not move the finished file into place: \(reason)")
        }
    }

    /// Removes a partial a write abandoned. Missing is fine.
    public func discardPartial(_ partial: URL) {
        if fileManager.fileExists(atPath: partial.path) {
            try? fileManager.removeItem(at: partial)
        }
    }

    // MARK: - Running a plan

    /// Copies, then deletions. `copy` writes `copy.source` to the URL it is
    /// given: the destination's partial file, in a folder that exists. The
    /// executor renames it into place. `onProgress` gets (copies done,
    /// copies in the plan). A cancel stops the remaining copies and every
    /// deletion.
    public func run(
        _ plan: DeviceTransferFilePlan,
        copy: (DeviceTransferFilePlan.Copy, URL) throws -> Void,
        isCancelled: () -> Bool = { false },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = runCopies(plan, copy: copy, isCancelled: isCancelled, onProgress: onProgress)
        runDeletions(plan, after: &outcome, isCancelled: isCancelled)
        return outcome
    }

    /// The copy half. A converting caller writes its copies its own way and
    /// records them in an `Outcome` itself, then calls `runDeletions`.
    public func runCopies(
        _ plan: DeviceTransferFilePlan,
        copy: (DeviceTransferFilePlan.Copy, URL) throws -> Void,
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
                    try write(item, with: copy)
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
    /// whose old files stay gets a line saying so.
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
    }

    // MARK: - Helpers

    /// One copy: refuse a destination that appeared since the review before
    /// spending a write on it, write the partial, rename it into place.
    private func write(
        _ item: DeviceTransferFilePlan.Copy,
        with copy: (DeviceTransferFilePlan.Copy, URL) throws -> Void
    ) throws {
        if !item.overwrites, fileManager.fileExists(atPath: item.destinationURL.path) {
            throw Self.error(Self.appearedReason)
        }
        let partial = try preparePartial(for: item.destinationURL, keepingExtension: false)
        do {
            try copy(item, partial)
        } catch {
            discardPartial(partial)
            throw error
        }
        try finish(partial, onto: item.destinationURL, overwrites: item.overwrites)
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

    private static func error(_ reason: String) -> NSError {
        NSError(domain: "CrateDigger.DeviceTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
