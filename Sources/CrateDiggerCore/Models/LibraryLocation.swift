import Foundation

/// Where the crates index lives right now, decided before anything reads or
/// writes it.
///
/// The index folder is a bookmark the user chose, often on an external drive.
/// When that drive was out, resolving the bookmark failed, the app quietly
/// used an empty folder in Application Support instead, and wrote a fresh
/// Personal Crate into it: the library looked gone and every edit landed in a
/// stand-in. This is the one place that tells "no folder chosen", "the folder
/// is here" and "the folder is on a drive that is not connected" apart, so
/// nothing downstream has to guess from an empty crate list.
public enum LibraryLocation: Equatable, Sendable {
    /// No folder was ever chosen: the Application Support default applies.
    case notChosen
    /// The folder can be read and written.
    case available(URL)
    /// The folder is on `/Volumes/<volumeName>` and that drive is not mounted.
    /// Both are nil when the bookmark cannot be resolved and nothing recorded
    /// where the folder was, which is also what a deleted folder looks like.
    case disconnected(volumeName: String?, folder: URL?)

    /// - Parameters:
    ///   - bookmarkChosen: whether a crates folder bookmark is saved at all.
    ///   - resolvedFolder: what the bookmark resolved to, nil if it failed.
    ///     Still checked: whether macOS returns the old path for a drive that
    ///     is gone is not something to rely on.
    ///   - lastKnownFolder: where the folder was when the local copy was last
    ///     written, used when the bookmark cannot be resolved.
    ///   - isVolumeMounted: whether `/Volumes/<name>` is mounted.
    public static func resolve(
        bookmarkChosen: Bool,
        resolvedFolder: URL?,
        lastKnownFolder: URL?,
        isVolumeMounted: (String) -> Bool
    ) -> LibraryLocation {
        guard bookmarkChosen else { return .notChosen }
        guard let folder = resolvedFolder ?? lastKnownFolder else {
            return .disconnected(volumeName: nil, folder: nil)
        }
        if let volume = volumeName(of: folder), !isVolumeMounted(volume) {
            return .disconnected(volumeName: volume, folder: folder)
        }
        return .available(folder)
    }

    /// The `/Volumes/<name>` drive a path lives on, or nil for the boot volume.
    public static func volumeName(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return components[2]
    }

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}
