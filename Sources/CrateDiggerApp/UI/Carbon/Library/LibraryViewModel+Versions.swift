import AppKit
import CrateDiggerCore

// MARK: - Notification name

extension NSNotification.Name {
    /// Posted by `LibraryViewModel.beginGroupAlbums()` / `editGroup(_:)`.
    /// `object` is a `GroupSheetInputs` value.
    static let crateDiggerPresentGroupAlbumsSheet = NSNotification.Name(
        "CrateDiggerPresentGroupAlbumsSheet"
    )
}

/// Carries the pre-filled inputs from the view model to MainWindowController.
struct GroupSheetInputs {
    let id: String
    let kind: AlbumGroupKind
    let name: String
    let year: Int?
    let rows: [GroupAlbumsSheetController.VersionRow]
    let primaryKey: AlbumFolderKey
}

// MARK: -

/// Album version-group actions: grouping multiple albums into one release,
/// editing/ungrouping, and the helpers the browser + sheet rely on. Grouping is
/// non-destructive — it only writes to `AlbumGroupStore`; files are untouched.
@MainActor
extension LibraryViewModel {

    private var versionPlanner: OutputPathPlanner { OutputPathPlanner() }

    /// The stable identity used to reference a pressing inside a group. Prefer
    /// the key the index build assigned (it carries the version discriminator
    /// that tells two same-tagged rips apart); tag re-derivation is only a
    /// fallback for albums that predate `folderKey`.
    func versionKey(for album: Album) -> AlbumFolderKey? {
        // A grouped release has no single key; use its primary pressing.
        let source = album.isVersionGroup ? album.versions?.first : album
        if let key = source?.folderKey { return key }
        guard let track = source?.tracks.first else { return nil }
        return versionPlanner.albumFolderKey(for: track)
    }

    /// Albums currently multi-selected (for "Group Albums"). Resolves the selected
    /// album ids to top-level albums in the current index.
    func selectedAlbumsForGrouping() -> [Album] {
        let ids = selectedAlbumIDs.isEmpty ? Set([selectedAlbumID].compactMap { $0 }) : selectedAlbumIDs
        return index.allAlbums.filter { ids.contains($0.id) }
    }

    /// Enabled when 2+ plain (non-grouped) local albums of the same artist are selected.
    var canGroupSelection: Bool { canGroup(as: .versionGroup) }

    /// Whether the current selection can form a group of the given kind. Version
    /// groups + box sets are same-artist; compilations are cross-artist by nature.
    func canGroup(as kind: AlbumGroupKind) -> Bool {
        guard isLocalVersionSource else { return false }
        let albums = selectedAlbumsForGrouping().filter { !$0.isVersionGroup }
        guard albums.count >= 2 else { return false }
        switch kind {
        case .versionGroup: return Set(albums.map(\.artistID)).count == 1
        case .boxSet, .compilation: return true
        }
    }

    /// True when any group kind can be formed from the selection (drives the
    /// "Group as ▸" submenu visibility).
    var canGroupSelectionAnyKind: Bool { canGroup(as: .boxSet) }

    /// True for the library sources where grouping applies.
    private var isLocalVersionSource: Bool {
        switch currentSource {
        case .localAll, .localCrate, .prepCrate: return true
        default: return false
        }
    }

    /// Create or update a group, persist it, and rebuild the local index.
    func commitGroup(id: String, kind: AlbumGroupKind, name: String, originalYear: Int?,
                     primaryKey: AlbumFolderKey, members: [VersionMember]) {
        guard members.count >= 2 else { return }
        let artistID = members.first.flatMap { albumForKey($0.key)?.artistID } ?? ""
        let group = AlbumGroup(id: id, kind: kind, name: name, artistID: artistID,
                               originalYear: originalYear, primaryKey: primaryKey, members: members)
        albumGroupStore.upsert(group)
        reloadAfterGroupChange()
    }

    func ungroupRelease(_ release: Album) {
        guard let groupID = groupID(of: release) else { return }
        albumGroupStore.remove(id: groupID)
        reloadAfterGroupChange()
    }

    func setPrimaryVersion(_ pressing: Album, in release: Album) {
        guard let key = versionKey(for: pressing) else { return }
        mutateGroup(of: release) { group in
            group.primaryKey = key
        }
    }

    func setEditionLabel(_ label: String?, for pressing: Album, in release: Album) {
        guard let key = versionKey(for: pressing) else { return }
        mutateGroup(of: release) { group in
            if let i = group.members.firstIndex(where: { $0.key == key }) {
                group.members[i].editionLabel = label?.isEmpty == true ? nil : label
            }
        }
    }

