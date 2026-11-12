import Foundation

/// The offline queue's side of a device transfer. Queuing reviews the tracks
/// against the device's last-known catalog with the staging tree standing in
/// for the device, so the queue holds only what the device lacks, with each
/// differing album's answer; SYNC reviews the queue again against the device
/// itself. The review and the plan are `DeviceTransferResolver`'s; this maps
/// them onto the queue and its staging tree.
public enum DeviceSyncQueuePlanner {
    // MARK: - Queuing

    /// The device's saved catalog moved onto the staging tree: each track at
    /// the same path relative to `stagingRoot` as it had to `deviceRoot` (the
    /// device's root when the catalog was saved), so a review made against
    /// the staging tree plans the same relative paths it would on the device.
    /// Tracks outside `deviceRoot` are dropped. The root compares ignoring
    /// case, as the volume does.
    public static func catalog(
        _ catalog: [LoadedTrack],
        rebasedFrom deviceRoot: URL,
        onto stagingRoot: URL
    ) -> [LoadedTrack] {
        let root = deviceRoot.standardizedFileURL.pathComponents
        return catalog.compactMap { loaded in
            let components = loaded.track.fileURL.standardizedFileURL.pathComponents
            guard components.count > root.count,
                  zip(root, components).allSatisfy({ folded($0) == folded($1) })
            else { return nil }
            let rebased = components.dropFirst(root.count).reduce(stagingRoot) { $0.appendingPathComponent($1) }
            return LoadedTrack(
                track: loaded.track.withFileURL(rebased),
                metadata: loaded.metadata,
                recordMarkers: loaded.recordMarkers
            )
        }
    }

    /// The file manager a queue-time review and plan use
    /// (`DeviceTransferResolver(fileManager:)`): it sees no file under
    /// `stagingRoot`, so the review stands on the catalog alone. The staging
    /// tree holds only bakes of earlier entries; a name one of them uses is
    /// not a file on the device, so it must not come to the sheet as a taken
    /// path, nor be answered and stored for SYNC. `entries` steps a clash
    /// with a queued path past it, and SYNC asks about any real clash
    /// against the device. Paths elsewhere are seen as they are.
    public static func catalogOnlyFileManager(stagingRoot: URL) -> FileManager {
        StagingBlindFileManager(stagingRoot: stagingRoot)
    }

    /// The entries a plan made against the staging tree adds to the queue:
    /// one per copy, at its path relative to `stagingRoot`, unbaked. A copy
    /// written for an album the user answered (Replace, Keep both) carries
    /// that answer; New and Gaps tracks carry none. The plan's deletions are
    /// not queued: SYNC plans them again against the device itself.
    ///
    /// `kinds` are the review's differing albums' kinds
    /// (`DeviceTransferReview.differenceKinds`), stored beside each answer so
    /// SYNC reuses it only while the album still differs the same way.
    ///
    /// A copy whose source is already queued is skipped. One planned onto a
    /// path the queue already holds (another source file filed under the same
    /// name) gets the first free ` (n)` name, because the path is also where
    /// its bake is staged; SYNC plans the real device path afresh, and asks
    /// about the clash there.
    public static func entries(
        for plan: DeviceTransferFilePlan,
        stagingRoot: URL,
        decisions: [DeviceAlbumIdentity: DeviceAlbumDecision],
        kinds: [DeviceAlbumIdentity: DeviceDifferenceKind],
        queued: [DeviceSyncQueueEntry],
        queuedAt: Date = Date()
    ) -> [DeviceSyncQueueEntry] {
        var queuedSources = Set(queued.map { $0.track.track.fileURL.path })
        var taken = Set(queued.map { folded($0.destinationRelativePath) })
        let rootPrefix = stagingRoot.standardizedFileURL.path + "/"

        var entries: [DeviceSyncQueueEntry] = []
        for copy in plan.copies {
            guard queuedSources.insert(copy.source.track.fileURL.path).inserted else { continue }
            let path = copy.destinationURL.standardizedFileURL.path
            let relative = path.hasPrefix(rootPrefix)
                ? String(path.dropFirst(rootPrefix.count))
                : copy.destinationURL.lastPathComponent
            let free = firstFree(relative, taken: taken)
            taken.insert(folded(free))

            let answered: DeviceAlbumDecision?
            switch copy.kind {
            case .replacement, .keptBoth: answered = decisions[copy.album]
            case .new, .gap: answered = nil
            }
            entries.append(DeviceSyncQueueEntry(
                track: copy.source,
                destinationRelativePath: free,
                isStaged: false,
                // Stamped at bake time; until then it can't make a bake look stale.
                sourceModifiedAt: .distantPast,
                queuedAt: queuedAt,
                decision: answered,
                decisionKind: answered == nil ? nil : kinds[copy.album]
            ))
        }
        return entries
    }

    // MARK: - SYNC

