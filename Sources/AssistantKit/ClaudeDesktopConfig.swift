import Foundation

/// Adds CrateDigger to Claude Desktop's list of local MCP servers.
///
/// Claude Desktop reads `claude_desktop_config.json` and launches each entry
/// under `mcpServers` as a subprocess speaking MCP on stdio. The file belongs
/// to the user and to Claude, so this edits one key and leaves everything else
/// as it was; a file it cannot parse is left alone rather than replaced.
public enum ClaudeDesktopConfig {
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Claude/claude_desktop_config.json")
    }

    public enum ConfigError: Error, LocalizedError, Equatable {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "Claude Desktop's settings file isn't valid JSON, so CrateDigger left it alone (\(detail)). Fix or remove it in Claude Desktop, then try again."
            }
        }
    }

    public enum Status: Equatable {
        /// No config file, or no CrateDigger entry in it.
        case notInstalled
        /// An entry pointing at this helper.
        case installed
        /// An entry pointing somewhere else: an older copy of the app, or a
        /// build run from source.
        case pointsElsewhere(String)
    }

    public static func status(of data: Data?, helperPath: String) -> Status {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[AssistantTool.serverName] as? [String: Any] else {
            return .notInstalled
        }
        let command = entry["command"] as? String ?? ""
        return command == helperPath ? .installed : .pointsElsewhere(command)
    }

    /// The config with CrateDigger's entry set to `helperPath`.
    public static func merged(existing: Data?, helperPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            do {
                guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                    throw ConfigError.unreadable("the top level isn't an object")
                }
                root = object
            } catch let error as ConfigError {
                throw error
            } catch {
                throw ConfigError.unreadable(error.localizedDescription)
            }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[AssistantTool.serverName] = ["command": helperPath, "args": [String]()]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes the entry. The previous file, if any, is kept beside it as
    /// `claude_desktop_config.json.bak`.
    public static func install(helperPath: String, at url: URL = defaultURL) throws {
        let fileManager = FileManager.default
        let existing = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let updated = try merged(existing: existing, helperPath: helperPath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            try existing.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try updated.write(to: url, options: .atomic)
    }
}