    func removeFromGroup(_ pressing: Album, release: Album) {
        guard let key = versionKey(for: pressing) else { return }
        mutateGroup(of: release) { group in
            group.members.removeAll { $0.key == key }
        }
    }

    // MARK: - Split mixed folder

    /// True when this album is one on-disk folder holding 2+ codecs — the
    /// "mixed folder" case Split Folder untangles.
    func canSplitAlbumFolder(_ album: Album) -> Bool {
        guard isLocalVersionSource, !album.isVersionGroup else { return false }
        guard let first = album.tracks.first?.track.fileURL, first.isFileURL else { return false }
        let folders = Set(album.tracks.map { $0.track.fileURL.deletingLastPathComponent().standardizedFileURL.path })
        return folders.count == 1 && AlbumFolderSplitter.codecGroups(for: album.tracks).count >= 2
    }

    /// Ask which codec to move out and what to call the new folder, then split.
    func promptSplitAlbumFolder(_ album: Album) {
        let groups = AlbumFolderSplitter.codecGroups(for: album.tracks)
        guard groups.count >= 2,
              let sourceFolder = album.tracks.first?.track.fileURL.deletingLastPathComponent() else { return }

        let alert = NSAlert()
        alert.messageText = "Split “\(sourceFolder.lastPathComponent)”"
        alert.informativeText = "Move one format into its own folder next to the current one. It becomes a separate version you can then group."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 280, height: 25))
        for group in groups {
            popup.addItem(withTitle: "\(group.codec) — \(group.tracks.count) track\(group.tracks.count == 1 ? "" : "s")")
        }
        // The smallest bucket is usually the odd one out — the likeliest split.
        popup.selectItem(at: groups.count - 1)
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.stringValue = "\(sourceFolder.lastPathComponent) [\(groups[groups.count - 1].codec)]"
        nameField.placeholderString = "New folder name"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        container.addSubview(popup)
        container.addSubview(nameField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Split")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = groups[max(0, popup.indexOfSelectedItem)]
        splitAlbumFolder(album, movingCodec: chosen.codec, folderName: nameField.stringValue)
    }

    /// Move every `movingCodec` file of `album` into a new sibling folder named
    /// `folderName`, then rewrite crate references. All-or-nothing: a failure
    /// mid-batch rolls the already-moved files back so the album never ends up
    /// half-split.
    func splitAlbumFolder(_ album: Album, movingCodec: String, folderName: String) {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            appAlert = .error(title: "Folder Name Needed", message: "Type a name for the new folder.")
            return
        }
        guard let sourceFolder = album.tracks.first?.track.fileURL.deletingLastPathComponent(),
              let movers = AlbumFolderSplitter.codecGroups(for: album.tracks)
                  .first(where: { $0.codec == movingCodec })?.tracks,
              !movers.isEmpty else { return }

        let destFolder = sourceFolder.deletingLastPathComponent()
            .appendingPathComponent(trimmed, isDirectory: true)
        guard destFolder.standardizedFileURL.path != sourceFolder.standardizedFileURL.path else {
            appAlert = .error(title: "Same Folder", message: "The new folder name matches the current folder.")
            return
        }

        let fm = FileManager.default
        // Never overwrite audio: refuse if any destination file already exists.
        if movers.contains(where: { fm.fileExists(atPath: destFolder.appendingPathComponent($0.track.fileURL.lastPathComponent).path) }) {
            appAlert = .error(title: "Files Already There",
                              message: "“\(trimmed)” already contains files with these names.")
            return
        }

        do {
            try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
            var updated: [LoadedTrack] = []
            var movedPairs: [(from: URL, to: URL)] = []
            do {
                for loaded in movers {
                    let dest = destFolder.appendingPathComponent(loaded.track.fileURL.lastPathComponent)
                    try fm.moveItem(at: loaded.track.fileURL, to: dest)
                    movedPairs.append((loaded.track.fileURL, dest))
                    updated.append(LoadedTrack(track: loaded.track.withFileURL(dest),
                                               metadata: loaded.metadata,
                                               recordMarkers: loaded.recordMarkers))
                }
            } catch {
                for pair in movedPairs.reversed() { try? fm.moveItem(at: pair.to, to: pair.from) }
                try? fm.removeItem(at: destFolder)
                throw error
            }
            // ponytail: a sibling-folder move on the same volume is a rename per
            // file — synchronous on the main actor is fine at album scale.
            updateTrackURLsInIndex(updated)
            selectSource(currentSource)
            appAlert = .info(title: "Folder Split",
                             message: "Moved \(updated.count) \(movingCodec) file\(updated.count == 1 ? "" : "s") to “\(trimmed)”. It now shows as its own version — select both and Group to link them.")
        } catch {
            appAlert = .error(title: "Split Failed",
                              message: "Could not split the folder: \(error.localizedDescription)\nEverything was left as it was.")
        }
    }

    // MARK: - Edition label prompt

    func promptEditionLabel(for pressing: Album, in release: Album) {
        let alert = NSAlert()
        alert.messageText = "Edition label"
        alert.informativeText = "e.g. Gold CD, JP Vinyl, 2011 Remaster"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = pressing.editionLabel ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            setEditionLabel(field.stringValue, for: pressing, in: release)
        }
    }

    // MARK: - Sheet present actions

    /// Open the group-albums sheet for the current multi-selection. The release name
    /// defaults to the pressings' shared base title, and each row's edition label is
    /// pre-filled with whatever distinguishes that pressing (a catalog suffix in the
    /// album title, else its year/format/folder) so the user rarely has to type.
    func beginGroup(kind: AlbumGroupKind) {
        let albums = selectedAlbumsForGrouping().filter { !$0.isVersionGroup }
        guard albums.count >= 2 else { return }
        var rows: [GroupAlbumsSheetController.VersionRow] = albums.compactMap { album in
            guard let key = versionKey(for: album) else { return nil }
            return .init(album: album, key: key,
                         formatBadge: VersionLabel.formatBadge(for: album), editionLabel: "")
        }
        guard rows.count >= 2 else { return }
        let autoLabels = VersionDistinguisher.labels(for: rows.map(\.album))
        for i in rows.indices { rows[i].editionLabel = autoLabels[i] }
        // A compilation's title is usually the shared album name; version/box use the base title.
        let suggestedName = VersionDistinguisher.commonBaseTitle(rows.map { $0.album.title })
        let suggestedYear = albums.compactMap(\.year).min()
        presentGroupSheet(id: UUID().uuidString, kind: kind, name: suggestedName, year: suggestedYear,
                          rows: rows, primaryKey: rows[0].key)
    }

    /// Re-open the sheet to edit an existing release.
    func editGroup(_ release: Album) {
        guard let id = groupID(of: release),
              let group = albumGroupStore.all().first(where: { $0.id == id }) else { return }
        var rows: [GroupAlbumsSheetController.VersionRow] = (release.versions ?? []).compactMap { v in
            guard let key = versionKey(for: v) else { return nil }
            let existing = group.members.first { $0.key == key }?.editionLabel ?? ""
            return .init(album: v, key: key,
                         formatBadge: VersionLabel.formatBadge(for: v), editionLabel: existing)
        }
        guard rows.count >= 2 else { return }
        // Fill in a suggested label only where the user hasn't already set one.
        let autoLabels = VersionDistinguisher.labels(for: rows.map(\.album))
        for i in rows.indices where rows[i].editionLabel.isEmpty { rows[i].editionLabel = autoLabels[i] }
        presentGroupSheet(id: id, kind: group.kind, name: group.name, year: group.originalYear,
                          rows: rows, primaryKey: group.primaryKey)
    }

    private func presentGroupSheet(id: String, kind: AlbumGroupKind, name: String, year: Int?,
                                   rows: [GroupAlbumsSheetController.VersionRow],
                                   primaryKey: AlbumFolderKey) {
        let inputs = GroupSheetInputs(id: id, kind: kind, name: name, year: year,
                                      rows: rows, primaryKey: primaryKey)
        NotificationCenter.default.post(
            name: .crateDiggerPresentGroupAlbumsSheet,
            object: inputs
        )
    }

    // MARK: - Helpers

    func groupID(of release: Album) -> String? {
        guard release.id.hasPrefix("group::") else { return nil }
        return String(release.id.dropFirst("group::".count))
    }

    private func albumForKey(_ key: AlbumFolderKey) -> Album? {
        index.allAlbums.first { album in
            if let built = (album.isVersionGroup ? album.versions?.first?.folderKey : album.folderKey) {
                return built == key
            }
            guard let t = (album.isVersionGroup ? album.versions?.first?.tracks.first : album.tracks.first)
            else { return false }
            return versionPlanner.albumFolderKey(for: t) == key
        }
    }

    private func mutateGroup(of release: Album, _ body: (inout AlbumGroup) -> Void) {
        guard let id = groupID(of: release),
              var group = albumGroupStore.all().first(where: { $0.id == id }) else { return }
        body(&group)
        if group.members.count < 2 {
            albumGroupStore.remove(id: id)        // dissolves to plain albums
        } else {
            albumGroupStore.upsert(group)
        }
        reloadAfterGroupChange()
    }

    /// Rebuild the visible local index after a group change.
    private func reloadAfterGroupChange() {
        clearMultiSelection()
        selectSource(currentSource)
    }
}
