import Foundation

/// Which rows are picked in each column of a view.
///
/// One anchor per column — the last thing clicked there, what drill-down
/// reads — and at most one multi-selection set, owned by exactly one column.
/// That is the browser's oldest invariant restated for N columns: you are
/// picking things in one column, never a mixture.
public struct BrowserSelection: Equatable, Sendable {
    public var anchors: [String?]
    public var multiSelection: MultiSelection?

    public struct MultiSelection: Equatable, Sendable {
        public var column: Int
        public var ids: Set<String>

        public init(column: Int, ids: Set<String>) {
            self.column = column
            self.ids = ids
        }
    }

    public init(anchors: [String?] = [], multiSelection: MultiSelection? = nil) {
        self.anchors = anchors
        self.multiSelection = multiSelection
    }

    public func anchor(_ column: Int) -> String? {
        anchors.indices.contains(column) ? anchors[column] : nil
    }

    /// What a column narrows the next one by: its set if it owns one, else
    /// its anchor, else nothing — a column with nothing picked passes
    /// everything through, so a fresh view is never empty.
    public func effectiveIDs(column: Int) -> Set<String>? {
        if let multi = multiSelection, multi.column == column, !multi.ids.isEmpty { return multi.ids }
        return anchor(column).map { [$0] }
    }
}

/// How a value column (genre, year, …) is ordered.
public enum ValueSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case title
    case count

    public var displayName: String {
        switch self {
        case .title: return "Name"
        case .count: return "Count"
        }
    }
}

/// The four sort pairs the cascade orders columns by: the three the browser
/// has always had, plus one for value columns.
public struct BrowserSorts: Equatable, Sendable {
    public var artist: BrowserSort<ArtistSortField>
    public var album: BrowserSort<AlbumSortField>
    public var track: BrowserSort<TrackSortField>
    public var value: BrowserSort<ValueSortField>

    public init(artist: BrowserSort<ArtistSortField>,
                album: BrowserSort<AlbumSortField>,
                track: BrowserSort<TrackSortField>,
                value: BrowserSort<ValueSortField>) {
        self.artist = artist
        self.album = album
        self.track = track
        self.value = value
    }

    public static let defaults = BrowserSorts(
        artist: BrowserSort(field: .name),
        album: BrowserSort(field: .year),
        track: BrowserSort(field: .trackNumber),
        value: BrowserSort(field: .title)
    )
}

/// What one column draws. Artist, Album and Track columns carry the index's
/// own objects so rows keep their art, version groups and disc headers;
/// everything else is a value row.
public enum ColumnContent: Equatable, Sendable {
    case artists([Artist])
    case albums([Album])
    case tracks([LoadedTrack])
    case values([FacetValue])

    /// Row ids in display order — what shift-ranges and the arrow keys walk.
    public var ids: [String] {
        switch self {
        case .artists(let artists): return artists.map(\.id)
        case .albums(let albums):   return albums.map(\.id)
        case .tracks(let tracks):   return tracks.map { $0.track.id.uuidString }
        case .values(let values):   return values.map(\.id)
        }
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { count == 0 }
}

/// The browser: column k shows facet k's values among the tracks surviving
/// columns 0..<k.
///
/// The index is a lookup here, not the shape of the browser. Every column is
/// a pass over the surviving population, so a view is at most three passes
/// over the source, and a click in column k only invalidates the columns to
/// its right.
public enum BrowserCascade {

    /// One `ColumnContent` per facet in the view.
    public static func columns(view: BrowserView,
                               in index: LibraryIndex,
                               selection: BrowserSelection,
                               sorts: BrowserSorts,
                               context: FacetContext) -> [ColumnContent] {
        var population = index.allTracks
        var result: [ColumnContent] = []
        result.reserveCapacity(view.facets.count)
        for (column, facet) in view.facets.enumerated() {
            result.append(content(of: facet, population: population, index: index, sorts: sorts, context: context))
            if column < view.facets.count - 1 {
                population = narrow(population, by: facet, to: selection.effectiveIDs(column: column),
                                    index: index, context: context)
            }
        }
        return result
    }

    /// What "the selection" means, in one place.
    ///
    /// A multi-selection is what the user picked, literally: its rows' tracks,
    /// over the whole index, ignoring the anchors on either side. ⌘A on the
    /// Album column selects every album in the source, not the anchored
    /// artist's, and the track anchor to its right must not shrink that to one
    /// song. Without a set, the anchors narrow all the way down: a single
    /// click at a Track leaf is that track, at an Album leaf the album's
    /// surviving tracks, at a Genre leaf the genre's. Index order.
    public static func selectedTracks(view: BrowserView,
                                      in index: LibraryIndex,
                                      selection: BrowserSelection,
                                      context: FacetContext) -> [LoadedTrack] {
        if let multi = selection.multiSelection, !multi.ids.isEmpty,
           view.facets.indices.contains(multi.column) {
            return narrow(index.allTracks, by: view.facets[multi.column], to: multi.ids,
                          index: index, context: context)
        }
        var population = index.allTracks
        for (column, facet) in view.facets.enumerated() {
            population = narrow(population, by: facet, to: selection.effectiveIDs(column: column),
                                index: index, context: context)
        }
        return population
    }

    // MARK: - Re-anchoring

