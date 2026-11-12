import Foundation

/// Which Rockbox a device runs, as far as its `.rockbox` folder tells.
public enum RockboxFlavour: String, Codable, Sendable {
    /// PodBox: `library/format.dat` starts `LYOT`, or the folder holds
    /// PodBox's own setup files and the player has not started on them yet.
    case podBox
    /// Stock Rockbox (or RockPod): a `rocks/` plugin folder, no PodBox layout.
    case stockRockbox
    /// A `.rockbox` folder that says neither.
    case unknownRockbox
}

/// What `rockbox-info.txt` says about the build.
public struct RockboxBuildInfo: Equatable, Codable, Sendable {
    /// "ipodvideo", "ipod6g".
    public let target: String?
    /// Raw, e.g. "-261108" (empty hash, built 2026-11-08) or "abc1234-250101".
    public let version: String?
    /// The part before the trailing `-YYMMDD`; nil when empty or when the
    /// version carries no date (a release tag such as "v4.0").
    public let gitHash: String?
    /// Year, month and day from a trailing `-YYMMDD`, read as 20YY.
    public let buildDate: DateComponents?

    public init(target: String?, version: String?) {
        self.target = target
        self.version = version
        let parsed = version.flatMap(Self.parseVersion)
        gitHash = parsed?.hash
        buildDate = parsed?.date
    }

    public var modelName: String {
        switch target {
        case nil: return "iPod"
        case "ipodvideo": return "iPod Video"
        case "ipod6g": return "iPod Classic"
        case let other?: return "iPod (\(other))"
        }
    }

    /// `<git hash>-<YYMMDD>` per Rockbox's `tools/version.sh`.
    private static func parseVersion(_ version: String) -> (hash: String?, date: DateComponents)? {
        guard let dash = version.lastIndex(of: "-") else { return nil }
        let digits = version[version.index(after: dash)...]
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let chars = Array(digits)
        guard let yy = Int(String(chars[0...1])), let mm = Int(String(chars[2...3])),
              let dd = Int(String(chars[4...5])),
              (1...12).contains(mm), (1...31).contains(dd)
        else { return nil }
        let hash = String(version[..<dash])
        return (hash.isEmpty ? nil : hash, DateComponents(year: 2000 + yy, month: mm, day: dd))
    }
}

/// The player's `play log` setting.
public enum PlayLogMode: String, Sendable {
    case off, on
    case lastFM = "last.fm"
}

/// The player's settings, layered: PodBox's built-in defaults (only those
/// CrateDigger reads), then `default-config.cfg`, then `config.cfg`. The
/// player writes only non-default settings to `config.cfg`, which is why the
/// defaults table is needed at all.
public struct PodBoxConfig: Equatable, Sendable {
    /// From `apps-ipod/settings/settings_list.c` (brief, Appendix F).
    public static let defaults: [String: String] = [
        "play log": "on",
        "playlist catalog directory": "/Playlists",
        "database scan paths": "/",
        "year from folder": "off",
        "skip ipod games": "on",
        "database artist art": "on",
        "database album art": "on",
        "featured artists": "off",
        "playlist engine": "off",
    ]

    private let values: [String: String]

    public init(defaultConfig: String?, config: String?) {
        var merged = Self.defaults
        for text in [defaultConfig, config].compactMap({ $0 }) {
            merged.merge(DeviceFirmwareProbe.configValues(text)) { _, new in new }
        }
        values = merged
    }

    public func value(_ key: String) -> String? { values[key] }

    public var playLogMode: PlayLogMode {
        value("play log").flatMap { PlayLogMode(rawValue: $0.lowercased()) } ?? .on
    }

    /// Relative to the volume root, without the leading "/".
    public var playlistDirectory: String {
        let raw = value("playlist catalog directory") ?? "/Playlists"
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty && raw.isEmpty ? "Playlists" : trimmed
    }

    /// Colon separated in the setting, as Rockbox stores its path lists.
    public var scanPaths: [String] {
        let paths = (value("database scan paths") ?? "/")
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? ["/"] : paths
    }

    public var yearFromFolder: Bool { isOn("year from folder") }
    public var artistArt: Bool { isOn("database artist art") }
    public var featuredArtists: Bool { isOn("featured artists") }

    private func isOn(_ key: String) -> Bool { value(key)?.lowercased() == "on" }
}

/// Everything a mount-time probe learned about a Rockbox device. Read-only:
/// producing one never writes to the device.
public struct DeviceFirmware: Equatable, Sendable {
    /// The PodBox library layout this build of CrateDigger was written against.
    public static let knownLayout = 5

