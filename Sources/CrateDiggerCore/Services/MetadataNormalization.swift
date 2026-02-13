import Foundation

public enum MetadataNormalization {
    private static let canonicalKeyGroups: [Set<String>] = [
        Set(["title"]),
        Set(["artist"]),
        Set(["albumartist"]),
        Set(["album"]),
        Set(["compilation", "tcmp", "cpil"]),
        Set(["tracknumber", "track", "trck"]),
        Set(["tracktotal", "totaltracks"]),
        Set(["discnumber", "disc", "disk", "tpos"]),
        Set(["disctotal", "totaldiscs"]),
        Set(["date", "year", "originalyear"]),
        Set(["genre"]),
        Set(["comment", "description"])
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

    private static func customTagPairs(from tags: [String: String]) -> [MetadataTagPair] {
        let canonicalKeys = Set(canonicalKeyGroups.joined())
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
