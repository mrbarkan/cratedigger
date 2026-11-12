import Foundation

/// What the player can see of pictures on a device: one read-only listing of
/// `/Artwork`, the music folder and the folders above it, plus what the
/// catalog says about whose tracks lie where. Paths are device-relative with
/// `/` separators and no leading slash; the volume root is `""`. Names are
/// NFC, whatever form the file system handed back.
public struct DeviceArtTree: Sendable {
    public let peopleFiles: [String]                  // every name in /Artwork/People, as the player's readdir sees it
    public let coverFiles: [String]                   // every name in /Artwork/Covers
    public let folderImages: [String: [String]]       // device-relative folder -> image file names in it
    public let foldersWithAudio: Set<String>          // folders that directly hold audio
    public let artistsByFolder: [String: Set<String>] // folder -> folded keys of the artists whose albums lie under it
    /// Folders the player treats as library folders: they hold folders named
    /// for two or more people (as `Music/` does). Its last-resort step skips them.
    public let libraryFolders: Set<String>
    /// More folders hold named folders than the player's table has slots
    /// (1,024): the player then treats every folder it could not note as a
    /// library folder, which this simulation cannot reproduce.
    public let libraryTableFull: Bool

    /// The player's folder table size (`AA_LIBDIR_SLOTS`).
    static let libraryTableSlots = 1_024

    /// `libraryFolders` nil: derived from `artistsByFolder`, a folder whose
    /// child folders are named for two or more of the artists listed under
    /// them. `scan` passes the exact set, worked out from the catalog.
    public init(peopleFiles: [String], coverFiles: [String], folderImages: [String: [String]],
                foldersWithAudio: Set<String>, artistsByFolder: [String: Set<String>],
                libraryFolders: Set<String>? = nil, libraryTableFull: Bool = false) {
        self.peopleFiles = peopleFiles
        self.coverFiles = coverFiles
        self.folderImages = folderImages
        self.foldersWithAudio = foldersWithAudio
        self.artistsByFolder = artistsByFolder
        self.libraryFolders = libraryFolders ?? Self.derivedLibraryFolders(artistsByFolder)
        self.libraryTableFull = libraryTableFull
    }

    /// Names PodBox never gives a picture to (compared trimmed and case-folded).
    static let skippedNames: Set<String> = ["various artists", "unknown artist", "<untagged>"]
    static let peopleFolder = "Artwork/People"
    static let coversFolder = "Artwork/Covers"

    /// One walk of the music folder, a listing of each folder above it and
    /// of /Artwork, plus the catalog. Read-only: lists folders, never opens a file.
    public static func scan(volumeRoot: URL, musicSubpath: String, catalog: [LoadedTrack],
                            fileManager: FileManager = .default) -> DeviceArtTree {
        let music = nfc(trimmedSlashes(musicSubpath))
        let paths = DevicePaths(root: volumeRoot)
        let audioExtensions = LibraryScanService.defaultSupportedExtensions
        let imageExtensions = Set(PodBoxArtLookup.imageExtensions)

        var folderImages: [String: [String]] = [:]
        var foldersWithAudio = Set<String>()
        func note(fileNamed name: String, in folder: String) {
            let ext = (name as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                folderImages[folder, default: []].append(name)
            } else if audioExtensions.contains(ext) {
                foldersWithAudio.insert(folder)
            }
        }

        // The music folder, recursively.
        let musicURL = music.isEmpty ? volumeRoot : volumeRoot.appendingPathComponent(music, isDirectory: true)
        let walker = fileManager.enumerator(at: musicURL, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let relative = paths.relative(url) else { continue }
            note(fileNamed: nfc(url.lastPathComponent), in: parent(of: relative) ?? "")
        }
        // Each folder above it, the volume root included (a disc folder's
        // step up can reach it), each on its own.
        var above = parent(of: music)
        while let folder = above {
            let url = folder.isEmpty ? volumeRoot : volumeRoot.appendingPathComponent(folder, isDirectory: true)
            for name in files(in: url, fileManager) where !name.hasPrefix(".") {
                note(fileNamed: name, in: folder)
            }
            above = parent(of: folder)
        }
        for key in folderImages.keys { folderImages[key]?.sort() }

        var artistsByFolder: [String: Set<String>] = [:]
        var noted: [String: Set<UInt32>] = [:]
        var seen = Set<String>() // track folder + person, each worked out once
        for loaded in catalog {
            let person = rawPerson(for: loaded)
            guard let relative = paths.relative(loaded.track.fileURL), let trackFolder = parent(of: relative),
                  seen.insert(trackFolder + "\u{0}" + person).inserted else { continue }

            // The player's note: folders up to three above the track named
            // for the person, and the folder holding each named one.
            let key = PodBoxArtName.key(person)
            if key != 0 {
                var folder: String? = trackFolder
                for _ in 0...3 {
                    guard let current = folder, !current.isEmpty else { break }
                    if PodBoxArtName.matches(lastComponent(current), person),
                       let up = parent(of: current), !up.isEmpty {
                        noted[up, default: []].insert(key)
                    }
                    folder = parent(of: current)
                }
            }

            let folded = PodBoxArtName.folded(person)
            guard !folded.isEmpty, isWithin(trackFolder, music) else { continue }
            var folder = trackFolder
            while true {
                artistsByFolder[folder, default: []].insert(folded)
                guard folder != music, let up = parent(of: folder), isWithin(up, music) else { break }
                folder = up
            }
        }

        let artwork = volumeRoot.appendingPathComponent("Artwork", isDirectory: true)
        return DeviceArtTree(peopleFiles: files(in: artwork.appendingPathComponent("People"), fileManager),
                             coverFiles: files(in: artwork.appendingPathComponent("Covers"), fileManager),
                             folderImages: folderImages, foldersWithAudio: foldersWithAudio,
                             artistsByFolder: artistsByFolder,
                             libraryFolders: Set(noted.filter { $0.value.count > 1 }.keys),
                             libraryTableFull: noted.count > libraryTableSlots)
    }

