import Darwin
import Foundation

/// What a sweep would remove, worked out without removing anything.
public struct AppleDoubleSweepPlan: Sendable {
    /// Relative paths of the `._` files that passed the whole proof, sorted.
    public let candidates: [String]
    /// `AppleDoubleSweeper.LeftAloneReason.rawValue` -> how many `._` files it kept.
    public let leftAlone: [String: Int]
    /// Candidates by size, rounded up to a power of two -> count.
    public let sizeHistogram: [Int: Int]

    public init(candidates: [String], leftAlone: [String: Int], sizeHistogram: [Int: Int]) {
        self.candidates = candidates
        self.leftAlone = leftAlone
        self.sizeHistogram = sizeHistogram
    }

    /// One AppleDouble delete per candidate, in path order. The executor
    /// proves each file again at the moment it deletes it, and keeps a copy
    /// on the Mac first (spec invariant I4).
    public var operations: [DeviceFileOperation] {
        candidates.map { .delete(relativePath: $0, reason: .appleDouble) }
    }
}

/// Finds the macOS `._` twins that PodBox would otherwise scan as music
/// (spec "Why"). It walks and reads at most 8 bytes per `._` file; it never
/// deletes. A file is a candidate only with the whole proof (D20, D21):
///
/// - the name starts with `._` and is longer than two characters;
/// - `lstat` says a regular file (not a folder, not a symlink);
/// - 26 bytes to 128 KB;
/// - bytes 0-7 are `00 05 16 07 00 02 00 00` (AppleDouble magic and version);
/// - the name after `._` has a media extension;
/// - no path component is one of the player's trees.
///
/// No audio, image or playlist format starts with those eight bytes, so an
/// orphan twin (its file already gone) still qualifies: the bytes are the proof.
public struct AppleDoubleSweeper {
    public static let minimumSize = 26
    public static let maximumSize = 128 * 1024

    /// Audio, pictures, playlists, lyrics and documents PodBox reads.
    /// The policy's list, so the plan never lists a twin the executor would refuse.
    public static let defaultMediaExtensions: Set<String> = DeviceWritePolicy.appleDoubleMediaExtensions

    /// Why a `._` file stays. Checked in this order, so "too large" and "not
    /// media" only ever describe a file that does carry the AppleDouble header.
    public enum LeftAloneReason: String, Sendable {
        case notRegularFile = "not a file"
        case notAppleDouble = "not AppleDouble"
        case tooLarge = "too large"
        case notMedia = "not media"
    }

    private static let deniedKeys = Set(DeviceWritePolicy.deniedTrees.map { DeviceWritePolicy.key(forRelativePath: $0) })
    private static let twinPrefix = "._"
    /// The AppleDouble delete rule does not depend on the music folder.
    private static let policy = DeviceWritePolicy(musicSubpath: "")

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 8 bytes: `00 05 16 07 00 02 00 00`.
    public static func isAppleDouble(header: Data) -> Bool {
        DeviceFileIO.isAppleDoubleHeader(header)
    }

