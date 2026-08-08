import Foundation

/// A field the flat Track browser can show as a column.
///
/// The hierarchical layouts (Artist · Album · Track) already carry their context
/// in the panes to the left, so they keep the compact number/title/time row. The
/// flat list has no such context — it's the table you scan and sort across the
/// whole library — so it lets you choose what's in it, the way iTunes and
/// Swinsian always have.
public enum TrackColumn: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case trackNumber
    case title
    case duration
    case artist
    case albumArtist
    case album
    case genre
    case year
    case format
    case bitrate
    case sampleRate
    case discNumber

    public var id: String { rawValue }

    /// Header text. Kept short — these sit above narrow columns.
    public var title: String {
        switch self {
        case .trackNumber: return "#"
        case .title:       return "Title"
        case .duration:    return "Time"
        case .artist:      return "Artist"
        case .albumArtist: return "Album Artist"
        case .album:       return "Album"
        case .genre:       return "Genre"
        case .year:        return "Year"
        case .format:      return "Format"
        case .bitrate:     return "Bitrate"
        case .sampleRate:  return "Sample Rate"
        case .discNumber:  return "Disc"
        }
    }

    /// What the header sorts by, when the browser can sort on it at all.
    public var sortField: TrackSortField? {
        switch self {
        case .trackNumber: return .trackNumber
        case .title:       return .title
        case .artist:      return .artist
        case .duration:    return .duration
        default:           return nil
        }
    }

    /// Starting width in points. `title` is the flexible one — it takes whatever
    /// is left over — so its value here is only a minimum.
    public var defaultWidth: Double {
        switch self {
        case .trackNumber, .discNumber: return 34
        case .duration, .year:          return 54
        case .title:                    return 220
        case .artist, .albumArtist:     return 150
        case .album:                    return 170
        case .genre, .format:           return 90
        case .bitrate, .sampleRate:     return 90
        }
    }

    /// Numbers read right-aligned; text reads left-aligned.
    public var isTrailingAligned: Bool {
        switch self {
        case .trackNumber, .duration, .year, .bitrate, .sampleRate, .discNumber: return true
        default: return false
        }
    }

    /// The one column that always earns its place, and can't be switched off —
    /// a table of blank rows helps nobody.
    public static let required: TrackColumn = .title

    /// What a fresh install shows: the set every library app opens with.
    public static let defaultSelection: [TrackColumn] = [
        .trackNumber, .title, .duration, .artist, .album
    ]

    /// The cell text for `track`. Empty string when the tag isn't set — a table
    /// says "nothing here" with a blank, not with a dash.
    public func value(for track: LoadedTrack) -> String {
        switch self {
        case .trackNumber:
            return track.track.trackNumber.map { String(format: "%d", $0) } ?? ""
        case .title:
            return track.track.title
        case .duration:
            return Self.durationText(track.track.durationSeconds)
        case .artist:
            return track.track.artist
        case .albumArtist:
            return track.metadata.albumArtist ?? ""
        case .album:
            return track.track.album
        case .genre:
            return track.metadata.genre ?? ""
        case .year:
            return track.track.year.map(String.init) ?? ""
        case .format:
            return track.track.formatName?.uppercased() ?? ""
        case .bitrate:
            return track.track.bitrateKbps.map { "\($0) kbps" } ?? ""
        case .sampleRate:
            return track.track.sampleRateHz.map { rate in
                String(format: "%.1f kHz", Double(rate) / 1000)
            } ?? ""
        case .discNumber:
            return track.track.discNumber.map(String.init) ?? ""
        }
    }

    /// m:ss, or h:mm:ss once a track runs past the hour (a vinyl side rip does).
    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Decode a saved selection, dropping anything unrecognised (a column
    /// removed in a later version) and guaranteeing the required column is
    /// present, so a stale or hand-edited preference can't yield a blank table.
    public static func selection(fromSaved raw: [String]) -> [TrackColumn] {
        var columns = raw.compactMap { TrackColumn(rawValue: $0) }
        columns = columns.reduce(into: []) { acc, c in if !acc.contains(c) { acc.append(c) } }
        guard !columns.isEmpty else { return defaultSelection }
        if !columns.contains(required) { columns.insert(required, at: 0) }
        return columns
    }
}
