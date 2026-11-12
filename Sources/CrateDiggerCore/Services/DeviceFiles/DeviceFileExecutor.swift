import CryptoKit
import Darwin
import Foundation

/// What a write puts on the device: bytes in memory or a file on the Mac.
public enum DeviceFileContents: Sendable {
    case data(Data)
    case file(URL)
}

/// One planned change to one file on a device, by path relative to the volume root.
public enum DeviceFileOperation: Sendable {
    /// `replacesForeign` is honoured for `.cover` only (spec D19): the
    /// transfer that wrote a folder's tracks owns its cover. The replaced file
    /// is still backed up first.
    /// `subject` names who the file is for (an artist picture's player key),
    /// kept in the journal record so a later plan can tell whose it is.
    case write(relativePath: String, role: DeviceFileRole, contents: DeviceFileContents, replacesForeign: Bool = false,
               subject: String? = nil)
    case delete(relativePath: String, reason: DeviceDeleteReason)

    var relativePath: String {
        switch self {
        case .write(let path, _, _, _, _), .delete(let path, _): return path
        }
    }
}

public enum DeviceFileOutcome: Equatable, Sendable {
    case written, unchanged, refusedForeign, refusedPolicy(String), refusedWrongVolume, refusedNoSpace,
         deleted, alreadyGone, refusedNotAppleDouble, failed(String)
}

/// The one door PodBox writers go through (spec invariant I1): every
/// operation is checked against the volume, the policy and the journal, and
/// only then handed to `DeviceFileIO`.
///
/// The volume (I7): at init the executor captures the root's identity (device
/// and inode from `stat`) and its volume UUID. Before the plan and before each
/// operation the root must still be that same mount point, a mount point at
/// all, and report the expected UUID when one was given. "Whatever is at that
/// path now" is never enough. Journal records from another volume UUID are
/// not ours here.
///
/// For a write: (1) the volume, (2) the policy, for the file and for its
/// `.cdtmp`, both as given and after resolving symlinks (I2), (3) an existing
/// file with identical bytes is left alone (I5), (4) there is room for it plus
/// `freeSpaceMargin`, (5) a file the journal proves ours is backed up and
/// replaced, anything else is foreign and refused (I3), (6) the bytes land
/// through a flushed temp and a rename, attributes stripped (I8), (7) the
/// journal records it. A delete needs the journal's proof for
/// `ownedByCrateDigger` and backs the file up first. An AppleDouble twin is
/// proven and read through one descriptor, backed up from those bytes, and
/// deleted only if the path still holds that very file, checked again
/// immediately before the `unlink` (I4).
public struct DeviceFileExecutor {
    /// Room left on the device after any write.
    public static let freeSpaceMargin: Int64 = 8 * 1024 * 1024

    public let volumeRoot: URL
    public let expectedVolumeUUID: String?
    public let policy: DeviceWritePolicy
    public let journal: DeviceWriteJournal
    private let fileManager: FileManager
    private let volumeUUID: (URL) -> String?
    private let freeSpace: (URL) -> Int64?
    private let rootMustBeMountPoint: Bool
    /// The root as it was when the session was planned.
    private let capturedIdentity: VolumeIdentity?
    /// The UUID journal records are matched and written against: the expected
    /// one, else what the volume reported at init.
    private let sessionVolumeUUID: String?
    /// Tests only: runs between an AppleDouble twin's backup and its removal,
    /// so a test can swap the file in that gap.
    private let beforeAppleDoubleRemoval: ((URL) -> Void)?

