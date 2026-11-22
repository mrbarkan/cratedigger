import Foundation

/// The words the artist page prints (spec §2), from a profile's facts and
/// the library's summary. Pure, so the page's copy is tested here and the
/// view only lays it out.
public enum ArtistPageText {
    /// One line of facts: kind, origin, years, each left out when unknown.
    /// "Band · Bristol, England · 1991 to now". nil when there is nothing.
    public static func factsLine(_ facts: ArtistFacts) -> String? {
        let parts = [kind(facts.kind), nonBlank(facts.origin), years(begin: facts.begin, end: facts.end)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A MusicBrainz artist type as the page names it: a Group is a Band,
    /// every other type (Person, Orchestra, Choir, Character, Other) as it is.
    public static func kind(_ raw: String?) -> String? {
        guard let raw = nonBlank(raw) else { return nil }
        return raw.caseInsensitiveCompare("Group") == .orderedSame ? "Band" : raw
    }

    /// "1991 to now", "1970 to 1980", "until 1999"; nil when neither is known.
    public static func years(begin: String?, end: String?) -> String? {
        switch (year(begin), year(end)) {
        case let (begin?, end?): return "\(begin) to \(end)"
        case let (begin?, nil): return "\(begin) to now"
        case let (nil, end?): return "until \(end)"
        case (nil, nil): return nil
        }
    }

    /// A member's years in the group. A current member with no start year
    /// shows none rather than a bare "to now".
    public static func memberYears(_ member: ArtistMember) -> String? {
        if member.isCurrent, year(member.begin) == nil { return nil }
        return years(begin: member.begin, end: member.isCurrent ? nil : member.end)
    }

    /// "Mostly FLAC" when one format holds at least 60% of the tracks, just
    /// "FLAC" when it holds all of them, else the top two ("FLAC · MP3").
    public static func formats(_ summary: ArtistLibrarySummary) -> String? {
        if let dominant = summary.dominantFormat {
            return summary.formatCounts.count == 1 ? dominant : "Mostly \(dominant)"
        }
        let top = summary.formatCounts.prefix(2).map(\.0)
        return top.isEmpty ? nil : top.joined(separator: " · ")
    }

    /// Total listening time in hours and minutes: "3 h 4 min", "52 min".
    /// nil for nothing.
    public static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The first letter or digit of the first two words, in capitals, for
    /// the empty portrait (the Artist Pictures sheet's tile); "?" for none.
    public static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace)
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // MARK: - Private

    /// The year at the start of a MusicBrainz date ("1991-03-02" reads 1991).
    private static func year(_ text: String?) -> String? {
        guard let text = nonBlank(text) else { return nil }
        let digits = text.prefix(while: \.isNumber)
        return digits.count >= 3 ? String(digits) : text
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
