import Foundation

/// Points a library at a copy of itself made outside the app (Finder, rsync, a
/// backup restored onto a new drive).
///
/// The owner picks the folder the music was copied to. A copy keeps its folder
/// structure, so a track at `<old root>/Artist/Album/01.flac` has its copy at
/// `<new root>/Artist/Album/01.flac`: the old root is worked out from the
/// library's own paths, never asked for, because the drive it is on may not
/// even be connected. One root per run, the one most tracks sit under.
///
/// This is not `RelinkMatcher`. That one re-attaches files that are *missing*,
/// where a matching file name is a fair guess. These tracks still play, so a
/// track is moved only onto the file at its own relative path.
///
/// Pure: no disk access. The caller supplies the files found under the folder.
public enum LibraryRelocation {

    public struct Plan: Equatable, Sendable {
        /// The folder the relocated tracks sit under now.
        public let oldRoot: URL
        /// The folder the owner picked.
        public let newRoot: URL
        /// Track file as the library has it, to its copy as the new drive names it.
        public let moves: [URL: URL]
        /// Tracks under the old root with no file at their place in the new one.
        public let withoutCopy: Int
        /// Tracks whose copy the library already holds as a track of its own.
        public let alreadyInLibrary: Int

        public init(oldRoot: URL, newRoot: URL, moves: [URL: URL], withoutCopy: Int, alreadyInLibrary: Int) {
            self.oldRoot = oldRoot
            self.newRoot = newRoot
            self.moves = moves
            self.withoutCopy = withoutCopy
            self.alreadyInLibrary = alreadyInLibrary
        }
    }

    public enum Outcome: Equatable, Sendable {
        case relocate(Plan)
        /// The library plays from the folder already, or holds every copy in it.
        case alreadyThere
        /// No track has a copy at its own place inside the folder.
        case noCopyFound
    }

    /// - Parameters:
    ///   - tracks: the file of every track in the library.
    ///   - newRoot: the folder the owner picked.
    ///   - candidates: the files found under `newRoot`.
    public static func plan(tracks: [URL], newRoot: URL, candidates: [URL]) -> Outcome {
        let newRootKey = key(newRoot)

        // Every file in the new folder by its folded path below that folder.
        // Path-sorted so two names that fold alike resolve the same way each run.
        var copies: [String: URL] = [:]
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            let candidateKey = key(candidate)
            guard isInside(candidateKey, root: newRootKey) else { continue }
            let relative = candidateKey[newRootKey.count...].joined(separator: "/")
            if copies[relative] == nil { copies[relative] = candidate }
        }

        struct Track {
            let url: URL
            let components: [String]
            let key: [String]
        }
        var elsewhere: [Track] = []
        var libraryPaths = Set<String>()
        var someAlreadyInside = false
        for url in tracks {
            let components = url.standardizedFileURL.pathComponents
            let trackKey = components.map(fold)
            libraryPaths.insert(trackKey.joined(separator: "/"))
            if isInside(trackKey, root: newRootKey) {
                someAlreadyInside = true
            } else {
                elsewhere.append(Track(url: url, components: components, key: trackKey))
            }
        }

        // Each track votes for the root its longest matching tail implies.
        struct Vote {
            var count: Int
            let root: [String]
        }
        var votes: [String: Vote] = [:]
        for track in elsewhere {
            for depth in 1..<max(track.key.count, 1) {
                let relative = track.key[depth...].joined(separator: "/")
                guard copies[relative] != nil else { continue }
                let rootKey = track.key[..<depth].joined(separator: "/")
                votes[rootKey, default: Vote(count: 0, root: Array(track.components[..<depth]))].count += 1
                break
            }
        }
        let winner = votes.max { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
        }
        guard let winner else { return someAlreadyInside ? .alreadyThere : .noCopyFound }
        let oldRootKey = winner.value.root.map(fold)

        var moves: [URL: URL] = [:]
        var claimed = Set<String>()
        var withoutCopy = 0
        var alreadyInLibrary = 0
        for track in elsewhere.sorted(by: { $0.url.path < $1.url.path }) where isInside(track.key, root: oldRootKey) {
            let relative = track.key[oldRootKey.count...].joined(separator: "/")
            guard let copy = copies[relative] else {
                withoutCopy += 1
                continue
            }
            // A copy the library already has as a track, or that another track
            // just took, would put one file in a crate twice.
            let copyPath = key(copy).joined(separator: "/")
            guard !libraryPaths.contains(copyPath), claimed.insert(copyPath).inserted else {
                alreadyInLibrary += 1
                continue
            }
            moves[track.url] = copy
        }
        guard !moves.isEmpty else { return .alreadyThere }

