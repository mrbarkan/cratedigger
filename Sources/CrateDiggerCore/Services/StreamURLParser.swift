import Foundation

/// Result of classifying a pasted URL. `isValidHost` is true only for genuine
/// YouTube hosts; a typo'd host still classifies (so the UI can preview it) but
/// is flagged so the caller can refuse to add it.
public struct ParsedStream: Equatable, Sendable {
    public var isValidHost: Bool
    public var kind: StreamKind
    public var suggestedTitle: String
    public var channel: String
    public var host: String

    public init(isValidHost: Bool, kind: StreamKind, suggestedTitle: String, channel: String, host: String) {
        self.isValidHost = isValidHost
        self.kind = kind
        self.suggestedTitle = suggestedTitle
        self.channel = channel
        self.host = host
    }
}

/// Pure classifier that turns a pasted YouTube link into a `ParsedStream`.
/// Swift port of the v7 mockup's `parseYT` (CrateDigger_v7.html). Used by both
/// the Add-Stream sheet's live detection and `LibraryViewModel.addStream`.
public enum StreamURLParser {

    /// Returns nil when the string can't be interpreted as a URL at all.
    public static func parse(_ raw: String) -> ParsedStream? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
            ? trimmed
            : "https://" + trimmed
        guard let url = URL(string: withScheme), let rawHost = url.host else { return nil }

        let host = rawHost.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let isValidHost = host.range(of: "(youtube\\.com|youtu\\.be)$", options: .regularExpression) != nil

        // A non-YouTube host with no dot is just garbage text, not a URL.
        if !isValidHost && !host.contains(".") { return nil }

        let path = url.path
        let query = queryItems(url)

        // 1. Playlist — ?list= or a /playlist path.
        if query["list"] != nil || path.range(of: "playlist", options: .caseInsensitive) != nil {
            return ParsedStream(isValidHost: isValidHost, kind: .playlist,
                                suggestedTitle: "YouTube Playlist", channel: "Playlist", host: host)
        }

        // 2. /channel/<id>
        if let range = path.range(of: "/channel/", options: .caseInsensitive) {
            let rest = String(path[range.upperBound...])
            let id = rest.split(separator: "/").first.map(String.init) ?? rest
            let decoded = id.removingPercentEncoding ?? id
            let channel = decoded.count > 16 ? String(decoded.prefix(14)) + "\u{2026}" : decoded
            return ParsedStream(isValidHost: isValidHost, kind: .live,
                                suggestedTitle: "YouTube Channel", channel: channel, host: host)
        }

        // 3. /@handle
        if let range = path.range(of: "/@", options: .caseInsensitive) {
            let rest = String(path[range.upperBound...])
            let handle = rest.split(separator: "/").first.map(String.init) ?? rest
            let title = handle.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            return ParsedStream(isValidHost: isValidHost, kind: .live,
                                suggestedTitle: title, channel: "@" + handle, host: host)
        }

        // 4. /c/<name> or /user/<name>
        if path.range(of: "/(c|user)/", options: .regularExpression) != nil {
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            let decoded = name.removingPercentEncoding ?? name
            return ParsedStream(isValidHost: isValidHost, kind: .live,
                                suggestedTitle: decoded, channel: decoded, host: host)
        }

        // 5. /live
        if path.range(of: "/live", options: .caseInsensitive) != nil {
            return ParsedStream(isValidHost: isValidHost, kind: .live,
                                suggestedTitle: "Live Stream", channel: "YouTube", host: host)
        }

        // 6. ?v= or youtu.be short link → video. 7. default → video.
        return ParsedStream(isValidHost: isValidHost, kind: .video,
                            suggestedTitle: "YouTube Video", channel: "YouTube", host: host)
    }

    private static func queryItems(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [:] }
        var dict: [String: String] = [:]
        for item in items where item.value != nil { dict[item.name] = item.value }
        return dict
    }
}
