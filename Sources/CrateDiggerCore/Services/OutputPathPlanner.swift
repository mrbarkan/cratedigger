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

    public func buildOutputSubpath(
        for loadedTrack: LoadedTrack,
        templateConfig: FolderTemplateConfig
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
            if let value = tokenValue(for: token, loadedTrack: loadedTrack) {
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
            resolvedYearComponent(for: loadedTrack),
            resolvedAlbumArtistComponent(for: loadedTrack),
            resolvedAlbumComponent(for: loadedTrack)
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
        avoidExistingFiles: Bool = true
    ) -> PlannedOutputPath {
        let track = loadedTrack.track
        let sourceDirectory = track.fileURL.deletingLastPathComponent()
        var outputDirectory = destinationRoot
        var relativeSubpath: String?
        var albumKey: AlbumFolderKey?

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
            albumKey = albumFolderKey(for: loadedTrack)
            let subpath = reviewedAlbumFolders[albumKey!] ?? buildOutputSubpath(for: loadedTrack, templateConfig: templateConfig)
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

    private func tokenValue(for token: FolderToken, loadedTrack: LoadedTrack) -> String? {
        switch token {
        case .disabled:
            return nil
        case .year:
            return resolvedYearComponent(for: loadedTrack)
        case .albumArtist:
            return resolvedAlbumArtistComponent(for: loadedTrack)
        case .album:
            return resolvedAlbumComponent(for: loadedTrack)
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
enum PathComponentSanitizer {
    /// Compiled once; sanitize runs ~4x per track on every index rebuild.
    private static let whitespaceRuns = try! NSRegularExpression(pattern: "\\s+")

    static func sanitize(_ rawValue: String, fallback: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return fallback }

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
        return trimmed.isEmpty ? fallback : trimmed
    }
}
