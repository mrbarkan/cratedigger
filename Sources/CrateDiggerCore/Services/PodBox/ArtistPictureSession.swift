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

    /// Names worth looking up now: the player can key them, their profile
    /// has no picture for the iPod and no reason to wait (the owner kept the
    /// artist off the iPod or chose the default, the lookup holds candidates
    /// for the owner to pick from, or nothing was found in the last 30
    /// days), and the player finds no picture for them (`PodBoxArtLookup`
    /// says `.none`). A default photo whose file is gone is looked up again,
    /// unless the owner picked it. Nothing at all when the catalog does not
    /// match the device, since the lookup cannot be trusted then. Reads the
    /// profile store and checks files: off the main actor.
    public static func namesToFind(_ inputs: Inputs, profiles store: ArtistProfileStore, now: Date) -> [ArtistOnDevice] {
        guard inputs.tree.catalogMismatch.isEmpty else { return [] }
        let profiles = ArtistPictureProfiles(store: store)
        return inputs.artists.filter { artist in
            guard PodBoxArtName.fileStem(for: artist.name) != nil else { return false }
            if let profile = profiles.profile(forName: artist.name) {
                if profile.notOnIPod || profile.noPhoto || profile.defaultPickedByOwner { return false }
                if let photo = ArtistPictureProfiles.iPodPhoto(of: profile), store.hasPhotoFile(hash: photo.hash) {
                    return false
                }
                if !profile.photoCandidates.isEmpty { return false }
                if ArtistPictureProfiles.freshNotFound(profile, now: now) != nil { return false }
            }
            return PodBoxArtLookup.artistPicture(for: artist.name, albumFolders: artist.albumFolders,
                                                 tree: inputs.tree) == .none
        }
    }

    /// Keeps what a picture search found in the artist profiles, under the
    /// owner's rules, and returns how many artists it changed. A failure is
    /// never kept: it would read as "not found" for 30 days. A found picture
    /// becomes one of the artist's photos, from its full-size original (the
    /// finding's, else its prepared bytes) under its own source, id and
    /// credit; it is the default only when the profile has none, so an
    /// owner's pick never moves. Nothing is added under "no photo", nor a
    /// photo of a source the owner removed. Uncertain candidates are held as
    /// references for the owner to pick from; "not found" is remembered with
    /// its date (`photoSearchedAt`). Does not save. Store I/O and image work:
    /// off the main actor, after `refuseWhileLibraryDisconnected`.
    ///
    /// A source's pick goes through `vetted` first: one `ArtistPhotoTrust`
    /// would not take (a namesake's Commons picture under a confirmed
    /// artist, one shared title under no confirmed identity) is held as a
    /// candidate instead.
    @discardableResult
    public static func store(_ findings: [ArtistPictureFinding], in profiles: ArtistProfileStore, now: Date) -> Int {
        let searched = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down))
        var changed = 0
        for finding in vetted(findings, profiles: profiles) {
            let name = finding.name
            switch finding.outcome {
            case let .found(prepared, candidate, source):
                guard let photoSource = ArtistLookupRun.photoSource(source) else { continue }
                let sourceID = candidate?.sourceID ?? finding.originalURL?.path
                let rejection = ArtistPhoto(hash: "", source: photoSource, sourceID: sourceID, pixelWidth: 0,
                                            pixelHeight: 0, added: .distantPast).rejectionKey
                do {
                    let added = try profiles.addPhoto(name: name, data: finding.original ?? prepared, source: photoSource,
                                                      sourceID: sourceID, credit: candidate?.credit) { before, after, _ in
                        guard before?.noPhoto != true,
                              rejection.map({ before?.rejectedPhotoSources.contains($0) == true }) != true
                        else { return false }
                        if let candidate {
                            let key = ArtistLookupRun.rejectionKey(ArtistPictureRecord.HeldCandidate(candidate))
                            after.photoCandidates.removeAll { ArtistLookupRun.rejectionKey($0) == key }
                        }
                        return true
                    }
                    if added != nil { changed += 1 }
                } catch {
                    // Bytes the store will not keep, or a store that cannot
                    // write: this artist goes without, the others still land.
                    continue
                }
            case .uncertain(let candidates):
                let held = candidates.prefix(ArtistPictureFinder.maximumUncertain).map(ArtistPictureRecord.HeldCandidate.init)
                var didChange = false
                profiles.update(name: name) { profile in
                    guard !profile.noPhoto else { return }
                    var known = Set(profile.rejectedPhotoSources).union(profile.photos.compactMap(\.rejectionKey))
                    known.formUnion(profile.photoCandidates.map(ArtistLookupRun.rejectionKey))
                    for candidate in held where known.insert(ArtistLookupRun.rejectionKey(candidate)).inserted {
                        profile.photoCandidates.append(candidate)
                        didChange = true
                    }
                }
                if didChange { changed += 1 }
            case .notFound:
                profiles.update(name: name) { $0.photoSearchedAt = searched }
                changed += 1
            case .failed:
                continue
            }
        }
        return changed
    }

    /// `findings` with every found pick that `ArtistPhotoTrust` would not
    /// make the default, under the identity its profile has now, turned
    /// into an uncertain finding of that one candidate, so it is held for
    /// the owner (a CHECK row) rather than kept as a photo. The owner's own
    /// library picture is kept as found. Reads the profiles.
    public static func vetted(_ findings: [ArtistPictureFinding],
                              profiles store: ArtistProfileStore) -> [ArtistPictureFinding] {
        let profiles = ArtistPictureProfiles(store: store)
        return findings.map { finding in
            guard case let .found(_, candidate?, source) = finding.outcome else { return finding }
            let profile = profiles.profile(forName: finding.name)
            guard !ArtistPhotoTrust.mayBecomeDefault(candidate, source: source, sharedTitles: finding.sharedTitles,
                                                     identity: profile?.identity ?? .unknown,
                                                     confirmedName: profile?.displayName ?? finding.name)
            else { return finding }
            return ArtistPictureFinding(name: finding.name, outcome: .uncertain([candidate]))
        }
    }

    /// One request per name for the finder, with the owner's own picture
    /// from the library when there is one.
    public static func requests(for artists: [ArtistOnDevice], library: LibraryFolders?)
        -> [(name: String, deviceAlbumTitles: [String], libraryPicture: URL?)] {
        artists.map { ($0.name, $0.albumTitles, library?.picture(for: $0.name)) }
    }

    // MARK: - Planning and writing

    /// The pictures the iPod gets, for the planner, asked for lazily
    /// (`ArtistPicturePlanner.Pictures`): each artist's default photo
    /// (`ArtistPictureProfiles.iPodPhoto`), prepared to the 400 px square
    /// baseline JPEG through `cache`, so the artist page and the iPod always
    /// show the same picture and a photo is prepared once, not on every
    /// transfer. Only the artists the planner will write are prepared at
    /// all. Never for an artist the owner kept off the iPod or wants no
    /// photo for, and nothing when the photo's file cannot be read or will
    /// not prepare. The profiles are read once, here; the closures read and
    /// decode images: call the planner off the main actor.
    public static func pictures(profiles store: ArtistProfileStore,
                                cache: ArtistPicturePreparedCache) -> ArtistPicturePlanner.Pictures {
        let profiles = ArtistPictureProfiles(store: store)
        func photo(_ artist: ArtistOnDevice) -> ArtistPhoto? {
            ArtistPictureProfiles.iPodPhoto(of: profiles.profile(forName: artist.name))
        }
        return ArtistPicturePlanner.Pictures(
            has: { artist in photo(artist).map { store.hasPhotoFile(hash: $0.hash) } ?? false },
            bytes: { artist in
                guard let photo = photo(artist) else { return nil }
                return cache.prepared(hash: photo.hash) { store.photoData(hash: photo.hash) }
            })
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

    // MARK: - Apply in the Artist Pictures sheet

    /// The footer while check M5 has not been marked passed on this iPod.
    public static let oneFirstFooter = "Writing one picture first. Check it on the iPod, then mark the check as "
        + "passed in Preferences ▸ Devices to write the rest."

    /// What Apply writes of a plan. Until the owner has marked M5 passed
    /// (`passedM5`), at most one artist's picture: the first ready one the
    /// owner changed in this sheet session (`changedNames`, in the order
    /// they were changed), else the first ready one in the sheet's order
    /// (most tracks first); the rest stay ready. After M5, every ready one.
    public static func applySelection(_ plan: ArtistPicturePlan, artists: [ArtistOnDevice], changedNames: [String],
                                      passedM5: Bool) -> (operations: [DeviceFileOperation], heldBack: Int) {
        guard !passedM5 else { return (plan.operations, 0) }
        let bySubject = Dictionary(plan.operations.compactMap { op -> (String, DeviceFileOperation)? in
            guard case let .write(_, _, _, _, subject?) = op else { return nil }
            return (subject, op)
        }, uniquingKeysWith: { first, _ in first })
        func operation(for name: String) -> DeviceFileOperation? {
            [PodBoxArtName.key(name), PodBoxArtName.altKey(name)].filter { $0 != 0 }
                .lazy.compactMap { bySubject[String($0)] }.first
        }
        let ordered = artists.sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }.map(\.name)
        guard let chosen = (changedNames + ordered).lazy.compactMap(operation(for:)).first else {
            return ([], plan.operations.count)
        }
        return ([chosen], plan.operations.count - 1)
    }

    /// Asked before Apply writes every ready picture (M5 passed).
    public static func applyConfirmation(count: Int, deviceName: String) -> (title: String, message: String) {
        let pictures = count == 1 ? "1 artist picture" : "\(count) artist pictures"
        return ("Write \(pictures) to \(deviceName)?",
                "\(count == 1 ? "It goes" : "They go") where PodBox looks for them. A picture already on the iPod "
                    + "is never covered, and anything CrateDigger replaces of its own is kept on the Mac.")
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
