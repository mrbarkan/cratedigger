import Foundation

/// Derives the auto-generated format/quality badge shown on a version sub-row
/// (e.g. "FLAC · 96 kHz", "MP3 · 320", "ALAC · CD"). The user's editable edition
/// label ("Gold CD", "JP Vinyl") is stored separately on `VersionMember`.
public enum VersionLabel {
    private static let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "pcm", "ape"]

    public static func formatBadge(for album: Album) -> String {
        let track = album.tracks.first?.track
        guard let rawFormat = track?.formatName, !rawFormat.isEmpty else { return "—" }

        let codec = rawFormat.uppercased()
        let isLossless = lossless.contains(rawFormat.lowercased())

        var parts: [String] = [codec]
        if isLossless {
            if let hz = track?.sampleRateHz, hz > 0 {
                parts.append("\(Int((Double(hz) / 1000).rounded())) kHz")
            }
        } else if let kbps = track?.bitrateKbps, kbps > 0 {
            parts.append("\(kbps)")
        }
        if let media = album.mediaFormat {
            parts.append(media.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}
