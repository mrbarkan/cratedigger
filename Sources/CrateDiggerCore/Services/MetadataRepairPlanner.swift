import Foundation

/// A tag field the repair pass can fill from a freshly probed file.
public enum MetadataRepairField: String, CaseIterable, Sendable, Codable {
    case title = "Title"
    case artist = "Artist"
    case albumArtist = "Album Artist"
    case album = "Album"
    case trackNumber = "Track #"
    case trackTotal = "Track Total"
    case discNumber = "Disc #"
    case discTotal = "Disc Total"
    case year = "Year"
    case genre = "Genre"
}

/// A field where the crate's stored value and the file's tag both exist but
/// disagree. The stored value is kept; the user decides via the review sheet.
public struct MetadataFieldConflict: Equatable, Sendable, Identifiable {
    public let field: MetadataRepairField
    public let storedValue: String
    public let probedValue: String
    public var id: MetadataRepairField { field }
}

public struct MetadataRepairOutcome: Equatable, Sendable {
    /// Stored metadata with blank fields filled from the probe.
    public let metadata: ConversionMetadata
    public let filledFields: [MetadataRepairField]
    public let conflicts: [MetadataFieldConflict]
    public var didFill: Bool { !filledFields.isEmpty }
}

/// Pure merge logic for healing crate metadata from a fresh file probe.
/// Fills blanks, never overwrites, and surfaces disagreements as conflicts —
/// it does not touch the filesystem; callers re-probe via
/// `LibraryScanService.reloadTrack(at:)` and persist the result.
public enum MetadataRepairPlanner {

    /// A track qualifies for the repair pass when its track number is missing —
    /// the symptom the FIX TAGS button advertises. Year/disc/genre are
    /// legitimately absent on many files, so treating them as candidacy would
    /// re-probe most of the library on every press; they're still *filled*
    /// opportunistically once a candidate is probed.
    public static func needsRepair(_ metadata: ConversionMetadata) -> Bool {
        metadata.trackNumber == nil
    }

    /// The other repair signal: tracks whose (disc, track#) is shared by 2+
    /// tracks of the same album — e.g. an album where every track is "11".
    /// A wrong-but-present number never trips `needsRepair`, so without this an
    /// obviously broken album is never even probed. Pass one album's tracks.
    public static func duplicatedNumberTrackIDs(in albumTracks: [LoadedTrack]) -> Set<UUID> {
        var byNumber: [String: [UUID]] = [:]
        for loaded in albumTracks {
            guard let number = loaded.metadata.trackNumber else { continue }
            byNumber["\(loaded.metadata.discNumber ?? 1)-\(number)", default: []].append(loaded.track.id)
        }
        return Set(byNumber.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Merge a fresh probe into stored crate metadata: blank stored fields take
    /// the probed value; populated fields that disagree become conflicts (stored
    /// value kept).
    public static func repair(stored: ConversionMetadata, probed: ConversionMetadata) -> MetadataRepairOutcome {
        var merged = stored
        var filled: [MetadataRepairField] = []
        var conflicts: [MetadataFieldConflict] = []

        for field in MetadataRepairField.allCases {
            let storedValue = value(of: field, in: stored)
            let probedValue = value(of: field, in: probed)
            switch (storedValue, probedValue) {
            case (nil, .some):
                copy(field, from: probed, into: &merged)
                filled.append(field)
            case let (.some(s), .some(p)) where s != p:
                conflicts.append(MetadataFieldConflict(field: field, storedValue: s, probedValue: p))
            default:
                break
            }
        }

        return MetadataRepairOutcome(metadata: merged, filledFields: filled, conflicts: conflicts)
    }

    /// Apply the file's value for the chosen conflict fields (the review sheet's
    /// "use file value" checkboxes).
    public static func adopt(_ fields: [MetadataRepairField], from probed: ConversionMetadata, into stored: ConversionMetadata) -> ConversionMetadata {
        var result = stored
        for field in fields {
            copy(field, from: probed, into: &result)
        }
        return result
    }

    /// Display/compare value of a field. Strings are trimmed and empty-collapsed
    /// so a stray trailing space never registers as a conflict. Shared with
    /// `ReleaseScorer` so "did this field actually change?" means the same thing
    /// whether the new value came from the file or from an online release.
    public static func value(of field: MetadataRepairField, in metadata: ConversionMetadata) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        switch field {
        case .title: return clean(metadata.title)
        case .artist: return clean(metadata.artist)
        case .albumArtist: return clean(metadata.albumArtist)
        case .album: return clean(metadata.album)
        case .trackNumber: return metadata.trackNumber.map(String.init)
        case .trackTotal: return metadata.trackTotal.map(String.init)
        case .discNumber: return metadata.discNumber.map(String.init)
        case .discTotal: return metadata.discTotal.map(String.init)
        case .year: return metadata.year.map(String.init)
        case .genre: return clean(metadata.genre)
        }
    }

    private static func copy(_ field: MetadataRepairField, from source: ConversionMetadata, into target: inout ConversionMetadata) {
        switch field {
        case .title: target.title = source.title
        case .artist: target.artist = source.artist
        case .albumArtist: target.albumArtist = source.albumArtist
        case .album: target.album = source.album
        case .trackNumber: target.trackNumber = source.trackNumber
        case .trackTotal: target.trackTotal = source.trackTotal
        case .discNumber: target.discNumber = source.discNumber
        case .discTotal: target.discTotal = source.discTotal
        case .year: target.year = source.year
        case .genre: target.genre = source.genre
        }
    }
}
