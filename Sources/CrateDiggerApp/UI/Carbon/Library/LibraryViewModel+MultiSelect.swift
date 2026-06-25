import AppKit
import CrateDiggerCore

/// Multi-selection in the browser (⌘/⇧-click, ⌘A) and the batch Add-to-Crate
/// resolver. Album and track selections are kept mutually exclusive — you're
/// picking whole records *or* individual tracks.
@MainActor
extension LibraryViewModel {

    func isAlbumSelected(_ id: String) -> Bool {
        selectedAlbumIDs.contains(id) || selectedAlbumID == id
    }

    func isTrackSelected(_ id: UUID) -> Bool {
        selectedTrackIDs.contains(id) || selectedTrackID == id
    }

    func clearMultiSelection() {
        selectedAlbumIDs = []
        selectedTrackIDs = []
    }

    /// Album-column click with modifier keys. Clears the track set, updates the
    /// anchor, and drills into the album so the Track column follows the last click.
    /// - Parameter ordered: the albums in their current display order (for ⇧-range).
    func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        let id = album.id
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

    /// Track-column click with modifier keys. Clears the album set and updates the
    /// anchor.
    func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        let id = loaded.track.id
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

    /// ⌘A — select every track in the current source (the "batch-add everything"
    /// gesture). When a text field is editing, the menu's Select All is handled by
    /// the field editor first, so this isn't reached.
    func selectAllTracksInSource() {
        guard !index.allTracks.isEmpty else { return }
        selectedAlbumIDs = []
        selectedTrackIDs = Set(index.allTracks.map { $0.track.id })
        if selectedTrackID == nil { selectedTrackID = index.allTracks.first?.track.id }
    }

    /// The tracks an Add-to-Crate action resolves to: the selected tracks, else
    /// the selected albums' tracks, else (fallback) the single anchor album.
    func selectedTracksForCrateAdd() -> [LoadedTrack] {
        if !selectedTrackIDs.isEmpty {
            let ids = selectedTrackIDs
            return index.allTracks.filter { ids.contains($0.track.id) }
        }
        if !selectedAlbumIDs.isEmpty {
            let ids = selectedAlbumIDs
            return index.allAlbums.filter { ids.contains($0.id) }.flatMap { $0.tracks }
        }
        return selectedAlbum?.tracks ?? []
    }

    /// Add the current selection to a crate (drives the sidebar button + menus).
    func addSelectionToCrate(crateName: String) {
        let tracks = selectedTracksForCrateAdd()
        guard !tracks.isEmpty else { return }
        addItemsToCrate(tracks.map { "track::" + $0.track.id.uuidString }, crateName: crateName)
    }
}
