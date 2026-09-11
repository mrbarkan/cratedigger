import Foundation

public enum FolderStructureMode: String, Codable, CaseIterable, Sendable {
    case sourceRelative = "source_relative"
    case flat
    case metadataTemplate = "metadata_template"

    public var title: String {
        switch self {
        case .sourceRelative:
            return "Source Relative"
        case .flat:
            return "Flat"
        case .metadataTemplate:
            return "Metadata Template"
        }
    }
}

public enum FolderToken: String, Codable, CaseIterable, Sendable {
    case disabled
    case year
    case albumArtist = "album_artist"
    case album
    case compilation
    case genre

    public var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .year:
            return "Year"
        case .albumArtist:
            return "Album Artist"
        case .album:
            return "Album"
        case .compilation:
            return "Compilation"
        case .genre:
            return "Genre"
        }
    }

    public var isDisabled: Bool {
        self == .disabled
    }
}

/// What follows a token in the folder pattern: `slash` ends the current folder
/// (the next token starts a new one); `space` keeps the next token in the same
/// folder, so tokens can be grouped like "1998 OK Computer".
public enum FolderSeparator: String, Codable, Sendable {
    case slash = "/"
    case space = " "
}

public enum TemplatePreset: String, Codable, CaseIterable, Sendable {
    case artistYearAlbum
    case yearArtistAlbum
    case artistAlbumYear
    case custom

    public var title: String {
        switch self {
        case .artistYearAlbum:
            return "Album Artist / Year / Album"
        case .yearArtistAlbum:
            return "Year / Album Artist / Album"
        case .artistAlbumYear:
            return "Album Artist / Album / Year"
        case .custom:
            return "Custom Order"
        }
    }

    public var defaultTokenOrder: [FolderToken] {
        switch self {
        case .artistYearAlbum:
            return [.albumArtist, .year, .album]
        case .yearArtistAlbum:
            return [.year, .albumArtist, .album]
        case .artistAlbumYear:
            return [.albumArtist, .album, .year]
        case .custom:
            return [.year, .albumArtist, .album, .compilation, .disabled]
        }
    }
}

public struct FolderTemplateConfig: Hashable, Codable, Sendable {
    public let preset: TemplatePreset
    public let tokenOrder: [FolderToken]
    /// Separator after `tokenOrder[i]`. Empty (every preset, and any config written
    /// before this field existed) means every gap is a folder break — the original
    /// all-`/` behavior. Read defensively by index so any length is tolerated.
    public let separators: [FolderSeparator]

    public init(preset: TemplatePreset, tokenOrder: [FolderToken], separators: [FolderSeparator] = []) {
        self.preset = preset
        self.tokenOrder = tokenOrder
        self.separators = separators
    }

    private enum CodingKeys: String, CodingKey { case preset, tokenOrder, separators }

    /// Back-compatible decode: device profiles / selections saved before separators
    /// existed simply have no key, so they decode as `[]` (all-`/`, unchanged).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decode(TemplatePreset.self, forKey: .preset)
        tokenOrder = try container.decode([FolderToken].self, forKey: .tokenOrder)
        separators = try container.decodeIfPresent([FolderSeparator].self, forKey: .separators) ?? []
    }
}

public struct AlbumFolderKey: Hashable, Sendable, Codable {
    public let artistBucket: String
    public let album: String
    public let year: String
    /// Distinguishes same-tagged albums that live in different source folders —
    /// two rips/pressings of one release whose tags are identical. nil for the
    /// primary (or only) copy, so keys persisted before this field existed keep
    /// matching: synthesized Codable decodes an absent field as nil and omits
    /// nil on encode. Assigned by `LibraryIndex.build`; tag-derived keys from
    /// `albumFolderKey(for:)` always carry nil.
    public let discriminator: String?

    public init(artistBucket: String, album: String, year: String, discriminator: String? = nil) {
        self.artistBucket = artistBucket
        self.album = album
        self.year = year
        self.discriminator = discriminator
    }

    /// This key with a different discriminator.
    public func discriminated(_ discriminator: String?) -> AlbumFolderKey {
        AlbumFolderKey(artistBucket: artistBucket, album: album, year: year, discriminator: discriminator)
    }
}

public struct PlannedOutputPath: Hashable, Sendable {
    public let destinationURL: URL
    public let relativeSubpath: String?

    public init(destinationURL: URL, relativeSubpath: String?) {
        self.destinationURL = destinationURL
        self.relativeSubpath = relativeSubpath
    }
}

