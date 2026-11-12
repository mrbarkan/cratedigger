import CryptoKit
import Foundation
import XCTest

/// A temp-dir replica of a Rockbox iPod's file layout, built from literals
/// copied out of the PodBox brief. Every device-writer test builds one, takes
/// `manifest()` first and ends with `assertPlayerStateUntouched(since:)`, so a
/// writer that reaches into the player's own files fails loudly here instead
/// of on the owner's iPod. Nothing in it is read from a real device.
final class FakeIPod {
    enum Flavour {
        case podBox(layout: UInt16)
        case podBoxNotBooted
        case stockRockbox
        case unknownRockbox
        case noRockbox
    }

    /// A fresh temp folder, symlinks resolved (so `/var` vs `/private/var`
    /// never makes a path look as if it left the root). Removed in deinit.
    let root: URL
    let musicSubpath: String

    /// The folders the player owns. `manifest()` covers these, plus the root
    /// file `.scrobbler.log`.
    static let protectedTrees = [".rockbox", ".rockbox_backup", ".backup", "iPod_Control"]

    static let rockboxInfo = "Target: ipodvideo\nTarget id: 15\nTarget define: -DIPOD_VIDEO\nMemory: 64\nCPU: arm\nManufacturer: ipod\nVersion: -261108\nBinary: rockbox.ipod\nFeatures: albumart:tagcache:usbstack\n"
    static let config = "# .cfg file created by rockbox -261108 - http://www.rockbox.org\n\nstatusbar: off\ntheme: /.rockbox/themes/scrim.cfg\ndatabase artist art: on\n"
    static let defaultConfig = "database artist art: on\ndatabase album art: on\n"
    static let playbackLog = "# Started Ver. -261108 / Time 261111-222243\n1794435900:28746:291757:/<HDD0>/Music/Classics/Beach House/2010 Teen Dream/01 - Zebra.m4a\n1794436675:33158:291757:/<HDD0>/Music/Classics/Beach House/2010 Teen Dream/01 - Zebra.m4a\n"
    static let playlistLine = "/<HDD0>/Music/Classics/David Gilmour/2008 Live in Gdańsk/02 - Wearing the Inside Out.m4a\n"

    static func formatDat(layout: UInt16) -> Data {
        var bytes: [UInt8] = [0x4c, 0x59, 0x4f, 0x54, UInt8(layout & 0xff), UInt8(layout >> 8),
                              0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [UInt8](repeating: 0xff, count: 16)
        return Data(bytes)
    }

    init(flavour: Flavour = .podBox(layout: 5), musicSubpath: String = "Music") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeIPod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath: Foundation strips "/private"
        // back off, and the file walker reports the "/private/var" form.
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        self.musicSubpath = musicSubpath
        if !musicSubpath.isEmpty {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(musicSubpath, isDirectory: true),
                withIntermediateDirectories: true)
        }

