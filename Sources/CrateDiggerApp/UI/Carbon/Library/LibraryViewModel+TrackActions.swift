import CrateDiggerCore
import Foundation

/// Track context-menu actions: re-reading tags from disk and replacing a track
/// in place across the Prep Crate and every `.cdlib` that references it.
@MainActor
extension LibraryViewModel {

    /// Replace a track (matched by file path) everywhere it lives — the in-memory
    /// Prep Crate and every crate file — then refresh the active view. Used by tag
    /// edits, marker saves, and Refresh; the path is the stable key.
    func replaceTrackEverywhere(matchingPath path: String, with updated: LoadedTrack) {
        if let i = prepCrateTracks.firstIndex(where: { $0.track.fileURL.path == path }) {
            prepCrateTracks[i] = updated
        }
        for crateName in availableCrates {
            var tracks = loadCrateTracks(name: crateName)
            var modified = false
            for i in tracks.indices where tracks[i].track.fileURL.path == path {
                tracks[i] = updated
                modified = true
            }
            if modified { saveCrateTracks(tracks, name: crateName) }
        }
        selectSource(currentSource)
    }

    /// Re-read a track's tags from disk (context-menu "Refresh Tags"), keeping its
    /// id and any Record Divider markers, and update it everywhere.
    func refreshTrackTags(_ track: LoadedTrack) {
        let url = track.track.fileURL
        let id = track.track.id
        let markers = track.recordMarkers
        Task { [weak self] in
            guard let self else { return }
            let fresh = await self.scanner.reloadTrack(at: url)
            await MainActor.run {
                guard let fresh else {
                    self.appAlert = .error(title: "Refresh Failed",
                                           message: "Couldn't re-read tags from \(url.lastPathComponent).")
                    return
                }
                let updated = LoadedTrack(track: fresh.track.withID(id),
                                          metadata: fresh.metadata,
                                          recordMarkers: markers)
                self.replaceTrackEverywhere(matchingPath: url.path, with: updated)
                self.appAlert = .error(title: "Tags Refreshed",
                                       message: "Re-read tags for “\(updated.track.title)”.")
            }
        }
    }
}