    /// The name the player gives this track's pictures: the album artist,
    /// else the artist. nil for names it skips: Various Artists, Unknown
    /// Artist, `<untagged>`, empty.
    public static func person(for track: LoadedTrack) -> String? {
        let name = rawPerson(for: track).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !skippedNames.contains(name.lowercased()) else { return nil }
        return name
    }

    // MARK: - Path helpers (shared with the lookup)

    /// The album artist when it has any non-space text, else the artist.
    static func rawPerson(for track: LoadedTrack) -> String {
        let albumArtist = track.metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !albumArtist.isEmpty { return albumArtist }
        return track.metadata.artist ?? track.track.artist
    }

    /// `"a/b"` gives `"a"`, `"a"` gives `""` (the root), `""` gives nil.
    static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    static func isWithin(_ folder: String, _ music: String) -> Bool {
        music.isEmpty || folder == music || folder.hasPrefix(music + "/")
    }

    static func trimmedSlashes(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// For a tree built without the catalog: a folder whose child folders are
    /// named for two or more different artists listed under those children.
    private static func derivedLibraryFolders(_ artistsByFolder: [String: Set<String>]) -> Set<String> {
        var named: [String: Set<UInt32>] = [:]
        for (child, artists) in artistsByFolder {
            guard let up = parent(of: child), !up.isEmpty else { continue }
            let name = lastComponent(child)
            for artist in artists where PodBoxArtName.matches(name, artist) {
                named[up, default: []].insert(PodBoxArtName.key(artist))
            }
        }
        return Set(named.filter { $0.value.count > 1 }.keys)
    }

    /// Every file in a folder, hidden ones included (the player's `readdir`
    /// sees them all), NFC, sorted. Folders are left out.
    private static func files(in folder: URL, _ fileManager: FileManager) -> [String] {
        guard let names = AppleDoubleSweeper.entryNames(inFolder: folder.path) else { return [] }
        return names.filter { name in
            var isFolder: ObjCBool = false
            return fileManager.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder)
                && !isFolder.boolValue
        }
        .map(nfc)
        .sorted()
    }

    /// Turns absolute URLs into device-relative NFC paths, accepting both the
    /// root as given and its resolved form (`/var` against `/private/var`).
    private struct DevicePaths {
        let prefixes: [String]

        init(root: URL) {
            var forms = [root.standardizedFileURL.path]
            if let real = realpath(root.path, nil) {
                forms.append(String(cString: real))
                free(real)
            }
            prefixes = forms.map { $0 == "/" ? "/" : $0 + "/" }
        }

        func relative(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            for prefix in prefixes where path.hasPrefix(prefix) {
                return DeviceArtTree.nfc(String(path.dropFirst(prefix.count)))
            }
            return nil
        }
    }
}

/// The player's search for a person's picture (PodBox's art cache, people
/// step), simulated so CrateDigger never writes a picture that would hide
/// the owner's own. In the player's order:
/// 1. a file in `/Artwork/People` whose name keys as the person's;
/// 2. else the **highest** folder named for the person, from each of their
///    tracks' own folder up to three above it (never the volume root), and
///    its image, whether or not it also holds audio;
/// 3. else, track by track, the folder above the track's or the one above
///    that, unless it is the volume root or a library folder (one holding
///    folders named for two or more people).
///
/// A folder's image is `_.<ext>`, `cover.<ext>` or `folder.<ext>` in it, in
/// that order, extensions in `imageExtensions` order; a disc folder (`CD1`)
/// also takes `cover`/`folder` from the folder above it.
///
/// Where the answer depends on something the simulation cannot know (the
/// order of the player's walks or of a folder listing, a full table, a file
/// that is not a picture) the outcome is `.uncertain`, and a writer must
/// treat that as "leave it alone".
public enum PodBoxArtLookup {
    public enum Outcome: Equatable, Sendable {
        /// The player finds no picture for this person: room for ours.
        case none
        /// The player uses this device-relative file.
        case found(String)
        /// The player may use a picture that is not ours; the reason says why.
        case uncertain(String)

