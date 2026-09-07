import Foundation

/// Artwork you have imported but not committed.
///
/// Imports used to land straight in the album folder, which made "let me look
/// at these first" impossible: by the time you saw the images they were already
/// in your library. Staged files live in the app's cache instead, and the album
/// folder is untouched until SAVE.
///
/// The staging folder is deterministic per album and carries its own role
/// sidecar, so a pending import survives closing the search panel — or the app.
/// Everything about a pending artwork edit that isn't the image bytes: the
/// roles chosen for the staged files, the disc numbers, which existing files
/// are marked for removal, and whether the embedded picture is to be stripped.
///
/// Saved beside the staged images so a whole pending session survives closing
/// the panel, switching albums, or quitting — which is what makes "you have
/// unsaved artwork" a warning you can act on rather than a loss report.
public struct StagedArtworkInfo: Codable, Equatable, Sendable {
    public var roles: [String: ArtworkRole]
    public var discNumbers: [String: Int]
    public var releaseMBID: String?
    /// The album folder this session belongs to. Recorded so the launch sweep
    /// can tell a live session from one whose album has since been deleted or
    /// moved — the staging folder's own name is a hash and can't be reversed.
    public var albumFolderPath: String?
    /// Filenames in the *album* folder the user marked for the Trash.
    public var removals: [String]
    public var stripEmbedded: Bool

    public init(roles: [String: ArtworkRole] = [:],
                discNumbers: [String: Int] = [:],
                releaseMBID: String? = nil,
                albumFolderPath: String? = nil,
                removals: [String] = [],
                stripEmbedded: Bool = false) {
        self.roles = roles
        self.discNumbers = discNumbers
        self.releaseMBID = releaseMBID
        self.albumFolderPath = albumFolderPath
        self.removals = removals
        self.stripEmbedded = stripEmbedded
    }

    public var hasMarks: Bool { !removals.isEmpty || stripEmbedded }

    /// True when this session holds no user intent at all. `releaseMBID` alone
    /// doesn't count — it's a breadcrumb from the search panel, not a change,
    /// and treating it as one kept empty sidecars alive forever.
    public var isIdle: Bool {
        roles.isEmpty && discNumbers.isEmpty && removals.isEmpty && !stripEmbedded
    }
}

public enum ArtworkStaging {
    private static let infoFilename = "cratedigger-staging.json"

    /// Where this album's pending images live. Deterministic, so any part of
    /// the app can find them again without being handed a path.
    public static func folder(forAlbumFolder albumFolder: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("CrateDigger", isDirectory: true)
            .appendingPathComponent("ArtworkStaging", isDirectory: true)
            .appendingPathComponent(key(for: albumFolder), isDirectory: true)
    }

    /// A filesystem-safe, collision-resistant name for an album folder path.
    static func key(for albumFolder: URL) -> String {
        let path = albumFolder.standardizedFileURL.path
        // Not a cryptographic use — this only has to be stable and unique
        // enough to keep two albums' pending imports apart.
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let leaf = albumFolder.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(40)
        return "\(leaf)-\(String(hash, radix: 36))"
    }

    @discardableResult
    public static func makeFolder(forAlbumFolder albumFolder: URL) throws -> URL {
        let url = folder(forAlbumFolder: albumFolder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every staged image, sorted by name so the grid order is stable.
    public static func stagedFiles(forAlbumFolder albumFolder: URL) -> [URL] {
        let url = folder(forAlbumFolder: albumFolder)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.lastPathComponent != infoFilename }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The pending session's non-image state.
    public static func saveInfo(_ info: StagedArtworkInfo, forAlbumFolder albumFolder: URL) {
        var info = info
        info.albumFolderPath = albumFolder.standardizedFileURL.path
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? FileManager.default.createDirectory(at: folder(forAlbumFolder: albumFolder),
                                                 withIntermediateDirectories: true)
        let url = folder(forAlbumFolder: albumFolder).appendingPathComponent(infoFilename)
        try? data.write(to: url, options: .atomic)
    }

    public static func info(forAlbumFolder albumFolder: URL) -> StagedArtworkInfo {
        let url = folder(forAlbumFolder: albumFolder).appendingPathComponent(infoFilename)
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(StagedArtworkInfo.self, from: data)
        else { return StagedArtworkInfo() }
        return info
    }

    /// True when this album has *anything* waiting — staged images or marks.
    public static func hasPending(forAlbumFolder albumFolder: URL) -> Bool {
        !stagedFiles(forAlbumFolder: albumFolder).isEmpty
            || info(forAlbumFolder: albumFolder).hasMarks
    }

    /// Throw the pending import away. Called by DISCARD, and after a commit.
    public static func clear(forAlbumFolder albumFolder: URL) {
        try? FileManager.default.removeItem(at: folder(forAlbumFolder: albumFolder))
    }


    /// Delete pending sessions that can no longer be finished, and any that
    /// have been sitting untouched for `maxAge`.
    ///
    /// Staged images are cached, not owned: a session the user walked away
    /// from months ago is dead weight, and one whose album has since moved or
    /// been deleted can never be committed at all. Everything a live session
    /// needs is rewritten on every edit, so age is measured from the most
    /// recent file in the folder.
    ///
    /// Returns how many sessions were removed.
    @discardableResult
    public static func sweep(maxAge: TimeInterval = 30 * 24 * 60 * 60,
                             now: Date = Date()) -> Int {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = caches
            .appendingPathComponent("CrateDigger", isDirectory: true)
            .appendingPathComponent("ArtworkStaging", isDirectory: true)

        guard let sessions = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return 0 }

        var removed = 0
        for session in sessions {
            guard shouldSweep(session, maxAge: maxAge, now: now, fileManager: fm) else { continue }
            if (try? fm.removeItem(at: session)) != nil { removed += 1 }
        }
        return removed
    }

    /// The decision, split out so the rule is readable on its own: gone album,
    /// nothing in it, or untouched for too long.
    static func shouldSweep(_ session: URL,
                            maxAge: TimeInterval,
                            now: Date,
                            fileManager fm: FileManager) -> Bool {
        let contents = (try? fm.contentsOfDirectory(
            at: session, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        if contents.isEmpty { return true }

        // The album it belongs to is gone: this session can never be committed.
        let infoURL = session.appendingPathComponent(infoFilename)
        if let data = try? Data(contentsOf: infoURL),
           let info = try? JSONDecoder().decode(StagedArtworkInfo.self, from: data),
           let path = info.albumFolderPath,
           !fm.fileExists(atPath: path) {
            return true
        }

        // Only a sidecar, no images and nothing marked — nothing to finish.
        let images = contents.filter { $0.lastPathComponent != infoFilename }
        if images.isEmpty {
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? JSONDecoder().decode(StagedArtworkInfo.self, from: data)
            else { return true }
            if info.isIdle { return true }
        }

        let newest = contents.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        guard let newest else { return false }
        return now.timeIntervalSince(newest) > maxAge
    }
}

/// How far a background artwork fetch has got. Lives in Core so the count and
/// the wording of "12 of 27" are one decidable value rather than a string built
/// in two different views.
public struct ArtworkFetchProgress: Equatable, Sendable {
    public let albumID: String
    public let albumTitle: String
    public var done: Int
    public let total: Int

    public init(albumID: String, albumTitle: String, done: Int, total: Int) {
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.done = done
        self.total = total
    }

    /// 0…1, and never divides by zero for an empty batch.
    public var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    /// The one line the ART tab shows: "FETCHING 12 OF 27".
    public var label: String { "FETCHING \(min(done + 1, total)) OF \(total)" }
}