        return .relocate(Plan(
            oldRoot: URL(fileURLWithPath: NSString.path(withComponents: winner.value.root), isDirectory: true),
            newRoot: newRoot,
            moves: moves,
            withoutCopy: withoutCopy,
            alreadyInLibrary: alreadyInLibrary
        ))
    }

    /// Where a folder that was the old root, or inside it, sits in the new one.
    /// Nil for a folder elsewhere, which a relocation leaves alone.
    public static func counterpart(of folder: URL, from oldRoot: URL, to newRoot: URL) -> URL? {
        let components = folder.standardizedFileURL.pathComponents
        let rootKey = key(oldRoot)
        let folderKey = components.map(fold)
        guard folderKey.count >= rootKey.count, Array(folderKey[..<rootKey.count]) == rootKey else { return nil }
        return components[rootKey.count...].reduce(newRoot) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// The old drive's name when the Crates Index is still on it and the music
    /// has gone to another: unplugging that drive would disconnect the library.
    public static func driveStillHoldingIndex(indexFolder: URL, oldRoot: URL, newRoot: URL) -> String? {
        guard let oldDrive = LibraryLocation.volumeName(of: oldRoot),
              LibraryLocation.volumeName(of: indexFolder) == oldDrive,
              LibraryLocation.volumeName(of: newRoot) != oldDrive else { return nil }
        return oldDrive
    }

    // MARK: - Path keys

    /// Drives disagree about case and about composed or decomposed accents, so
    /// paths are compared with both folded away.
    private static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func key(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map(fold)
    }

    /// Strictly inside: the root itself is not inside itself.
    private static func isInside(_ path: [String], root: [String]) -> Bool {
        path.count > root.count && Array(path[..<root.count]) == root
    }
}

/// The words Relocate Library shows: the confirmation, the summary and the two
/// ways of having nothing to do.
public enum LibraryRelocationText {

    static func tracks(_ count: Int) -> String {
        "\(count) track\(count == 1 ? "" : "s")"
    }

    static func quoted(_ folder: URL) -> String {
        "“\(folder.path)”"
    }

    /// Before anything is changed: what moves, from where to where, what stays.
    public static func confirmation(_ plan: LibraryRelocation.Plan) -> (title: String, message: String) {
        let count = plan.moves.count
        var message = "\(count == 1 ? "It has" : "Each has") a copy there, at the same place it has in "
            + "\(quoted(plan.oldRoot)). Crates, play counts and ratings follow. No file is moved or deleted."
        if plan.withoutCopy > 0 {
            message += "\n\n\(tracks(plan.withoutCopy)) "
                + (plan.withoutCopy == 1
                    ? "has no copy there and stays where it is."
                    : "have no copy there and stay where they are.")
        }
        if plan.alreadyInLibrary > 0 {
            message += "\n\n\(tracks(plan.alreadyInLibrary)) "
                + (plan.alreadyInLibrary == 1 ? "is" : "are")
                + " in the library at both places already and "
                + (plan.alreadyInLibrary == 1 ? "is" : "are") + " left alone."
        }
        return ("Relocate \(tracks(count)) to \(quoted(plan.newRoot))?", message)
    }

    /// After the crates were rewritten.
    public static func summary(
        _ plan: LibraryRelocation.Plan,
        relocated: Int,
        musicFolderFollowed: Bool,
        driveStillHoldingIndex: String?
    ) -> (title: String, message: String) {
        var message = "\(tracks(relocated)) now \(relocated == 1 ? "plays" : "play") from \(quoted(plan.newRoot))."
        if musicFolderFollowed {
            message += " The Music Folder points there too."
        }
        if plan.withoutCopy > 0 {
            message += " \(tracks(plan.withoutCopy)) had no copy there and stayed where "
                + (plan.withoutCopy == 1 ? "it was." : "they were.")
        }
        if let drive = driveStillHoldingIndex {
            message += "\n\nThe Crates Index is still on “\(drive)”. Before you retire that drive, "
                + "use Move Index Files… in Preferences to bring it along."
        }
        return ("Library Relocated", message)
    }

    public static func noCopyFound(in folder: URL) -> (title: String, message: String) {
        ("No Copy Found",
         "No track in the library has a copy at its own place inside \(quoted(folder)). "
            + "Choose the folder that now holds what your music folder held: "
            + "the same artist and album folders, under the same names.")
    }

    public static func alreadyThere(in folder: URL) -> (title: String, message: String) {
        ("Already There",
         "The library already holds the tracks in \(quoted(folder)). Nothing was changed.")
    }
}
