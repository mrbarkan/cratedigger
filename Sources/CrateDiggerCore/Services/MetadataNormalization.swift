import Foundation

public enum MetadataNormalization {
    private static let canonicalKeys: Set<String> = [
        "title",
        "artist",
        "albumartist",
        "album",
        "compilation", "tcmp", "cpil",
        "tracknumber", "track", "trck",
        "tracktotal", "totaltracks",
        "discnumber", "disc", "disk", "tpos",
        "disctotal", "totaldiscs",
        "date", "year", "originalyear",
        "genre",
        "comment", "description"
    ]

    public static func normalize(
        formatTags: [String: String],
        fallback: ConversionMetadata = ConversionMetadata(),
        artwork: ArtworkAsset? = nil
    ) -> ConversionMetadata {
        let normalizedTags = normalizedTagMap(from: formatTags)

        let title = coalesce(
            firstTagValue(in: normalizedTags, keys: ["title"]),
            fallback.title
        )
        let artist = coalesce(
            firstTagValue(in: normalizedTags, keys: ["artist"]),
            fallback.artist
        )
        let albumArtist = coalesce(
            firstTagValue(in: normalizedTags, keys: ["albumartist"]),
            fallback.albumArtist
        )
        let album = coalesce(
            firstTagValue(in: normalizedTags, keys: ["album"]),
            fallback.album
        )
        let genre = coalesce(
            firstTagValue(in: normalizedTags, keys: ["genre"]),
            fallback.genre
        )
        let comment = coalesce(
            firstTagValue(in: normalizedTags, keys: ["comment", "description"]),
            fallback.comment
        )
        let year = coalesce(
            yearValue(from: firstTagValue(in: normalizedTags, keys: ["date", "year", "originalyear"])),
            fallback.year
        )
        let compilation = coalesce(
            boolValue(from: firstTagValue(in: normalizedTags, keys: ["compilation", "tcmp", "cpil"])),
            fallback.compilation
        )

        let parsedTrack = parseIndexAndTotal(
            firstTagValue(in: normalizedTags, keys: ["tracknumber", "track", "trck"])
        )
        let parsedTrackTotal = intValue(from: firstTagValue(in: normalizedTags, keys: ["tracktotal", "totaltracks"]))
        let trackNumber = coalesce(parsedTrack.number, fallback.trackNumber)
        let trackTotal = coalesce(parsedTrack.total, parsedTrackTotal, fallback.trackTotal)

        let parsedDisc = parseIndexAndTotal(
            firstTagValue(in: normalizedTags, keys: ["discnumber", "disc", "disk", "tpos"])
        )
        let parsedDiscTotal = intValue(from: firstTagValue(in: normalizedTags, keys: ["disctotal", "totaldiscs"]))
        let discNumber = coalesce(parsedDisc.number, fallback.discNumber)
        let discTotal = coalesce(parsedDisc.total, parsedDiscTotal, fallback.discTotal)

        let customTags = customTagPairs(from: formatTags)
        let resolvedArtwork = artwork ?? fallback.artwork

        return ConversionMetadata(
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            compilation: compilation,
            trackNumber: trackNumber,
            trackTotal: trackTotal,
            discNumber: discNumber,
            discTotal: discTotal,
            year: year,
            genre: genre,
            comment: comment,
            customTagPairs: customTags,
            artwork: resolvedArtwork
        )
    }