public struct OutputPathPlanner {
    private let fileManager: FileManager
    private let unknownArtist: String
    private let unknownAlbum: String
    private let unknownYear: String

    public init(
        fileManager: FileManager = .default,
        unknownArtist: String = "Unknown Artist",
        unknownAlbum: String = "Unknown Album",
        unknownYear: String = "Unknown Year"
    ) {
        self.fileManager = fileManager
        self.unknownArtist = unknownArtist
        self.unknownAlbum = unknownAlbum
        self.unknownYear = unknownYear
    }

    public func albumFolderKey(for loadedTrack: LoadedTrack) -> AlbumFolderKey {
        AlbumFolderKey(
            artistBucket: resolvedAlbumArtistComponent(for: loadedTrack),
            album: resolvedAlbumComponent(for: loadedTrack),
            year: resolvedYearComponent(for: loadedTrack)
        )
    }

    /// Pass the `albumKey` from `albumFolderKeys(for:)` whenever the whole
    /// batch is in hand: the album-artist / album / year tokens then read the
    /// album's reconciled identity, so a soundtrack lands in one Various Artists
    /// folder instead of one folder per performer. Without it the tokens read
    /// the single file's tags, which is all a lone track can offer.
    public func buildOutputSubpath(
        for loadedTrack: LoadedTrack,
        templateConfig: FolderTemplateConfig,
        albumKey: AlbumFolderKey? = nil
    ) -> String {
        let tokenOrder = (templateConfig.preset == .custom)
            ? templateConfig.tokenOrder
            : templateConfig.preset.defaultTokenOrder
        // Presets are always one-folder-per-token; only custom order carries the
        // user's separators. Empty separators ⇒ every gap is `/` (original behavior).
        let separators = (templateConfig.preset == .custom) ? templateConfig.separators : []

        // Group token values into folder levels: a `/` after a token ends the
        // current folder; a `space` keeps the next token in the same folder.
        var levels: [[String]] = [[]]
        for (i, token) in tokenOrder.enumerated() {
            if let value = tokenValue(for: token, loadedTrack: loadedTrack, albumKey: albumKey) {
                levels[levels.count - 1].append(value)
            }
            if i < tokenOrder.count - 1 {
                let separator = i < separators.count ? separators[i] : .slash
                if separator == .slash { levels.append([]) }
            }
        }
        let components = levels
            .map { $0.joined(separator: " ") }
            .filter { !$0.isEmpty }

        let fallbackPath = [
            albumKey?.year ?? resolvedYearComponent(for: loadedTrack),
            albumKey?.artistBucket ?? resolvedAlbumArtistComponent(for: loadedTrack),
            albumKey?.album ?? resolvedAlbumComponent(for: loadedTrack)
        ].joined(separator: "/")
        let rawPath = components.joined(separator: "/")

        return sanitizeRelativeSubpath(rawPath, fallback: fallbackPath)
    }

