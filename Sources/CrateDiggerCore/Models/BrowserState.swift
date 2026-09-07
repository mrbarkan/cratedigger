import Foundation

/// A column's ordering: which field, which direction.
///
/// Named `BrowserSort` rather than the obvious `SortOrder` because Foundation
/// already has a `SortOrder`, and a Core type shadowing it is a trap for the
/// next person reading this.
public struct BrowserSort<Field: Equatable & Sendable>: Sendable, Equatable {
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

/// Everything the browser is currently showing you and how: what shape it
/// has, what is picked in each column, and what order each column is in.
///
/// This lived as roughly a dozen loose `@Published` properties on
/// `LibraryViewModel` plus 177 lines of selection rules in an extension, which
/// meant the most-clicked behaviour in the app had no tests at all. As a value
/// type the rules are testable, and the mutual-exclusivity invariant is
/// something one type enforces rather than something several call sites happen
/// to agree on.
///
/// The columns are generic: `view` says what each shows, `selection` holds one
/// anchor per column and at most one multi-selection set, owned by one column.
/// The old names — `selectedArtistID`, `selectedAlbumIDs`, `selectArtist(…)` —
/// are forwards onto whichever column shows that facet, so the ~120 call sites
/// outside the browser did not have to move when the browser stopped being
/// hard-wired to Artist · Album · Track.
public struct BrowserState: Sendable, Equatable {

    // MARK: Shape

    /// What each column shows. Changing it reshapes the anchors and drops the
    /// set: nothing picked in the old columns means anything in the new ones.
    public var view: BrowserView = .classic {
        didSet {
            guard view != oldValue else { return }
            selection = BrowserSelection(anchors: Array(repeating: nil, count: view.facets.count))
        }
    }

    // MARK: Selection
    //
    // One anchor per column — the last thing clicked there, what drill-down
    // reads and what a single selection resolves to — and at most one set.
    // Every click below writes the anchor and moves the set to that column,
    // which is how "you pick artists, or records, or tracks, never a mixture"
    // holds for any three facets.

    public var selection = BrowserSelection(anchors: [nil, nil, nil])

    // MARK: Ordering

    public var trackSort = BrowserSort<TrackSortField>(field: .trackNumber)
    public var albumSort = BrowserSort<AlbumSortField>(field: .year)
    public var artistSort = BrowserSort<ArtistSortField>(field: .name)
    public var valueSort = BrowserSort<ValueSortField>(field: .title)

    public var sorts: BrowserSorts {
        BrowserSorts(artist: artistSort, album: albumSort, track: trackSort, value: valueSort)
    }

    /// Which column the arrow keys act on, as an index into `view.facets`.
    /// May point past the end after the view narrows; readers clamp.
    public var focusedColumn: Int = 2

    // MARK: Filtering

    /// The live search. `LibraryIndex.filtered(by:)` turns it into what the
    /// browser draws; nothing else in the app narrows because of it.
    public var filter = BrowserFilter()

    public init() {}

    // MARK: - Columns by facet

    public func column(of facet: BrowserFacet) -> Int? { view.column(of: facet) }

    private func anchor(of facet: BrowserFacet) -> String? {
        column(of: facet).flatMap { selection.anchor($0) }
    }

    /// A no-op when the view has no such column: there is nowhere to put it.
    private mutating func setAnchor(_ id: String?, of facet: BrowserFacet) {
        guard let column = column(of: facet) else { return }
        selection.anchors[column] = id
    }

    private func set(of facet: BrowserFacet) -> Set<String> {
        guard let column = column(of: facet),
              let multi = selection.multiSelection, multi.column == column else { return [] }
        return multi.ids
    }

    private mutating func setSet(_ ids: Set<String>, of facet: BrowserFacet) {
        guard let column = column(of: facet) else { return }
        if ids.isEmpty {
            if selection.multiSelection?.column == column { selection.multiSelection = nil }
        } else {
            selection.multiSelection = BrowserSelection.MultiSelection(column: column, ids: ids)
        }
    }

    // MARK: - The old names

    public var selectedArtistID: String? {
        get { anchor(of: .artist) }
        set { setAnchor(newValue, of: .artist) }
    }

    public var selectedAlbumID: String? {
        get { anchor(of: .album) }
        set { setAnchor(newValue, of: .album) }
    }

    public var selectedTrackID: UUID? {
        get { anchor(of: .track).flatMap(UUID.init(uuidString:)) }
        set { setAnchor(newValue?.uuidString, of: .track) }
    }

    public var selectedArtistIDs: Set<String> {
        get { set(of: .artist) }
        set { setSet(newValue, of: .artist) }
    }

    public var selectedAlbumIDs: Set<String> {
        get { set(of: .album) }
        set { setSet(newValue, of: .album) }
    }

    public var selectedTrackIDs: Set<UUID> {
        get { Set(set(of: .track).compactMap(UUID.init(uuidString:))) }
        set { setSet(Set(newValue.map(\.uuidString)), of: .track) }
    }

