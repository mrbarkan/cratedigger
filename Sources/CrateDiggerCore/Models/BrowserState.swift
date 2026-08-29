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

    // MARK: - Phase 1 seam
    //
    // Search lands here: a query string plus whatever scope it runs at. Left
    // empty deliberately rather than guessed at, so Phase 1 designs it against
    // a real search field instead of against this comment.
}
