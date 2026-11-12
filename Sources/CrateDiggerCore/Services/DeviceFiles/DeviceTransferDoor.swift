import Foundation

/// Why the door would not write, or what went wrong when it did.
public enum DeviceTransferDoorError: Error, Equatable, LocalizedError {
    /// The path is not on the device this session writes to.
    case outsideVolume(String)
    /// The write policy refuses the path; the policy's own reason.
    case forbidden(String)
    /// A file nothing cleared for overwriting is at the name.
    case appeared
    /// The device at the root is not the one the session started on.
    case wrongVolume
    case noSpace
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideVolume(let path): return "CrateDigger does not write there: \(path) is not on the device"
        case .forbidden(let reason): return "CrateDigger does not write there: \(reason)"
        case .appeared: return DeviceTransferDoor.appearedReason
        case .wrongVolume: return "The device is not the one this transfer started on, so nothing was written"
        case .noSpace: return "Not enough space on the device"
        case .failed(let reason): return reason
        }
    }
}

/// The three things a transfer does to a device, policy first: copy audio,
/// delete what the user chose to Replace, write an album's cover. Every one
/// goes through one `DeviceFileExecutor` (the guarded door, spec invariant
/// I1), so it is checked against the volume, the write policy and the
/// journal, lands through a flushed temp and a rename, and carries no
/// extended attributes, which is what stops macOS leaving a `._` twin beside
/// it on FAT. Nothing here writes a byte itself.
///
/// One door is one session: one session ID in the journal for everything it
/// does. Synchronous; callers run it off the main actor.
public struct DeviceTransferDoor: @unchecked Sendable {
    // @unchecked: the executor is immutable after init, its closures are pure
    // system reads, and the journal serialises itself with a lock.

    /// The failure reason when a file appeared at a destination after the review.
    public static let appearedReason = "A file appeared at this name"

    public let volumeRoot: URL
    public let policy: DeviceWritePolicy
    public let sessionID: UUID
    private let executor: DeviceFileExecutor

