import Foundation

/// Which browser column the keyboard arrows act on.
public enum BrowserColumn: Sendable, Equatable {
    case artist, album, track
}

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

/// Everything the browser is currently showing you and how: what is picked and
/// what order it is in.
///
/// This lived as roughly a dozen loose `@Published` properties on
/// `LibraryViewModel` plus 177 lines of selection rules in an extension, which
/// meant the most-clicked behaviour in the app had no tests at all. As a value
/// type the rules are testable, and the mutual-exclusivity invariant is
/// something one type enforces rather than something several call sites happen
/// to agree on.
///
/// Phase 1's search lands in the `filter` seam left at the bottom.
public struct BrowserState: Sendable, Equatable {

    // MARK: Anchors
    //
    // The last thing clicked in each column. Drives drill-down (picking an
    // artist moves the Album and Track columns) and is what a single selection
    // reads from, which is why clearing the multi-selection leaves these alone:
    // the browser always has to be showing something.

    public var selectedArtistID: String?
    public var selectedAlbumID: String?
    public var selectedTrackID: UUID?

    // MARK: Multi-selection
    //
    // Mutually exclusive by construction: you are picking whole artists, or
    // whole records, or individual tracks, never a mixture. Every select method
    // below clears the other two sets first.

    public var selectedArtistIDs: Set<String> = []
    public var selectedAlbumIDs: Set<String> = []
    public var selectedTrackIDs: Set<UUID> = []

    // MARK: Ordering

    public var trackSort = BrowserSort<TrackSortField>(field: .trackNumber)
    public var albumSort = BrowserSort<AlbumSortField>(field: .year)
    public var artistSort = BrowserSort<ArtistSortField>(field: .name)

    public var focusedColumn: BrowserColumn = .track

    // MARK: Filtering

    /// The live search. `LibraryIndex.filtered(by:)` turns it into what the
    /// browser draws; nothing else in the app narrows because of it.
    public var filter = BrowserFilter()

    public init() {}

    // MARK: - Predicates

    public func isArtistSelected(_ id: String) -> Bool {
        selectedArtistIDs.contains(id) || selectedArtistID == id
    }

    public func isAlbumSelected(_ id: String) -> Bool {
        selectedAlbumIDs.contains(id) || selectedAlbumID == id
    }

    public func isTrackSelected(_ id: UUID) -> Bool {
        selectedTrackIDs.contains(id) || selectedTrackID == id
    }

    public mutating func clearMultiSelection() {
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = []
    }

    // MARK: - Clicks

    /// Artist-column click with modifier keys. Clears the album/track sets,
    /// updates the anchor, and drills into the artist so the Album and Track
    /// columns follow.
    /// - Parameter ordered: the artists in their current display order, which is
    ///   what a shift-range is measured against.
    public mutating func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
        let id = artist.id
        selectedAlbumIDs = []
        selectedTrackIDs = []
        if command {
            if selectedArtistIDs.contains(id) { selectedArtistIDs.remove(id) } else { selectedArtistIDs.insert(id) }
        } else if shift, let anchor = selectedArtistID,
                  let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == id }) {
            selectedArtistIDs = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else {
            selectedArtistIDs = [id]
        }
        selectedArtistID = id
        selectedAlbumID = artist.albums.first?.id
        selectedTrackID = artist.albums.first?.tracks.first?.track.id
    }

    /// Album-column click with modifier keys. Clears the artist/track sets,
    /// updates the anchor, and drills into the album so the Track column
    /// follows the last click.
    /// - Parameter flat: true in the flat Album/Track layout, where there is no
    ///   Artist column to have set the artist anchor already.
    public mutating func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        let id = album.id
        selectedArtistIDs = []
        selectedTrackIDs = []
        if command {
            if selectedAlbumIDs.contains(id) { selectedAlbumIDs.remove(id) } else { selectedAlbumIDs.insert(id) }
        } else if shift, let anchor = selectedAlbumID,
                  let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == id }) {
            selectedAlbumIDs = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else {
            selectedAlbumIDs = [id]
        }
        if flat { selectedArtistID = album.artistID }
        selectedAlbumID = id
        selectedTrackID = album.tracks.first?.track.id
    }

    /// Track-column click with modifier keys. Clears the artist/album sets and
    /// updates the anchor.
    public mutating func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        let id = loaded.track.id
        selectedArtistIDs = []
        selectedAlbumIDs = []
        if command {
            if selectedTrackIDs.contains(id) { selectedTrackIDs.remove(id) } else { selectedTrackIDs.insert(id) }
        } else if shift, let anchor = selectedTrackID,
                  let a = ordered.firstIndex(where: { $0.track.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.track.id == id }) {
            selectedTrackIDs = Set(ordered[min(a, b)...max(a, b)].map { $0.track.id })
        } else {
            selectedTrackIDs = [id]
        }
        selectedTrackID = id
    }

    // MARK: - Select all

    public mutating func selectAllArtists(_ artists: [Artist]) {
        guard !artists.isEmpty else { return }
        selectedAlbumIDs = []
        selectedTrackIDs = []
        selectedArtistIDs = Set(artists.map(\.id))
        if selectedArtistID == nil { selectedArtistID = artists.first?.id }
    }

    public mutating func selectAllAlbums(_ albums: [Album]) {
        guard !albums.isEmpty else { return }
        selectedArtistIDs = []
        selectedTrackIDs = []
        selectedAlbumIDs = Set(albums.map(\.id))
        if selectedAlbumID == nil { selectedAlbumID = albums.first?.id }
    }

    public mutating func selectAllTracks(_ tracks: [LoadedTrack]) {
        guard !tracks.isEmpty else { return }
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = Set(tracks.map { $0.track.id })
        if selectedTrackID == nil { selectedTrackID = tracks.first?.track.id }
    }

    // MARK: - Re-anchoring

    /// Point every anchor at something the index actually contains.
    ///
    /// An anchor that is still there stays; one that is not moves to the first
    /// artist, its first album and that album's first track. The
    /// multi-selection sets are cleared outright: a selection you cannot see is
    /// one that can still be converted, retagged or added to a crate, which is
    /// the worst way to find out it survived.
    ///
    /// Called on a source switch (where this used to live inline) and after
    /// every change to `filter`, which hides rows the same way a new source
    /// does.
    public mutating func reanchor(in index: LibraryIndex) {
        clearMultiSelection()

        if let id = selectedArtistID, index.artist(id: id) != nil {
            // Anchor survives; its album/track anchors are checked below.
        } else {
            selectedArtistID = index.artists.first?.id
        }

        let artist = selectedArtistID.flatMap { index.artist(id: $0) }
        // `albumOrVersion`, not `album`: a member pressing inside a grouped
        // release is a legal anchor, and resolving it as missing would bounce
        // the browser off the version row the user just clicked.
        if let id = selectedAlbumID, index.albumOrVersion(id: id) != nil {
            // Keep it.
        } else {
            selectedAlbumID = artist?.albums.first?.id
        }

        let album = selectedAlbumID.flatMap { index.albumOrVersion(id: $0) }
        if let id = selectedTrackID, index.allTracks.contains(where: { $0.track.id == id }) {
            // Keep it.
        } else {
            selectedTrackID = album?.tracks.first?.track.id
        }
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
    private static func fold(_ text: String) -> String {
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
