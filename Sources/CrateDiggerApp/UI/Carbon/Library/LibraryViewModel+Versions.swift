import AppKit
import CrateDiggerCore

/// Album version-group actions: grouping multiple albums into one release,
/// editing/ungrouping, and the helpers the browser + sheet rely on. Grouping is
/// non-destructive — it only writes to `AlbumGroupStore`; files are untouched.
@MainActor
extension LibraryViewModel {

    private var versionPlanner: OutputPathPlanner { OutputPathPlanner() }

    /// The stable identity used to reference a pressing inside a group.
    func versionKey(for album: Album) -> AlbumFolderKey? {
        // A grouped release has no single key; use its primary pressing.
        let source = album.isVersionGroup ? album.versions?.first : album
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
    var canGroupSelection: Bool {
        guard isLocalVersionSource else { return false }
        let albums = selectedAlbumsForGrouping().filter { !$0.isVersionGroup }
        guard albums.count >= 2 else { return false }
        return Set(albums.map(\.artistID)).count == 1
    }

    /// True for the library sources where grouping applies.
    private var isLocalVersionSource: Bool {
        switch currentSource {
        case .localAll, .localCrate, .prepCrate: return true
        default: return false
        }
    }

    /// Create or update a group, persist it, and rebuild the local index.
    func commitGroup(id: String, name: String, originalYear: Int?,
                     primaryKey: AlbumFolderKey, members: [VersionMember]) {
        guard members.count >= 2 else { return }
        let artistID = members.first.flatMap { albumForKey($0.key)?.artistID } ?? ""
        let group = AlbumGroup(id: id, name: name, artistID: artistID,
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
        mutateGroup(of: release) { group in
            if let track = pressing.tracks.first {
                group.primaryKey = versionPlanner.albumFolderKey(for: track)
            }
        }
    }

    func setEditionLabel(_ label: String?, for pressing: Album, in release: Album) {
        guard let track = pressing.tracks.first else { return }
        let key = versionPlanner.albumFolderKey(for: track)
        mutateGroup(of: release) { group in
            if let i = group.members.firstIndex(where: { $0.key == key }) {
                group.members[i].editionLabel = label?.isEmpty == true ? nil : label
            }
        }
    }

    func removeFromGroup(_ pressing: Album, release: Album) {
        guard let track = pressing.tracks.first else { return }
        let key = versionPlanner.albumFolderKey(for: track)
        mutateGroup(of: release) { group in
            group.members.removeAll { $0.key == key }
        }
    }

    // MARK: - Helpers

    func groupID(of release: Album) -> String? {
        guard release.id.hasPrefix("group::") else { return nil }
        return String(release.id.dropFirst("group::".count))
    }

    private func albumForKey(_ key: AlbumFolderKey) -> Album? {
        index.allAlbums.first { album in
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