        public var foundPath: String? {
            if case .found(let path) = self { return path }
            return nil
        }
    }

    public static let imageExtensions = ["jpeg", "jpg", "bmp", "png", "gif", "webp"]
    /// `_` is the player probing a folder for an image named after the file "_".
    static let folderImageStems = ["_", "cover", "folder"]
    static let discFolderStems = ["cover", "folder"]

    /// What the player would show for `name`, whose tracks lie in the
    /// device-relative `albumFolders` (each track's own folder).
    public static func artistPicture(for name: String, albumFolders: [String], tree: DeviceArtTree) -> Outcome {
        guard PodBoxArtName.key(name) != 0 else { return .none } // the player cannot key it at all

        // 1. /Artwork/People.
        let people = tree.peopleFiles.filter { PodBoxArtName.matches(stem(of: $0), name) }
        if let only = people.first {
            guard people.count == 1 else {
                return .uncertain("several files in /Artwork/People match: \(people.joined(separator: ", "))")
            }
            guard imageExtensions.contains((only as NSString).pathExtension.lowercased()) else {
                return .uncertain("/Artwork/People/\(only) matches and is not a picture the player can show")
            }
            return .found(DeviceArtTree.peopleFolder + "/" + only)
        }

        let tracks = Array(Set(albumFolders.map { DeviceArtTree.nfc(DeviceArtTree.trimmedSlashes($0)) })).sorted()

        // 2. The highest named folder.
        var highest = -1
        var named = Set<String>()
        for track in tracks {
            var folder: String? = track
            for level in 0...3 {
                guard let current = folder, !current.isEmpty else { break }
                if PodBoxArtName.matches(DeviceArtTree.lastComponent(current), name) {
                    if level > highest {
                        highest = level
                        named = [current]
                    } else if level == highest {
                        named.insert(current)
                    }
                }
                folder = DeviceArtTree.parent(of: current)
            }
        }
        if !named.isEmpty {
            let probes = named.sorted().map { image(in: $0, tree: tree) }
            if named.count == 1 {
                switch probes[0] {
                case .found, .uncertain: return probes[0]
                case .none: break
                }
            } else if probes.contains(where: { $0 != .none }) {
                return .uncertain("folders named for \(name) at the same height: \(named.sorted().joined(separator: ", "))")
            }
        }

        // 3. The folder above a track's, or the one above that.
        var candidates = Set<String>()
        for track in tracks {
            var folder = DeviceArtTree.parent(of: track)
            for _ in 1...2 {
                guard let current = folder, !current.isEmpty else { break }
                folder = DeviceArtTree.parent(of: current)
                if !tree.libraryTableFull, tree.libraryFolders.contains(current) { continue }
                switch image(in: current, tree: tree) {
                case .none:
                    continue
                case .uncertain(let reason):
                    return .uncertain(reason)
                case .found(let path):
                    if tree.libraryTableFull {
                        return .uncertain("the player's folder table is full, so it may skip \(current)")
                    }
                    candidates.insert(path)
                }
                break
            }
        }
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates.first!)
        default:
            return .uncertain("the player takes the first of \(candidates.sorted().joined(separator: ", "))")
        }
    }

    /// Whether a folder name stands for one disc of an album: `cd`, `disc`
    /// or `disk` (any case), then any of space `-` `_` `.`, then digits and
    /// nothing else (`CD1`, `Disc 2`, `disk_3`).
    static func isDiscFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard let word = ["cd", "disc", "disk"].first(where: { lower.count > $0.count && lower.hasPrefix($0) })
        else { return false }
        let rest = lower.dropFirst(word.count).drop { " -_.".contains($0) }
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Private

    /// The file name before its last dot (the whole name when it has none).
    private static func stem(of file: String) -> String {
        guard let dot = file.lastIndex(of: ".") else { return file }
        return String(file[..<dot])
    }

    /// The image the player takes for a folder, or `.none`.
    private static func image(in folder: String, tree: DeviceArtTree) -> Outcome {
        if let file = named(folderImageStems, in: folder, tree: tree) {
            return .found(join(folder, file))
        }
        guard isDiscFolder(DeviceArtTree.lastComponent(folder)), let up = DeviceArtTree.parent(of: folder) else {
            return .none
        }
        if let file = named(discFolderStems, in: up, tree: tree) {
            return .found(join(up, file))
        }
        return .none
    }

    /// The first `<stem>.<ext>` in the folder, stems then extensions in
    /// order, names compared without case (FAT ignores it).
    private static func named(_ stems: [String], in folder: String, tree: DeviceArtTree) -> String? {
        let images = tree.folderImages[folder] ?? []
        for stem in stems {
            for ext in imageExtensions {
                let wanted = stem + "." + ext
                if let file = images.first(where: { $0.lowercased() == wanted }) { return file }
            }
        }
        return nil
    }

    private static func join(_ folder: String, _ file: String) -> String {
        folder.isEmpty ? file : folder + "/" + file
    }
}