    /// `selection` with every anchor on something its column contains and the
    /// set trimmed to rows still shown, plus the columns as they stand after.
    /// One pass: column k is computed, its anchor settled, then k+1 is
    /// narrowed by the settled anchor — so a re-anchored column 0 re-derives
    /// column 1 under the artist it actually landed on.
    /// - Parameters:
    ///   - from: the first column whose content is recomputed. Columns before
    ///     it are taken from `reusing` — a click in column k changes nothing
    ///     to its left, and the sort of a fourteen-thousand-row Track column
    ///     is not something to repeat on every arrow key.
    ///   - pruningSet: whether the multi-selection is trimmed to rows still
    ///     shown. True when the index or the search changed under it; false
    ///     for a click, because ⌘A may have selected albums outside the
    ///     anchored artist on purpose and they must survive the next click.
    public static func reanchored(_ selection: BrowserSelection,
                                  view: BrowserView,
                                  in index: LibraryIndex,
                                  sorts: BrowserSorts,
                                  context: FacetContext,
                                  from: Int = 0,
                                  reusing: [ColumnContent] = [],
                                  pruningSet: Bool = true) -> (BrowserSelection, [ColumnContent]) {
        var settled = BrowserSelection(anchors: Array(repeating: nil, count: view.facets.count),
                                       multiSelection: pruningSet ? nil : selection.multiSelection)
        var population = index.allTracks
        var columns: [ColumnContent] = []
        for (column, facet) in view.facets.enumerated() {
            let content: ColumnContent
            if column < from, reusing.indices.contains(column) {
                content = reusing[column]
            } else {
                content = self.content(of: facet, population: population, index: index, sorts: sorts, context: context)
            }
            columns.append(content)
            let ids = content.ids
            let idSet = Set(ids)
            // A version member is present when its release is: the row the
            // browser shows is the release, the member is disclosed under it.
            func present(_ id: String) -> Bool {
                if idSet.contains(id) { return true }
                guard facet == .album, let top = context.topLevelAlbumID(forAlbumID: id) else { return false }
                return idSet.contains(top)
            }
            let anchor = selection.anchor(column)
            settled.anchors[column] = anchor.flatMap { present($0) ? $0 : nil } ?? ids.first
            if pruningSet, let multi = selection.multiSelection, multi.column == column {
                let kept = multi.ids.filter(present)
                if !kept.isEmpty {
                    settled.multiSelection = BrowserSelection.MultiSelection(column: column, ids: kept)
                }
            }
            if column < view.facets.count - 1 {
                population = narrow(population, by: facet, to: settled.effectiveIDs(column: column),
                                    index: index, context: context)
            }
        }
        return (settled, columns)
    }

    // MARK: - Narrowing

    /// The tracks in `tracks` whose facet key is one of `ids`. Nil ids narrow
    /// nothing. An Album column narrows by containment rather than key
    /// equality, so a version member's id — which is no track's own key —
    /// still selects that pressing.
    private static func narrow(_ tracks: [LoadedTrack],
                               by facet: BrowserFacet,
                               to ids: Set<String>?,
                               index: LibraryIndex,
                               context: FacetContext) -> [LoadedTrack] {
        guard let ids, !ids.isEmpty else { return tracks }
        switch facet {
        case .album:
            var contained: Set<UUID> = []
            for id in ids {
                if let album = index.albumOrVersion(id: id) {
                    contained.formUnion(album.tracks.map(\.track.id))
                }
            }
            return tracks.filter { contained.contains($0.track.id) }
        default:
            return tracks.filter { ids.contains(facet.key(of: $0, context: context)) }
        }
    }

    // MARK: - Content

    private static func content(of facet: BrowserFacet,
                                population: [LoadedTrack],
                                index: LibraryIndex,
                                sorts: BrowserSorts,
                                context: FacetContext) -> ColumnContent {
        switch facet {
        case .artist:
            let present = Set(population.compactMap { context.artistID(of: $0.track.id) })
            let artists = index.artists.filter { present.contains($0.id) }
            return .artists(LibraryIndex.sortedArtists(artists, by: sorts.artist.field, ascending: sorts.artist.ascending))
        case .album:
            let present = Set(population.compactMap { context.albumID(of: $0.track.id) })
            let albums = index.allAlbums.filter { present.contains($0.id) }
            return .albums(LibraryIndex.sortedAlbums(albums, by: sorts.album.field, ascending: sorts.album.ascending))
        case .track:
            return .tracks(LibraryIndex.sortedTracks(population, by: sorts.track.field, ascending: sorts.track.ascending))
        default:
            return .values(values(of: facet, population: population, sort: sorts.value, context: context))
        }
    }

    /// Distinct keys with counts, first spelling wins the title.
    private static func values(of facet: BrowserFacet,
                               population: [LoadedTrack],
                               sort: BrowserSort<ValueSortField>,
                               context: FacetContext) -> [FacetValue] {
        var byKey: [String: FacetValue] = [:]
        var order: [String] = []
        for loaded in population {
            let value = facet.value(of: loaded, context: context)
            if byKey[value.id] == nil {
                order.append(value.id)
                byKey[value.id] = value
            }
            byKey[value.id]?.count += 1
        }
        var rows = order.compactMap { byKey[$0] }
        rows.sort { a, b in
            let ordered: Bool
            switch sort.field {
            case .title:
                ordered = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .count:
                ordered = a.count != b.count
                    ? a.count < b.count
                    : a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            return sort.ascending ? ordered : !ordered
        }
        return rows
    }
}
