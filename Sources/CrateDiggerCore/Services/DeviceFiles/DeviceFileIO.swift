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
/// `DeviceWriteDoorLintTests` enforces it). It does no policy checking:
/// callers run `DeviceWritePolicy` first, and PodBox writers go through
/// `DeviceFileExecutor`, which does both and keeps the journal.
///
/// Every write lands in `<name>.cdtmp` beside its target, is flushed with
/// `fsync` and renamed over the target (I8), so the player never sees half a
/// file. Nothing here carries extended attributes onto the device, which is
/// what makes macOS write a `._` twin beside each file on FAT.
public enum DeviceFileIO {
    public static let tempSuffix = ".cdtmp"
    /// The AppleDouble magic `00 05 16 07` and version `00 02 00 00`.
    static let appleDoubleHeader: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]
    /// A twin macOS makes for attributes is about 4 KB; a bigger one may hold
    /// a real resource fork (spec D20).
    static let twinSizeRange: ClosedRange<Int64> = 26...(128 * 1024)

    /// `copyfile(COPYFILE_DATA)` to "<dest>.cdtmp", fsync, rename, restore the
    /// source's modification date, strip attributes, remove a proven "._"
    /// twin. Creates no directories. On a failure before the rename the temp
    /// is removed and the error rethrown.
    public static func copyDataOnly(from source: URL, to destination: URL,
                                    fileManager: FileManager = .default) throws {
        let temp = tempURL(for: destination)
        do {
            guard copyfile(source.path, temp.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw posixError("Copy", temp)
            }
            try sync(temp)
            try rename(temp, over: destination)
        } catch {
            discardTemp(temp)
            throw error
        }
        let sourceDate = try fileManager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        if let sourceDate {
            try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: destination.path)
        }
        stripExtendedAttributes(at: destination)
        removeProvenTwin(of: destination)
    }

    /// Same-folder temp, fsync, rename, strip, twin. Never `Data.write(.atomic)`,
    /// which stages through a folder of its own on some volumes.
    public static func writeAtomically(_ data: Data, to destination: URL,
                                       fileManager: FileManager = .default) throws {
        let temp = tempURL(for: destination)
        do {
            try writeAndSync(data, to: temp) // closed before the rename
            try rename(temp, over: destination)
        } catch {
            discardTemp(temp)
            throw error
        }
        stripExtendedAttributes(at: destination)
        removeProvenTwin(of: destination)
    }

    /// Removes every extended attribute, without following a symlink.
    public static func stripExtendedAttributes(at url: URL) {
        let path = url.path
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return }
        let names = buffer.prefix(read).split(separator: 0)
            .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        for name in names {
            removexattr(path, name, XATTR_NOFOLLOW)
        }
    }

    /// Deletes `._<name>` beside `url` only when it is a regular file of 26
    /// bytes to 128 KB that starts with the AppleDouble header. Returns
    /// whether it deleted.
    @discardableResult
    public static func removeProvenTwin(of url: URL) -> Bool {
        let twin = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        guard isProvenAppleDouble(twin) else { return false }
        return unlink(twin.path) == 0
    }

    /// `unlink`; a missing file is not an error.
    public static func remove(_ url: URL) throws {
        guard unlink(url.path) != 0 else { return }
        guard errno != ENOENT else { return }
        throw posixError("Delete", url)
    }

    public static func createDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
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
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              twinSizeRange.contains(Int64(info.st_size))
        else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: appleDoubleHeader.count)
        guard Darwin.read(fd, &header, header.count) == header.count else { return false }
        return header == appleDoubleHeader
    }

    static func tempURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + tempSuffix)
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

    static func discardTemp(_ temp: URL) {
        unlink(temp.path)
    }

    static func posixError(_ operation: String, _ url: URL) -> DeviceFileIOError {
        DeviceFileIOError(operation: operation, path: url.path, code: errno)
    }
}
