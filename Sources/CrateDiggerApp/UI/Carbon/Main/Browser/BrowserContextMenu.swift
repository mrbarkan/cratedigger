import SwiftUI
import AppKit
import CrateDiggerCore

/// Shared right-click menu contents for albums and tracks, so the column browser
/// and the artwork gallery offer the same actions. Source-specific items (remove
/// from the current crate / from the library) are appended based on
/// `model.currentSource`. Callers may add their own extra items after these (e.g.
/// the gallery's "Search Cover Art" / "Open Booklet").
@MainActor
enum BrowserContextMenu {

    /// Menu for a single artist. "Add to Crate" becomes "Add N Artists to Crate"
    /// when the clicked artist is part of a multi-artist selection, mirroring the
    /// album/track menus. Always offers Select All, so it's never an empty popup.
    @ViewBuilder
    static func artist(_ artist: Artist, model: LibraryViewModel) -> some View {
        if !model.availableCrates.isEmpty {
            let usesSelection = model.selectedArtistIDs.count > 1 && model.selectedArtistIDs.contains(artist.id)
            Menu(usesSelection ? "Add \(model.selectedArtistIDs.count) Artists to Crate" : "Add to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        if usesSelection {
                            model.addSelectionToCrate(crateName: crate)
                        } else {
                            model.addItemsToCrate(["artist::" + artist.id], crateName: crate)
                        }
                    }
                }
            }
            moveToCrateMenu(for: usesSelection ? model.selectedTracksForCrateAdd() : artist.albums.flatMap { $0.tracks },
                            model: model)
        }
        Button("Select All") { model.selectAllArtists() }

        Divider()
        Button("Edit Tags…") {
            if model.selectedArtistIDs.count > 1 && model.selectedArtistIDs.contains(artist.id) {
                model.editTags(for: model.selectedTracksForCrateAdd())
            } else {
                model.editTags(for: artist.albums.flatMap { $0.tracks })
            }
        }
        Button("View Artwork") {
            if let album = artworkAlbum(for: artist) { model.showArtwork(for: album) }
        }
        let usesSel = model.selectedArtistIDs.count > 1 && model.selectedArtistIDs.contains(artist.id)
        transferToDeviceMenu(for: usesSel ? model.selectedTracksForCrateAdd() : artist.albums.flatMap { $0.tracks },
                             model: model)
        // One representative track — revealing every album would spawn a Finder
        // window per folder.
        showInFinderButton(for: artist.albums.first?.tracks.first.map { [$0] } ?? [])

        if case .localCrate(let crateName) = model.currentSource {
            Divider()
            Button("Remove from “\(crateName)”") { model.removeArtistFromCrate(artist, crateName: crateName) }
        }
    }

    /// "Transfer to Device" submenu — lists saved device profiles; picking one
    /// copies/converts the given tracks straight to that device with its saved
    /// settings. With no profiles saved yet, a single item opens the transfer
    /// sheet whose empty-state points the user at Preferences > Devices. Hidden
    /// for streaming sources whose tracks have no on-disk file to copy.
    @ViewBuilder
    static func transferToDeviceMenu(for tracks: [LoadedTrack], model: LibraryViewModel) -> some View {
        if tracks.contains(where: { $0.track.fileURL.isFileURL }) {
            Menu("Transfer to Device") {
                let profiles = model.prefs.savedExternalDeviceProfiles
                if profiles.isEmpty {
                    Button("Set Up a Device…") { model.requestExternalDeviceTransfer() }
                } else {
                    ForEach(profiles) { profile in
                        Button(profile.name) { model.transferToDevice(profileID: profile.id, tracks: tracks) }
                    }
                }
            }
            .disabled(model.isConversionRunning)
        }
    }

    /// "Show in Finder" — reveals the given tracks' files in Finder (selecting
    /// them). Only shown for real on-disk files, so it's hidden for Radio / remote
    /// streaming sources whose tracks have no file URL.
    @ViewBuilder
    static func showInFinderButton(for tracks: [LoadedTrack]) -> some View {
        let urls = tracks.map { $0.track.fileURL }.filter { $0.isFileURL }
        if !urls.isEmpty {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    /// Best album to represent an artist's artwork: the first with embedded art
    /// or a booklet, else just the first album.
    private static func artworkAlbum(for artist: Artist) -> Album? {
        artist.albums.first { $0.artworkHash != nil || $0.booklet != nil } ?? artist.albums.first
    }

    /// Menu for a single album. "Add to Crate" becomes "Add N Albums to Crate"
    /// when the clicked album is part of a multi-album selection, mirroring the
    /// track menu. Always offers Play + Select All, so it's never an empty popup.
    @ViewBuilder
    static func album(_ album: Album, model: LibraryViewModel) -> some View {
        Button("Play Album") {
            model.selectedArtistID = album.artistID
            model.selectedAlbumID = album.id
            if let first = album.tracks.first { model.playTrack(id: first.track.id) }
        }
        .disabled(album.tracks.isEmpty)

        if !model.availableCrates.isEmpty {
            let usesSelection = model.selectedAlbumIDs.count > 1 && model.selectedAlbumIDs.contains(album.id)
            Menu(usesSelection ? "Add \(model.selectedAlbumIDs.count) Albums to Crate" : "Add to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        if usesSelection {
                            model.addSelectionToCrate(crateName: crate)
                        } else {
                            model.addItemsToCrate(album.tracks.map { "track::" + $0.track.id.uuidString }, crateName: crate)
                        }
                    }
                }
            }
            moveToCrateMenu(for: usesSelection ? model.selectedTracksForCrateAdd() : album.tracks, model: model)
        }
        Button("Select All") { model.selectAllAlbums() }

        if model.canGroupSelectionAnyKind {
            let n = model.selectedAlbumsForGrouping().filter { !$0.isVersionGroup }.count
            Menu("Group \(n) as") {
                Button("Version") { model.beginGroup(kind: .versionGroup) }
                    .disabled(!model.canGroup(as: .versionGroup))
                Button("Box Set") { model.beginGroup(kind: .boxSet) }
                Button("Compilation") { model.beginGroup(kind: .compilation) }
            }
        }

        Divider()
        Button("Edit Tags…") {
            if model.selectedAlbumIDs.count > 1 && model.selectedAlbumIDs.contains(album.id) {
                model.editTags(for: model.selectedTracksForCrateAdd())
            } else {
                model.editTags(for: album.tracks)
            }
        }
        Button("View Artwork") { model.showArtwork(for: album) }
        let usesSel = model.selectedAlbumIDs.count > 1 && model.selectedAlbumIDs.contains(album.id)
        transferToDeviceMenu(for: usesSel ? model.selectedTracksForCrateAdd() : album.tracks, model: model)
        showInFinderButton(for: album.tracks)

        removalItems(forAlbum: album, model: model)
    }

    /// Menu for a single track. Mirrors the album menu's selection-aware Add and
    /// Select All, and keeps the Record-Divider / Refresh actions.
    @ViewBuilder
    static func track(_ loaded: LoadedTrack, model: LibraryViewModel) -> some View {
        Button("Refresh Tags") { model.refreshTrackTags(loaded) }

        if !model.availableCrates.isEmpty {
            let usesSelection = model.selectedTrackIDs.count > 1 && model.selectedTrackIDs.contains(loaded.track.id)
            Menu(usesSelection ? "Add \(model.selectedTrackIDs.count) Selected to Crate" : "Add to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        if usesSelection {
                            model.addSelectionToCrate(crateName: crate)
                        } else {
                            model.addItemsToCrate(["track::" + loaded.track.id.uuidString], crateName: crate)
                        }
                    }
                }
            }
            moveToCrateMenu(for: usesSelection ? model.selectedTracksForCrateAdd() : [loaded], model: model)
        }
        Button("Select All") { model.selectAllTracks() }

        Divider()
        Button("Edit Tags…") {
            if model.selectedTrackIDs.count > 1 && model.selectedTrackIDs.contains(loaded.track.id) {
                model.editTags(for: model.selectedTracksForCrateAdd())
            } else {
                model.editTags(for: [loaded])
            }
        }
        let usesSel = model.selectedTrackIDs.count > 1 && model.selectedTrackIDs.contains(loaded.track.id)
        transferToDeviceMenu(for: usesSel ? model.selectedTracksForCrateAdd() : [loaded], model: model)
        showInFinderButton(for: [loaded])

        Divider()
        let hasMarkers = !(loaded.recordMarkers ?? []).isEmpty
        Button(hasMarkers ? "Edit Record Divider…" : "Record Divider…") {
            model.beginRecordDivider(for: loaded)
        }
        .disabled(!model.canRecordDivide(loaded))
        if hasMarkers {
            Button("Clear Track Markers") { model.clearRecordMarkers(for: loaded) }
        }

        switch model.currentSource {
        case .localCrate(let crateName):
            Divider()
            Button("Remove from “\(crateName)”") { model.removeTrackFromCrate(loaded, crateName: crateName) }
            Button("Remove from Library…") { model.promptRemoveTrackFromLibrary(loaded) }
        case .localAll, .prepCrate:
            Divider()
            Button("Remove from Library…") { model.promptRemoveTrackFromLibrary(loaded) }
        case .offlineDevice:
            removeFromSyncQueueButton(for: usesSel ? model.selectedTracksForCrateAdd() : [loaded], model: model)
        default:
            EmptyView()
        }
    }

    /// "Remove from Sync Queue" — offered on pending items while browsing an
    /// offline device. Deletes the entries AND their staged bytes.
    @ViewBuilder
    static func removeFromSyncQueueButton(for tracks: [LoadedTrack], model: LibraryViewModel) -> some View {
        let pending = tracks.filter { model.isPendingSync($0.track.id) }
        if !pending.isEmpty {
            Divider()
            Button("Remove from Sync Queue (\(pending.count))", role: .destructive) {
                model.removeFromSyncQueue(trackIDs: Set(pending.map { $0.track.id }))
            }
        }
    }

    /// Menu for a version-group release row.
    @ViewBuilder
    static func release(_ release: Album, model: LibraryViewModel) -> some View {
        if !model.availableCrates.isEmpty {
            Menu("Add Primary Version to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        model.addItemsToCrate(release.tracks.map { "track::" + $0.track.id.uuidString },
                                              crateName: crate)
                    }
                }
            }
        }
        Button("Edit Group…") { model.editGroup(release) }
        Button("Ungroup") { model.ungroupRelease(release) }
    }

    /// Menu for a version (pressing) sub-row.
    @ViewBuilder
    static func version(_ version: Album, release: Album, model: LibraryViewModel) -> some View {
        if !model.availableCrates.isEmpty {
            Menu("Add This Version to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        model.addItemsToCrate(version.tracks.map { "track::" + $0.track.id.uuidString },
                                              crateName: crate)
                    }
                }
            }
        }
        Button("Set as Primary") { model.setPrimaryVersion(version, in: release) }
        Button("Edit Edition Label…") { model.promptEditionLabel(for: version, in: release) }
        Divider()
        Button("Remove from Group") { model.removeFromGroup(version, release: release) }
    }

    /// "Move to Crate" submenu — only shown while viewing a specific crate (you can
    /// only move *out of* the crate you're in). Lists every other crate as a target.
    /// Membership-only: repoints the crate pointers, never copies files.
    @ViewBuilder
    static func moveToCrateMenu(for tracks: [LoadedTrack], model: LibraryViewModel) -> some View {
        if case .localCrate(let current) = model.currentSource {
            let targets = model.availableCrates.filter { $0 != current }
            if !targets.isEmpty && !tracks.isEmpty {
                Menu("Move to Crate") {
                    ForEach(targets, id: \.self) { crate in
                        Button(crate) { model.moveTracksToCrate(tracks, toCrate: crate) }
                    }
                }
            }
        }
    }

    /// The source-specific "Remove from …" items shared by the album menu.
    @ViewBuilder
    private static func removalItems(forAlbum album: Album, model: LibraryViewModel) -> some View {
        switch model.currentSource {
        case .localCrate(let crateName):
            Divider()
            Button("Remove from “\(crateName)”") { model.removeAlbumFromCrate(album, crateName: crateName) }
            Button("Remove from Library…") { model.promptRemoveAlbumFromLibrary(album) }
        case .localAll, .prepCrate:
            Divider()
            Button("Remove from Library…") { model.promptRemoveAlbumFromLibrary(album) }
        case .offlineDevice:
            removeFromSyncQueueButton(for: album.tracks, model: model)
        default:
            EmptyView()
        }
    }
}
