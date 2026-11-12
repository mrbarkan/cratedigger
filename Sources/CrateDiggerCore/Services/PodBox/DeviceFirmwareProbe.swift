import Foundation

/// Reads what a mounted Rockbox device says about itself: flavour, build,
/// library layout, settings and the path prefix the player writes.
///
/// Mounting only reads (spec invariant I6). Every read here opens with
/// `FileHandle(forReadingFrom:)`, only after `attributesOfItem` says the path
/// is a regular file (a FIFO would block the open), reads at most a fixed
/// number of bytes and closes before returning. Garbage text decodes lossily
/// and parses to nils; nothing here throws.
public enum DeviceFirmwareProbe {
    // Read caps, in bytes.
    static let formatDatCap = 28
    static let rockboxInfoCap = 16 * 1024
    static let configCap = 64 * 1024
    static let unreadableCap = 256 * 1024
    static let playerFileCap = 64 * 1024
    static let playlistControlCap = 4 * 1024
    static let playerNameCap = 4 * 1024

    /// Opens nothing for writing and holds no handle past its return. nil = no `.rockbox` folder.
    public static func probe(volumeRoot: URL, fileManager: FileManager = .default) -> DeviceFirmware? {
        let rockbox = volumeRoot.appendingPathComponent(".rockbox", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rockbox.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        func read(_ relative: String, cap: Int, under base: URL = rockbox) -> Data? {
            readCapped(base.appendingPathComponent(relative), cap: cap, fileManager: fileManager)
        }
        func text(_ relative: String, cap: Int, under base: URL = rockbox) -> String? {
            read(relative, cap: cap, under: base).map { String(decoding: $0, as: UTF8.self) }
        }

        let layout = read("library/format.dat", cap: formatDatCap).flatMap(layoutVersion(formatDat:))

        var entries = Set((try? fileManager.contentsOfDirectory(atPath: rockbox.path)) ?? [])
        if fileManager.fileExists(atPath: rockbox.appendingPathComponent("docs/settings-help.txt").path) {
            entries.insert("docs/settings-help.txt")
        }
        let flavour = flavour(layout: layout, rockboxEntries: entries)

        let build = text("rockbox-info.txt", cap: rockboxInfoCap)
            .map(buildInfo(rockboxInfo:))
            .flatMap { $0.target == nil && $0.version == nil ? nil : $0 }

        // `config.cfg.new` is the player's half-written replacement: ignored.
        let config = PodBoxConfig(defaultConfig: text("default-config.cfg", cap: configCap),
                                  config: text("config.cfg", cap: configCap))

        var playerLines: [String] = []
        if let directory = config.playlistDirectory,
           let playlist = firstPlayerPlaylist(in: volumeRoot, relativeFolder: directory, fileManager: fileManager),
           let body = readCapped(playlist, cap: playerFileCap, fileManager: fileManager) {
            playerLines += lines(String(decoding: body, as: UTF8.self))
        }
        if let log = text("library/user/playback.log", cap: playerFileCap) { playerLines += lines(log) }
        if let control = text(".playlist_control", cap: playlistControlCap) { playerLines += lines(control) }

        let playerName = text("library/user/player_name.txt", cap: playerNameCap)
            .flatMap { lines($0).first?.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || $0.contains("\u{FFFD}") ? nil : $0 }

        let unreadable = text("library/cache/unreadable.txt", cap: unreadableCap)
            .map(appleDoubleCount(unreadableText:)) ?? 0

        let scrobblerLog = fileManager.fileExists(atPath: volumeRoot.appendingPathComponent(".scrobbler.log").path)

        return DeviceFirmware(flavour: flavour, layout: layout, build: build, config: config,
                              playerPathPrefix: playerPathPrefix(fromPlayerLines: playerLines),
                              playerName: playerName, unreadableAppleDoubleCount: unreadable,
                              scrobblerLogPresent: scrobblerLog)
    }

    /// "LYOT" then a little-endian u16. The header's checksum is NOT verified:
    /// the device's real `format.dat` carries `FF FF FF FF`, which is not the
    /// CRC of an empty tail, so a strict reader would reject the real iPod.
    public static func layoutVersion(formatDat: Data) -> Int? {
        let bytes = [UInt8](formatDat.prefix(formatDatCap))
        guard bytes.count == formatDatCap, bytes[0..<4] == [0x4c, 0x59, 0x4f, 0x54] else { return nil }
        return Int(bytes[4]) | Int(bytes[5]) << 8
    }

    public static func buildInfo(rockboxInfo: String) -> RockboxBuildInfo {
        let values = configValues(rockboxInfo)
        return RockboxBuildInfo(target: values["Target"].flatMap { $0.isEmpty ? nil : $0 },
                                version: values["Version"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Splits each line on its first ": ". Lines starting with "#", blank
    /// lines and lines without the separator are skipped; CRLF is tolerated.
    /// A key given twice keeps the last value.
    public static func configValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.range(of: ": ")
            else { continue }
            let key = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// The first `/<NAME0>` volume prefix in the player's own lines: a
    /// playlist line as is, a `.playlist_control` line after `P:<n>:`, a
    /// `playback.log` line after its third colon. Returned without the
    /// trailing slash.
    public static func playerPathPrefix(fromPlayerLines: [String]) -> String? {
        for raw in fromPlayerLines {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\r\n"))
            var candidates = [Substring(line)]
            if line.hasPrefix("P:") {
                let rest = line.dropFirst(2).drop(while: { $0.isASCII && $0.isNumber })
                if rest.first == ":" { candidates.append(rest.dropFirst()) }
            } else {
                let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                if parts.count == 4 { candidates.append(parts[3]) }
            }
            for candidate in candidates {
                if let prefix = volumePrefix(candidate) { return prefix }
            }
        }
        return nil
    }

    /// LYOT present is PodBox. Else all of PodBox's setup files and no
    /// `rocks/` is PodBox not yet booted. Else `rocks/` is stock. Else unknown.
    /// `rockboxEntries` are names inside `.rockbox` (plus "docs/settings-help.txt").
    public static func flavour(layout: Int?, rockboxEntries: Set<String>) -> RockboxFlavour {
        if layout != nil { return .podBox }
        let names = Set(rockboxEntries.map { $0.lowercased() })
        let hasRocks = names.contains("rocks")
        if !hasRocks, names.isSuperset(of: ["default-config.cfg", "trim.config", "docs/settings-help.txt"]) {
            return .podBox
        }
        return hasRocks ? .stockRockbox : .unknownRockbox
    }

    /// Lines whose last path component starts with "._".
    public static func appleDoubleCount(unreadableText: String) -> Int {
        lines(unreadableText).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.split(separator: "/").last else { return false }
            return last.hasPrefix("._")
        }.count
    }

    // MARK: - Helpers

    /// "/<HDD0>" when `text` starts `/<` + uppercase letters + digits + `>/`.
    private static func volumePrefix(_ text: Substring) -> String? {
        guard text.hasPrefix("/<") else { return nil }
        let body = text.dropFirst(2)
        let letters = body.prefix(while: { $0.isASCII && $0.isUppercase })
        let afterLetters = body.dropFirst(letters.count)
        let digits = afterLetters.prefix(while: { $0.isASCII && $0.isNumber })
        let tail = afterLetters.dropFirst(digits.count)
        guard !letters.isEmpty, !digits.isEmpty, tail.hasPrefix(">/") else { return nil }
        return "/<\(letters)\(digits)>"
    }

    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    }

    /// The first `*.m3u8` in the player's playlist folder by name. Hidden
    /// files (`._` twins among them) are skipped.
    /// A folder whose real path leaves the volume (a symlink) is not read.
    private static func firstPlayerPlaylist(in volumeRoot: URL, relativeFolder: String,
                                            fileManager: FileManager) -> URL? {
        let folder = relativeFolder.isEmpty ? volumeRoot : volumeRoot.appendingPathComponent(relativeFolder)
        guard DeviceWritePolicy.relativePath(of: folder, under: volumeRoot) != nil,
              let names = try? fileManager.contentsOfDirectory(atPath: folder.path)
        else { return nil }
        return names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == "m3u8" }
            .sorted()
            .first
            .map { folder.appendingPathComponent($0) }
    }

    /// At most `cap` bytes of a regular file, opened for reading only.
    private static func readCapped(_ url: URL, cap: Int, fileManager: FileManager) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: cap)) ?? Data()
    }
}
