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
    case write(relativePath: String, role: DeviceFileRole, contents: DeviceFileContents, replacesForeign: Bool = false)
    case delete(relativePath: String, reason: DeviceDeleteReason)

    var relativePath: String {
        switch self {
        case .write(let path, _, _, _), .delete(let path, _): return path
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
/// For a write: (1) the volume is still the one planned for (I7), (2) the
/// policy allows the path, both as given and after resolving symlinks (I2),
/// (3) there is room for it plus `freeSpaceMargin`, (4) an existing file with
/// identical bytes is left alone (I5); one the journal proves ours is backed
/// up and replaced; anything else is foreign and refused (I3), (5)-(6) the
/// bytes land through a flushed temp and a rename, attributes and a proven
/// `._` twin removed (I8), (7) the journal records it. A delete needs the
/// journal's proof for `ownedByCrateDigger`, re-proves an AppleDouble twin at
/// the moment of deletion (I4), and backs up either first.
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

    public init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
                journal: DeviceWriteJournal, fileManager: FileManager = .default,
                volumeUUID: @escaping (URL) -> String? = DeviceFileExecutor.systemVolumeUUID,
                freeSpace: @escaping (URL) -> Int64? = DeviceFileExecutor.systemFreeSpace) {
        self.volumeRoot = volumeRoot
        self.expectedVolumeUUID = expectedVolumeUUID
        self.policy = policy
        self.journal = journal
        self.fileManager = fileManager
        self.volumeUUID = volumeUUID
        self.freeSpace = freeSpace
    }

    public static func systemVolumeUUID(_ root: URL) -> String? {
        try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    public static func systemFreeSpace(_ root: URL) -> Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// Applies `ops` in order. The outcomes are index-aligned with `ops`.
    /// `progress` gets (operations done, total) after each one.
    public func apply(_ ops: [DeviceFileOperation], sessionID: UUID,
                      progress: (Int, Int) -> Void = { _, _ in }) -> [DeviceFileOutcome] {
        guard isExpectedVolume() else {
            return ops.map { _ in .refusedWrongVolume }
        }

        // Temp paths a crashed earlier session may have left; only these are
        // ever cleaned up as stale.
        let earlierIntents = Set(journal.records.filter { $0.kind == .tempIntent }.map(\.relativeKey))
        recordTempIntents(for: ops, sessionID: sessionID)

        var outcomes: [DeviceFileOutcome] = []
        outcomes.reserveCapacity(ops.count)
        for (index, op) in ops.enumerated() {
            let outcome: DeviceFileOutcome
            if !isExpectedVolume() {
                outcome = .refusedWrongVolume
            } else {
                switch op {
                case let .write(path, role, contents, replacesForeign):
                    outcome = write(path, role: role, contents: contents, replacesForeign: replacesForeign,
                                    sessionID: sessionID, earlierIntents: earlierIntents)
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
                       sessionID: UUID, earlierIntents: Set<String>) -> DeviceFileOutcome {
        let target: URL
        switch resolve(path, check: { try policy.checkWrite($0, role: role) }) {
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
        if let available = freeSpace(volumeRoot), available < incomingSize + Self.freeSpaceMargin {
            return .refusedNoSpace
        }

        // A leftover temp is ours to clear only when an earlier session said
        // it would make one. Decided before anything is touched or backed up.
        let temp = DeviceFileIO.tempURL(for: target)
        let tempPath = path + DeviceFileIO.tempSuffix
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

        // (4) What is there already.
        var kind = DeviceFileRecord.Kind.created
        var backupFile: String?
        switch fileState(target) {
        case .missing:
            break
        case .other:
            return .refusedForeign
        case .regular(let size):
            do {
                let existingHash = try DeviceFileIO.sha256(of: target)
                if size == incomingSize, existingHash == (try hash(of: contents)) { return .unchanged }
                let owned = isOwned(path, size: size, sha256: existingHash)
                guard owned || (replacesForeign && role == .cover) else { return .refusedForeign }
                backupFile = try journal.backUp(fileAt: target, relativePath: path, sessionID: sessionID)
                kind = .replaced
            } catch {
                return .failed("Could not read \(target.lastPathComponent) or keep a copy of it before replacing it: \(describe(error))")
            }
        }

        // (5)-(6) Folders only for a path the policy passed, then the bytes.
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

        // (7) The journal: no hash for audio (spec D18).
        let written = regularFileSize(target)
        let sha = role == .audio ? nil : try? DeviceFileIO.sha256(of: target)
        let record = DeviceFileRecord(relativePath: path, kind: kind, role: role.rawValue, size: written,
                                      sha256: sha, backupFile: backupFile, volumeUUID: expectedVolumeUUID,
                                      sessionID: sessionID)
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
        var sha: String?
        switch reason {
        case .userReplace:
            break // the user chose this; no proof and no backup (duplicates spec)
        case .staleTemp:
            guard earlierIntents.contains(DeviceWritePolicy.key(forRelativePath: path)) else { return .refusedForeign }
        case .ownedByCrateDigger:
            do {
                let current = try DeviceFileIO.sha256(of: target)
                guard isOwned(path, size: size, sha256: current) else { return .refusedForeign }
                sha = current
                backupFile = try journal.backUp(fileAt: target, relativePath: path, sessionID: sessionID)
            } catch {
                return .failed("Could not keep a copy of \(target.lastPathComponent) before removing it: \(describe(error))")
            }
        case .appleDouble:
            // The proof again, now: the file may have changed since the plan.
            guard DeviceFileIO.isProvenAppleDouble(target) else { return .refusedNotAppleDouble }
            do {
                backupFile = try journal.backUp(fileAt: target, relativePath: path, sessionID: sessionID)
            } catch {
                return .failed("Could not keep a copy of \(target.lastPathComponent) before removing it: \(describe(error))")
            }
        }

        do { try DeviceFileIO.remove(target) } catch { return .failed(describe(error)) }

        let record = DeviceFileRecord(relativePath: path, kind: .deleted, role: reason.rawValue, size: size,
                                      sha256: sha, backupFile: backupFile, volumeUUID: expectedVolumeUUID,
                                      sessionID: sessionID)
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

    /// The policy, run on the path as given and again on the path its folder
    /// really resolves to, so a symlink cannot carry a write out of its area.
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

    private func isExpectedVolume() -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: volumeRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        guard let expectedVolumeUUID else { return true }
        return volumeUUID(volumeRoot) == expectedVolumeUUID
    }

    /// Ours only when the journal's last act here was a write and the size
    /// and hash it recorded are what is on disk now (I3).
    private func isOwned(_ path: String, size: Int64, sha256: String) -> Bool {
        guard let record = journal.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: path)),
              let recordedHash = record.sha256
        else { return false }
        return record.size == size && recordedHash == sha256
    }

    /// One `tempIntent` per `.cdtmp` the writes in `ops` may leave, before
    /// the first of them. A failure here costs only the cleanup of a temp a
    /// crash leaves behind, which then reads as foreign: the safe way round.
    private func recordTempIntents(for ops: [DeviceFileOperation], sessionID: UUID) {
        let intents: [DeviceFileRecord] = ops.compactMap { op in
            guard case let .write(path, role, _, _) = op, (try? policy.checkWrite(path, role: role)) != nil
            else { return nil }
            return DeviceFileRecord(relativePath: path + DeviceFileIO.tempSuffix, kind: .tempIntent,
                                    role: DeviceFileRole.temp.rawValue, volumeUUID: expectedVolumeUUID,
                                    sessionID: sessionID)
        }
        try? journal.append(intents)
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
