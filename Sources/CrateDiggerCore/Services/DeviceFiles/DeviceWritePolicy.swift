import Foundation

/// What a file written to a device is for. The policy allows a write only by
/// role, each role with its own area and name rule (an allowlist), and only
/// for roles the caller enabled: that is how a phase or a manual check gates
/// a writer in one place.
public enum DeviceFileRole: String, Sendable, Hashable, CaseIterable {
    case audio, cover, temp                         // phase 1
    case artistPicture, artistFolderPicture         // phase 2
    case lyrics, playlist                           // phase 4
    case centralCover, ignoreMarker, knownArtists   // phase 5
}

/// Why a file is being deleted from a device.
public enum DeviceDeleteReason: String, Sendable, Hashable {
    /// A macOS `._` twin; the executor re-proves its bytes before deleting.
    case appleDouble
    /// A file the journal proves CrateDigger wrote.
    case ownedByCrateDigger
    /// An audio file the user chose to Replace (the duplicates spec).
    case userReplace
    /// A leftover `.cdtmp` from an interrupted write.
    case staleTemp
}

public enum DeviceWritePolicyError: Error, Equatable, LocalizedError {
    case forbidden(String)

    public var errorDescription: String? {
        switch self {
        case .forbidden(let reason): return "CrateDigger will not touch that file on the device: \(reason)."
        }
    }
}

/// The allowlist every device write and delete passes before any IO
/// (spec invariant I2). Pure: `checkWrite` and `checkDelete` never touch the
/// file system. Paths are relative to the volume root.
///
/// Comparison is by key: NFC, case-folded through upper case (so `ı` and `ſ`
/// fold as FAT's upper-casing would), each component trimmed of trailing dots
/// and spaces, because FAT ignores case and drops those characters. Paths are
/// stricter than keys: a component ending in a dot or a space, or holding a
/// FAT short name's `~<digit>`, is refused outright, since it may name a
/// different file on the device than it does here (`.rockbox.`, `ROCKBO~1`).
public struct DeviceWritePolicy: Sendable {
    /// Folders that are never written or deleted in, whatever the profile says.
    public static let deniedTrees = [
        ".rockbox", ".rockbox_backup", ".backup", "iPod_Control", ".Trashes", ".Spotlight-V100", ".fseventsd",
    ]
    /// The player's own log at the volume root: read, never written.
    static let scrobblerLogKey = ".scrobbler.log"
    /// The single exception to the denied trees (phase 5, behind M13).
    static let knownArtistsKey = ".rockbox/library/user/known_artists.txt"

    /// What a `._` twin may belong to for an AppleDouble delete (spec D21):
    /// audio, pictures, playlists, lyrics and documents PodBox reads. The
    /// policy's own audio extensions count too. Other twins are not ours to tidy.
    public static let appleDoubleMediaExtensions: Set<String> = LibraryScanService.defaultSupportedExtensions.union([
        "jpg", "jpeg", "png", "bmp", "gif", "webp", "m3u", "m3u8", "lrc", "lrc8", "snc", "epub", "pdf", "cue",
    ])

    private static let deniedKeys = Set(deniedTrees.map(componentKey))
    private static let tempSuffix = ".cdtmp"

    public let musicSubpath: String
    public let playlistDirectory: String
    public let audioExtensions: Set<String>
    public let enabledRoles: Set<DeviceFileRole>

    private let musicKeys: [String]
    private let playlistKeys: [String]

    public init(musicSubpath: String, playlistDirectory: String = "Playlists",
                audioExtensions: Set<String> = LibraryScanService.defaultSupportedExtensions,
                enabledRoles: Set<DeviceFileRole> = [.audio, .cover, .temp]) {
        self.musicSubpath = musicSubpath
        self.playlistDirectory = playlistDirectory
        self.audioExtensions = Set(audioExtensions.map { $0.lowercased() })
        self.enabledRoles = enabledRoles
        musicKeys = Self.keyComponents(musicSubpath)
        playlistKeys = Self.keyComponents(playlistDirectory)
    }

    // MARK: - Checks