    /// Infer a track number from a filename (extension already stripped) when
    /// the tags carry none — "01 Song", "03 - Song", "7. Song", "04_Song", a
    /// bare "04", or a disc-track prefix like "1-01 Song" / "2.05 Song".
    /// Conservative on purpose: only a *leading* 1–2 digit run followed by a
    /// separator counts, so years ("1999 - Song") and titles that merely
    /// contain numbers never match.
    public static func trackNumber(fromFilename name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Disc-track prefix ("1-01 Song", "2.05 Song"): the second run is the track.
        if let match = trimmed.firstMatch(of: #/^(\d)[-.](\d{1,2})(?:[\s._)-]|$)/#),
           let number = Int(match.2), number >= 1 {
            return number
        }
        if let match = trimmed.firstMatch(of: #/^(\d{1,2})(?:[\s._)-]|$)/#),
           let number = Int(match.1), number >= 1 {
            return number
        }
        return nil
    }

    /// Best-effort title from a filename: strip a leading track number and any
    /// "Artist - " prefix, then tidy separators. Used only where the file has no
    /// title tag at all — a guess good enough to *search* with, never something
    /// written to a file without review.
    public static func title(fromFilename name: String) -> String? {
        var text = name.trimmingCharacters(in: .whitespaces)

        // Leading track number: "03 - Song", "1-01. Song", "04_Song".
        if let match = text.firstMatch(of: #/^\d{1,2}(?:[-.]\d{1,2})?\s*[-._)\s]\s*/#) {
            text = String(text[match.range.upperBound...])
        }
        // "Artist - Song" → "Song". Only the FIRST dash splits, and only when
        // both sides have substance, so "Song - Part 2" keeps its tail.
        if let range = text.range(of: " - "), range.lowerBound != text.startIndex {
            let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { text = tail }
        }

        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.split(separator: " ").joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Artist / album / year inferred from an album folder name. Recognizes the
    /// common rip layouts: "Artist - Album (1997)", "Album (1997)", "Album".
    /// Every component is optional — an unparseable name yields all `nil` rather
    /// than a wrong guess.
    public static func albumFolderComponents(
        _ folderName: String
    ) -> (artist: String?, album: String?, year: Int?) {
        var text = folderName.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return (nil, nil, nil) }

        // Trailing "(1997)" / "[1997]" — a 4-digit run in the plausible range.
        var year: Int?
        if let match = text.firstMatch(of: #/[\(\[](\d{4})[\)\]]\s*$/#),
           let parsed = Int(match.1), isPlausibleReleaseYear(parsed) {
            year = parsed
            text = String(text[text.startIndex..<match.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        // Leading "1997 - " (year-first layouts).
        if year == nil, let match = text.firstMatch(of: #/^(\d{4})\s*[-._]\s*/#),
           let parsed = Int(match.1), isPlausibleReleaseYear(parsed) {
            year = parsed
            text = String(text[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // "Artist - Album": first dash splits, both sides must have substance.
        if let range = text.range(of: " - ") {
            let artist = String(text[text.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let album = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !album.isEmpty {
                return (artist, album, year)
            }
        }

        return (nil, text.isEmpty ? nil : text, year)
    }

    /// Recorded music starts around 1900 and nothing is released in the future,
    /// so a "year" outside that window is part of the title — "Blade Runner
    /// (2049)", "1984", "Blink-182 (1999)". The +1 leaves room for a pressing
    /// dated to next year at the turn of a year.
    private static func isPlausibleReleaseYear(_ year: Int) -> Bool {
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (1900...(thisYear + 1)).contains(year)
    }

    private static func customTagPairs(from tags: [String: String]) -> [MetadataTagPair] {
        var results: [MetadataTagPair] = []
        results.reserveCapacity(tags.count)

        for (rawKey, rawValue) in tags {
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else {
                continue
            }

            let normalizedKey = normalizedKey(rawKey)
            if canonicalKeys.contains(normalizedKey) {
                continue
            }

            results.append(MetadataTagPair(key: rawKey, value: trimmedValue))
        }

        return results.sorted { lhs, rhs in
            let keyCompare = lhs.key.localizedCaseInsensitiveCompare(rhs.key)
            if keyCompare != .orderedSame {
                return keyCompare == .orderedAscending
            }
            return lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
        }
    }

    private static func normalizedTagMap(from tags: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in tags {
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else {
                continue
            }

            let normalizedKey = normalizedKey(key)
            if normalized[normalizedKey] == nil {
                normalized[normalizedKey] = cleanedValue
            }
        }

        return normalized
    }

    private static func firstTagValue(in normalizedTags: [String: String], keys: [String]) -> String? {
        for key in keys {
            let normalizedLookupKey = normalizedKey(key)
            if let value = normalizedTags[normalizedLookupKey], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseIndexAndTotal(_ rawValue: String?) -> (number: Int?, total: Int?) {
        guard let rawValue else {
            return (nil, nil)
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil)
        }

        if trimmed.contains("/") {
            let components = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let index = components.first.flatMap { intValue(from: String($0)) }
            let total = components.count > 1 ? intValue(from: String(components[1])) : nil
            return (index, total)
        }

        return (intValue(from: trimmed), nil)
    }

    private static func intValue(from rawValue: String?) -> Int? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let direct = Int(trimmed) {
            return direct
        }

        let firstNumericRun = trimmed.split(whereSeparator: { !$0.isNumber }).first
        return firstNumericRun.flatMap { Int($0) }
    }

    private static func yearValue(from rawValue: String?) -> Int? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        for numericRun in trimmed.split(whereSeparator: { !$0.isNumber }) {
            guard numericRun.count == 4, let year = Int(numericRun), (1000...2999).contains(year) else {
                continue
            }
            return year
        }

        if let numeric = intValue(from: trimmed), (1000...2999).contains(numeric) {
            return numeric
        }
        return nil
    }

    private static func boolValue(from rawValue: String?) -> Bool? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            if let numeric = Int(normalized) {
                return numeric != 0
            }
            return nil
        }
    }

    private static func normalizedKey(_ rawKey: String) -> String {
        rawKey
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private static func coalesce(_ values: String?...) -> String? {
        for value in values {
            guard let value else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func coalesce(_ values: Int?...) -> Int? {
        for value in values {
            if let value {
                return value
            }
        }
        return nil
    }

    private static func coalesce(_ values: Bool?...) -> Bool? {
        for value in values {
            if let value {
                return value
            }
        }
        return nil
    }
}