    public func planDestination(
        for loadedTrack: LoadedTrack,
        preset: ConversionPreset,
        destinationRoot: URL,
        sourceRoot: URL?,
        folderMode: FolderStructureMode,
        templateConfig: FolderTemplateConfig,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:],
        reservedDestinationPaths: Set<String> = [],
        destinationFileExtension: String? = nil,
        baseNameOverride: String? = nil,
        avoidExistingFiles: Bool = true,
        albumKey: AlbumFolderKey? = nil
    ) -> PlannedOutputPath {
        let track = loadedTrack.track
        let sourceDirectory = track.fileURL.deletingLastPathComponent()
        var outputDirectory = destinationRoot
        var relativeSubpath: String?

        switch folderMode {
        case .sourceRelative:
            if let root = sourceRoot {
                let rootComponents = root.standardizedFileURL.pathComponents
                let sourceComponents = sourceDirectory.standardizedFileURL.pathComponents
                if sourceComponents.starts(with: rootComponents) {
                    let relativeComponents = Array(sourceComponents.dropFirst(rootComponents.count))
                    if !relativeComponents.isEmpty {
                        relativeSubpath = relativeComponents.joined(separator: "/")
                        for component in relativeComponents {
                            outputDirectory.appendPathComponent(component, isDirectory: true)
                        }
                    }
                }
            }
        case .flat:
            break
        case .metadataTemplate:
            let key = albumKey ?? albumFolderKey(for: loadedTrack)
            let subpath = reviewedAlbumFolders[key]
                ?? buildOutputSubpath(for: loadedTrack, templateConfig: templateConfig, albumKey: key)
            relativeSubpath = subpath
            for component in subpath.split(separator: "/").map(String.init) where !component.isEmpty {
                outputDirectory.appendPathComponent(component, isDirectory: true)
            }
        }

        // Record Divider splits name each output by track number + title rather
        // than the (shared) source-side filename.
        let rawBaseName = baseNameOverride ?? track.fileURL.deletingPathExtension().lastPathComponent
        let baseName = PathComponentSanitizer.sanitize(rawBaseName, fallback: "Track")
        let outputExtension = normalizedFileExtension(destinationFileExtension) ?? preset.outputExtension
        let destinationURL = uniqueDestinationURL(
            in: outputDirectory,
            baseName: baseName,
            extension: outputExtension,
            reservedDestinationPaths: reservedDestinationPaths,
            avoidExistingFiles: avoidExistingFiles
        )

        return PlannedOutputPath(
            destinationURL: destinationURL,
            relativeSubpath: relativeSubpath
        )
    }

    /// Returns a destination that doesn't collide with other jobs in this batch
    /// (`reservedDestinationPaths`). When `avoidExistingFiles` is true it also
    /// steps past files already on disk (the ` (2)` "keep both" behavior); when
    /// false it returns the natural path even if a file is already there, so the
    /// caller can decide to skip or overwrite it.
    private func uniqueDestinationURL(
        in directory: URL,
        baseName: String,
        extension fileExtension: String,
        reservedDestinationPaths: Set<String>,
        avoidExistingFiles: Bool
    ) -> URL {
        // Fold both sides once so batch reservations and candidates compare the
        // way the (case-insensitive, APFS-default) destination volume does.
        let reservedKeys = Set(reservedDestinationPaths.map(collisionKey(forPath:)))
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        var attempt = 1

        // ponytail: O(m²) attempts for m same-named files, but each attempt is
        // now string work plus at most one fileExists stat — no symlink walk.
        while true {
            let candidateName = attempt == 1 ? baseName : "\(baseName) (\(attempt))"
            let candidatePath = (directoryPath as NSString)
                .appendingPathComponent("\(candidateName).\(fileExtension)")

            let clashesWithBatch = reservedKeys.contains(collisionKey(forPath: candidatePath))
            let clashesWithDisk = avoidExistingFiles && fileManager.fileExists(atPath: candidatePath)
            if !clashesWithBatch && !clashesWithDisk {
                return directory
                    .appendingPathComponent(candidateName)
                    .appendingPathExtension(fileExtension)
            }

            attempt += 1
        }
    }

    private func normalizedFileExtension(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix(".") {
            value.removeFirst()
        }
        value = value.replacingOccurrences(of: "/", with: "")
        value = value.replacingOccurrences(of: ":", with: "")
        value = value.replacingOccurrences(of: "\\", with: "")
        return value.isEmpty ? nil : value
    }

    private func tokenValue(
        for token: FolderToken,
        loadedTrack: LoadedTrack,
        albumKey: AlbumFolderKey?
    ) -> String? {
        switch token {
        case .disabled:
            return nil
        case .year:
            return albumKey?.year ?? resolvedYearComponent(for: loadedTrack)
        case .albumArtist:
            return albumKey?.artistBucket ?? resolvedAlbumArtistComponent(for: loadedTrack)
        case .album:
            return albumKey?.album ?? resolvedAlbumComponent(for: loadedTrack)
        case .compilation:
            return loadedTrack.metadata.compilation == true ? "Compilation" : nil
        case .genre:
            guard let genre = normalizedMetadataValue(loadedTrack.metadata.genre) else { return nil }
            return PathComponentSanitizer.sanitize(genre, fallback: "Genre")
        }
    }

    private func resolvedYearComponent(for loadedTrack: LoadedTrack) -> String {
        let value = loadedTrack.metadata.year.map(String.init) ?? ""
        return PathComponentSanitizer.sanitize(value, fallback: unknownYear)
    }

    /// The "Various Artists" bucket a compilation reunites under.
    public static let variousArtists = "Various Artists"

    private func resolvedAlbumArtistComponent(for loadedTrack: LoadedTrack) -> String {
        // A compilation with no explicit album-artist tag reunites under "Various
        // Artists" instead of shattering into one album per track artist. This is
        // shared by the browser index, conversion output, and the review sheet, so
        // they all agree a compilation is one album.
        if loadedTrack.metadata.compilation == true,
           normalizedMetadataValue(loadedTrack.metadata.albumArtist) == nil {
            return PathComponentSanitizer.sanitize(Self.variousArtists, fallback: unknownArtist)
        }
        let value = normalizedMetadataValue(loadedTrack.metadata.albumArtist)
            ?? normalizedMetadataValue(loadedTrack.metadata.artist)
            ?? normalizedMetadataValue(loadedTrack.track.artist)
            ?? unknownArtist
        return PathComponentSanitizer.sanitize(value, fallback: unknownArtist)
    }

    private func resolvedAlbumComponent(for loadedTrack: LoadedTrack) -> String {
        let value = normalizedMetadataValue(loadedTrack.metadata.album)
            ?? normalizedMetadataValue(loadedTrack.track.album)
            ?? unknownAlbum
        return PathComponentSanitizer.sanitize(value, fallback: unknownAlbum)
    }

    /// `"Bitches Brew (Disc 2)"` -> `"Bitches Brew"`. A disc suffix in the album
    /// tag is the commonest way a two-disc release shatters into two albums that
    /// sort apart, and it is a property of the *file*, not of the release. Only
    /// `albumFolderKeys(for:)` applies it, and only to files that share one album
    /// folder: two discs filed as separate folders stay separate albums, keeping
    /// their own titles, so a box set's discs remain tellable apart. The disc
    /// number itself is never lost either way — it lives in `discNumber`, which
    /// is what the track sort already reads.
    static func strippingDiscSuffix(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = discSuffixPattern.firstMatch(in: title, options: [], range: range),
              let matched = Range(match.range, in: title)
        else { return title }
        let remainder = title[title.startIndex..<matched.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        // "Disc 2" on its own is the whole title; stripping it leaves nothing.
        return remainder.isEmpty ? title : remainder
    }

    /// Trailing `(Disc 2)`, `[CD 1 of 3]`, `- Disc 2`, `, CD2`, or a bare `Disc 2`.
    private static let discSuffixPattern = try! NSRegularExpression(
        pattern: #"[ ._,:–-]*(?:[(\[{][ ._-]*)?(?:cd|disc|disk)[ ._-]*\d{1,3}(?:[ ._-]*(?:of|/)[ ._-]*\d{1,3})?[ ._-]*[)\]}]?$"#,
        options: [.caseInsensitive]
    )

    /// The folder that decides which physical album a file belongs to: its own
    /// folder, except that a disc subfolder (`CD1`, `Disc 2`) resolves to the
    /// album folder above it, so a multi-disc rip is one album, not two pressings.
    public func albumSourceFolder(for loadedTrack: LoadedTrack) -> String {
        guard loadedTrack.track.fileURL.isFileURL else { return "" }
        var folder = loadedTrack.track.fileURL.deletingLastPathComponent()
        let range = NSRange(folder.lastPathComponent.startIndex..., in: folder.lastPathComponent)
        if Self.discFolderPattern.firstMatch(in: folder.lastPathComponent, options: [], range: range) != nil {
            folder = folder.deletingLastPathComponent()
        }
        return folder.standardizedFileURL.path
    }

    /// A disc folder starts with a disc number: `CD1`, `Disc 2 - Live`, Picard's
    /// `01 - Digital Media`, or a bare `1`. Three digits at most, so a year
    /// folder (`1994 - Album`) is not a disc, and a folder that merely *ends*
    /// in a number (`Vol. 3`) is not one either.
    private static let discFolderPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:cd|disc|disk|d)[ ._-]*)?\d{1,3}(?:[ ._-].*)?$"#, options: [.caseInsensitive]
    )

    /// Album identity for a whole set of tracks at once.
    ///
    /// `albumFolderKey(for:)` reads one file's tags literally, and three ordinary
    /// tag inconsistencies each shatter one release into several albums: a disc
    /// suffix in the title, per-track artists on a compilation or soundtrack with
    /// no album-artist tag, and tracks carrying different years. Files that share
    /// one album folder (disc subfolders folded into it) and one album title ARE
    /// one album, so the whole group agrees on a single artist bucket and year.
    ///
    /// Untitled files are left alone — a flat folder of loose, untagged tracks
    /// would otherwise collapse into a single "Unknown Album".
    public func albumFolderKeys(for tracks: [LoadedTrack]) -> [UUID: AlbumFolderKey] {
        struct PhysicalAlbum: Hashable { let folder: String; let album: String }

        var members: [PhysicalAlbum: [LoadedTrack]] = [:]
        var keys: [UUID: AlbumFolderKey] = [:]
        for track in tracks {
            let key = albumFolderKey(for: track)
            keys[track.track.id] = key
            guard key.album != unknownAlbum else { continue }
            let physical = PhysicalAlbum(
                folder: albumSourceFolder(for: track),
                album: Self.strippingDiscSuffix(key.album)
            )
            members[physical, default: []].append(track)
        }

        for (physical, group) in members where group.count > 1 {
            let reconciled = AlbumFolderKey(
                artistBucket: sharedArtistBucket(in: group),
                album: physical.album,
                year: sharedYearComponent(in: group)
            )
            for track in group { keys[track.track.id] = reconciled }
        }
        return keys
    }

    /// One album-artist for a set of files: the tag they agree on, else Various
    /// Artists. An explicit album-artist outranks the per-track artist, which is
    /// what makes a soundtrack one album instead of one album per performer.
    private func sharedArtistBucket(in group: [LoadedTrack]) -> String {
        let various = PathComponentSanitizer.sanitize(Self.variousArtists, fallback: unknownArtist)
        if group.contains(where: { $0.metadata.compilation == true })
            && group.allSatisfy({ normalizedMetadataValue($0.metadata.albumArtist) == nil }) {
            return various
        }
        let albumArtists = Set(group.compactMap { normalizedMetadataValue($0.metadata.albumArtist) })
        if albumArtists.count == 1, let only = albumArtists.first {
            return PathComponentSanitizer.sanitize(only, fallback: unknownArtist)
        }
        if albumArtists.count > 1 { return various }

        let artists = Set(group.compactMap {
            normalizedMetadataValue($0.metadata.artist) ?? normalizedMetadataValue($0.track.artist)
        })
        guard artists.count == 1, let only = artists.first else { return various }
        return PathComponentSanitizer.sanitize(only, fallback: unknownArtist)
    }

    /// The year the set mostly agrees on. A stray original-release year on one
    /// track of a compilation must not split the album off from its siblings.
    private func sharedYearComponent(in group: [LoadedTrack]) -> String {
        var counts: [Int: Int] = [:]
        for track in group {
            if let year = track.metadata.year { counts[year, default: 0] += 1 }
        }
        guard let winner = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
            return PathComponentSanitizer.sanitize("", fallback: unknownYear)
        }
        return PathComponentSanitizer.sanitize(String(winner), fallback: unknownYear)
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizeRelativeSubpath(_ rawPath: String, fallback: String) -> String {
        let components = rawPath
            .split(separator: "/")
            .map { PathComponentSanitizer.sanitize(String($0), fallback: "") }
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return fallback
        }
        return components.joined(separator: "/")
    }

    /// Case-folds + Unicode-normalizes a path so collision checks agree with
    /// case-insensitive destination volumes, where `Mix.m4a` and `MIX.m4a` are
    /// the same file. Callers pass in already-standardized/symlink-resolved
    /// reserved paths; this folds both sides for comparison.
    private func collisionKey(forPath path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Sanitizes a single filesystem path component (strips path separators, collapses
/// whitespace, falls back when empty). Shared by `OutputPathPlanner` and
/// `LibraryOrganizerService` so both agree on how names become folders/files.
public enum PathComponentSanitizer {
    /// Compiled once; sanitize runs ~4x per track on every index rebuild.
    private static let whitespaceRuns = try! NSRegularExpression(pattern: "\\s+")

    /// One path component, cleaned. Returns nil when nothing usable survives,
    /// so a caller assembling a subpath can drop the component outright rather
    /// than substitute something for it.
    public static func sanitizedComponent(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }

        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\\", with: "-")

        let collapsed = whitespaceRuns.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: " "
        )
        var trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

        // Traversal/hidden-file guard: "." and ".." would escape the output
        // root as path components; a leading "." hides the output file.
        while trimmed.first == "." {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func sanitize(_ rawValue: String, fallback: String) -> String {
        sanitizedComponent(rawValue) ?? fallback
    }

    /// A relative subpath, every component put through the same rule and the
    /// empties dropped. Because the traversal guard runs on each component,
    /// the result can never climb out of the directory it is joined onto —
    /// which is the whole reason this exists in one place instead of being
    /// re-derived at each call site.
    public static func sanitizeSubpath(_ rawValue: String, fallback: String) -> String {
        let components = rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { sanitizedComponent(String($0)) }
        return components.isEmpty ? fallback : components.joined(separator: "/")
    }
}
