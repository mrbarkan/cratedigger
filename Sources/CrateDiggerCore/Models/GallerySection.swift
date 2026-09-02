import Foundation

/// One run of albums under a divider in the artwork gallery: a year, an
/// initial, or an artist, whichever the sort is by. Built from the list
/// *after* it's sorted, by cutting wherever the label changes, so the
/// dividers follow ascending and descending alike and never reorder a cover.
public struct GallerySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let albums: [Album]

    public static func sections(of sortedAlbums: [Album], by field: AlbumSortField) -> [GallerySection] {
        var sections: [GallerySection] = []
        var run: [Album] = []
        var runTitle = ""
        for album in sortedAlbums {
            let title = title(for: album, by: field)
            if title != runTitle, !run.isEmpty {
                sections.append(GallerySection(id: "\(sections.count)-\(runTitle)", title: runTitle, albums: run))
                run = []
            }
            runTitle = title
            run.append(album)
        }
        if !run.isEmpty {
            sections.append(GallerySection(id: "\(sections.count)-\(runTitle)", title: runTitle, albums: run))
        }
        return sections
    }

    /// The divider an album falls under. Each reads the same key the sort
    /// compares on (`LibraryIndex.sortedAlbums`), so a divider never splits
    /// what the order kept together.
    public static func title(for album: Album, by field: AlbumSortField) -> String {
        switch field {
        case .year:
            return (album.originalYear ?? album.year).map(String.init) ?? "Unknown Year"
        case .albumArtist:
            let name = album.artistName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Unknown Artist" : name
        case .title:
            let folded = album.title
                .trimmingCharacters(in: .whitespaces)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            guard let first = folded.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
    }

    /// Where ↑/↓ lands from `index` (into the flat sorted list) when the
    /// covers are laid out `columns` wide under these dividers. Each section
    /// starts a fresh row, so a plain ±columns step would jump diagonally
    /// across a divider; this keeps the column and crosses into the
    /// neighbouring section's nearest row, clamped to what that row holds.
    /// Off either end it stays put.
    public static func verticalNeighbor(of index: Int, in sections: [GallerySection], columns: Int, down: Bool) -> Int {
        let columns = max(columns, 1)
        var start = 0
        for (position, section) in sections.enumerated() {
            let count = section.albums.count
            guard index < start + count else { start += count; continue }

            let local = index - start
            let row = local / columns
            let column = local % columns
            if down {
                if (row + 1) * columns < count {
                    return start + min((row + 1) * columns + column, count - 1)
                }
                guard position + 1 < sections.count else { return index }
                let next = sections[position + 1].albums.count
                return start + count + min(column, next - 1)
            } else {
                if row > 0 {
                    return start + (row - 1) * columns + column
                }
                guard position > 0 else { return index }
                let previous = sections[position - 1].albums.count
                let lastRowStart = ((previous - 1) / columns) * columns
                return start - previous + min(lastRowStart + column, previous - 1)
            }
        }
        return index
    }
}
