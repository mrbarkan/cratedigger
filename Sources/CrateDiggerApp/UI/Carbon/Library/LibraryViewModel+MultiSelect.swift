import AppKit
import CrateDiggerCore

/// Multi-selection in the browser (⌘/⇧-click, ⌘A) and the batch Add-to-Crate
/// resolver. Artist, album, and track selections are kept mutually exclusive —
/// you're picking whole artists *or* whole records *or* individual tracks.
@MainActor
extension LibraryViewModel {

    func isArtistSelected(_ id: String) -> Bool {
        selectedArtistIDs.contains(id) || selectedArtistID == id
    }

    func isAlbumSelected(_ id: String) -> Bool {
        selectedAlbumIDs.contains(id) || selectedAlbumID == id
    }

    func isTrackSelected(_ id: UUID) -> Bool {
        selectedTrackIDs.contains(id) || selectedTrackID == id
    }

    func clearMultiSelection() {
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = []
    }

    /// Artist-column click with modifier keys. Clears the album/track sets, updates
    /// the anchor, and drills into the artist so the Album/Track columns follow.
    /// - Parameter ordered: the artists in their current display order (for ⇧-range).
    func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
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

    /// Album-column click with modifier keys. Clears the artist/track sets, updates
    /// the anchor, and drills into the album so the Track column follows the last click.
    /// - Parameter ordered: the albums in their current display order (for ⇧-range).
    func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
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
    func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
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

    /// ⌘A — select everything in the current source (the "batch-add everything"
    /// gesture, e.g. file every album in the Prep Crate into a crate at once). The
    /// selection is made *visible* by matching the browser layout: the album-oriented
    /// layouts (`.full`, `.albumTrack`) show selection in the Album column, while the
    /// Track column there is scoped to a single album — so selecting all *tracks*
    /// would highlight nothing. We therefore select all albums in those layouts and
    /// all tracks only in the flat `.track` layout. Either selection resolves to the
    /// same files through `selectedTracksForCrateAdd()`. When a text field is editing,
    /// the field editor handles Select All first, so this isn't reached.
    func selectAllInSource() {
        switch browserLayout {
        case .full, .albumTrack: selectAllAlbums()
        case .track:             selectAllTracks()
        }
    }

    /// Select every artist in the current source (the Artist column's "Select All").
    func selectAllArtists() {
        let artists = index.artists
        guard !artists.isEmpty else { return }
        selectedAlbumIDs = []
        selectedTrackIDs = []
        selectedArtistIDs = Set(artists.map(\.id))
        if selectedArtistID == nil { selectedArtistID = artists.first?.id }
    }

    /// Select every album in the current source (the Album column's "Select All").
    func selectAllAlbums() {
        let albums = index.allAlbums
        guard !albums.isEmpty else { return }
        selectedArtistIDs = []
        selectedTrackIDs = []
        selectedAlbumIDs = Set(albums.map(\.id))
        if selectedAlbumID == nil { selectedAlbumID = albums.first?.id }
    }

    /// Select every track in the current source (the Track column's "Select All").
    func selectAllTracks() {
        guard !index.allTracks.isEmpty else { return }
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = Set(index.allTracks.map { $0.track.id })
        if selectedTrackID == nil { selectedTrackID = index.allTracks.first?.track.id }
    }

    /// The tracks an Add-to-Crate action resolves to: the selected tracks, else the
    /// selected albums' tracks, else the selected artists' tracks, else (fallback)
    /// the single anchor album.
    func selectedTracksForCrateAdd() -> [LoadedTrack] {
        if !selectedTrackIDs.isEmpty {
            let ids = selectedTrackIDs
            return index.allTracks.filter { ids.contains($0.track.id) }
        }
        if !selectedAlbumIDs.isEmpty {
            let ids = selectedAlbumIDs
            return index.allAlbums.filter { ids.contains($0.id) }.flatMap { $0.tracks }
        }
        if !selectedArtistIDs.isEmpty {
            let ids = selectedArtistIDs
            return index.artists.filter { ids.contains($0.id) }.flatMap { $0.albums }.flatMap { $0.tracks }
        }
        return selectedAlbum?.tracks ?? []
    }

    /// Tracks the Inspector's EDIT TAGS should edit: any genuine multi-selection
    /// (several tracks / albums / artists) resolves to all of its tracks; a single
    /// selection stays the single anchor track (so one-track editing is unchanged,
    /// not promoted to the whole album).
    func tracksForInspectorTagEdit() -> [LoadedTrack] {
        if selectedTrackIDs.count > 1 || selectedAlbumIDs.count > 1 || selectedArtistIDs.count > 1 {
            return selectedTracksForCrateAdd()
        }
        return selectedTrack.map { [$0] } ?? []
    }

    /// Add the current selection to a crate (drives the sidebar button + menus).
    func addSelectionToCrate(crateName: String) {
        let tracks = selectedTracksForCrateAdd()
        guard !tracks.isEmpty else { return }
        addItemsToCrate(tracks.map { "track::" + $0.track.id.uuidString }, crateName: crateName)
    }
}
