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

    /// Delegates to `BrowserState.selectTrack` — the rules live there. The
    /// inspector's album follows by derivation (`selectedAlbum` reads the
    /// anchored track when the view has no Album column), so nothing here
    /// has to keep it in step.
    func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        browser.selectTrack(loaded, command: command, shift: shift, ordered: ordered)
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
        if browser.column(of: .album) != nil {
            selectAllAlbums()
        } else if browser.column(of: .track) != nil {
            selectAllTracks()
        } else {
            // A view ending on a genre, a decade, an artist: everything in
            // its leaf column.
            let leaf = browserView.facets.count - 1
            browser.selectAll(column: leaf, ids: browserColumns[safe: leaf]?.ids ?? [])
        }
    }

    // All three read `browsedIndex`, not `index`: ⌘A has to select what the
    // browser is showing. Under a live search it would otherwise hand the
    // convert queue several thousand rows the user could not see.

    /// Select every artist the browser is showing (the Artist column's "Select All").
    func selectAllArtists() { browser.selectAllArtists(browsedIndex.artists) }

    /// Select every album the browser is showing (the Album column's "Select All").
    func selectAllAlbums() { browser.selectAllAlbums(browsedIndex.allAlbums) }

    /// Select every track the browser is showing (the Track column's "Select All").
    func selectAllTracks() { browser.selectAllTracks(browsedIndex.allTracks) }

    /// The tracks an Add-to-Crate action resolves to: the selected tracks, else the
    /// selected albums' tracks, else the selected artists' tracks, else (fallback)
    /// the single anchor album.
    func selectedTracksForCrateAdd() -> [LoadedTrack] {
        if let multi = browser.selection.multiSelection, !multi.ids.isEmpty {
            // Whatever column owns the set — artists, albums, tracks, genres —
            // the cascade resolves it to tracks the same way.
            return BrowserCascade.selectedTracks(view: browserView, in: browsedIndex,
                                                 selection: browser.selection, context: facetContext)
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
        if (browser.selection.multiSelection?.ids.count ?? 0) > 1 {
            return selectedTracksForCrateAdd()
        }
        // A view that ends on an album or a genre has no single track to
        // mean: the leaf's tracks are the selection.
        if browser.column(of: .track) == nil { return leafTracks }
        return selectedTrack.map { [$0] } ?? []
    }

    /// Add the current selection to a crate (drives the sidebar button + menus).
    func addSelectionToCrate(crateName: String) {
        let tracks = selectedTracksForCrateAdd()
        guard !tracks.isEmpty else { return }
        addItemsToCrate(tracks.map { "track::" + $0.track.id.uuidString }, crateName: crateName)
    }
}
