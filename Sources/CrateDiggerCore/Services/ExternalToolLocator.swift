import Foundation

public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case ytdlp

    public var executableName: String {
        switch self {
        case .ffmpeg, .ffprobe: return rawValue
        case .ytdlp: return "yt-dlp"   // binary name differs from the case name
        }
    }

    public var environmentOverrideKey: String {
        switch self {
        case .ffmpeg:
            return "CRATEDIGGER_FFMPEG_PATH"
        case .ffprobe:
            return "CRATEDIGGER_FFPROBE_PATH"
        case .ytdlp:
            return "CRATEDIGGER_YTDLP_PATH"
        }
    }
}

public struct ResolvedExternalTool: Sendable, Hashable {
    public let tool: ExternalTool
    public let url: URL

    public init(tool: ExternalTool, url: URL) {
        self.tool = tool
        self.url = url
    }
}

public enum ExternalToolLocatorError: Error, LocalizedError {
    case toolMissing(ExternalTool, searchedLocations: [String])

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool, let searchedLocations):
            let locations = searchedLocations.joined(separator: ", ")
            return "Could not locate \(tool.executableName). Searched: \(locations)"
        }
    }
}

public struct ExternalToolLocator {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let bundle: Bundle
    private let defaultSystemSearchDirectories: [String]

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        defaultSystemSearchDirectories: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.bundle = bundle
        self.defaultSystemSearchDirectories = defaultSystemSearchDirectories
    }

    public func resolveRequired(_ tool: ExternalTool, explicitOverride: URL? = nil) throws -> ResolvedExternalTool {
        if let resolved = resolveOptional(tool, explicitOverride: explicitOverride) {
            return resolved
        }

        throw ExternalToolLocatorError.toolMissing(tool, searchedLocations: searchedLocations(for: tool, explicitOverride: explicitOverride))
    }

    public func resolveOptional(_ tool: ExternalTool, explicitOverride: URL? = nil) -> ResolvedExternalTool? {
        for candidate in candidates(for: tool, explicitOverride: explicitOverride) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return ResolvedExternalTool(tool: tool, url: candidate)
            }
        }

        return nil
    }

    private func candidates(for tool: ExternalTool, explicitOverride: URL?) -> [URL] {
        var candidates: [URL] = []

        if let resourceURL = bundle.resourceURL?.absoluteURL {
            candidates.append(resourceURL.appendingPathComponent(tool.executableName))
        }

        if let explicitOverride {
            candidates.append(explicitOverride)
        }

        if let overridePath = environment[tool.environmentOverrideKey], !overridePath.isEmpty {
            candidates.append(URL(fileURLWithPath: overridePath))
        }

        for path in systemSearchPaths(for: tool) {
            candidates.append(URL(fileURLWithPath: path))
        }

        return deduplicated(candidates)
    }

    private func searchedLocations(for tool: ExternalTool, explicitOverride: URL?) -> [String] {
        candidates(for: tool, explicitOverride: explicitOverride).map(\.path)
    }

    private func systemSearchPaths(for tool: ExternalTool) -> [String] {
        var orderedPaths = defaultSystemSearchDirectories

        if let rawPath = environment["PATH"], !rawPath.isEmpty {
            orderedPaths.append(contentsOf: rawPath.split(separator: ":").map(String.init))
        }

        return deduplicated(orderedPaths).map { directory in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(tool.executableName)
                .path
        }
    }

    private func deduplicated(_ candidates: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []

        for candidate in candidates {
            let key = candidate.standardizedFileURL.path
            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                unique.append(value)
            }
        }
        return unique
    }
}
