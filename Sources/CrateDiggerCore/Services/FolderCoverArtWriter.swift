import Foundation

/// Writes a `cover.jpg` sidecar into album folders on a device.
///
/// Rockbox looks for a cover file in the track's own folder before it looks
/// inside the file, and its embedded-JPEG path renders a large cover in
/// greyscale once it has to scale the image down to the theme's art size. A
/// small baseline JPEG sitting next to the tracks is what those players
/// actually want, so Rockbox profiles ship the art as a sidecar and leave it
/// out of the audio files entirely.
public struct FolderCoverArtWriter {
    /// The name Rockbox (and most other players that read folder art) checks first.
    public static let filename = "cover.jpg"
    /// Comfortably above any Rockbox theme's art size while staying small
    /// enough that the decoder never has to scale it far.
    public static let defaultMaxDimension = 400

    private let preparer: ArtworkPreparing
    private let fileManager: FileManager
    private let writeData: (Data, URL) throws -> Bool

    /// `writeData` puts one prepared cover at its destination and says
    /// whether the bytes there changed. A device run passes its
    /// `DeviceTransferDoor.writeCover`, so every cover on a device goes
    /// through the write door. The default, for an ordinary conversion's
    /// destination folder, is `writeIfChanged`.
    public init(preparer: ArtworkPreparing = ArtworkService(), fileManager: FileManager = .default,
                writeData: ((Data, URL) throws -> Bool)? = nil) {
        self.preparer = preparer
        self.fileManager = fileManager
        self.writeData = writeData ?? { data, url in try FolderCoverArtWriter.writeIfChanged(data, to: url) }
    }

    /// Writes one `cover.jpg` per folder, replacing any file already there.
    /// Which folders may be given one is decided before this:
    /// `DeviceTransferFilePlan.coverFolders(after:hasCover:)` for a device
    /// run (a Gaps fill keeps the cover it found), `conversionCovers` for an
    /// ordinary conversion (never over an existing cover). Folders
    /// that don't exist (nothing landed there) are skipped. Returns the number
    /// of covers whose bytes changed: one already holding the same bytes is
    /// left as it is, date included. A cover that can't be encoded or written
    /// is skipped and logged, never fatal: the music is already there.
    @discardableResult
    public func write(
        _ coversByFolder: [URL: ArtworkAsset],
        maxDimension: Int = defaultMaxDimension
    ) -> Int {
        var written = 0
        for (folder, artwork) in coversByFolder {
            guard !artwork.data.isEmpty,
                  fileManager.fileExists(atPath: folder.path),
                  let prepared = try? preparer.prepareCompatibleArtwork(
                    asset: artwork, profile: .generic, maxDimension: maxDimension)
            else { continue }
            let destination = folder.appendingPathComponent(Self.filename)
            do {
                if try writeData(prepared.data, destination) { written += 1 }
            } catch {
                AppLog.conversion.warning(
                    "Skipped a cover.jpg: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    /// The ordinary (non-device) cover write: nothing when the file already
    /// holds `data`, else a write through a temp file renamed into place in
    /// the same folder, so no reader sees half a JPEG. Returns whether it wrote.
    public static func writeIfChanged(_ data: Data, to destination: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: destination), existing == data { return false }
        try data.write(to: destination, options: .atomic)
        return true
    }

    /// Whether `folder` already holds a `cover.jpg` (any case, as a FAT
    /// device or a default macOS volume compares names).
    public static func hasCover(in folder: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: folder.appendingPathComponent(filename).path)
    }

    /// One file an ordinary (non-device) conversion wrote, for deciding its
    /// folder covers.
    public struct ConversionLanding {
        public let folder: URL
        /// The album the file belongs to (`OutputPathPlanner.albumFolderKeys`).
        public let album: AlbumFolderKey
        public let artwork: ArtworkAsset?

        public init(folder: URL, album: AlbumFolderKey, artwork: ArtworkAsset?) {
            self.folder = folder
            self.album = album
            self.artwork = artwork
        }
    }

    /// The covers an ordinary conversion with Folder Art on writes: one per
    /// folder something landed in, from the first landing there that carries
    /// art, except where a cover would not belong to one album the user just
    /// converted. Skipped: a folder that already holds a `cover.jpg` (it is
    /// the user's, and a conversion never replaces it), the destination root
    /// itself in flat mode (every album lands there), and a folder that
    /// `planned` puts more than one album of the batch into. `planned` is
    /// every file of the batch, landed or not, so a failed track still
    /// counts as its album being there.
    public static func conversionCovers(
        landed: [ConversionLanding],
        planned: [ConversionLanding],
        destinationRoot: URL,
        folderMode: FolderStructureMode,
        hasCover: (URL) -> Bool
    ) -> [URL: ArtworkAsset] {
        func key(_ url: URL) -> String { url.standardizedFileURL.path }
        var albumsByFolder: [String: Set<AlbumFolderKey>] = [:]
        for landing in planned + landed {
            albumsByFolder[key(landing.folder), default: []].insert(landing.album)
        }
        let root = key(destinationRoot)
        let skipped = Set(landed.map { key($0.folder) }).filter { path in
            (folderMode == .flat && path == root)
                || (albumsByFolder[path]?.count ?? 0) > 1
                || hasCover(URL(fileURLWithPath: path, isDirectory: true))
        }

        var covers: [URL: ArtworkAsset] = [:]
        for landing in landed {
            let folder = landing.folder.standardizedFileURL
            guard !skipped.contains(key(folder)), covers[folder] == nil,
                  let artwork = landing.artwork, !artwork.data.isEmpty
            else { continue }
            covers[folder] = artwork
        }
        return covers
    }

    /// One audio file per folder under `root` — the first in name order, so a
    /// repeat run reads the same track's cover. Deep walk; hidden files are
    /// skipped, which on a FAT device also drops the `._` AppleDouble twins
    /// macOS leaves beside every file.
    ///
    /// This is how FIX ART repairs a device that was filled before folder art
    /// existed: the covers come back out of the files already on it, so nothing
    /// has to match them to the library.
    public static func representativeAudioFiles(
        under root: URL,
        extensions: Set<String> = LibraryScanService.defaultSupportedExtensions,
        fileManager: FileManager = .default
    ) -> [URL: URL] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var firstByFolder: [URL: URL] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let folder = url.deletingLastPathComponent()
            if let current = firstByFolder[folder],
               current.lastPathComponent <= url.lastPathComponent { continue }
            firstByFolder[folder] = url
        }
        return firstByFolder
    }
}
