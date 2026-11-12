import CryptoKit
import Darwin
import Foundation

/// A device file operation that failed at the system call, with the path and
/// the system's own reason, so a failed outcome says what went wrong where.
public struct DeviceFileIOError: Error, Equatable, LocalizedError {
    public let operation: String
    public let path: String
    public let code: Int32

    public init(operation: String, path: String, code: Int32) {
        self.operation = operation
        self.path = path
        self.code = code
    }

    public var errorDescription: String? {
        "\(operation) failed for \((path as NSString).lastPathComponent): \(String(cString: strerror(code)))"
    }
}

/// The only code in the repo that mutates a device path (spec invariant I1;
/// `DeviceWriteDoorLintTests` enforces it). It does no policy checking, so
/// its mutators are internal to Core and the lint allows them to be called
/// from `DeviceFileExecutor` only, which checks the volume, the policy and
/// the journal first.
///
/// Every write lands in `<name>.cdtmp` beside its target, is flushed with
/// `fsync` and renamed over the target (I8), so the player never sees half a
/// file. Nothing here carries extended attributes onto the device, which is
/// what makes macOS write a `._` twin beside each file on FAT.
///
/// That alone is not enough in a notarized build: macOS tags everything such
/// an app creates with `com.apple.provenance`, which cannot be removed, so on
/// FAT each file and folder the door writes still gets a `._` twin holding
/// only that attribute. `ProvenanceTwins` and `removeProvenanceTwins` take
/// exactly those away again, and only those: a twin that was not there
/// before the write and holds nothing but provenance. Every other `._` file
/// is the sweep's job, through the executor, which proves it and backs it up first.
public enum DeviceFileIO {
    public static let tempSuffix = ".cdtmp"
    /// The AppleDouble magic `00 05 16 07` and version `00 02 00 00`.
    static let appleDoubleHeader: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]
    /// A twin macOS makes for attributes is about 4 KB; a bigger one may hold
    /// a real resource fork (spec D20).
    static let twinSizeRange: ClosedRange<Int64> = 26...(128 * 1024)

    /// `copyfile(COPYFILE_DATA)` to "<dest>.cdtmp", fsync, rename, restore the
    /// source's modification date, strip attributes. Creates no directories.
    /// On a failure before the rename the temp is removed and the error
    /// rethrown. Once the rename has landed the write has succeeded: failing
    /// to restore the date or strip an attribute is logged, never thrown.
    ///
    /// `exclusive`: the destination must not exist. The rename itself refuses
    /// one that appears (`RENAME_EXCL`), so nothing slips in between a check
    /// and the move; FAT has no such rename, and there the check runs right
    /// before a plain one. A refusal throws `EEXIST`.
    static func copyDataOnly(from source: URL, to destination: URL, exclusive: Bool = false,
                             fileManager: FileManager = .default) throws {
        let temp = tempURL(for: destination)
        do {
            guard copyfile(source.path, temp.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw posixError("Copy", temp)
            }
            try sync(temp)
            if exclusive {
                try renameExclusively(temp, onto: destination)
            } else {
                try rename(temp, over: destination)
            }
        } catch {
            discardTemp(temp)
            throw error
        }
        do {
            if let sourceDate = try fileManager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date {
                try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: destination.path)
            }
        } catch {
            AppLog.library.warning(
                "Copied \(destination.lastPathComponent, privacy: .private) but kept the copy's own date: \(String(describing: error), privacy: .private)")
        }
        stripExtendedAttributes(at: destination)
    }

    /// Same-folder temp, fsync, rename, strip. Never `Data.write(.atomic)`,
    /// which stages through a folder of its own on some volumes.
    /// `exclusive` as for `copyDataOnly`.
    static func writeAtomically(_ data: Data, to destination: URL, exclusive: Bool = false,
                                fileManager: FileManager = .default) throws {
        let temp = tempURL(for: destination)
        do {
            try writeAndSync(data, to: temp) // closed before the rename
            if exclusive {
                try renameExclusively(temp, onto: destination)
            } else {
                try rename(temp, over: destination)
            }
        } catch {
            discardTemp(temp)
            throw error
        }
        stripExtendedAttributes(at: destination)
    }

    /// Removes every extended attribute, without following a symlink, except
    /// `com.apple.provenance`, which the kernel will not let go (on FAT its
    /// twin is `removeProvenanceTwins`' business). Best effort: any other
    /// attribute that will not go is logged.
    static func stripExtendedAttributes(at url: URL) {
        let path = url.path
        for name in attributeNames(at: url) where name != AppleDoubleFile.provenanceAttribute
            && removexattr(path, name, XATTR_NOFOLLOW) != 0 {
            AppLog.library.warning(
                "Could not remove attribute \(name, privacy: .public) from \(url.lastPathComponent, privacy: .private): errno \(errno)")
        }
    }

    /// `unlink`; a missing file is not an error.
    static func remove(_ url: URL) throws {
        guard unlink(url.path) != 0 else { return }
        guard errno != ENOENT else { return }
        throw posixError("Delete", url)
    }

    static func createDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes `folder`, then each parent up to and including `top`, while it
    /// is empty. `rmdir` removes only an empty folder, so a folder holding
    /// anything (a hidden file included) stops the climb and is left as it is.
    static func removeEmptyFolders(from folder: URL, upTo top: URL) {
        let topPath = top.path.hasSuffix("/") ? String(top.path.dropLast()) : top.path
        var current = folder
        while current.path == topPath || current.path.hasPrefix(topPath + "/") {
            guard rmdir(current.path) == 0, current.path != topPath else { return }
            current = current.deletingLastPathComponent()
        }
    }
}

