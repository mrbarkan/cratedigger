import Foundation

/// Derives, from the set of pressings being grouped into one release, a clean base
/// release title plus a short per-pressing label capturing whatever distinguishes
/// each one. The distinguisher most often hides in the album title itself — e.g.
/// `OK Computer (TOSHIBA-EMI TOCP-50201)` → `TOSHIBA-EMI TOCP-50201` — so we strip
/// the shared base and surface the remainder, falling back to year, format, or the
/// source folder when the titles are identical. Used to pre-fill the Group sheet.
public enum VersionDistinguisher {

    /// The shared base release title across the pressings: the longest common prefix
    /// of the titles, trimmed of trailing separators/brackets. Falls back to the
    /// shortest title when there's no meaningful common prefix.
    public static func commonBaseTitle(_ titles: [String]) -> String {
        let trimmed = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = trimmed.first else { return "" }
        var prefix = first
        for title in trimmed.dropFirst() {
            prefix = longestCommonPrefix(prefix, title)
            if prefix.isEmpty { break }
        }
        let cleaned = prefix.trimmingCharacters(in: edgeSeparators)
        if cleaned.count >= 2 { return cleaned }
        return trimmed.min(by: { $0.count < $1.count }) ?? ""
    }

    /// One distinguishing label per album, in the same order. Priority: the differing
    /// tail of the album title vs the common base; else the year (when years differ);
    /// else the format/quality badge (when formats differ); else the source folder
    /// name; else empty (let the user fill it in).
    public static func labels(for albums: [Album]) -> [String] {
        let base = commonBaseTitle(albums.map { $0.title })
        let yearsDiffer = Set(albums.map { $0.year }).count > 1
        let badges = albums.map { VersionLabel.formatBadge(for: $0) }
        let badgesDiffer = Set(badges).count > 1

        return albums.enumerated().map { index, album in
            let tail = titleTail(album.title, base: base)
            if !tail.isEmpty { return tail }
            if yearsDiffer, let year = album.year { return String(year) }
            if badgesDiffer { return badges[index] }
            if let folder = sourceFolder(album) { return folder }
            return ""
        }
    }

    // MARK: - Private

    /// Separators/brackets to strip from the edges of a base title or a tail.
    private static let edgeSeparators =
        CharacterSet(charactersIn: " ()[]{}-–—:·,/|").union(.whitespacesAndNewlines)

    private static func longestCommonPrefix(_ a: String, _ b: String) -> String {
        String(zip(a, b).prefix { $0.0 == $0.1 }.map(\.0))
    }

    /// The portion of `title` following the common `base`, stripped of wrapping
    /// brackets/separators. Empty when the title is just the base.
    private static func titleTail(_ title: String, base: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder: String
        if !base.isEmpty, t.lowercased().hasPrefix(base.lowercased()) {
            remainder = String(t.dropFirst(base.count))
        } else if t.caseInsensitiveCompare(base) == .orderedSame {
            remainder = ""
        } else {
            remainder = t   // titles diverge entirely; the whole title distinguishes
        }
        return remainder.trimmingCharacters(in: edgeSeparators)
    }

    private static func sourceFolder(_ album: Album) -> String? {
        guard let url = album.tracks.first?.track.fileURL, url.isFileURL else { return nil }
        let name = url.deletingLastPathComponent().lastPathComponent
        return name.isEmpty ? nil : name
    }
}
