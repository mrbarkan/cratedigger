import SwiftUI
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

        if case .localCrate(let crateName) = model.currentSource {
            Divider()
            Button("Remove from “\(crateName)”") { model.removeArtistFromCrate(artist, crateName: crateName) }
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
        }
        Button("Select All") { model.selectAllAlbums() }

        if model.canGroupSelection {
            Button("Group \(model.selectedAlbumsForGrouping().filter { !$0.isVersionGroup }.count) Albums…") {
                model.beginGroupAlbums()
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
        default:
            EmptyView()
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
        default:
            EmptyView()
        }
    }
}