public extension DeviceFileIO {
    /// 8 bytes: `00 05 16 07 00 02 00 00`.
    static func isAppleDoubleHeader(_ header: Data) -> Bool {
        header.count >= appleDoubleHeader.count && [UInt8](header.prefix(appleDoubleHeader.count)) == appleDoubleHeader
    }

    /// Streamed, lowercase hex.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// The whole AppleDouble proof for one file, read at the moment of asking:
    /// `lstat` says a regular file, 26 bytes to 128 KB, and the first 8 bytes
    /// are the header. The name is the caller's business.
    static func isProvenAppleDouble(_ url: URL) -> Bool {
        proveAppleDouble(url) != nil
    }

    static func tempURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + tempSuffix)
    }

    /// The `._<name>` sibling where FAT and exFAT keep the attributes of the
    /// file or folder at `url`.
    static func twinURL(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
    }

    /// The extended attribute names on `url`, without following a symlink;
    /// empty when there are none or they cannot be read.
    static func attributeNames(at url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(url.path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer.prefix(read).split(separator: 0)
            .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}

/// The `._` twins one write may leave on FAT, noted before the write starts:
/// for each, whether the door may take it away afterwards. A twin that was
/// already there (anything at that name, of any kind) never may.
struct ProvenanceTwins: Equatable {
    /// In the order they are settled after the write.
    let removable: [URL]

    /// Before writing `target` through `temp`: `._<temp>`, and `._<target>`.
    /// The rename that lands the file moves the temp's twin onto the
    /// target's, so `._<target>` is removable only when neither was there.
    static func beforeWriting(_ target: URL, through temp: URL) -> ProvenanceTwins {
        let targetTwin = DeviceFileIO.twinURL(of: target)
        let tempTwin = DeviceFileIO.twinURL(of: temp)
        let tempTwinExisted = exists(tempTwin)
        var removable: [URL] = []
        if !exists(targetTwin), !tempTwinExisted { removable.append(targetTwin) }
        if !tempTwinExisted { removable.append(tempTwin) }
        return ProvenanceTwins(removable: removable)
    }

    /// Before creating `folders` (outermost first): each folder's own twin,
    /// settled in the same order, the deepest last.
    static func beforeCreating(_ folders: [URL]) -> ProvenanceTwins {
        ProvenanceTwins(removable: folders.map(DeviceFileIO.twinURL(of:)).filter { !exists($0) })
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }
}

/// What `DeviceFileIO.removeProvenanceTwin` found at one twin's name.
enum ProvenanceTwinRemoval: Equatable {
    case removed
    /// Nothing there: the write left no twin.
    case absent
    /// Something is there that is not a provenance-only AppleDouble twin
    /// (another attribute, Finder info, a resource fork, not AppleDouble, not
    /// a regular file, out of size), or it changed before the `unlink`. Kept.
    case kept
    case failed(String)
}

extension DeviceFileIO {
    /// After a write on FAT or exFAT: removes each twin `twins` noted as
    /// removable that holds nothing but `com.apple.provenance`. Never throws
    /// and never journals (the twin is the write's own by-product); each
    /// removal or refusal is logged at debug level.
    @discardableResult
    static func removeProvenanceTwins(_ twins: ProvenanceTwins) -> [ProvenanceTwinRemoval] {
        twins.removable.map { twin in
            let result = removeProvenanceTwin(twin)
            switch result {
            case .absent:
                break
            case .removed:
                AppLog.library.debug("Removed the macOS provenance file \(twin.lastPathComponent, privacy: .private) the write left")
            case .kept:
                AppLog.library.debug("Left \(twin.lastPathComponent, privacy: .private) alone: it is not only the write's provenance")
            case .failed(let reason):
                AppLog.library.debug("Could not remove \(twin.lastPathComponent, privacy: .private): \(reason, privacy: .private)")
            }
            return result
        }
    }

    /// The whole rule for one twin, read at the moment of asking: the
    /// AppleDouble proof (`lstat` a regular file, 26 bytes to 128 KB, the
    /// header, all read through one descriptor), then `AppleDoubleFile`
    /// says it holds only provenance, then `removeProvenAppleDouble`
    /// re-checks the bytes, device, inode and size right before `unlink`.
    /// Whether the twin is new is the caller's (`ProvenanceTwins`).
    static func removeProvenanceTwin(_ twin: URL) -> ProvenanceTwinRemoval {
        var info = stat()
        guard lstat(twin.path, &info) == 0 else { return errno == ENOENT ? .absent : .kept }
        guard let proof = proveAppleDouble(twin),
              let contents = AppleDoubleFile(proof.bytes), contents.holdsOnlyProvenance
        else { return .kept }
        do {
            switch try removeProvenAppleDouble(twin, proof: proof) {
            case .removed: return .removed
            case .gone: return .absent
            case .changed: return .kept
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// A `._` file that passed the AppleDouble proof, with everything read
/// through the one descriptor that proved it: its bytes (at most 128 KB, so
/// the backup is written from memory, not copied over USB again) and which
/// file it was, so the deletion can refuse anything else.
struct AppleDoubleProof: Equatable {
    let bytes: Data
    let device: Int64
    let inode: UInt64
    let size: Int64
}

/// What `DeviceFileIO.removeProvenAppleDouble` did.
enum AppleDoubleRemoval: Equatable {
    case removed
    /// Something else is at the path now (other bytes, another file, not a
    /// regular file): nothing was deleted.
    case changed
    /// Nothing is at the path any more.
    case gone
}

extension DeviceFileIO {
    /// The proof, read from one descriptor: `lstat` a regular file of 26
    /// bytes to 128 KB; opened without following a symlink or blocking on a
    /// FIFO; `fstat` of that descriptor the same file, still regular and in
    /// range; all its bytes read, the first 8 the AppleDouble header.
    static func proveAppleDouble(_ url: URL) -> AppleDoubleProof? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              twinSizeRange.contains(Int64(info.st_size))
        else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              twinSizeRange.contains(Int64(opened.st_size)),
              let bytes = readAll(fd, size: Int(opened.st_size)),
              isAppleDoubleHeader(bytes)
        else { return nil }
        return AppleDoubleProof(bytes: bytes, device: Int64(opened.st_dev), inode: UInt64(opened.st_ino),
                                size: Int64(opened.st_size))
    }

    /// Deletes the `._` file at `url` only if it is still exactly what
    /// `proof` read. Its bytes are read again and must match, then, as the
    /// last thing before `unlink`, `lstat` must name the same device, inode
    /// and size. Anything else is `.changed` and nothing is touched. (Inode
    /// alone is not enough on FAT, where a file written into a freed slot can
    /// be given the old number; the bytes settle that.)
    static func removeProvenAppleDouble(_ url: URL, proof: AppleDoubleProof) throws -> AppleDoubleRemoval {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .gone : .changed }
        var opened = stat()
        let sameBytes = fstat(fd, &opened) == 0 && matches(opened, proof)
            && readAll(fd, size: Int(proof.size)) == proof.bytes
        close(fd)
        guard sameBytes else { return .changed }

        var now = stat()
        guard lstat(url.path, &now) == 0 else { return errno == ENOENT ? .gone : .changed }
        guard matches(now, proof) else { return .changed }
        guard unlink(url.path) == 0 else {
            if errno == ENOENT { return .gone }
            throw posixError("Delete", url)
        }
        return .removed
    }

    private static func matches(_ info: stat, _ proof: AppleDoubleProof) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && Int64(info.st_dev) == proof.device
            && UInt64(info.st_ino) == proof.inode && Int64(info.st_size) == proof.size
    }

    /// Exactly `size` bytes from `fd`, and nothing after them; nil otherwise.
    private static func readAll(_ fd: Int32, size: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: size + 1)
        var total = 0
        while total < buffer.count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if got == 0 { break }
            total += got
        }
        guard total == size else { return nil } // shorter, or it grew since the stat
        return Data(buffer.prefix(size))
    }
}

private extension DeviceFileIO {
    static func writeAndSync(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw posixError("Write", url) }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("Write", url)
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw posixError("Flush", url) }
    }

    static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("Flush", url) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError("Flush", url) }
    }

    static func rename(_ temp: URL, over destination: URL) throws {
        guard Darwin.rename(temp.path, destination.path) == 0 else { throw posixError("Rename", destination) }
    }

    /// `renamex_np(RENAME_EXCL)`; where the volume has no such rename (FAT
    /// answers `ENOTSUP`), an `lstat` right before a plain rename stands in.
    static func renameExclusively(_ temp: URL, onto destination: URL) throws {
        if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            throw DeviceFileIOError(operation: "Rename", path: destination.path, code: code)
        }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            throw DeviceFileIOError(operation: "Rename", path: destination.path, code: EEXIST)
        }
        try rename(temp, over: destination)
    }

    static func discardTemp(_ temp: URL) {
        unlink(temp.path)
    }

    static func posixError(_ operation: String, _ url: URL) -> DeviceFileIOError {
        DeviceFileIOError(operation: operation, path: url.path, code: errno)
    }
}
