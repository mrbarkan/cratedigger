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

    /// What one `write` did, folder by folder.
    public struct WriteCounts: Equatable, Sendable {
        /// Covers whose bytes changed.
        public var written = 0
        /// Already held these very bytes.
        public var unchanged = 0
        /// Could not be encoded or written (a refused path, a cover that
        /// appeared, a full device): skipped and logged.
        public var failed = 0
        /// The folder is gone or the art was empty: nothing to do.
        public var skipped = 0

        public init(written: Int = 0, unchanged: Int = 0, failed: Int = 0, skipped: Int = 0) {
            self.written = written
            self.unchanged = unchanged
            self.failed = failed
            self.skipped = skipped
        }
    }

    /// Writes one `cover.jpg` per folder through `writeData`. Which folders
    /// may be given one is decided before this:
    /// `DeviceTransferFilePlan.coverFolders(after:hasCover:)` for a device
    /// run (a Gaps fill keeps the cover it found), `conversionCovers` for an
    /// ordinary conversion (never over an existing cover), `fixArtPlan` for
    /// FIX ART (only folders with none). Folders that don't exist (nothing
    /// landed there) are skipped. Returns the number of covers whose bytes
    /// changed: one already holding the same bytes is left as it is, date
    /// included. A cover that can't be encoded or written is skipped and
    /// logged, never fatal: the music is already there.
    @discardableResult
    public func write(
        _ coversByFolder: [URL: ArtworkAsset],
        maxDimension: Int = defaultMaxDimension
    ) -> Int {
        writeCounting(coversByFolder, maxDimension: maxDimension).written
    }

    /// `write`, reporting every folder's outcome.
    public func writeCounting(
        _ coversByFolder: [URL: ArtworkAsset],
        maxDimension: Int = defaultMaxDimension
    ) -> WriteCounts {
        var counts = WriteCounts()
        for (folder, artwork) in coversByFolder {
            guard !artwork.data.isEmpty, fileManager.fileExists(atPath: folder.path) else {
                counts.skipped += 1
                continue
            }
            guard let prepared = try? preparer.prepareCompatibleArtwork(
                asset: artwork, profile: .generic, maxDimension: maxDimension)
            else {
                counts.failed += 1
                continue
            }
            let destination = folder.appendingPathComponent(Self.filename)
            do {
                if try writeData(prepared.data, destination) {
                    counts.written += 1
                } else {
                    counts.unchanged += 1
                }
            } catch {
                counts.failed += 1
                AppLog.conversion.warning(
                    "Skipped a cover.jpg: \(error.localizedDescription, privacy: .public)")
            }
        }
        return counts
    }

    /// The ordinary (non-device) cover write: nothing when the file already
    /// holds `data`, else a write through a temp file renamed into place in
    /// the same folder, so no reader sees half a JPEG. Returns whether it wrote.
    public static func writeIfChanged(_ data: Data, to destination: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: destination), existing == data { return false }
        try data.write(to: destination, options: .atomic)
        return true
    }

    /// Whether `folder` already holds a `cover.jpg` in any case (`Cover.JPG`
    /// too), read from the folder's listing so a case-sensitive volume
    /// answers as a FAT device does. Hidden `._` twins do not count.
    public static func hasCover(in folder: URL, fileManager: FileManager = .default) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains { $0.lowercased() == filename }
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
    /// has to match them to the library. `fixArtPlan` then keeps only the
    /// folders that have no cover.
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

    // MARK: - FIX ART

    /// What FIX ART will do on a device: add a cover to the album folders
    /// that have none, and leave every folder that already has one exactly
    /// as it is. It never replaces a cover: on a device that already has
    /// covers, replacing each with a 400 px re-encode of itself only loses
    /// quality.
    public struct FixArtPlan: Equatable, Sendable {
        /// Album folder -> the audio file whose art it would get, for the
        /// folders with no `cover.jpg`.
        public let needsCover: [URL: URL]
        /// Album folders that already hold a `cover.jpg` (any case), sorted.
        public let alreadyCovered: [URL]

        public init(needsCover: [URL: URL], alreadyCovered: [URL]) {
            self.needsCover = needsCover
            self.alreadyCovered = alreadyCovered
        }

        public var albumCount: Int { needsCover.count + alreadyCovered.count }
    }

    /// Splits `representatives` (`representativeAudioFiles`) by whether each
    /// folder already has a cover.
    public static func fixArtPlan(representatives: [URL: URL], hasCover: (URL) -> Bool) -> FixArtPlan {
        var needs: [URL: URL] = [:]
        var covered: [URL] = []
        for (folder, file) in representatives {
            if hasCover(folder) { covered.append(folder) } else { needs[folder] = file }
        }
        return FixArtPlan(needsCover: needs, alreadyCovered: covered.sorted { $0.path < $1.path })
    }

    /// The words FIX ART shows: the confirmation and the summary.
    public enum FixArtText {
        static func folders(_ count: Int) -> String {
            "\(count) album folder\(count == 1 ? "" : "s")"
        }

        /// `singular` for one, `plural` otherwise.
        static func verb(_ count: Int, _ singular: String, _ plural: String) -> String {
            count == 1 ? singular : plural
        }

        /// Nothing to add: every album folder already has a cover (or there is no album).
        public static func nothingToAdd(_ plan: FixArtPlan, deviceName: String) -> (title: String, message: String) {
            guard plan.albumCount > 0 else {
                return ("No albums found", "CrateDigger found no album folders with music on \(deviceName).")
            }
            let count = plan.alreadyCovered.count
            return ("Every album has a cover",
                    "\(count == 1 ? "The" : "All") \(folders(count)) on \(deviceName) already "
                        + "\(verb(count, "has", "have")) a cover.jpg. FIX ART only adds covers where there are none, "
                        + "so nothing was changed.")
        }

        /// Before writing: how many folders get a cover and how many already had one.
        public static func confirmation(_ plan: FixArtPlan, deviceName: String) -> (title: String, message: String) {
            let needs = plan.needsCover.count, covered = plan.alreadyCovered.count
            var message = "\(folders(needs)) on \(deviceName) \(verb(needs, "has", "have")) no cover.jpg. "
                + "\(verb(needs, "It gets", "Each gets")) one made from its tracks' artwork, where they carry any."
            if covered > 0 {
                message += " \(folders(covered)) already \(verb(covered, "has", "have")) one and "
                    + "\(verb(covered, "is", "are")) left as \(verb(covered, "it is", "they are"))."
            }
            return ("Add covers to \(folders(needs))?", message)
        }

        /// After writing.
        public static func result(_ counts: WriteCounts, noArtwork: Int, plan: FixArtPlan,
                                  deviceName: String) -> (title: String, message: String) {
            let covered = plan.alreadyCovered.count
            var parts = ["Added a cover.jpg to \(folders(counts.written)) on \(deviceName)."]
            if covered > 0 {
                parts.append("\(folders(covered)) already had one and \(verb(covered, "was", "were")) left as "
                             + "\(verb(covered, "it was", "they were")).")
            }
            if noArtwork > 0 {
                parts.append("\(folders(noArtwork)) \(verb(noArtwork, "has", "have")) no artwork in "
                             + "\(verb(noArtwork, "its", "their")) tracks to copy out.")
            }
            if counts.failed > 0 {
                parts.append("\(folders(counts.failed)) could not be given a cover; the log says why.")
            }
            return (counts.written > 0 ? "Album art fixed" : "No covers written", parts.joined(separator: " "))
        }
    }
}