    public let flavour: RockboxFlavour
    /// `format.dat`'s u16; nil = never booted, or not PodBox.
    public let layout: Int?
    public let build: RockboxBuildInfo?
    public let config: PodBoxConfig
    /// "/<HDD0>", learned from the player's own files.
    public let playerPathPrefix: String?
    public let playerName: String?
    /// Lines of `unreadable.txt` naming a "._" file.
    public let unreadableAppleDoubleCount: Int
    /// `/.scrobbler.log` exists at the volume root (stat only, never opened by the probe).
    public let scrobblerLogPresent: Bool

    public init(flavour: RockboxFlavour, layout: Int?, build: RockboxBuildInfo?,
                config: PodBoxConfig = PodBoxConfig(defaultConfig: nil, config: nil),
                playerPathPrefix: String? = nil, playerName: String? = nil,
                unreadableAppleDoubleCount: Int = 0, scrobblerLogPresent: Bool = false) {
        self.flavour = flavour
        self.layout = layout
        self.build = build
        self.config = config
        self.playerPathPrefix = playerPathPrefix
        self.playerName = playerName
        self.unreadableAppleDoubleCount = unreadableAppleDoubleCount
        self.scrobblerLogPresent = scrobblerLogPresent
    }

    public var modelName: String { build?.modelName ?? "iPod" }

    /// "PodBox · iPod Video · build 8 Nov 2026 · library layout 5".
    public var summaryLine: String {
        guard flavour == .podBox else { return "Rockbox · \(modelName)" }
        guard let layout else { return "PodBox, not started yet · \(modelName)" }
        var parts = ["PodBox", modelName]
        if let date = build?.buildDate.flatMap(Self.formatBuildDate) { parts.append("build \(date)") }
        parts.append("library layout \(layout)")
        return parts.joined(separator: " · ")
    }

    /// Why some features are held back, or nil when nothing is.
    public var layoutNotice: String? {
        guard flavour == .podBox else { return nil }
        guard let layout else { return "Start the iPod once so PodBox can finish setting up" }
        if layout > Self.knownLayout {
            return "This iPod runs a newer PodBox library layout (\(layout)) than CrateDigger knows (\(Self.knownLayout))"
        }
        return nil
    }

    private static func formatBuildDate(_ components: DateComponents) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// What CrateDigger may offer for a mounted device, decided once at mount
/// from the probe and the volume's file system.
public struct DeviceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let appleDoubleSweep = DeviceCapabilities(rawValue: 1 << 0)
    public static let coverSidecar = DeviceCapabilities(rawValue: 1 << 1)
    public static let centralPeopleArtwork = DeviceCapabilities(rawValue: 1 << 2)
    public static let playlistCatalog = DeviceCapabilities(rawValue: 1 << 3)
    public static let playbackLogImport = DeviceCapabilities(rawValue: 1 << 4)
    public static let scrobblerLogImport = DeviceCapabilities(rawValue: 1 << 5)
    public static let lyricsSidecar = DeviceCapabilities(rawValue: 1 << 6)

    /// `fileSystem` is the volume's type name: "msdos", "exfat", "apfs", ...
    /// A nil `firmware` means the device has no `.rockbox` folder.
    public init(firmware: DeviceFirmware?, fileSystem: String?) {
        var caps: DeviceCapabilities = []
        if let fileSystem, ["msdos", "exfat"].contains(fileSystem.lowercased()) {
            caps.insert(.appleDoubleSweep)
        }
        guard let firmware else {
            self = caps
            return
        }
        caps.insert(.coverSidecar)
        if firmware.scrobblerLogPresent { caps.insert(.scrobblerLogImport) }
        if firmware.flavour == .podBox {
            // File features: they depend on the firmware, not on its library
            // layout, so a newer or not-yet-started PodBox keeps them.
            caps.insert(.centralPeopleArtwork)
            if firmware.playerPathPrefix != nil,
               !Self.isInDeniedTree(firmware.config.playlistDirectory) {
                caps.insert(.playlistCatalog)
            }
            // Read-back and lyrics are proven only against layout 5.
            if firmware.layout == DeviceFirmware.knownLayout {
                caps.insert(.lyricsSidecar)
                caps.insert(.playbackLogImport)
            }
        }
        self = caps
    }

    /// The playlist folder's first component names one of the player's own trees.
    private static func isInDeniedTree(_ relativePath: String) -> Bool {
        guard let first = DeviceWritePolicy.key(forRelativePath: relativePath).split(separator: "/").first
        else { return false }
        return DeviceWritePolicy.deniedTrees.contains { DeviceWritePolicy.key(forRelativePath: $0) == first }
    }
}
