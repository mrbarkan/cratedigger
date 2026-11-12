import Foundation

/// What the player can see of pictures on a device: one read-only listing of
/// `/Artwork` and the music folder, plus the catalog's artists per folder.
/// Paths are device-relative with `/` separators and no leading slash; the
/// volume root is `""`.
public struct DeviceArtTree: Sendable {
    public let peopleFiles: [String]                  // names in /Artwork/People, hidden files excluded
    public let coverFiles: [String]                   // names in /Artwork/Covers
    public let folderImages: [String: [String]]       // device-relative folder -> image file names in it
    public let foldersWithAudio: Set<String>          // folders that directly hold audio
    public let artistsByFolder: [String: Set<String>] // folder -> folded keys of the artists whose albums lie under it
    /// The music folder, device-relative. The lookup never climbs above it.
    /// nil: no bound but the volume root.
    public let musicFolder: String?

    public init(peopleFiles: [String], coverFiles: [String], folderImages: [String: [String]],
                foldersWithAudio: Set<String>, artistsByFolder: [String: Set<String>],
                musicFolder: String? = nil) {
        self.peopleFiles = peopleFiles
        self.coverFiles = coverFiles
        self.folderImages = folderImages
        self.foldersWithAudio = foldersWithAudio
        self.artistsByFolder = artistsByFolder
        self.musicFolder = musicFolder.map(Self.trimmedSlashes)
    }

    /// Names PodBox never gives a picture to (compared trimmed and case-folded).
    static let skippedNames: Set<String> = ["various artists", "unknown artist", "<untagged>"]
    static let peopleFolder = "Artwork/People"
    static let coversFolder = "Artwork/Covers"

    /// One walk of the music folder and /Artwork, plus the catalog for
    /// artistsByFolder. Read-only: lists folders, never opens a file.
    public static func scan(volumeRoot: URL, musicSubpath: String, catalog: [LoadedTrack],
                            fileManager: FileManager = .default) -> DeviceArtTree {
        let music = trimmedSlashes(musicSubpath)
        let paths = DevicePaths(root: volumeRoot)
        let audioExtensions = LibraryScanService.defaultSupportedExtensions
        let imageExtensions = Set(PodBoxArtLookup.imageExtensions)

        var folderImages: [String: [String]] = [:]
        var foldersWithAudio = Set<String>()
        let musicURL = music.isEmpty ? volumeRoot : volumeRoot.appendingPathComponent(music, isDirectory: true)
        let walker = fileManager.enumerator(at: musicURL, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let relative = paths.relative(url) else { continue }
            let folder = parent(of: relative) ?? ""
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                folderImages[folder, default: []].append(url.lastPathComponent)
            } else if audioExtensions.contains(ext) {
                foldersWithAudio.insert(folder)
            }
        }
        for key in folderImages.keys { folderImages[key]?.sort() }

        var artistsByFolder: [String: Set<String>] = [:]
        for loaded in catalog {
            let key = PodBoxArtName.folded(rawPerson(for: loaded))
            guard !key.isEmpty, let relative = paths.relative(loaded.track.fileURL),
                  var folder = parent(of: relative), isWithin(folder, music) else { continue }
            while true {
                artistsByFolder[folder, default: []].insert(key)
                guard folder != music, let up = parent(of: folder), isWithin(up, music) else { break }
                folder = up
            }
        }

        return DeviceArtTree(peopleFiles: listing(volumeRoot.appendingPathComponent(peopleFolder), fileManager),
                             coverFiles: listing(volumeRoot.appendingPathComponent(coversFolder), fileManager),
                             folderImages: folderImages, foldersWithAudio: foldersWithAudio,
                             artistsByFolder: artistsByFolder, musicFolder: music)
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

    static func isWithin(_ folder: String, _ music: String?) -> Bool {
        guard let music, !music.isEmpty else { return true }
        return folder == music || folder.hasPrefix(music + "/")
    }

    static func trimmedSlashes(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private static func listing(_ folder: URL, _ fileManager: FileManager) -> [String] {
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Turns absolute URLs into device-relative paths, accepting both the
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
                return String(path.dropFirst(prefix.count))
            }
            return nil
        }
    }
}

/// The player's search for a person's picture, simulated so CrateDigger
/// never writes one the player would not use, nor one that would hide the
/// owner's own. First match wins:
/// 1. `/Artwork/People/<name>.<ext>`;
/// 2. `cover.<ext>` or `folder.<ext>` in a folder named after the person:
///    the album folder or up to three levels above it;
/// 3. `cover`/`folder` in the album folder's parent or grandparent, unless
///    that folder holds more than one artist's albums.
/// In steps 2 and 3 a folder that directly holds audio is skipped: its
/// images are album covers, even in a self-titled album's folder.
public enum PodBoxArtLookup {
    public static let imageExtensions = ["jpeg", "jpg", "bmp", "png", "gif", "webp"]
    static let portraitStems = ["cover", "folder"]

    /// Device-relative path of the image the player would use, by its three steps. nil = none.
    public static func artistPicture(for name: String, albumFolders: [String], tree: DeviceArtTree) -> String? {
        for file in tree.peopleFiles {
            let ns = file as NSString
            guard imageExtensions.contains(ns.pathExtension.lowercased()),
                  PodBoxArtName.matches(ns.deletingPathExtension, name) else { continue }
            return DeviceArtTree.peopleFolder + "/" + file
        }

        let albums = albumFolders.map(DeviceArtTree.trimmedSlashes)
        for album in albums {
            for folder in chain(from: album, levels: 0...3, tree: tree)
            where !tree.foldersWithAudio.contains(folder) {
                let folderName = folder.split(separator: "/").last.map(String.init) ?? ""
                guard PodBoxArtName.matches(folderName, name), let image = portrait(in: folder, tree: tree)
                else { continue }
                return image
            }
        }

        for album in albums {
            for folder in chain(from: album, levels: 1...2, tree: tree)
            where !tree.foldersWithAudio.contains(folder) && (tree.artistsByFolder[folder]?.count ?? 0) <= 1 {
                if let image = portrait(in: folder, tree: tree) { return image }
            }
        }
        return nil
    }

    /// The album folder (level 0) and its ancestors at the given levels,
    /// nearest first, stopping at the music folder.
    private static func chain(from album: String, levels: ClosedRange<Int>, tree: DeviceArtTree) -> [String] {
        guard DeviceArtTree.isWithin(album, tree.musicFolder) else { return [] }
        var result: [String] = []
        var folder: String? = album
        for level in 0...levels.upperBound {
            guard let current = folder, DeviceArtTree.isWithin(current, tree.musicFolder) else { break }
            if levels.contains(level) { result.append(current) }
            folder = DeviceArtTree.parent(of: current)
        }
        return result
    }

    /// `cover.<ext>` before `folder.<ext>`, extensions in list order, names
    /// compared without case (FAT ignores it).
    private static func portrait(in folder: String, tree: DeviceArtTree) -> String? {
        let images = tree.folderImages[folder] ?? []
        for stem in portraitStems {
            for ext in imageExtensions {
                let wanted = stem + "." + ext
                if let file = images.first(where: { $0.lowercased() == wanted }) {
                    return folder.isEmpty ? file : folder + "/" + file
                }
            }
        }
        return nil
    }
}