    public func checkWrite(_ relativePath: String, role: DeviceFileRole) throws {
        let keys = try Self.validatedKeys(relativePath)
        // The one exception, matched on its exact key before the denied trees.
        if role == .knownArtists {
            guard enabledRoles.contains(.knownArtists) else { throw forbidden("known artists writing is off") }
            guard keys.joined(separator: "/") == Self.knownArtistsKey else {
                throw forbidden("the known artists file has one fixed place")
            }
            return
        }
        try Self.refuseProtected(keys)
        guard enabledRoles.contains(role) else { throw forbidden("\(role.rawValue) files are not enabled") }
        try checkArea(relativePath, keys: keys, role: role)
    }

    public func checkDelete(_ relativePath: String, reason: DeviceDeleteReason) throws {
        let keys = try Self.validatedKeys(relativePath)
        try Self.refuseProtected(keys)
        switch reason {
        case .userReplace:
            try checkWrite(relativePath, role: .audio)
        case .staleTemp:
            try checkWrite(relativePath, role: .temp)
        case .appleDouble:
            let name = relativePath.split(separator: "/").last.map(String.init) ?? ""
            guard name.hasPrefix("._"), name.count > 2 else { throw forbidden("not a ._ file") }
            let twinOf = (String(name.dropFirst(2)) as NSString).pathExtension.lowercased()
            guard Self.appleDoubleMediaExtensions.contains(twinOf) || audioExtensions.contains(twinOf) else {
                throw forbidden("only the macOS twins of media files are removed")
            }
        case .ownedByCrateDigger:
            let passes = enabledRoles.contains { (try? checkWrite(relativePath, role: $0)) != nil }
            guard passes else { throw forbidden("no enabled writer may own that path") }
        }
    }

    // MARK: - Keys and paths

    /// NFC, case-folded, components trimmed of trailing dots and spaces. The journal uses the same key.
    public static func key(forRelativePath path: String) -> String {
        keyComponents(path).joined(separator: "/")
    }

    /// Relative path of `url` under `root` after resolving symlinks; nil when
    /// it leaves the root. Any `.` or `..` component, or a symlink that points
    /// nowhere, also gives nil. Missing trailing components are kept as
    /// written, so this works for a file about to be created. `""` is the root.
    public static func relativePath(of url: URL, under root: URL) -> String? {
        guard let rootReal = realPath(root.path) else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }

        // The deepest ancestor that exists, resolved; the rest cannot be a
        // symlink because it does not exist yet.
        var existingCount = parts.count
        var resolved: String?
        while existingCount >= 0 {
            let candidate = "/" + parts.prefix(existingCount).joined(separator: "/")
            var info = stat()
            if lstat(candidate, &info) == 0 {
                guard let real = realPath(candidate) else { return nil } // dangling symlink
                resolved = real
                break
            }
            existingCount -= 1
        }
        guard let base = resolved else { return nil }
        let full = ([base == "/" ? "" : base] + parts.dropFirst(existingCount)).joined(separator: "/")
        if full == rootReal { return "" }
        let prefix = rootReal == "/" ? "/" : rootReal + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    // MARK: - Private

    private func forbidden(_ reason: String) -> DeviceWritePolicyError { .forbidden(reason) }

    private static func componentKey(_ component: String) -> String {
        var key = component.precomposedStringWithCanonicalMapping.uppercased().lowercased()
        while let last = key.last, last == "." || last == " " { key.removeLast() }
        return key
    }