        switch flavour {
        case .podBox(let layout):
            try writePodBoxBase()
            try addFile(".rockbox/library/format.dat", Self.formatDat(layout: layout))
            try addFile(".rockbox/library/database/database_idx.tcd", Data([0x54, 0x43, 0x44, 0x00]))
            try addFile(".rockbox/library/user/plays.dat", Data("PLYS".utf8) + Data(count: 24))
            try addFile(".rockbox/library/user/playback.log", Data(Self.playbackLog.utf8))
            try addFile(".rockbox/library/user/player_name.txt", Data("PodBox".utf8))
            try addFile(".rockbox/library/cache/unreadable.txt", Data())
            try addFile(".rockbox/library/cache/art/stamps.dat", Data("ARTS".utf8) + Data(count: 24))
        case .podBoxNotBooted:
            try writePodBoxBase()
        case .stockRockbox:
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".rockbox/rocks", isDirectory: true),
                withIntermediateDirectories: true)
            try addFile(".rockbox/rockbox-info.txt", Data(Self.rockboxInfo.utf8))
        case .unknownRockbox:
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".rockbox", isDirectory: true),
                withIntermediateDirectories: true)
        case .noRockbox:
            break
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePodBoxBase() throws {
        try addFile(".rockbox/rockbox-info.txt", Data(Self.rockboxInfo.utf8))
        try addFile(".rockbox/config.cfg", Data(Self.config.utf8))
        try addFile(".rockbox/default-config.cfg", Data(Self.defaultConfig.utf8))
        try addFile(".rockbox/trim.config", Data("the\n".utf8))
        try addFile(".rockbox/docs/settings-help.txt", Data("Settings help\n".utf8))
        try addFile(".rockbox_backup/x.txt", Data("backup\n".utf8))
        try addFile(".backup/x.zip", Data([0x50, 0x4b, 0x03, 0x04]))
        try addFile("iPod_Control/iTunes/iTunesDB", Data("mhbd".utf8))
        try addFile("Playlists/Pl.m3u8", Data([0xef, 0xbb, 0xbf]) + Data(Self.playlistLine.utf8))
    }

    /// Writes an album folder under the music folder (and the category, when
    /// given) with stand-in track bytes, an optional `cover.jpg` and optional
    /// `._` AppleDouble twins beside every file. Returns the album folder.
    @discardableResult
    func addAlbum(category: String?, artist: String, folder: String,
                  tracks: [String], cover: Bool = true, appleDoubleTwins: Bool = false) throws -> URL {
        var parts = [musicSubpath]
        if let category { parts.append(category) }
        parts += [artist, folder]
        let relativeFolder = parts.filter { !$0.isEmpty }.joined(separator: "/")
        for track in tracks {
            // "ftyp" at offset 4, as in a real MPEG-4 file: never AppleDouble bytes.
            try addFile("\(relativeFolder)/\(track)",
                        Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(track.utf8))
            if appleDoubleTwins {
                try addFile("\(relativeFolder)/._\(track)", Self.appleDoubleBytes())
            }
        }
        if cover {
            try addFile("\(relativeFolder)/cover.jpg", Data([0xff, 0xd8, 0xff, 0xe0]) + Data(folder.utf8))
            if appleDoubleTwins {
                try addFile("\(relativeFolder)/._cover.jpg", Self.appleDoubleBytes())
            }
        }
        return root.appendingPathComponent(relativeFolder, isDirectory: true)
    }

    /// Writes `data` at `relativePath` under the root, creating its folders.
    @discardableResult
    func addFile(_ relativePath: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// The header macOS writes into a `._` twin (magic `00 05 16 07`, version
    /// `00 02 00 00`), then zero padding up to `size`.
    static func appleDoubleBytes(size: Int = 4096) -> Data {
        var data = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00])
        if size > data.count { data.append(Data(count: size - data.count)) }
        return data
    }

    /// Every file and folder in the protected trees, plus the root
    /// `.scrobbler.log`: relative path -> "size:sha256:mtime" (folders read
    /// "dir", symlinks "link:<destination>").
    func manifest() throws -> [String: String] {
        var result: [String: String] = [:]
        for tree in Self.protectedTrees {
            try record(tree, into: &result)
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".scrobbler.log").path) {
            try record(".scrobbler.log", into: &result)
        }
        return result
    }

    /// Every path under `relativeFolder` (default: the whole volume), `._`
    /// files included, without following symlinks. Sorted.
    func allRelativePaths(under relativeFolder: String = "") -> [String] {
        let folder = relativeFolder.isEmpty ? root.path : root.appendingPathComponent(relativeFolder).path
        var paths: [String] = []
        for name in Self.entryNames(inFolder: folder) {
            let relative = relativeFolder.isEmpty ? name : relativeFolder + "/" + name
            paths.append(relative)
            var info = stat()
            if lstat(root.appendingPathComponent(relative).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                paths += allRelativePaths(under: relative)
            }
        }
        return paths.sorted()
    }

    /// Walks with `readdir`, because Foundation's `contentsOfDirectory` and
    /// its enumerators leave `._` files out on macOS, and a `._` file the
    /// manifest cannot see is exactly what a broken sweep would touch.
    private func record(_ relative: String, into result: inout [String: String]) throws {
        let url = root.appendingPathComponent(relative)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            result[relative] = "dir"
            for name in Self.entryNames(inFolder: url.path) {
                try record(relative + "/" + name, into: &result)
            }
        case S_IFLNK:
            result[relative] = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?")
        default:
            result[relative] = try Self.fingerprint(url)
        }
    }

    private static func entryNames(inFolder path: String) -> [String] {
        guard let folder = opendir(path) else { return [] }
        defer { closedir(folder) }
        var names: [String] = []
        while let entry = readdir(folder) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Fails the calling test when anything in the protected trees was added,
    /// removed or changed since `before` was taken.
    func assertPlayerStateUntouched(since before: [String: String],
                                    file: StaticString = #filePath, line: UInt = #line) {
        let after: [String: String]
        do {
            after = try manifest()
        } catch {
            XCTFail("Could not read the player state: \(error)", file: file, line: line)
            return
        }
        guard after != before else { return }
        let added = Set(after.keys).subtracting(before.keys).sorted()
        let removed = Set(before.keys).subtracting(after.keys).sorted()
        let changed = Set(before.keys).intersection(after.keys).filter { before[$0] != after[$0] }.sorted()
        XCTFail("The player's own files changed. Added: \(added) Removed: \(removed) Changed: \(changed)",
                file: file, line: line)
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(data.count):\(hash):\(mtime)"
    }
}
