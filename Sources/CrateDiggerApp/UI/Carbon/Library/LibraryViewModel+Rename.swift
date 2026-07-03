import AppKit
import CrateDiggerCore

/// Inline rename of user crates and playlists from the Sources sidebar. Renames
/// the file on disk and updates every in-app reference to the old name.
@MainActor
extension LibraryViewModel {

    /// Rename a user crate. "Personal Crate" is reserved and can't be renamed.
    /// Returns false (and shows a Carbon alert) on an invalid name or file error.
    @discardableResult
    func renameCrate(_ oldName: String, to proposed: String) -> Bool {
        guard oldName != LibraryViewModel.personalCrateName else { return false }
        let others = availableCrates.filter { $0 != oldName }
        switch CrateNameValidator.validate(proposed, existing: others, currentName: oldName) {
        case .invalid(let reason):
            appAlert = .error(title: "Can’t Rename Crate", message: reason)
            return false
        case .ok(let newName):
            guard newName != oldName else { return true }
            let dir = cratesDirectoryURL
            let src = dir.appendingPathComponent("\(oldName).cdlib")
            let dest = dir.appendingPathComponent("\(newName).cdlib")
            do {
                try Self.moveFile(at: src, to: dest,
                                  caseOnly: oldName.lowercased() == newName.lowercased(),
                                  ext: "cdlib", in: dir)
            } catch {
                appAlert = .error(title: "Rename Failed", message: error.localizedDescription)
                return false
            }
            if targetCrateName == oldName { targetCrateName = newName }
            if case .localCrate(let n) = currentSource, n == oldName {
                currentSource = .localCrate(name: newName)
            }
            refreshAvailableCrates()
            if case .localCrate(let n) = currentSource, n == newName {
                selectSource(.localCrate(name: newName))
            }
            return true
        }
    }

    /// Rename a playlist. Returns false (and shows a Carbon alert) on failure.
    @discardableResult
    func renamePlaylist(_ oldName: String, to proposed: String) -> Bool {
        let others = playlists.map(\.name).filter { $0 != oldName }
        switch CrateNameValidator.validate(proposed, existing: others, currentName: oldName) {
        case .invalid(let reason):
            appAlert = .error(title: "Can’t Rename Playlist", message: reason)
            return false
        case .ok(let newName):
            guard newName != oldName else { return true }
            do {
                try playlistService.renamePlaylist(from: oldName, to: newName)
            } catch {
                appAlert = .error(title: "Rename Failed", message: error.localizedDescription)
                return false
            }
            playlists = playlistService.listPlaylists()
            if case .playlist(let n) = currentSource, n == oldName {
                selectSource(.playlist(name: newName))
            }
            return true
        }
    }

    /// Move a file, with a temp hop for case-only renames on case-insensitive volumes.
    private static func moveFile(at src: URL, to dest: URL, caseOnly: Bool, ext: String, in dir: URL) throws {
        let fm = FileManager.default
        if caseOnly {
            let tmp = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try fm.moveItem(at: src, to: tmp)
            try fm.moveItem(at: tmp, to: dest)
        } else {
            try fm.moveItem(at: src, to: dest)
        }
    }
}