    /// The answers queued entries carry, by album, to pass to the review at
    /// SYNC as already made. Albums are reconciled across the whole queue, as
    /// the review that SYNC runs on it does. An album whose entries carry
    /// different answers (queued twice, answered differently) has none, so it
    /// is asked about again; entries with no answer don't count against one.
    /// Each answer keeps the kind of difference it was given for.
    public static func storedDecisions(for entries: [DeviceSyncQueueEntry]) -> [DeviceAlbumIdentity: DeviceStoredDecision] {
        let identities = DeviceAlbumIdentity.identities(for: entries.map(\.track))
        var answers: [DeviceAlbumIdentity: Set<DeviceStoredDecision>] = [:]
        for entry in entries {
            guard let decision = entry.storedDecision else { continue }
            let identity = identities[entry.track.track.id]
                ?? DeviceAlbumIdentity(artist: entry.track.track.artist, album: entry.track.track.album)
            answers[identity, default: []].insert(decision)
        }
        return answers.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Where SYNC reads the bytes for one queued entry.
    public enum SyncSource: Equatable, Sendable {
        /// Copy the entry's bake from the staging tree.
        case staged
        /// Convert the source file on the way over.
        case convert
        /// Copy the source file as it is (copy-mode device).
        case copy
        /// Nothing usable to write, with why.
        case unavailable(String)
    }

    /// The bake is used while it is current: it exists, its source has not
    /// changed since it was made (a missing source leaves the bake standing),
    /// and it is in the format the destination is named for (settings changed
    /// since the bake would otherwise put one format under another's name).
    /// Otherwise the source is converted, or copied on a copy-mode device.
    ///
    /// `sourceModifiedAt` is the source file's modification date, nil when the
    /// source file is missing.
    public static func source(
        for entry: DeviceSyncQueueEntry,
        stagedURL: URL,
        destination: URL,
        converts: Bool,
        stagedFileExists: Bool,
        sourceModifiedAt: Date?
    ) -> SyncSource {
        if entry.isStaged, stagedFileExists,
           stagedURL.pathExtension.lowercased() == destination.pathExtension.lowercased() {
            let stale = converts && sourceModifiedAt.map { $0 != entry.sourceModifiedAt } == true
            if !stale { return .staged }
        }
        guard sourceModifiedAt != nil else {
            return .unavailable(entry.isStaged
                ? "Staged file missing or out of date, and the source file is gone. Remove it from the queue and add it again."
                : "Source file missing")
        }
        return converts ? .convert : .copy
    }

    // MARK: - Helpers

    /// `relative`, or the first ` (n)` name beside it the queue doesn't hold.
    private static func firstFree(_ relative: String, taken: Set<String>) -> String {
        guard taken.contains(folded(relative)) else { return relative }
        let path = relative as NSString
        let folder = path.deletingLastPathComponent
        let ext = path.pathExtension
        let base = (path.lastPathComponent as NSString).deletingPathExtension
        var attempt = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
            let candidate = folder.isEmpty ? name : "\(folder)/\(name)"
            if !taken.contains(folded(candidate)) { return candidate }
            attempt += 1
        }
    }

    /// A path as a case-insensitive volume compares it.
    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// `DeviceSyncQueuePlanner.catalogOnlyFileManager`: reports nothing at or
/// below the staging root, everything else as the default manager does.
private final class StagingBlindFileManager: FileManager, @unchecked Sendable {
    private let hiddenPrefix: String
    private let hiddenRoot: String

    init(stagingRoot: URL) {
        hiddenRoot = Self.folded(stagingRoot.standardizedFileURL.path)
        hiddenPrefix = hiddenRoot + "/"
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        hides(path) ? false : super.fileExists(atPath: path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        hides(path) ? false : super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    private func hides(_ path: String) -> Bool {
        let key = Self.folded(URL(fileURLWithPath: path).standardizedFileURL.path)
        return key == hiddenRoot || key.hasPrefix(hiddenPrefix)
    }

    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

// MARK: - Converting on the way

public extension DeviceSyncQueuePlanner {
    /// Where SYNC converts one copy on the way over: inside this run's
    /// staging folder on the Mac, one folder per copy, under the
    /// destination's own name. The extension is the destination's, never the
    /// queued bake's: ffmpeg picks its muxer from it, and the device's format
    /// may have changed since the entry was queued (an `.m4a` bake, an `.mp3`
    /// device now).
    static func conversionStagingURL(for copy: DeviceTransferFilePlan.Copy, index: Int, in root: URL) -> URL {
        root.appendingPathComponent(String(index), isDirectory: true)
            .appendingPathComponent(copy.destinationURL.lastPathComponent)
    }

    /// One conversion on the way over, judged by its own result:
    /// `ConversionService.runSingle` into `conversionStagingURL`. Returns
    /// that file; the caller copies it through the door and removes it
    /// however the entry ends. Throws ffmpeg's last log line on failure.
    static func convertOnTheWay(
        _ copy: DeviceTransferFilePlan.Copy,
        index: Int,
        source: URL,
        metadata: ConversionMetadata,
        stagingRoot: URL,
        service: ConversionService,
        preset: ConversionPreset
    ) throws -> URL {
        let output = conversionStagingURL(for: copy, index: index, in: stagingRoot)
        let result = service.runSingle(
            ConversionJob(sourceURL: source, destinationURL: output, metadata: metadata), preset: preset)
        guard result.status == .completed else {
            let detail = result.log.split(whereSeparator: \.isNewline).last.map(String.init)
            throw NSError(domain: "CrateDigger.DeviceSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: detail.map { "Conversion failed: \($0)" } ?? "Conversion failed",
            ])
        }
        return output
    }
}
