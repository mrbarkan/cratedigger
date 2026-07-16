import Foundation

/// Batch tag-editing support: prefill "shared value vs mixed" across many tracks
/// and merge only the fields the user actually changed back onto each track,
/// leaving per-track values untouched. Pure logic so it's unit-testable; the
/// file write stays in the app layer.
public extension ConversionMetadata {

    /// The album/artist-level fields that make sense to edit across a whole
    /// selection. Title and track number stay excluded — a batch shouldn't stamp
    /// the same title or track number onto every track. Disc number *is* shared
    /// by every track on a disc, so stamping it across a selection is exactly the
    /// point (e.g. select all of disc 2, set Disc No = 2).
    enum BatchField: CaseIterable, Sendable {
        case artist, albumArtist, album, genre, year, trackTotal, discNumber, discTotal, comment, compilation, side
    }

    /// This metadata's value for `field` as the editor's string representation
    /// (empty string when the tag is absent).
    func stringValue(_ field: BatchField) -> String {
        switch field {
        case .artist:      return artist ?? ""
        case .albumArtist: return albumArtist ?? ""
        case .album:       return album ?? ""
        case .genre:       return genre ?? ""
        case .year:        return year.map(String.init) ?? ""
        case .trackTotal:  return trackTotal.map(String.init) ?? ""
        case .discNumber:  return discNumber.map(String.init) ?? ""
        case .discTotal:   return discTotal.map(String.init) ?? ""
        case .comment:     return comment ?? ""
        case .compilation: return compilation == true ? "1" : (compilation == false ? "0" : "")
        case .side:        return side ?? ""
        }
    }

    /// The value `field` shares across every item, or `nil` when they differ
    /// (i.e. "mixed" — the editor should show a placeholder, not a value).
    static func commonValue(_ field: BatchField, in items: [ConversionMetadata]) -> String? {
        guard let first = items.first?.stringValue(field) else { return nil }
        return items.allSatisfy { $0.stringValue(field) == first } ? first : nil
    }

    /// Returns a copy with `edits` applied. A key being present means the user
    /// changed that field; an empty string clears the tag. Fields absent from
    /// `edits` are left exactly as they were, so untouched (incl. mixed) fields
    /// and all per-track fields survive.
    func applyingBatchEdits(_ edits: [BatchField: String]) -> ConversionMetadata {
        var out = self
        for (field, raw) in edits {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .artist:      out.artist = value.isEmpty ? nil : value
            case .albumArtist: out.albumArtist = value.isEmpty ? nil : value
            case .album:       out.album = value.isEmpty ? nil : value
            case .genre:       out.genre = value.isEmpty ? nil : value
            case .year:        out.year = Int(value)
            case .trackTotal:  out.trackTotal = Int(value)
            case .discNumber:  out.discNumber = Int(value)
            case .discTotal:   out.discTotal = Int(value)
            case .comment:     out.comment = value.isEmpty ? nil : value
            case .compilation: out.compilation = value == "1" ? true : (value == "0" ? false : nil)
            case .side:        out.side = value.isEmpty ? nil : value.uppercased()
            }
        }
        return out
    }
}