    // MARK: - Predicates

    public func isSelected(column: Int, id: String) -> Bool {
        if selection.anchor(column) == id { return true }
        guard let multi = selection.multiSelection, multi.column == column else { return false }
        return multi.ids.contains(id)
    }

    public func isArtistSelected(_ id: String) -> Bool {
        column(of: .artist).map { isSelected(column: $0, id: id) } ?? false
    }

    public func isAlbumSelected(_ id: String) -> Bool {
        column(of: .album).map { isSelected(column: $0, id: id) } ?? false
    }

    public func isTrackSelected(_ id: UUID) -> Bool {
        column(of: .track).map { isSelected(column: $0, id: id.uuidString) } ?? false
    }

    public mutating func clearMultiSelection() {
        selection.multiSelection = nil
    }

    // MARK: - Clicks

    /// A click in any column with modifier keys. Writes the anchor, moves the
    /// set here, and clears every anchor to the right: their populations just
    /// changed, and `reanchor` puts them on the first row of the new ones.
    /// - Parameter ordered: the column's row ids in display order, which is
    ///   what a shift-range is measured against.
    public mutating func select(column: Int, id: String, command: Bool, shift: Bool, ordered: [String]) {
        guard selection.anchors.indices.contains(column) else { return }
        if command {
            var ids = selection.multiSelection?.column == column ? (selection.multiSelection?.ids ?? []) : []
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            selection.multiSelection = BrowserSelection.MultiSelection(column: column, ids: ids)
        } else if shift, let anchor = selection.anchors[column],
                  let a = ordered.firstIndex(of: anchor),
                  let b = ordered.firstIndex(of: id) {
            selection.multiSelection = BrowserSelection.MultiSelection(column: column, ids: Set(ordered[min(a, b)...max(a, b)]))
        } else {
            selection.multiSelection = BrowserSelection.MultiSelection(column: column, ids: [id])
        }
        selection.anchors[column] = id
        for right in selection.anchors.indices where right > column {
            selection.anchors[right] = nil
        }
    }

    /// Artist-column click. Drills into the artist immediately when the
    /// columns to its right are the classic Album then Track, so a click lands
    /// with the next columns already anchored, as it always has.
    public mutating func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
        guard let column = column(of: .artist) else { return }
        select(column: column, id: artist.id, command: command, shift: shift, ordered: ordered.map(\.id))
        let firstAlbum = artist.albums.first
        if let albumColumn = self.column(of: .album), albumColumn == column + 1 {
            selection.anchors[albumColumn] = firstAlbum?.id
            if let trackColumn = self.column(of: .track), trackColumn == albumColumn + 1 {
                selection.anchors[trackColumn] = firstAlbum?.tracks.first?.track.id.uuidString
            }
        } else if let trackColumn = self.column(of: .track), trackColumn == column + 1 {
            selection.anchors[trackColumn] = firstAlbum?.tracks.first?.track.id.uuidString
        }
    }

    /// Album-column click.
    /// - Parameter flat: true when the click came from somewhere that did not
    ///   go through the Artist column (the gallery, the old Album · Track
    ///   layout), so the artist anchor is set from the album to keep the
    ///   cascade containing it.
    public mutating func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        guard let column = column(of: .album) else { return }
        select(column: column, id: album.id, command: command, shift: shift, ordered: ordered.map(\.id))
        if flat { setAnchor(album.artistID, of: .artist) }
        if let trackColumn = self.column(of: .track), trackColumn == column + 1 {
            selection.anchors[trackColumn] = album.tracks.first?.track.id.uuidString
        }
    }

    /// Track-column click.
    public mutating func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        guard let column = column(of: .track) else { return }
        select(column: column, id: loaded.track.id.uuidString, command: command, shift: shift,
               ordered: ordered.map { $0.track.id.uuidString })
    }

    // MARK: - Select all

    /// Every row of a column, anchored on the first if nothing was.
    public mutating func selectAll(column: Int, ids: [String]) {
        guard !ids.isEmpty, selection.anchors.indices.contains(column) else { return }
        selection.multiSelection = BrowserSelection.MultiSelection(column: column, ids: Set(ids))
        if selection.anchors[column] == nil { selection.anchors[column] = ids.first }
    }

    public mutating func selectAllArtists(_ artists: [Artist]) {
        guard let column = column(of: .artist) else { return }
        selectAll(column: column, ids: artists.map(\.id))
    }

    public mutating func selectAllAlbums(_ albums: [Album]) {
        guard let column = column(of: .album) else { return }
        selectAll(column: column, ids: albums.map(\.id))
    }

    public mutating func selectAllTracks(_ tracks: [LoadedTrack]) {
        guard let column = column(of: .track) else { return }
        selectAll(column: column, ids: tracks.map { $0.track.id.uuidString })
    }

    // MARK: - Re-anchoring and revealing

    /// Point every anchor at something its column actually contains, and
    /// trim the set to rows that are still on screen.
    ///
    /// An anchor that is still there stays; one that is not moves to the first
    /// row of its column, left to right, so each column is re-derived under
    /// the anchor the previous one settled on. The set keeps only ids its
    /// column still shows and goes away when none are left: a selection you
    /// cannot see is one that can still be converted, retagged or added to a
    /// crate, which is the worst way to find out it survived.
    ///
    /// Returns the columns it computed on the way, so a caller that needs
    /// them (the view model does) does not pay for the cascade twice.
    @discardableResult
    public mutating func reanchor(in index: LibraryIndex,
                                  sorts: BrowserSorts? = nil,
                                  context: FacetContext? = nil) -> [ColumnContent] {
        let (settled, columns) = BrowserCascade.reanchored(
            selection, view: view, in: index,
            sorts: sorts ?? self.sorts, context: context ?? FacetContext(index: index))
        selection = settled
        return columns
    }

    /// The outside-in click — "Go to Current Song", the gallery, the condensed
    /// browser: every column's anchor comes from the track, and the set goes.
    public mutating func reveal(track loaded: LoadedTrack, in index: LibraryIndex, context: FacetContext? = nil) {
        let context = context ?? FacetContext(index: index)
        selection = BrowserSelection(anchors: view.facets.map { $0.key(of: loaded, context: context) })
    }
}