    public init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
                journal: DeviceWriteJournal, fileManager: FileManager = .default,
                volumeUUID: @escaping (URL) -> String? = DeviceFileExecutor.systemVolumeUUID,
                freeSpace: @escaping (URL) -> Int64? = DeviceFileExecutor.systemFreeSpace) {
        self.init(volumeRoot: volumeRoot, expectedVolumeUUID: expectedVolumeUUID, policy: policy,
                  journal: journal, fileManager: fileManager, volumeUUID: volumeUUID, freeSpace: freeSpace,
                  rootMustBeMountPoint: true)
    }

    /// Tests only: `rootMustBeMountPoint: false` lets a temp folder stand in
    /// for a device. Every other volume check still applies.
    init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
         journal: DeviceWriteJournal, fileManager: FileManager = .default,
         volumeUUID: @escaping (URL) -> String? = DeviceFileExecutor.systemVolumeUUID,
         freeSpace: @escaping (URL) -> Int64? = DeviceFileExecutor.systemFreeSpace,
         rootMustBeMountPoint: Bool, beforeAppleDoubleRemoval: ((URL) -> Void)? = nil) {
        self.volumeRoot = volumeRoot
        self.expectedVolumeUUID = expectedVolumeUUID
        self.policy = policy
        self.journal = journal
        self.fileManager = fileManager
        self.volumeUUID = volumeUUID
        self.freeSpace = freeSpace
        self.rootMustBeMountPoint = rootMustBeMountPoint
        self.beforeAppleDoubleRemoval = beforeAppleDoubleRemoval
        capturedIdentity = VolumeIdentity(of: volumeRoot)
        sessionVolumeUUID = expectedVolumeUUID ?? (capturedIdentity == nil ? nil : volumeUUID(volumeRoot))
    }

    public static func systemVolumeUUID(_ root: URL) -> String? {
        try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    public static func systemFreeSpace(_ root: URL) -> Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// True when `root` is where a file system is mounted (its real path is
    /// the mount point `statfs` reports), not a folder on some other disk.
    public static func isMountPoint(_ root: URL) -> Bool {
        guard let real = realpath(root.path, nil) else { return false }
        let path = String(cString: real)
        free(real)
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: info.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return mountedOn == path
    }

    /// Applies `ops` in order. The outcomes are index-aligned with `ops`.
    /// `progress` gets (operations done, total) after each one.
    public func apply(_ ops: [DeviceFileOperation], sessionID: UUID,
                      progress: (Int, Int) -> Void = { _, _ in }) -> [DeviceFileOutcome] {
        guard isExpectedVolume() else {
            return ops.map { _ in .refusedWrongVolume }
        }

        // Temp paths a crashed earlier session on this volume may have left;
        // only these are ever cleaned up as stale.
        let earlierIntents = Set(journal.records
            .filter { $0.kind == .tempIntent && DeviceWriteJournal.sameVolume($0.volumeUUID, sessionVolumeUUID) }
            .map(\.relativeKey))
        recordTempIntents(for: ops, sessionID: sessionID)

        var outcomes: [DeviceFileOutcome] = []
        outcomes.reserveCapacity(ops.count)
        for (index, op) in ops.enumerated() {
            let outcome: DeviceFileOutcome
            if !isExpectedVolume() {
                outcome = .refusedWrongVolume
            } else {
                switch op {
                case let .write(path, role, contents, replacesForeign, subject):
                    outcome = write(path, role: role, contents: contents, replacesForeign: replacesForeign,
                                    subject: subject, sessionID: sessionID, earlierIntents: earlierIntents)
                case let .delete(path, reason):
                    outcome = delete(path, reason: reason, sessionID: sessionID, earlierIntents: earlierIntents)
                }
            }
            outcomes.append(outcome)
            progress(index + 1, ops.count)
        }
        return outcomes
    }

    // MARK: - Write

    private func write(_ path: String, role: DeviceFileRole, contents: DeviceFileContents, replacesForeign: Bool,
                       subject: String?,
                       sessionID: UUID, earlierIntents: Set<String>) -> DeviceFileOutcome {
        // (2) The file and the temp it lands through, as given and as resolved.
        let tempPath = path + DeviceFileIO.tempSuffix
        let target: URL
        switch resolve(path, check: { resolved in
            try policy.checkWrite(resolved, role: role)
            try policy.checkWrite(resolved + DeviceFileIO.tempSuffix, role: .temp)
        }) {
        case .success(let url): target = url
        case .failure(let refusal): return refusal.outcome
        }

        let incomingSize: Int64
        switch contents {
        case .data(let data): incomingSize = Int64(data.count)
        case .file(let source):
            guard let size = regularFileSize(source) else {
                return .failed("The file to copy is missing: \(source.lastPathComponent)")
            }
            incomingSize = size
        }

        // (3) Identical bytes need nothing, not even room. Hashed only when the sizes agree.
        let existing = fileState(target)
        if case .regular(let size) = existing, size == incomingSize {
            do {
                if try DeviceFileIO.sha256(of: target) == hash(of: contents) { return .unchanged }
            } catch {
                return .failed("Could not read \(target.lastPathComponent): \(describe(error))")
            }
        }

        // (4) Room.
        if let available = freeSpace(volumeRoot), available < incomingSize + Self.freeSpaceMargin {
            return .refusedNoSpace
        }

        // A leftover temp is ours to clear only when an earlier session on this
        // volume said it would make one. Decided before anything is touched.
        let temp = DeviceFileIO.tempURL(for: target)
        var staleTemp = false
        switch fileState(temp) {
        case .missing:
            break
        case .other:
            return .refusedForeign
        case .regular:
            guard earlierIntents.contains(DeviceWritePolicy.key(forRelativePath: tempPath)),
                  (try? policy.checkDelete(tempPath, reason: .staleTemp)) != nil
            else { return .refusedForeign }
            staleTemp = true
        }

        // (5) What is there already.
        var kind = DeviceFileRecord.Kind.created
        var backupFile: String?
        switch existing {
        case .missing:
            break
        case .other:
            return .refusedForeign
        case .regular(let size):
            do {
                let owned = try isOwned(path, at: target, size: size)
                guard owned || (replacesForeign && role == .cover) else { return .refusedForeign }
                backupFile = try journal.backUp(fileAt: target, relativePath: path, sessionID: sessionID)
                kind = .replaced
            } catch {
                return .failed("Could not read \(target.lastPathComponent) or keep a copy of it before replacing it: \(describe(error))")
            }
        }

        // (6) Folders only for a path the policy passed, then the bytes.
        do {
            if staleTemp { try DeviceFileIO.remove(temp) }
            let folder = target.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: folder.path) {
                try DeviceFileIO.createDirectory(folder, fileManager: fileManager)
            }
            switch contents {
            case .data(let data): try DeviceFileIO.writeAtomically(data, to: target, fileManager: fileManager)
            case .file(let source): try DeviceFileIO.copyDataOnly(from: source, to: target, fileManager: fileManager)
            }
        } catch {
            return .failed(describe(error))
        }

        // (7) The journal: no hash for audio (spec D18). A hash that cannot be
        // read leaves the record without one, so the file reads as not ours.
        let written = regularFileSize(target)
        let sha = role == .audio ? nil : try? DeviceFileIO.sha256(of: target)
        let record = DeviceFileRecord(relativePath: path, kind: kind, role: role.rawValue, size: written,
                                      sha256: sha, backupFile: backupFile, volumeUUID: sessionVolumeUUID,
                                      sessionID: sessionID, subject: subject)
        do {
            try journal.append([record])
        } catch {
            return .failed("\(target.lastPathComponent) was written but could not be recorded, so CrateDigger will treat it as not its own: \(describe(error))")
        }
        return .written
    }

    // MARK: - Delete

    private func delete(_ path: String, reason: DeviceDeleteReason, sessionID: UUID,
                        earlierIntents: Set<String>) -> DeviceFileOutcome {
        let target: URL
        switch resolve(path, check: { try policy.checkDelete($0, reason: reason) }) {
        case .success(let url): target = url
        case .failure(let refusal): return refusal.outcome
        }

        let size: Int64
        switch fileState(target) {
        case .missing: return .alreadyGone
        case .other: return reason == .appleDouble ? .refusedNotAppleDouble : .refusedForeign
        case .regular(let found): size = found
        }

        var backupFile: String?
        switch reason {
        case .userReplace:
            break // the user chose this; no proof and no backup (duplicates spec)
        case .staleTemp:
            guard earlierIntents.contains(DeviceWritePolicy.key(forRelativePath: path)) else { return .refusedForeign }
        case .ownedByCrateDigger:
            do {
                guard try isOwned(path, at: target, size: size) else { return .refusedForeign }
                backupFile = try journal.backUp(fileAt: target, relativePath: path, sessionID: sessionID)
            } catch {
                return .failed("Could not keep a copy of \(target.lastPathComponent) before removing it: \(describe(error))")
            }
        case .appleDouble:
            // The proof again, now: the file may have changed since the plan.
            // (The policy above has re-checked that it is the twin of a media file.)
            guard let proof = DeviceFileIO.proveAppleDouble(target) else { return .refusedNotAppleDouble }
            do {
                backupFile = try journal.backUp(proof.bytes, relativePath: path, sessionID: sessionID)
            } catch {
                return .failed("Could not keep a copy of \(target.lastPathComponent) before removing it: \(describe(error))")
            }
            beforeAppleDoubleRemoval?(target)
            do {
                switch try DeviceFileIO.removeProvenAppleDouble(target, proof: proof) {
                case .removed: break
                case .changed: return .refusedNotAppleDouble // the backup stays on the Mac, unused
                case .gone: return .alreadyGone
                }
            } catch {
                return .failed(describe(error))
            }
        }

        if reason != .appleDouble {
            do { try DeviceFileIO.remove(target) } catch { return .failed(describe(error)) }
        }

        let record = DeviceFileRecord(relativePath: path, kind: .deleted, role: reason.rawValue, size: size,
                                      backupFile: backupFile, volumeUUID: sessionVolumeUUID, sessionID: sessionID)
        do {
            try journal.append([record])
        } catch {
            return .failed("\(target.lastPathComponent) was removed but could not be recorded: \(describe(error))")
        }
        return .deleted
    }

    // MARK: - Checks

    private struct Refusal: Error {
        let outcome: DeviceFileOutcome
    }

    /// `check`, run on the path as given and again on the path its folder
    /// really resolves to, so a symlink cannot carry an operation out of its area.
    private func resolve(_ path: String, check: (String) throws -> Void) -> Result<URL, Refusal> {
        do {
            try check(path)
        } catch {
            return .failure(Refusal(outcome: .refusedPolicy(describe(error))))
        }
        let target = path.split(separator: "/").reduce(volumeRoot) { $0.appendingPathComponent(String($1)) }
        guard let folder = DeviceWritePolicy.relativePath(of: target.deletingLastPathComponent(), under: volumeRoot)
        else {
            return .failure(Refusal(outcome: .refusedPolicy("the path leads off the device")))
        }
        let resolved = folder.isEmpty ? target.lastPathComponent : folder + "/" + target.lastPathComponent
        do {
            try check(resolved)
        } catch {
            return .failure(Refusal(outcome: .refusedPolicy(describe(error))))
        }
        return .success(target)
    }

    /// The same mount point the session was planned on: same device and
    /// inode as at init, a folder, a mount point (unless a test allowed a
    /// plain folder), and the expected UUID when there is one.
    private func isExpectedVolume() -> Bool {
        guard let capturedIdentity, VolumeIdentity(of: volumeRoot) == capturedIdentity else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: volumeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        if rootMustBeMountPoint, !Self.isMountPoint(volumeRoot) { return false }
        guard let expectedVolumeUUID else { return true }
        return volumeUUID(volumeRoot) == expectedVolumeUUID
    }

    /// Ours only when the journal's last act here, on this volume, was a write
    /// and the size and hash it recorded are what is on disk now (I3). The
    /// file is hashed only when the size already agrees.
    private func isOwned(_ path: String, at url: URL, size: Int64) throws -> Bool {
        guard let record = journal.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: path),
                                               volumeUUID: sessionVolumeUUID),
              let recordedHash = record.sha256, record.size == size
        else { return false }
        return try DeviceFileIO.sha256(of: url) == recordedHash
    }

    /// One `tempIntent` per `.cdtmp` the writes in `ops` may leave, before
    /// the first of them. A failure here costs only the cleanup of a temp a
    /// crash leaves behind, which then reads as foreign: the safe way round.
    private func recordTempIntents(for ops: [DeviceFileOperation], sessionID: UUID) {
        let intents: [DeviceFileRecord] = ops.compactMap { op in
            guard case let .write(path, role, _, _, _) = op,
                  (try? policy.checkWrite(path, role: role)) != nil,
                  (try? policy.checkWrite(path + DeviceFileIO.tempSuffix, role: .temp)) != nil
            else { return nil }
            return DeviceFileRecord(relativePath: path + DeviceFileIO.tempSuffix, kind: .tempIntent,
                                    role: DeviceFileRole.temp.rawValue, volumeUUID: sessionVolumeUUID,
                                    sessionID: sessionID)
        }
        try? journal.append(intents)
    }

    /// Which file system object the root is: device and inode, from `stat`.
    private struct VolumeIdentity: Equatable {
        let device: Int64
        let inode: UInt64

        init?(of url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    private enum FileState {
        case missing
        case regular(size: Int64)
        /// A folder, a symlink or anything else CrateDigger never writes.
        case other
    }

    private func fileState(_ url: URL) -> FileState {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .other }
        return .regular(size: Int64(info.st_size))
    }

    private func regularFileSize(_ url: URL) -> Int64? {
        guard case .regular(let size) = fileState(url) else { return nil }
        return size
    }

    private func hash(of contents: DeviceFileContents) throws -> String {
        switch contents {
        case .data(let data): return SHA256.hash(data: data).hexString
        case .file(let url): return try DeviceFileIO.sha256(of: url)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
