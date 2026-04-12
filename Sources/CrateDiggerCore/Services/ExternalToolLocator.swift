import Foundation

public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe

    public var executableName: String {
        rawValue
    }

    public var environmentOverrideKey: String {
        switch self {
        case .ffmpeg:
            return "CRATEDIGGER_FFMPEG_PATH"
        case .ffprobe:
            return "CRATEDIGGER_FFPROBE_PATH"
        }
    }
}

public enum ExternalToolSource: String, Sendable {
    case bundled
    case explicitOverride = "explicit_override"
    case environmentOverride = "environment_override"
    case system
}

public struct ResolvedExternalTool: Sendable, Hashable {
    public let tool: ExternalTool
    public let url: URL
    public let source: ExternalToolSource

    public init(tool: ExternalTool, url: URL, source: ExternalToolSource) {
        self.tool = tool
        self.url = url
        self.source = source
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

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.bundle = bundle
    }

    public func resolveRequired(_ tool: ExternalTool, explicitOverride: URL? = nil) throws -> ResolvedExternalTool {
        if let resolved = resolveOptional(tool, explicitOverride: explicitOverride) {
            return resolved
        }

        throw ExternalToolLocatorError.toolMissing(tool, searchedLocations: searchedLocations(for: tool, explicitOverride: explicitOverride))
    }

    public func resolveOptional(_ tool: ExternalTool, explicitOverride: URL? = nil) -> ResolvedExternalTool? {
        for candidate in candidates(for: tool, explicitOverride: explicitOverride) {
            if fileManager.isExecutableFile(atPath: candidate.url.path) {
                return ResolvedExternalTool(tool: tool, url: candidate.url, source: candidate.source)
            }
        }

        return nil
    }

    private func candidates(for tool: ExternalTool, explicitOverride: URL?) -> [(url: URL, source: ExternalToolSource)] {
        var candidates: [(URL, ExternalToolSource)] = []

        if let resourceURL = bundle.resourceURL {
            candidates.append((resourceURL.appendingPathComponent(tool.executableName), .bundled))
        }

        if let explicitOverride {
            candidates.append((explicitOverride, .explicitOverride))
        }

        if let overridePath = environment[tool.environmentOverrideKey], !overridePath.isEmpty {
            candidates.append((URL(fileURLWithPath: overridePath), .environmentOverride))
        }

        for path in systemSearchPaths(for: tool) {
            candidates.append((URL(fileURLWithPath: path), .system))
        }

        return deduplicated(candidates)
    }

    private func searchedLocations(for tool: ExternalTool, explicitOverride: URL?) -> [String] {
        candidates(for: tool, explicitOverride: explicitOverride).map { $0.url.path }
    }

    private func systemSearchPaths(for tool: ExternalTool) -> [String] {
        var orderedPaths: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        if let rawPath = environment["PATH"], !rawPath.isEmpty {
            orderedPaths.append(contentsOf: rawPath.split(separator: ":").map(String.init))
        }

        return deduplicated(orderedPaths).map { directory in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(tool.executableName)
                .path
        }
    }

    private func deduplicated(_ candidates: [(URL, ExternalToolSource)]) -> [(URL, ExternalToolSource)] {
        var seen: Set<String> = []
        var unique: [(URL, ExternalToolSource)] = []

        for candidate in candidates {
            let key = candidate.0.standardizedFileURL.path
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
