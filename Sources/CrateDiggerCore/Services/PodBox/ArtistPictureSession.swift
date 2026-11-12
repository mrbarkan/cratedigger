import CryptoKit
import Darwin
import Foundation

/// Everything decidable about one run of artist pictures for a device, so
/// the view model only gathers the inputs and calls these: whether the run
/// may write at all, which names are worth looking up, what to store from
/// a finding, and the one line the transfer summary gets.
public enum ArtistPictureSession {
    /// What a run knows about the device and the owner's settings. `artists`
    /// and `tree` matter only to `namesToFind`; `mayWrite` reads the flags.
    public struct Inputs: Sendable {
        public var artists: [ArtistOnDevice]
        public var tree: DeviceArtTree
        public var destination: ArtistPictureDestination
        /// Inside a transfer, rather than pressed for in the Artist Pictures sheet.
        public var automatic: Bool
        public var matchedByUUID: Bool
        /// The device has `centralPeopleArtwork` (it runs PodBox).
        public var hasCapability: Bool
        /// The owner has run check M5 on this iPod.
        public var passedM5: Bool

        public init(artists: [ArtistOnDevice] = [], tree: DeviceArtTree? = nil,
                    destination: ArtistPictureDestination, automatic: Bool, matchedByUUID: Bool,
                    hasCapability: Bool, passedM5: Bool) {
            self.artists = artists
            self.tree = tree ?? DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:],
                                              foldersWithAudio: [], artistsByFolder: [:])
            self.destination = destination
            self.automatic = automatic
            self.matchedByUUID = matchedByUUID
            self.hasCapability = hasCapability
            self.passedM5 = passedM5
        }
    }

    /// The manual check that has to pass before pictures go on in a transfer.
    public static let m5Check = "M5"

    public static let picturesOff = "Artist pictures are off for this device."
    public static let notPodBox = "This device is not PodBox."
    public static let needsVolumeID = "Artist pictures need a device matched by its volume ID."
    public static let waitsForM5 = "Artist pictures wait for the M5 check on this iPod."
    public static let notAtMount = "Nothing is written to a device when it is plugged in."

    /// The DEVICES ticker's reminder after covers or pictures changed on PodBox.
    public static let artCacheReminder = "NEXT ON IPOD · UPDATE ART CACHE"
    /// The file PodBox rewrites when it rebuilds its art cache: only ever `stat`ed.
    public static let artCacheStamp = ".rockbox/library/cache/art/stamps.dat"

    // MARK: - May this run write?

    /// Whether a session may write pictures at all, and why not. The reasons
    /// come in this order: switched off, not PodBox, not matched by volume
    /// UUID (or the session gate refuses), and, inside a transfer only, the
    /// M5 check not passed. A mount never writes.
    public static func mayWrite(_ inputs: Inputs, trigger: DeviceSessionTrigger) -> (allowed: Bool, reason: String?) {
        if trigger == .mount { return (false, notAtMount) }
        guard inputs.destination != .off else { return (false, picturesOff) }
        guard inputs.hasCapability else { return (false, notPodBox) }
        guard inputs.matchedByUUID,
              DeviceSessionGate.allows(.writeExtras, trigger: trigger, matchedByUUID: inputs.matchedByUUID)
        else { return (false, needsVolumeID) }
        if inputs.automatic, !inputs.passedM5 { return (false, waitsForM5) }
        return (true, nil)
    }

    // MARK: - Finding

    /// Names worth looking up now: the player can key them, the store has
    /// no fresh answer (no record, a "not found" older than 30 days, or a
    /// found picture whose prepared bytes are gone and that the owner did not
    /// pick), and the player finds no picture for them (`PodBoxArtLookup`
    /// says `.none`). A rejected or uncertain record waits for the owner in
    /// the sheet. Nothing at all when the catalog does not match the device,
    /// since the lookup cannot be trusted then.
    public static func namesToFind(_ inputs: Inputs, store: ArtistPictureStore, now: Date) -> [ArtistOnDevice] {
        guard inputs.tree.catalogMismatch.isEmpty else { return [] }
        return inputs.artists.filter { artist in
            guard PodBoxArtName.fileStem(for: artist.name) != nil else { return false }
            if let record = store.record(forName: artist.name) {
                switch record.outcome {
                case .rejected, .uncertain:
                    return false
                case .notFound:
                    if !record.isStale(now: now) { return false }
                case .found:
                    if record.pickedByUser || store.preparedData(for: record) != nil { return false }
                }
            }
            return PodBoxArtLookup.artistPicture(for: artist.name, albumFolders: artist.albumFolders,
                                                 tree: inputs.tree) == .none
        }
    }

    /// What to store for a finding, and the prepared bytes to cache with it.
    /// nil for a failure, which is never stored (`isStorable`): it would
    /// read as "not found" for 30 days. A found picture keeps its source,
    /// the source's own id and credit, and the hash of the exact bytes.
    public static func record(from finding: ArtistPictureFinding, now: Date) -> (ArtistPictureRecord, Data?)? {
        guard finding.outcome.isStorable else { return nil }
        switch finding.outcome {
        case let .found(prepared, candidate, source):
            let record = ArtistPictureRecord(
                foldedKey: "", displayName: finding.name, outcome: .found, source: source,
                sourceID: candidate?.sourceID, preparedHash: SHA256.hash(data: prepared).hexString,
                pickedByUser: false, checkedAt: now, credit: candidate?.credit)
            return (record, prepared)
        case .uncertain:
            return (ArtistPictureRecord(foldedKey: "", displayName: finding.name, outcome: .uncertain, checkedAt: now),
                    nil)
        case .notFound:
            return (ArtistPictureRecord(foldedKey: "", displayName: finding.name, outcome: .notFound, checkedAt: now),
                    nil)
        case .failed:
            return nil
        }
    }

    /// One request per name for the finder, with the owner's own picture
    /// from the library when there is one.
    public static func requests(for artists: [ArtistOnDevice], library: LibraryFolders?)
        -> [(name: String, deviceAlbumTitles: [String], libraryPicture: URL?)] {
        artists.map { ($0.name, $0.albumTitles, library?.picture(for: $0.name)) }
    }

    // MARK: - Planning and writing

    /// The prepared bytes the store holds for these artists, by folded key:
    /// found records only, never a rejected or uncertain one. Reads the image
    /// cache, so call it off the main actor.
    public static func prepared(for artists: [ArtistOnDevice], store: ArtistPictureStore) -> [String: Data] {
        var result: [String: Data] = [:]
        for artist in artists {
            guard let record = store.record(forName: artist.name), record.outcome == .found,
                  let data = store.preparedData(for: record) else { continue }
            result[artist.foldedKey] = data
        }
        return result
    }

    /// `base` with the two picture roles switched on, for the executor that
    /// writes a plan. Nothing else about the policy changes.
    public static func picturePolicy(from base: DeviceWritePolicy) -> DeviceWritePolicy {
        DeviceWritePolicy(musicSubpath: base.musicSubpath, playlistDirectory: base.playlistDirectory,
                          audioExtensions: base.audioExtensions,
                          enabledRoles: base.enabledRoles.union([.artistPicture, .artistFolderPicture]))
    }

    /// The SHA-256 of a regular file on the device, by device-relative
    /// path; nil for anything else. Reads only.
    public static func deviceHash(volumeRoot: URL) -> @Sendable (String) -> String? {
        { path in
            let url = volumeRoot.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return try? DeviceFileIO.sha256(of: url)
        }
    }

    /// The transfer summary's line: `Wrote N artist pictures`, then how many
    /// already had one, how many wait for a pick (no picture found yet, or
    /// an uncertain match) and how many did not fit, each when non-zero. A
    /// refused plan gives its refusal. nil when nothing was written and
    /// nothing waits.
    public static func summaryLine(written: Int, plan: ArtistPicturePlan) -> String? {
        if let refusal = plan.refusal { return refusal }
        let had = plan.alreadyHasPicture.count + plan.foreign.count
        let waiting = plan.noPictureYet.count
        let didNotFit = plan.overBudget.count
        guard written > 0 || waiting > 0 else { return nil }
        var parts = ["Wrote \(written) artist \(written == 1 ? "picture" : "pictures")"]
        if had > 0 { parts.append("\(had) already had one") }
        if waiting > 0 { parts.append("\(waiting) waiting for a pick") }
        if didNotFit > 0 { parts.append("\(didNotFit) did not fit") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - The art cache reminder

    /// After a session that changed covers or pictures on PodBox, the owner
    /// has to rebuild the player's art cache.
    public static func remindsToUpdateArtCache(changes: DeviceWriteChanges, firmware: DeviceFirmware?) -> Bool {
        firmware?.flavour == .podBox && !changes.isDisjoint(with: [.covers, .pictures])
    }

    /// When the player last rebuilt its art cache: `stat` of its stamp file,
    /// never opened. nil when it is not there.
    public static func artCacheStampModified(volumeRoot: URL) -> Date? {
        var info = stat()
        guard lstat(volumeRoot.appendingPathComponent(artCacheStamp).path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    // MARK: - The owner's library

    /// The owner's library, as the library-folder source reads it: for each
    /// person the folders holding their tracks, and for each folder whose
    /// albums lie under it (every artist, Various Artists included, so a
    /// shared folder is never taken for one artist's).
    public struct LibraryFolders: Sendable {
        let foldersByKey: [UInt32: Set<URL>]
        let artistsByFolder: [URL: Set<String>]

        public init(tracks: [LoadedTrack]) {
            var foldersByKey: [UInt32: Set<URL>] = [:]
            var artistsByFolder: [URL: Set<String>] = [:]
            var seen = Set<String>()
            for track in tracks {
                let folder = track.track.fileURL.deletingLastPathComponent().standardizedFileURL
                let raw = DeviceArtTree.rawPerson(for: track)
                guard seen.insert(folder.path + "\u{0}" + raw).inserted else { continue }
                if let person = DeviceArtTree.person(for: track) {
                    for key in [PodBoxArtName.key(person), PodBoxArtName.altKey(person)] where key != 0 {
                        foldersByKey[key, default: []].insert(folder)
                    }
                }
                let folded = PodBoxArtName.folded(raw)
                guard !folded.isEmpty else { continue }
                // The album folder and the three above it: the source looks
                // at an album's parent and grandparent, a disc folder's one more.
                var current = folder
                for _ in 0...3 {
                    guard current.path != "/" else { break }
                    artistsByFolder[current, default: []].insert(folded)
                    current = current.deletingLastPathComponent()
                }
            }
            self.foldersByKey = foldersByKey
            self.artistsByFolder = artistsByFolder
        }

        /// The owner's own picture for `name` (`LibraryFolderPictureSource`),
        /// read on the Mac. nil when the library has none.
        public func picture(for name: String, fileManager: FileManager = .default) -> URL? {
            let keys = [PodBoxArtName.key(name), PodBoxArtName.altKey(name)].filter { $0 != 0 }
            let folders = keys.reduce(into: Set<URL>()) { $0.formUnion(foldersByKey[$1] ?? []) }
            guard !folders.isEmpty else { return nil }
            return LibraryFolderPictureSource.picture(for: name, albumFolders: folders.sorted { $0.path < $1.path },
                                                      artistsByFolder: artistsByFolder, fileManager: fileManager)
        }
    }
}
