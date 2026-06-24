import Foundation

/// Real metadata fetched for a stream (title, channel, thumbnail, etc.).
/// All fields are best-effort — a source may not provide every one.
public struct StreamMetadata: Sendable, Equatable {
    public var title: String?
    public var channel: String?
    public var thumbnailURL: String?
    public var durationSeconds: Double?
    public var isLive: Bool?
    public var viewers: String?   // formatted, e.g. "13.6K"

    public init(title: String? = nil, channel: String? = nil, thumbnailURL: String? = nil,
                durationSeconds: Double? = nil, isLive: Bool? = nil, viewers: String? = nil) {
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.isLive = isLive
        self.viewers = viewers
    }
}

/// Fetches real stream metadata. The pure pieces (argument building + output
/// parsing) are static and unit-tested; the actual fetching (Process / URLSession)
/// is done by the caller using `CommandRunning` / `URLSession`.
///
/// Two sources, preferred in order:
///   1. yt-dlp `--print` — richest (title, channel, thumb, duration, live, viewers),
///      works for videos / playlists / channels / live. Needs yt-dlp.
///   2. YouTube oEmbed — title / channel / thumbnail only, but zero-dependency.
public enum StreamMetadataService {

    // Tab-separated, positional (titles can contain almost anything but tabs).
    public static let ytdlpPrintTemplate =
        "%(title)s\t%(uploader)s\t%(thumbnail)s\t%(duration)s\t%(is_live)s\t%(view_count)s\t%(concurrent_view_count)s"

    public static func ytdlpArguments(url: String) -> [String] {
        ["--no-playlist", "--print", ytdlpPrintTemplate, url]
    }

    public static func parseYtDlp(_ output: String) -> StreamMetadata {
        guard let line = output.split(separator: "\n").first.map(String.init) else {
            return StreamMetadata()
        }
        let fields = line.components(separatedBy: "\t")
        func field(_ i: Int) -> String? {
            guard i < fields.count else { return nil }
            let v = fields[i].trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v == "NA") ? nil : v
        }
        let isLive = field(4).map { $0 == "True" }
        let viewCount = field(5).flatMap(Int.init)
        let concurrent = field(6).flatMap(Int.init)
        // Live streams report concurrent viewers; VOD reports total views.
        let viewers = formatViewCount((isLive == true ? concurrent : nil) ?? concurrent ?? viewCount)
        return StreamMetadata(
            title: field(0),
            channel: field(1),
            thumbnailURL: field(2),
            durationSeconds: field(3).flatMap(Double.init),
            isLive: isLive,
            viewers: viewers
        )
    }

    public static func parseOEmbed(_ data: Data) -> StreamMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return StreamMetadata(
            title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            channel: (obj["author_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            thumbnailURL: (obj["thumbnail_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public static func oEmbedURL(for streamURL: String) -> URL? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")
        comps?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "url", value: streamURL)
        ]
        return comps?.url
    }

    public static func formatViewCount(_ count: Int?) -> String? {
        guard let n = count else { return nil }
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<1_000_000:
            return String(format: "%.1fK", Double(n) / 1_000)
        default:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
