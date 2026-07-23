import Foundation

/// SACD ISOs can't be mounted by macOS; the reliable tell is the Master TOC
/// magic "SACDMTOC" at sector 510 (verified against a real disc image).
public enum SACDISOInspector {
    private static let magic = Data("SACDMTOC".utf8)
    private static let masterTOCOffset: UInt64 = 510 * 2048

    public static func isSACDISO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: masterTOCOffset)) != nil,
              let bytes = try? handle.read(upToCount: magic.count) else { return false }
        return bytes == magic
    }
}

public struct SACDTrackInfo: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let performer: String
    public let durationSeconds: Double
}

public struct SACDDiscInfo: Equatable, Sendable {
    public let albumTitle: String
    public let albumArtist: String
    public let year: Int?
    public let stereoTracks: [SACDTrackInfo]
}

/// Parses `sacd_extract -P` text output. Line-oriented on purpose — the tool's
/// format is stable, tab-indented `Key: Value` lines with per-area blocks; only
/// the 2-channel (stereo) area's track list matters. Track numbers are the
/// 1-based list positions, matching `-t` selection and the extractor's
/// "NN - Title.dsf" file naming.
public enum SACDMetadataParser {
    public static func parse(_ output: String) -> SACDDiscInfo? {
        var albumTitle = "", albumArtist = ""
        var year: Int?
        var inAlbumBlock = false
        var inStereoArea = false
        var tracks: [SACDTrackInfo] = []
        // Track fields arrive as Title[i]: / Performer[i]: / Duration: runs.
        var pendingTitle: String?
        var pendingPerformer = ""

        func value(of line: Substring, after key: String) -> String? {
            guard line.hasPrefix(key) else { return nil }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == "\t" || $0 == " " })
            if line.hasPrefix("Disc Information:") { inAlbumBlock = false }
            if line.hasPrefix("Album Information:") { inAlbumBlock = true }
            if line.hasPrefix("Area Information [") {
                inStereoArea = false   // until this area proves 2 Channel
                pendingTitle = nil
                pendingPerformer = ""
            }
            if let config = value(of: line, after: "Speaker config:") {
                inStereoArea = config.hasPrefix("2 Channel")
            }
            if let date = value(of: line, after: "Creation date:"), year == nil {
                year = Int(date.prefix(4))
            }
            if let title = value(of: line, after: "Title:") {
                // Disc block sets it first; the Album block's Title overrides.
                if inAlbumBlock || albumTitle.isEmpty { albumTitle = title }
            }
            if let artist = value(of: line, after: "Artist:") {
                if inAlbumBlock || albumArtist.isEmpty { albumArtist = artist }
            }
            guard inStereoArea else { continue }
            if line.hasPrefix("Title["), let range = line.range(of: "]: ") {
                pendingTitle = String(line[range.upperBound...])
                pendingPerformer = ""
            }
            if line.hasPrefix("Performer["), let range = line.range(of: "]: ") {
                pendingPerformer = String(line[range.upperBound...])
            }
            if let duration = value(of: line, after: "Duration:"), let title = pendingTitle {
                // "MM:SS:FF [mins:secs:frames]" — 75 frames/sec, like CD.
                let parts = duration.split(separator: " ").first?.split(separator: ":") ?? []
                if parts.count == 3, let m = Double(parts[0]), let s = Double(parts[1]),
                   let f = Double(parts[2]) {
                    tracks.append(SACDTrackInfo(number: tracks.count + 1, title: title,
                                                performer: pendingPerformer,
                                                durationSeconds: m * 60 + s + f / 75.0))
                    pendingTitle = nil
                    pendingPerformer = ""
                }
            }
        }
        guard !tracks.isEmpty else { return nil }
        return SACDDiscInfo(albumTitle: albumTitle, albumArtist: albumArtist,
                            year: year, stereoTracks: tracks)
    }
}