/// What the browser is hiding, and how far it is looking.
///
/// The search Phase 1 added: a query plus the scope it runs at. Session-only —
/// the sort pairs above persist, but a search is about what you are looking at
/// right now, and a field that comes back filled after a relaunch reads as a
/// broken library rather than as a remembered query.
public struct BrowserFilter: Sendable, Equatable {

    /// How wide the search casts.
    public enum Scope: String, Sendable, Equatable, Codable {
        /// The source you are in.
        case source
        /// Every crate you own, which is what All Records already is.
        case everywhere
    }

    public var query: String {
        didSet { tokens = Self.tokenize(query) }
    }

    public var scope: Scope

    /// The folded, whitespace-split query. Stored rather than computed because
    /// `matches` runs once per track per keystroke, and re-splitting the query
    /// fourteen thousand times is the one part of this that would be slow.
    private var tokens: [String]

    public init(query: String = "", scope: Scope = .source) {
        self.query = query
        self.scope = scope
        self.tokens = Self.tokenize(query)
    }

    /// False for an empty or all-whitespace query. An inactive filter is the
    /// identity: it matches everything and prunes nothing.
    public var isActive: Bool { !tokens.isEmpty }

    /// Case- and diacritic-folded, so `bjork` finds Björk and `MILES` finds
    /// Miles. Folding once per field beats folding once per comparison.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func tokenize(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every token must appear in at least one field: AND across the query,
    /// OR across the fields. So `mil blue` finds Kind of Blue by artist and
    /// album together, and `mil green` finds nothing.
    private func matches(fields: [String]) -> Bool {
        matches(folded: fields.lazy.map(Self.fold).joined(separator: "\n"))
    }

    /// The hot path: one already-folded haystack, one plain substring scan per
    /// token. Folding is what costs — at fourteen thousand tracks, folding six
    /// fields each on every keystroke is about 150 ms, and doing it once per
    /// track instead is about 10. See `LibraryIndex.searchHaystacks(for:)`.
    private func matches(folded haystack: String) -> Bool {
        guard !tokens.isEmpty else { return true }
        // `.literal`: both sides came out of `fold`, so there is no case or
        // diacritic left to be clever about, and a literal scan is several
        // times what a canonical one costs.
        return tokens.allSatisfy { haystack.range(of: $0, options: .literal) != nil }
    }

    /// The roadmap's five fields, with "artist" read generously: the album
    /// artist is in so `various` finds compilations whose every track is
    /// tagged to somebody else, and the path is in so a folder name that
    /// appears in no tag still finds the rip you filed by hand.
    public static func searchFields(of loaded: LoadedTrack) -> [String] {
        let track = loaded.track
        return [
            track.title,
            track.artist,
            loaded.metadata.albumArtist ?? "",
            track.album,
            track.fileURL.path,
            track.formatName ?? track.fileURL.pathExtension
        ]
    }

    /// One track's fields, pre-folded into the single string `matches` scans.
    public static func haystack(for loaded: LoadedTrack) -> String {
        searchFields(of: loaded).lazy.map(fold).joined(separator: "\n")
    }

    /// - Parameter haystack: this track's pre-folded fields, when the caller
    ///   has them cached. Passing `nil` folds them here instead, which is the
    ///   same answer at several times the cost.
    public func matches(_ loaded: LoadedTrack, haystack: String? = nil) -> Bool {
        if let haystack { return matches(folded: haystack) }
        return matches(fields: Self.searchFields(of: loaded))
    }

    public func matches(album: Album) -> Bool {
        matches(fields: [album.title, album.artistName])
    }

    public func matches(artist: Artist) -> Bool {
        matches(fields: [artist.name])
    }
}