    /// Walks, reads 8 bytes per "._" file, deletes nothing. `scope` nil walks
    /// the whole volume; otherwise each folder in it is listed on its own, not
    /// recursively (a session passes exactly the folders it wrote to). A scope
    /// folder outside the volume or inside one of the player's trees is skipped.
    public func plan(volumeRoot: URL, scope: [URL]?,
                     mediaExtensions: Set<String> = AppleDoubleSweeper.defaultMediaExtensions) -> AppleDoubleSweepPlan {
        var walk = Walk(rootPath: volumeRoot.path, mediaExtensions: Set(mediaExtensions.map { $0.lowercased() }))
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: volumeRoot.path, isDirectory: &isFolder), isFolder.boolValue else {
            return AppleDoubleSweepPlan(candidates: [], leftAlone: [:], sizeHistogram: [:])
        }
        if let scope {
            var seen = Set<String>()
            for folder in scope {
                guard let relative = DeviceWritePolicy.relativePath(of: folder, under: volumeRoot),
                      seen.insert(DeviceWritePolicy.key(forRelativePath: relative)).inserted,
                      !Self.isDenied(relative)
                else { continue }
                walk.visit(relative, recursive: false)
            }
        } else {
            walk.visit("", recursive: true)
        }
        return AppleDoubleSweepPlan(candidates: walk.candidates.sorted(),
                                    leftAlone: walk.leftAlone,
                                    sizeHistogram: walk.sizeHistogram)
    }

    private static func isDenied(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains {
            deniedKeys.contains(DeviceWritePolicy.key(forRelativePath: String($0)))
        }
    }

    /// Every name in a folder, `._` files included. Foundation's
    /// `contentsOfDirectory` and its enumerators leave `._` files out on
    /// macOS, which would make every twin invisible, so this reads the
    /// folder with `readdir`. A name that is not valid UTF-8 is skipped: no
    /// path built from it would name the same file. nil when the folder
    /// cannot be opened.
    static func entryNames(inFolder path: String) -> [String]? {
        guard let folder = opendir(path) else { return nil }
        defer { closedir(folder) }
        var names: [String] = []
        while let entry = readdir(folder) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(validatingCString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let name, name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    private static func roundedUpToPowerOfTwo(_ size: Int) -> Int {
        var bucket = 1
        while bucket < size { bucket <<= 1 }
        return bucket
    }

    /// One plan's walk. Paths are built from the names the folder listing
    /// gave, never from a resolved symlink, so a path always names the file
    /// that was looked at.
    private struct Walk {
        let rootPath: String
        let mediaExtensions: Set<String>
        var candidates: [String] = []
        var leftAlone: [String: Int] = [:]
        var sizeHistogram: [Int: Int] = [:]

        mutating func visit(_ relativeFolder: String, recursive: Bool) {
            let folderPath = relativeFolder.isEmpty ? rootPath : rootPath + "/" + relativeFolder
            // An unreadable or vanished folder holds nothing we can prove.
            guard let names = AppleDoubleSweeper.entryNames(inFolder: folderPath) else { return }
            for name in names.sorted() {
                let relative = relativeFolder.isEmpty ? name : relativeFolder + "/" + name
                let path = folderPath + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                let isFolder = (info.st_mode & S_IFMT) == S_IFDIR

                if name.hasPrefix(AppleDoubleSweeper.twinPrefix), name.count > AppleDoubleSweeper.twinPrefix.count {
                    consider(name: name, relative: relative, path: path, info: info)
                }
                // Never into the player's trees, at any depth (as the policy), and never through a symlink.
                if recursive, isFolder, !AppleDoubleSweeper.deniedKeys.contains(DeviceWritePolicy.key(forRelativePath: name)) {
                    visit(relative, recursive: true)
                }
            }
        }

        private mutating func consider(name: String, relative: String, path: String, info: stat) {
            guard (info.st_mode & S_IFMT) == S_IFREG else { return keep(.notRegularFile) }
            guard let size = provenAppleDoubleSize(path) else { return keep(.notAppleDouble) }
            guard size <= AppleDoubleSweeper.maximumSize else { return keep(.tooLarge) }
            let twinOf = String(name.dropFirst(AppleDoubleSweeper.twinPrefix.count))
            guard mediaExtensions.contains((twinOf as NSString).pathExtension.lowercased()) else {
                return keep(.notMedia)
            }
            // Never list what the executor's policy would refuse (a path through a
            // folder FAT stores as nothing, such as "..."); it is not ours to count either.
            guard (try? AppleDoubleSweeper.policy.checkDelete(relative, reason: .appleDouble)) != nil else { return }
            candidates.append(relative)
            sizeHistogram[AppleDoubleSweeper.roundedUpToPowerOfTwo(size), default: 0] += 1
        }

        private mutating func keep(_ reason: LeftAloneReason) {
            leftAlone[reason.rawValue, default: 0] += 1
        }

        /// Opens for reading only, never following a symlink or blocking on a
        /// FIFO swapped in since the `lstat`, and checks the open file itself:
        /// a regular file of at least 26 bytes whose first 8 bytes are the
        /// AppleDouble header. Returns its size, or nil.
        private func provenAppleDoubleSize(_ path: String) -> Int? {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= AppleDoubleSweeper.minimumSize
            else { return nil }
            var header = [UInt8](repeating: 0, count: 8)
            guard Darwin.read(fd, &header, header.count) == header.count,
                  AppleDoubleSweeper.isAppleDouble(header: Data(header))
            else { return nil }
            return Int(info.st_size)
        }
    }
}
