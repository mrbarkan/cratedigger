import Foundation

/// The period the STATS screen is looking at. Calendar-aligned: "month" is
/// this calendar month, not the last thirty days, because that is what the
/// histogram in `ListeningStats.playsByMonth` can answer exactly.
public enum ListeningWindow: String, Codable, CaseIterable, Sendable {
    case month
    case year
    case allTime

    /// The next window when the period tag on the glass is clicked.
    public var next: ListeningWindow {
        switch self {
        case .month:   return .year
        case .year:    return .allTime
        case .allTime: return .month
        }
    }

    /// The histogram keys the window covers, or nil for all time (which reads
    /// `playCount` instead, since plays before the histogram have no month).
    public func monthKeys(now: Date, calendar: Calendar) -> Set<String>? {
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return nil }
        switch self {
        case .allTime: return nil
        case .month:   return [ListeningStats.monthKey(year: year, month: month)]
        case .year:    return Set((1...12).map { ListeningStats.monthKey(year: year, month: $0) })
        }
    }

    /// "SEPTEMBER 2026", "2026", "ALL TIME". Month names come from the
    /// calendar's locale, so a French machine reads SEPTEMBRE.
    public func title(now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 0
        switch self {
        case .allTime:
            return "ALL TIME"
        case .year:
            return String(year)
        case .month:
            let index = max(0, min(11, (parts.month ?? 1) - 1))
            return "\(calendar.monthSymbols[index].uppercased()) \(year)"
        }
    }
}

/// What the listening history says about one window: how much, and which
/// record, artist and track came out on top. One pass over the store; the
/// view model caches the result and recomputes only when a play is counted
/// while the STATS screen is showing.
public struct ListeningSummary: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Album title, artist bucket, or track title.
        public let name: String
        /// The artist for a record or a track; empty for an artist.
        public let detail: String
        public let plays: Int

        public init(name: String, detail: String, plays: Int) {
            self.name = name
            self.detail = detail
            self.plays = plays
        }
    }

    public let window: ListeningWindow
    public let plays: Int
    /// Σ plays × track duration. An estimate: a play is most of a track by
    /// definition (`PlayThreshold`), and the number people want is hours.
    public let listenedSeconds: Double
    public let recordsTouched: Int
    public let tracksTouched: Int
    public let topRecord: Entry?
    public let topArtist: Entry?
    public let topTrack: Entry?

    public var isEmpty: Bool { plays == 0 }

    public static func compute(
        stats: [String: ListeningStats],
        window: ListeningWindow,
        now: Date = Date(),
        calendar: Calendar = .current,
        resolve: (String) -> LoadedTrack?
    ) -> ListeningSummary {
        let keys = window.monthKeys(now: now, calendar: calendar)
        // The same grouping the browser uses, so "top record" is the browser's
        // album and its artist is the browser's artist row.
        let planner = OutputPathPlanner()

        var plays = 0
        var tracksTouched = 0
        var listenedSeconds = 0.0
        var byRecord: [AlbumFolderKey: Tally] = [:]
        var byArtist: [String: Tally] = [:]
        var byTrack: [String: Tally] = [:]

        for (path, row) in stats {
            let count: Int
            if let keys {
                count = keys.reduce(0) { $0 + (row.playsByMonth[$1] ?? 0) }
            } else {
                count = row.playCount
            }
            guard count > 0 else { continue }
            plays += count
            tracksTouched += 1

            // A path the store has forgotten still happened; it just cannot
            // be named or timed.
            guard let loaded = resolve(path) else { continue }
            listenedSeconds += Double(count) * loaded.track.durationSeconds

            let key = planner.albumFolderKey(for: loaded)
            let albumTitle = loaded.track.album.isEmpty ? key.album : loaded.track.album
            byRecord[key, default: Tally(name: albumTitle, detail: key.artistBucket)].plays += count
            byArtist[key.artistBucket, default: Tally(name: key.artistBucket, detail: "")].plays += count
            byTrack[path, default: Tally(name: loaded.track.title, detail: loaded.track.artist)].plays += count
        }

        return ListeningSummary(
            window: window,
            plays: plays,
            listenedSeconds: listenedSeconds,
            recordsTouched: byRecord.count,
            tracksTouched: tracksTouched,
            topRecord: top(byRecord.values),
            topArtist: top(byArtist.values),
            topTrack: top(byTrack.values)
        )
    }

    private struct Tally {
        let name: String
        let detail: String
        var plays = 0
    }

    /// Most plays wins; on a tie the name that sorts first, so the result is
    /// deterministic rather than whichever the dictionary yielded last.
    private static func top<S: Sequence>(_ tallies: S) -> Entry? where S.Element == Tally {
        tallies.max { a, b in
            if a.plays != b.plays { return a.plays < b.plays }
            return a.name > b.name
        }
        .map { Entry(name: $0.name, detail: $0.detail, plays: $0.plays) }
    }
}
