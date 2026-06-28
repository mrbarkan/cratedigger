import Foundation

/// Result of validating a proposed crate or playlist name.
public enum CrateNameValidation: Equatable, Sendable {
    /// Valid — carries the trimmed/sanitized name to use.
    case ok(String)
    /// Invalid — carries a human-readable reason for an alert.
    case invalid(reason: String)

    public var isValid: Bool {
        if case .ok = self { return true }
        return false
    }

    /// The sanitized name when valid, else nil.
    public var sanitizedName: String? {
        if case .ok(let name) = self { return name }
        return nil
    }
}

/// Validates names for user-renamed crates (`.cdlib`) and playlists (`.m3u`).
/// Pure logic so it can be unit-tested without touching the filesystem.
public enum CrateNameValidator {
    /// - Parameters:
    ///   - proposed: The user's typed name (untrimmed).
    ///   - existing: All current names in the same namespace (crates or playlists).
    ///   - currentName: The name being renamed, if any. Renaming an item to its own
    ///     name (including a case-only change) is allowed and not flagged as a duplicate.
    public static func validate(_ proposed: String,
                                existing: [String],
                                currentName: String? = nil) -> CrateNameValidation {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .invalid(reason: "The name can’t be empty.")
        }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            return .invalid(reason: "The name can’t contain “/” or “:”.")
        }
        guard !trimmed.hasPrefix(".") else {
            return .invalid(reason: "The name can’t start with a dot.")
        }

        let lowered = trimmed.lowercased()
        if let currentName, currentName.lowercased() == lowered {
            // Unchanged (or case-only) — always allowed.
            return .ok(trimmed)
        }
        if existing.contains(where: { $0.lowercased() == lowered }) {
            return .invalid(reason: "A “\(trimmed)” already exists.")
        }
        return .ok(trimmed)
    }
}
