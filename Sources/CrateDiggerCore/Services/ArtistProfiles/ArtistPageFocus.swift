import Foundation

/// When the inspector's INFO tab shows the artist page rather than the
/// album page, and for whom (spec §1).
///
/// The focused browser column decides, not the anchors: clicking an artist
/// also fills the album anchor to its right, so `selectedAlbum` cannot tell
/// "looking at an artist" from "looking at a record". The artist page shows
/// while the focused column shows the Artist or Album Artist facet, or
/// while an explicit artist is set ("Show Artist" from a track's menu, or
/// the artist name under the album page's cover, for views with no artist
/// column). The view model clears the explicit artist when focus moves to
/// another column, so clicking an album or a track brings the album back.
public enum ArtistPageFocus {
    /// True when INFO should show the artist page.
    public static func showsArtist(view: BrowserView, focusedColumn: Int, explicitArtist: String?) -> Bool {
        if nonBlank(explicitArtist) != nil { return true }
        guard let facet = focused(view, focusedColumn)?.facet else { return false }
        return facet == .artist || facet == .albumArtist
    }

    /// The artist the page is about: the explicit one when set, else the
    /// focused artist column's anchor, by the name its row shows. `columns`
    /// is what the browser already drew (`BrowserCascade`), so this is one
    /// look along one column, never a walk of the library. nil when the page
    /// should not show, or nothing is picked there.
    public static func artistName(view: BrowserView, state: BrowserState, columns: [ColumnContent],
                                  explicitArtist: String?) -> String? {
        if let explicit = nonBlank(explicitArtist) { return explicit }
        guard let (column, facet) = focused(view, state.focusedColumn), facet == .artist || facet == .albumArtist,
              let anchor = state.selection.anchor(column), !anchor.isEmpty,
              columns.indices.contains(column) else { return nil }
        switch columns[column] {
        case .artists(let artists): return nonBlank(artists.first { $0.id == anchor }?.name)
        case .values(let values): return nonBlank(values.first { $0.id == anchor }?.title)
        case .albums, .tracks: return nil
        }
    }

    /// The focused column and its facet, a focus past the end read as the
    /// last column (the view narrowed after focus was set).
    private static func focused(_ view: BrowserView, _ column: Int) -> (column: Int, facet: BrowserFacet)? {
        guard !view.facets.isEmpty else { return nil }
        let clamped = min(max(column, 0), view.facets.count - 1)
        return (clamped, view.facets[clamped])
    }

    private static func nonBlank(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
