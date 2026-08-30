import CrateDiggerCore
import Foundation

/// Multi-selection in the browser (⌘/⇧-click, ⌘A) and the batch Add-to-Crate
/// resolver. Artist, album, and track selections are kept mutually exclusive —
/// you're picking whole artists *or* whole records *or* individual tracks.
@MainActor
extension LibraryViewModel {

    func isArtistSelected(_ id: String) -> Bool { browser.isArtistSelected(id) }
    func isAlbumSelected(_ id: String) -> Bool { browser.isAlbumSelected(id) }
    func isTrackSelected(_ id: UUID) -> Bool { browser.isTrackSelected(id) }

    func clearMultiSelection() { browser.clearMultiSelection() }

    /// Delegates to `BrowserState.selectArtist` — the rules live there.
    func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
        browser.selectArtist(artist, command: command, shift: shift, ordered: ordered)
    }

    /// Delegates to `BrowserState.selectAlbum` — the rules live there.
    func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        browser.selectAlbum(album, command: command, shift: shift, ordered: ordered, flat: flat)
    }

    /// Delegates to `BrowserState.selectTrack` — the rules live there.
    func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        browser.selectTrack(loaded, command: command, shift: shift, ordered: ordered)
        // The flat table spans albums, so the inspector's album has to follow
        // the row rather than sit on whatever the hidden Album column holds.
        syncAlbumSelectionToTrack(loaded)
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
        // The gallery is a bool that overlays the browser, not a BrowserLayout
        // case — so without this, ⌘A in gallery mode selected whatever the
        // hidden list browser was showing (often tracks, which the gallery
        // cannot draw).
        if showArtworkGallery {
            selectAllAlbums()
            return
        }
        switch browserLayout {
        case .full, .albumTrack: selectAllAlbums()
        case .track:             selectAllTracks()
        }
    }

    /// Select every artist in the current source (the Artist column's "Select All").
    func selectAllArtists() { browser.selectAllArtists(index.artists) }

    /// Select every album in the current source (the Album column's "Select All").
    func selectAllAlbums() { browser.selectAllAlbums(index.allAlbums) }

    /// Select every track in the current source (the Track column's "Select All").
    func selectAllTracks() { browser.selectAllTracks(index.allTracks) }

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

    /// The shared definition of "what does the selection mean": any genuine
    /// multi-selection (several tracks / albums / artists) resolves to all of
    /// its tracks; a single selection stays the single anchor track (so
    /// one-track editing/rating is unchanged, not promoted to the whole
    /// album). Every selection-scoped action (tag editing, rating, ...)
    /// should route through this so they never disagree about what "the
    /// selection" is.
    func resolvedSelectionTracks() -> [LoadedTrack] {
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