    private static func keyComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { componentKey(String($0)) }
    }

    /// Refuses empty and absolute paths, empty components, `.` and `..`, a
    /// component ending in a dot or a space (FAT drops those, so it would name
    /// another file), and one holding `~<digit>` (a FAT short name such as
    /// `ROCKBO~1` can be an alias of a protected folder). Returns the component keys.
    private static func validatedKeys(_ path: String) throws -> [String] {
        guard !path.isEmpty else { throw DeviceWritePolicyError.forbidden("empty path") }
        guard !path.hasPrefix("/") else { throw DeviceWritePolicyError.forbidden("absolute path") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component == "." || component == ".." {
                throw DeviceWritePolicyError.forbidden("path leaves its folder")
            }
            if component.hasSuffix(".") || component.hasSuffix(" ") {
                throw DeviceWritePolicyError.forbidden("a name ending in a dot or a space")
            }
            if hasShortNameMarker(component) {
                throw DeviceWritePolicyError.forbidden("a FAT short name (~ and a digit)")
            }
            if componentKey(component).isEmpty {
                throw DeviceWritePolicyError.forbidden("empty path component")
            }
        }
        return components.map(componentKey)
    }

    private static func hasShortNameMarker(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        return scalars.indices.dropLast().contains { scalars[$0] == "~" && ("0"..."9").contains(scalars[$0 + 1]) }
    }

    /// The denied trees, on every component (a `Music/.rockbox` folder is
    /// refused too: odd, and not worth being wrong about), and the root
    /// `.scrobbler.log`.
    private static func refuseProtected(_ keys: [String]) throws {
        if let denied = keys.first(where: { deniedKeys.contains($0) }) {
            throw DeviceWritePolicyError.forbidden("\(denied) belongs to the player")
        }
        if keys == [scrobblerLogKey] {
            throw DeviceWritePolicyError.forbidden("the scrobbler log belongs to the player")
        }
    }

    /// The area and name rule for `role` (the spec's role table).
    private func checkArea(_ path: String, keys: [String], role: DeviceFileRole) throws {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        let nameKey = keys.last ?? ""
        let folder = Array(keys.dropLast())
        let ext = (nameKey as NSString).pathExtension

        // Nothing CrateDigger writes is named like a macOS AppleDouble twin.
        guard !name.hasPrefix("._") else { throw forbidden("._ names are macOS metadata") }

        switch role {
        case .audio:
            guard isAudioFolder(folder) else { throw forbidden("audio goes in the music folder") }
            guard audioExtensions.contains(ext) else { throw forbidden("\(name) is not an audio file") }
        case .cover:
            guard isAudioFolder(folder) else { throw forbidden("covers go beside the music") }
            guard nameKey == "cover.jpg" else { throw forbidden("a cover is named cover.jpg") }
        case .temp:
            guard nameKey.hasSuffix(Self.tempSuffix), nameKey.count > Self.tempSuffix.count else {
                throw forbidden("a temp file ends in .cdtmp")
            }
            let target = String(path.dropLast(Self.tempSuffix.count))
            let allowed = enabledRoles.subtracting([.temp, .knownArtists]).contains {
                (try? checkWrite(target, role: $0)) != nil
            }
            guard allowed else { throw forbidden("a temp file sits beside a file CrateDigger may write") }
        case .artistPicture:
            guard folder == ["artwork", "people"], ext == "jpg" else {
                throw forbidden("artist pictures are JPEGs directly in Artwork/People")
            }
        case .centralCover:
            guard folder == ["artwork", "covers"], ext == "jpg" else {
                throw forbidden("central covers are JPEGs directly in Artwork/Covers")
            }
        case .artistFolderPicture:
            guard isSubfolderOfMusic(folder), nameKey == "folder.jpg" else {
                throw forbidden("a folder picture is folder.jpg in a folder under the music folder")
            }
        case .lyrics:
            guard isAudioFolder(folder), ext == "lrc8" else {
                throw forbidden("lyrics are .lrc8 files beside the music")
            }
        case .playlist:
            guard folder == playlistKeys, ext == "m3u8" else {
                throw forbidden("playlists are .m3u8 files directly in the playlist folder")
            }
        case .ignoreMarker:
            guard isSubfolderOfMusic(folder), nameKey == "database.ignore" || nameKey == "database.unignore" else {
                throw forbidden("an ignore marker sits in a folder under the music folder")
            }
        case .knownArtists:
            throw forbidden("the known artists file has one fixed place") // handled in checkWrite
        }
    }

    /// The music folder or below it. With an empty music folder (a
    /// direct-file player) that is the whole volume, minus the denied trees.
    private func isAudioFolder(_ folder: [String]) -> Bool {
        folder.count >= musicKeys.count && Array(folder.prefix(musicKeys.count)) == musicKeys
    }

    private func isSubfolderOfMusic(_ folder: [String]) -> Bool {
        folder.count > musicKeys.count && isAudioFolder(folder)
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}
