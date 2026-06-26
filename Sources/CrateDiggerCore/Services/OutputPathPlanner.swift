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
        }
    }

    public var isDisabled: Bool {
        self == .disabled
    }
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

    public init(preset: TemplatePreset, tokenOrder: [FolderToken]) {
        self.preset = preset
        self.tokenOrder = tokenOrder
    }
}

public struct AlbumFolderKey: Hashable, Sendable, Codable {
    public let artistBucket: String
    public let album: String
    public let year: String

    public init(artistBucket: String, album: String, year: String) {
        self.artistBucket = artistBucket
        self.album = album
        self.year = year
    }
}

public struct PlannedOutputPath: Hashable, Sendable {
    public let destinationURL: URL
    public let relativeSubpath: String?
    public let albumKey: AlbumFolderKey?
    public let collisionCount: Int

    public init(destinationURL: URL, relativeSubpath: String?, albumKey: AlbumFolderKey?, collisionCount: Int) {
        self.destinationURL = destinationURL
        self.relativeSubpath = relativeSubpath
        self.albumKey = albumKey
        self.collisionCount = collisionCount
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
        let tokenOrder: [FolderToken]
        switch templateConfig.preset {
        case .artistYearAlbum:
            tokenOrder = [.albumArtist, .year, .album]
        case .yearArtistAlbum:
            tokenOrder = [.year, .albumArtist, .album]
        case .artistAlbumYear:
            tokenOrder = [.albumArtist, .album, .year]
        case .custom:
            tokenOrder = templateConfig.tokenOrder
        }

        let components = tokenOrder.compactMap { tokenValue(for: $0, loadedTrack: loadedTrack) }
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
        baseNameOverride: String? = nil
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
        let baseName = sanitizePathComponent(rawBaseName, fallback: "Track")
        let outputExtension = normalizedFileExtension(destinationFileExtension) ?? preset.outputExtension
        let destinationURL = uniqueDestinationURL(
            in: outputDirectory,
            baseName: baseName,
            extension: outputExtension,
            reservedDestinationPaths: reservedDestinationPaths
        )

        let collisionCount = collisionCount(for: destinationURL, baseName: baseName, fileExtension: outputExtension)
        return PlannedOutputPath(
            destinationURL: destinationURL,
            relativeSubpath: relativeSubpath,
            albumKey: albumKey,
            collisionCount: collisionCount
        )
    }

    private func uniqueDestinationURL(
        in directory: URL,
        baseName: String,
        extension fileExtension: String,
        reservedDestinationPaths: Set<String>
    ) -> URL {
        var attempt = 1

        while true {
            let candidateName = attempt == 1 ? baseName : "\(baseName) (\(attempt))"
            let candidate = directory
                .appendingPathComponent(candidateName)
                .appendingPathExtension(fileExtension)
            let key = standardizedPathKey(for: candidate)

            if !reservedDestinationPaths.contains(key) && !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }

            attempt += 1
        }
    }

    private func collisionCount(for url: URL, baseName: String, fileExtension: String) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        if stem == baseName {
            return 1
        }

        let prefix = "\(baseName) ("
        guard stem.hasPrefix(prefix),
              stem.hasSuffix(")"),
              let count = Int(stem.dropFirst(prefix.count).dropLast())
        else {
            return 1
        }

        return max(1, count)
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
        }
    }

    private func resolvedYearComponent(for loadedTrack: LoadedTrack) -> String {
        let value = loadedTrack.metadata.year.map(String.init) ?? ""
        return sanitizePathComponent(value, fallback: unknownYear)
    }

    private func resolvedAlbumArtistComponent(for loadedTrack: LoadedTrack) -> String {
        let value = normalizedMetadataValue(loadedTrack.metadata.albumArtist)
            ?? normalizedMetadataValue(loadedTrack.metadata.artist)
            ?? normalizedMetadataValue(loadedTrack.track.artist)
            ?? unknownArtist
        return sanitizePathComponent(value, fallback: unknownArtist)
    }

    private func resolvedAlbumComponent(for loadedTrack: LoadedTrack) -> String {
        let value = normalizedMetadataValue(loadedTrack.metadata.album)
            ?? normalizedMetadataValue(loadedTrack.track.album)
            ?? unknownAlbum
        return sanitizePathComponent(value, fallback: unknownAlbum)
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizePathComponent(_ rawValue: String, fallback: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return fallback }

        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\\", with: "-")

        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func sanitizeRelativeSubpath(_ rawPath: String, fallback: String) -> String {
        let components = rawPath
            .split(separator: "/")
            .map { sanitizePathComponent(String($0), fallback: "") }
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return fallback
        }
        return components.joined(separator: "/")
    }

    private func standardizedPathKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