    public init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
                journal: DeviceWriteJournal, sessionID: UUID = UUID(), fileManager: FileManager = .default) {
        self.init(executor: DeviceFileExecutor(volumeRoot: volumeRoot, expectedVolumeUUID: expectedVolumeUUID,
                                               policy: policy, journal: journal, fileManager: fileManager),
                  sessionID: sessionID)
    }

    /// Tests: a temp folder stands in for the device (see `DeviceFileExecutor`).
    init(executor: DeviceFileExecutor, sessionID: UUID = UUID()) {
        self.executor = executor
        volumeRoot = executor.volumeRoot
        policy = executor.policy
        self.sessionID = sessionID
    }

    public var journal: DeviceWriteJournal { executor.journal }

    // MARK: - Checks

    /// `url` relative to the volume root, symlinks resolved; nil off the volume.
    public func relativePath(of url: URL) -> String? {
        guard let relative = DeviceWritePolicy.relativePath(of: url, under: volumeRoot), !relative.isEmpty
        else { return nil }
        return relative
    }

    /// Throws `.outsideVolume` or `.forbidden` when an audio file may not be
    /// written at `destination`. Reads nothing but the path.
    public func checkAudioDestination(_ destination: URL) throws {
        _ = try audioPath(destination)
    }

    /// Every planned output of a converting run, before it starts. Throws on
    /// the first that may not be written.
    public func checkConversionDestinations(_ destinations: [URL]) throws {
        for destination in destinations { try checkAudioDestination(destination) }
    }

    /// Throws `.outsideVolume` or `.forbidden` when the audio file at `url`
    /// may not be deleted as a Replace. Reads nothing but the path.
    public func checkReplacedAudioRemoval(_ url: URL) throws {
        guard let path = relativePath(of: url) else { throw DeviceTransferDoorError.outsideVolume(url.path) }
        do {
            try policy.checkDelete(path, reason: .userReplace)
        } catch DeviceWritePolicyError.forbidden(let reason) {
            throw DeviceTransferDoorError.forbidden(reason)
        }
    }

    /// What to tell the user about a path the policy refuses: for a name
    /// ending in a dot or a space (one an older version could write, such as
    /// "R.E.M."), which one to rename; otherwise the policy's own reason.
    public func refusalMessage(for url: URL, error: Error) -> String {
        let components = relativePath(of: url)?.split(separator: "/").map(String.init) ?? []
        if let name = components.first(where: { $0.hasSuffix(".") || $0.hasSuffix(" ") }) {
            let ending = name.hasSuffix(".") ? "a dot" : "a space"
            return "Rename \"\(name)\" on the device so it does not end in \(ending), then send again"
        }
        return error.localizedDescription
    }

    // MARK: - Writes

    /// Copies the bytes of `source` (a file on the Mac) to `destination` on
    /// the device. A file already at `destination` is replaced only when
    /// `overwrites` (the user chose Replace in the review); otherwise it is
    /// `.appeared` and left alone, unless it already holds these very bytes,
    /// which is the copy already done.
    public func copyAudio(from source: URL, to destination: URL, overwrites: Bool = false) throws {
        let path = try audioPath(destination)
        let op: DeviceFileOperation = overwrites
            ? .replaceAudio(relativePath: path, contents: .file(source))
            : .write(relativePath: path, role: .audio, contents: .file(source))
        switch apply(op) {
        case .written, .unchanged: return
        case .refusedForeign: throw DeviceTransferDoorError.appeared
        case let outcome: throw Self.error(for: outcome)
        }
    }

    /// Deletes an audio file the user chose to Replace. Returns false when it
    /// was already gone.
    @discardableResult
    public func removeReplacedAudio(at url: URL) throws -> Bool {
        guard let path = relativePath(of: url) else { throw DeviceTransferDoorError.outsideVolume(url.path) }
        do {
            try policy.checkDelete(path, reason: .userReplace)
        } catch DeviceWritePolicyError.forbidden(let reason) {
            throw DeviceTransferDoorError.forbidden(reason)
        }
        switch apply(.delete(relativePath: path, reason: .userReplace)) {
        case .deleted: return true
        case .alreadyGone: return false
        case .refusedForeign: throw DeviceTransferDoorError.failed("Not a file, so it was left alone")
        case let outcome: throw Self.error(for: outcome)
        }
    }

    /// Writes `data` as the cover at `destination`, replacing a cover already
    /// there (spec D19; the replaced one is kept on the Mac). Whether a folder
    /// may get a cover at all (a Gaps fill keeps the one it found) is decided
    /// before this. Returns false when the bytes there are already these.
    public func writeCover(_ data: Data, to destination: URL) throws -> Bool {
        guard let path = relativePath(of: destination) else {
            throw DeviceTransferDoorError.outsideVolume(destination.path)
        }
        do {
            try policy.checkWrite(path, role: .cover)
        } catch DeviceWritePolicyError.forbidden(let reason) {
            throw DeviceTransferDoorError.forbidden(reason)
        }
        switch apply(.write(relativePath: path, role: .cover, contents: .data(data), replacesForeign: true)) {
        case .written: return true
        case .unchanged: return false
        case let outcome: throw Self.error(for: outcome)
        }
    }

    // MARK: - Private

    private func audioPath(_ destination: URL) throws -> String {
        guard let path = relativePath(of: destination) else {
            throw DeviceTransferDoorError.outsideVolume(destination.path)
        }
        do {
            try policy.checkWrite(path, role: .audio)
        } catch DeviceWritePolicyError.forbidden(let reason) {
            throw DeviceTransferDoorError.forbidden(reason)
        }
        return path
    }

    private func apply(_ op: DeviceFileOperation) -> DeviceFileOutcome {
        executor.apply([op], sessionID: sessionID).first ?? .failed("Nothing was done")
    }

    private static func error(for outcome: DeviceFileOutcome) -> DeviceTransferDoorError {
        switch outcome {
        case .refusedPolicy(let reason): return .forbidden(reason)
        case .refusedWrongVolume: return .wrongVolume
        case .refusedNoSpace: return .noSpace
        case .refusedForeign: return .appeared
        case .refusedNotAppleDouble: return .failed("Not a file CrateDigger may remove")
        case .failed(let reason): return .failed(reason)
        case .written, .unchanged, .deleted, .alreadyGone: return .failed("Unexpected outcome")
        }
    }
}
