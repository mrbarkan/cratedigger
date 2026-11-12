import Darwin
import Foundation

/// The DEBUG dry run behind `CRATEDIGGER_PODBOX_DRYRUN` (the owner's checks
/// M1 to M3): what CrateDigger reads on a device and what a cleanup would
/// remove, as text. It probes and plans only. It constructs no executor and
/// no journal, opens nothing for writing, and its last line says so.
public enum PodBoxDryRun {
    /// How many non-ASCII folder names the names section shows.
    static let nonASCIIFolderLimit = 5
    /// Characters FAT and the player treat specially in a name.
    static let oddCharacters: Set<Character> = ["?", "*", "\"", "<", ">", "|"]

    /// Text report: firmware summary, capabilities, prefix, cleanup plan
    /// counts, left-alone counts, size table, the "names" section for M2,
    /// and the last line "0 files would be written".
    public static func report(volumeRoot: URL, musicSubpath: String, fileManager: FileManager = .default) -> String {
        report(volumeRoot: volumeRoot, musicSubpath: musicSubpath, fileManager: fileManager,
               fileSystemType: AppleDoubleSweeper.systemFileSystemType)
    }

    /// Tests: a temp folder on APFS stands in for a FAT device.
    static func report(volumeRoot: URL, musicSubpath: String, fileManager: FileManager = .default,
                       fileSystemType: @escaping (URL) -> String?) -> String {
        var out: [String] = []
        let fileSystem = fileSystemType(volumeRoot)
        out.append("CrateDigger PodBox dry run")
        out.append("Volume: \(volumeRoot.path)")
        out.append("File system: \(fileSystem ?? "unknown")")
        out.append("")

        // Firmware.
        let firmware = DeviceFirmwareProbe.probe(volumeRoot: volumeRoot, fileManager: fileManager)
        out.append("== Firmware")
        if let firmware {
            out.append(firmware.summaryLine)
            out.append("Flavour: \(firmware.flavour.rawValue)")
            out.append("Layout: \(firmware.layout.map(String.init) ?? "none (never booted, or not PodBox)")")
            out.append("Target: \(firmware.build?.target ?? "unknown")")
            out.append("Version: \(firmware.build?.version ?? "unknown")")
            if let date = firmware.build?.buildDate, let year = date.year, let month = date.month, let day = date.day {
                out.append(String(format: "Build date: %04d-%02d-%02d", year, month, day))
            }
            out.append("Player path prefix: \(firmware.playerPathPrefix ?? "not found")")
            out.append("Player name: \(firmware.playerName ?? "not set")")
            out.append("Playlist folder: \(firmware.config.playlistDirectory ?? "none")")
            out.append("Play log: \(firmware.config.playLogMode.rawValue)")
            out.append("unreadable.txt lines naming a ._ file: \(firmware.unreadableAppleDoubleCount)")
            if let notice = firmware.layoutNotice { out.append("Notice: \(notice)") }
        } else {
            out.append("No .rockbox folder: not a Rockbox device")
        }
        out.append("")

        // Capabilities.
        let capabilities = DeviceCapabilities(firmware: firmware, fileSystem: fileSystem)
        out.append("== Capabilities")
        let capabilityList = capabilityNames(capabilities)
        out.append(capabilityList.isEmpty ? "none" : capabilityList.joined(separator: ", "))
        out.append("")

        // Cleanup plan: planned only.
        let plan = AppleDoubleSweeper(fileManager: fileManager, fileSystemType: fileSystemType)
            .plan(volumeRoot: volumeRoot, scope: nil)
        out.append("== Cleanup plan (nothing removed)")
        if let refusal = plan.refusal {
            out.append("No cleanup: \(refusal)")
        } else {
            out.append("\(plan.candidates.count) Mac metadata files would be removed")
            out.append("Left alone:")
            if plan.leftAlone.isEmpty {
                out.append("  none")
            } else {
                for (reason, count) in plan.leftAlone.sorted(by: { $0.key < $1.key }) {
                    out.append("  \(reason): \(count)")
                }
            }
            out.append("Sizes:")
            for (bucket, count) in plan.sizeHistogram.sorted(by: { $0.key < $1.key }) {
                out.append("  \(bucket) bytes or less: \(count)")
            }
            out.append("Files:")
            for candidate in plan.candidates { out.append("  \(candidate)") }
        }
        out.append("")

        // Names (M2).
        out.append("== Names under \(musicSubpath.isEmpty ? "the volume root" : musicSubpath)")
        let names = nameFindings(volumeRoot: volumeRoot, musicSubpath: musicSubpath)
        out.append("Folders with non-ASCII names (first \(nonASCIIFolderLimit)), bytes as stored:")
        if names.nonASCII.isEmpty { out.append("  none") }
        for (path, hex) in names.nonASCII {
            out.append("  \(path)")
            out.append("    \(hex)")
        }
        out.append("Names containing ? * \" < > | or ending in a dot:")
        if names.odd.isEmpty { out.append("  none") }
        for path in names.odd { out.append("  \(path)") }
        out.append("")

        out.append("0 files would be written")
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private static func capabilityNames(_ caps: DeviceCapabilities) -> [String] {
        let all: [(DeviceCapabilities, String)] = [
            (.appleDoubleSweep, "appleDoubleSweep"), (.coverSidecar, "coverSidecar"),
            (.centralPeopleArtwork, "centralPeopleArtwork"), (.playlistCatalog, "playlistCatalog"),
            (.playbackLogImport, "playbackLogImport"), (.scrobblerLogImport, "scrobblerLogImport"),
            (.lyricsSidecar, "lyricsSidecar"),
        ]
        return all.filter { caps.contains($0.0) }.map(\.1)
    }

    /// Walks the music folder with `readdir` (names exactly as stored, `._`
    /// files included), never following a symlink and never entering the
    /// player's trees.
    private static func nameFindings(volumeRoot: URL, musicSubpath: String)
        -> (nonASCII: [(String, String)], odd: [String]) {
        var nonASCII: [(String, String)] = []
        var odd: [String] = []
        let deniedKeys = Set(DeviceWritePolicy.deniedTrees.map { DeviceWritePolicy.key(forRelativePath: $0) })

        func visit(_ relative: String) {
            let path = relative.isEmpty ? volumeRoot.path : volumeRoot.path + "/" + relative
            guard let entries = AppleDoubleSweeper.entryNames(inFolder: path) else { return }
            for name in entries.sorted() {
                let child = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(volumeRoot.path + "/" + child, &info) == 0 else { continue }
                let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
                if isFolder, nonASCII.count < nonASCIIFolderLimit, name.utf8.contains(where: { $0 >= 0x80 }) {
                    nonASCII.append((child, name.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")))
                }
                if name.hasSuffix(".") || name.contains(where: { oddCharacters.contains($0) }) {
                    odd.append(child)
                }
                if isFolder, !deniedKeys.contains(DeviceWritePolicy.key(forRelativePath: name)) {
                    visit(child)
                }
            }
        }
        let start = musicSubpath.split(separator: "/").joined(separator: "/")
        visit(start)
        return (nonASCII, odd)
    }
}
