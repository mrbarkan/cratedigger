import Foundation

/// A transfer's albums compared with the device, with the destinations the
/// unasked-for writes (New and Gaps) would take already checked against the
/// device's files. What the review sheet shows and `resolve` turns into a plan.
public struct DeviceTransferReview: Sendable {
    /// Every album sent, in order of first appearance. An album whose write
    /// would land on a file nothing matched is `.differs` with `.pathTaken`.
    public let albums: [DeviceAlbumComparison]
    /// Track count of the albums the device has nothing of.
    public let newTrackCount: Int
    /// Tracks already on the device in the same form: every track of a
    /// Present album, plus the ones a Gaps album already has.
    public let presentTrackCount: Int
    /// Albums with tracks missing and nothing differing, filled in without asking.
    public let gapAlbumCount: Int
    /// Differing albums the user chose Leave it for before, not asked again.
    public let leftAloneAlbumCount: Int
    /// The volume the review checked, and the profile's music folder on it
    /// (the only folder a transfer writes into or deletes from). nil for a
    /// review built from albums alone, which `resolve` refuses.
    public let mountedRoot: URL?
    public let musicFolder: URL?
    /// The per-album folder names the user reviewed (template mode), applied
    /// to natural paths. Kept here so `resolve` plans exactly what was checked.
    let reviewedAlbumFolders: [AlbumFolderKey: String]
    /// The settings the paths were planned with.
    let settings: ExternalDeviceTransferSettings?

    /// The albums the sheet asks about.
    public var needingDecision: [DeviceAlbumComparison] {
        albums.filter { $0.status == .differs && !$0.isLeftAlone }
    }

    /// Albums alone, for showing them (a preview of the sheet). Never checked
    /// against a device, so `resolve` refuses it.
    public init(albums: [DeviceAlbumComparison]) {
        self.init(albums: albums, mountedRoot: nil, musicFolder: nil, settings: nil, reviewedAlbumFolders: [:])
    }

    init(
        albums: [DeviceAlbumComparison],
        mountedRoot: URL?,
        musicFolder: URL?,
        settings: ExternalDeviceTransferSettings?,
        reviewedAlbumFolders: [AlbumFolderKey: String]
    ) {
        self.albums = albums
        self.mountedRoot = mountedRoot
        self.musicFolder = musicFolder
        self.settings = settings
        self.reviewedAlbumFolders = reviewedAlbumFolders
        newTrackCount = albums.filter { $0.status == .new }.reduce(0) { $0 + $1.sent.count }
        presentTrackCount = albums.reduce(0) { total, album in
            switch album.status {
            case .present: return total + album.sent.count
            case .gaps: return total + album.same.count
            case .new, .differs: return total
            }
        }
        gapAlbumCount = albums.filter { $0.status == .gaps }.count
        leftAloneAlbumCount = albums.filter { $0.status == .differs && $0.isLeftAlone }.count
    }
}

/// What a device transfer writes and deletes, decided. Run every copy first,
/// then the deletions, so an interrupted transfer never leaves an album with
/// neither its old files nor its new ones.
public struct DeviceTransferFilePlan: Sendable {
    public struct Copy: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            /// The device had nothing of the album.
            case new
            /// A track the device's copy of the album was missing.
            case gap
            /// Written for an album the user chose Replace for.
            case replacement
            /// Written beside the device's copy, for Keep both.
            case keptBoth
        }

        public let source: LoadedTrack
        public let destinationURL: URL
        /// The destination exists and is being replaced. When false the
        /// destination was free at planning time; a file found there at write
        /// time must fail that item, never be overwritten.
        public let overwrites: Bool
        public let kind: Kind
        /// The album the copy belongs to, so its deletions can wait on it.
        public let album: DeviceAlbumIdentity

        public init(source: LoadedTrack, destinationURL: URL, overwrites: Bool, kind: Kind, album: DeviceAlbumIdentity) {
            self.source = source
            self.destinationURL = destinationURL
            self.overwrites = overwrites
            self.kind = kind
            self.album = album
        }
    }

    public let copies: [Copy]
    /// Device audio files to remove once the copies have run. Only ever audio
    /// files the matcher attributed to a replaced album, inside the profile's
    /// music folder, and never a copy's destination or source.
    public let deletions: [URL]
    /// `deletions`, by the album whose Replace removes them.
    public let deletionsByAlbum: [DeviceAlbumIdentity: [URL]]
    /// Folders that get a `cover.jpg`, with the track whose art to use. Empty
    /// unless the device writes folder art.
    public let coverFolders: [URL: LoadedTrack]
    /// Tracks not written because the device has them in the same form.
    public let skippedPresent: Int
    /// Differing albums nothing was written for: Leave it, no decision, or
    /// remembered as left alone.
    public let leftAlone: Int
    public let replacedAlbums: Int
    public let keptBothAlbums: Int
    public let gapAlbums: Int
    /// Tracks that should have been written but could not be given a path.
    /// Never expected; callers count them as failed so none vanishes quietly.
    public let unplanned: [LoadedTrack]

    public init(
        copies: [Copy],
        deletionsByAlbum: [DeviceAlbumIdentity: [URL]],
        coverFolders: [URL: LoadedTrack],
        skippedPresent: Int,
        leftAlone: Int,
        replacedAlbums: Int,
        keptBothAlbums: Int,
        gapAlbums: Int,
        unplanned: [LoadedTrack] = []
    ) {
        self.copies = copies
        self.deletionsByAlbum = deletionsByAlbum
        // Album order, as the copies run.
        var seen: Set<DeviceAlbumIdentity> = []
        let order = copies.map(\.album).filter { seen.insert($0).inserted }
            + deletionsByAlbum.keys.filter { !seen.contains($0) }.sorted { ($0.artist, $0.album) < ($1.artist, $1.album) }
        self.deletions = order.flatMap { deletionsByAlbum[$0] ?? [] }
        self.coverFolders = coverFolders
        self.skippedPresent = skippedPresent
        self.leftAlone = leftAlone
        self.replacedAlbums = replacedAlbums
        self.keptBothAlbums = keptBothAlbums
        self.gapAlbums = gapAlbums
        self.unplanned = unplanned
    }

    /// The deletions to run once the copies are done, given the ones that
    /// failed: an album's old files go only when every copy written for it
    /// succeeded. A failed write leaves the old file in place, never neither.
    public func deletions(afterFailing failed: [Copy]) -> [URL] {
        let failedAlbums = Set(failed.map(\.album))
        return deletions.filter { url in
            !deletionsByAlbum.contains { album, urls in failedAlbums.contains(album) && urls.contains(url) }
        }
    }
}

/// Turns a device transfer into a file plan: `review` compares the tracks with
/// the device's catalog and checks the destinations against its files; once
/// the user has answered for the albums that differ, `resolve` decides every
/// copy and deletion.
///
/// The rules that keep a device safe:
/// - Nothing is ever written to a path another file holds unless the user
///   chose Replace for that album; New and Gaps writes that would land on one
///   turn the album into `.differs` with `.pathTaken` instead.
/// - No silent ` (2)`: only an album the user chose Keep both (or Replace onto
///   a name the batch itself already uses) is given a suffixed name.
/// - Nothing outside the profile's music folder is read from the catalog,
///   written into, versioned beside or deleted; on a volume-root music folder
///   hidden folders and `iPod_Control` are outside it too.
/// - A Replace overwrites only a file `review` saw and allowed; one that
///   appeared since gets `overwrites: false`, so the write fails, not clobbers.
/// - Deletions are only audio files of the device's copy of a replaced album,
///   inside the music folder, and never a path the plan writes or reads.
/// - Paths compare folded (case and Unicode form), as FAT and exFAT do.
public struct DeviceTransferResolver {
    /// Why `resolve` refused a review.
    public enum ResolveError: Error, Equatable, LocalizedError {
        /// The review was built from albums alone and never checked against a device.
        case notReviewedAgainstDevice
        /// The review checked another volume, music folder or transfer settings.
        case reviewedForAnotherDestination

        public var errorDescription: String? {
            switch self {
            case .notReviewedAgainstDevice:
                return "The transfer was never checked against the device. Nothing was written."
            case .reviewedForAnotherDestination:
                return "The device or its transfer settings changed after the check. Nothing was written; send again."
            }
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Review

    /// The matcher's comparison, with New and Gaps destinations checked: a
    /// planned path taken by a file nothing matched, or by another write of
    /// the same batch, sends that album to the sheet as `.pathTaken`.
    /// `reviewedAlbumFolders` are the per-album folder names the user reviewed
    /// for a template layout; they shape natural (New) paths only.
    public func review(
        sending: [LoadedTrack],
        catalog: [LoadedTrack],
        profile: ExternalDeviceProfile,
        mountedAt root: URL,
        leftAlone: Set<DeviceAlbumIdentity>,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:]
    ) -> DeviceTransferReview {
        let musicFolder = ExternalDeviceTransferPlanner(fileManager: fileManager)
            .destinationRoot(for: profile, mountedAt: root)
        // Only the music folder is the device's music: a backup folder or the
        // stock iPod's own database is never matched, so never replaced.
        let inScope = catalog.filter { Self.isMusic($0.track.fileURL, in: musicFolder, mountedAt: root) }
        var albums = DeviceTransferMatcher().compare(
            sending: sending,
            catalog: inScope,
            settings: profile.transferSettings,
            leftAlone: leftAlone
        )
        let layout = Layout(albums: albums, profile: profile, root: root,
                            reviewedAlbumFolders: reviewedAlbumFolders, fileManager: fileManager)

        // Differing albums reserve their Replace paths too, so a New album can
        // never be planned onto a path a Replace would then also write.
        var reserved: Set<String> = []
        for index in albums.indices {
            var taken = false
            for write in layout.writes(for: albums[index]) {
                let key = Self.key(write.url)
                if !reserved.insert(key).inserted {
                    taken = true
                } else if !write.mayReplace.contains(key), fileManager.fileExists(atPath: write.url.path) {
                    taken = true
                }
            }
            // Keep both writes a whole new copy; two of its tracks sharing a
            // name would need a suffix, so the row says so up front.
            if albums[index].status == .differs,
               Self.hasClash(layout.keepBothWrites(for: albums[index], isFolderTaken: { _ in false })) {
                taken = true
            }
            if taken {
                albums[index].status = .differs
                albums[index].differences.insert(.pathTaken)
            }
        }
        return DeviceTransferReview(
            albums: albums,
            mountedRoot: root,
            musicFolder: musicFolder,
            settings: profile.transferSettings,
            reviewedAlbumFolders: reviewedAlbumFolders
        )
    }

    // MARK: - Resolve

    /// The file plan for `review` under the user's answers. A differing album
    /// with no answer is left alone, as is one remembered as left alone that
    /// the user did not answer again; an answer always wins.
    ///
    /// Throws, and plans nothing, when `review` was not checked against this
    /// volume, music folder and transfer settings: its path checks would not
    /// hold for this plan.
    public func resolve(
        _ review: DeviceTransferReview,
        decisions: [DeviceAlbumIdentity: DeviceAlbumDecision],
        profile: ExternalDeviceProfile,
        mountedAt root: URL
    ) throws -> DeviceTransferFilePlan {
        guard let reviewedRoot = review.mountedRoot,
              let reviewedMusic = review.musicFolder,
              let reviewedSettings = review.settings
        else { throw ResolveError.notReviewedAgainstDevice }
        let layout = Layout(albums: review.albums, profile: profile, root: root,
                            reviewedAlbumFolders: review.reviewedAlbumFolders, fileManager: fileManager)
        guard Self.key(reviewedRoot) == Self.key(root),
              Self.key(reviewedMusic) == Self.key(layout.musicFolder),
              reviewedSettings == profile.transferSettings
        else { throw ResolveError.reviewedForAnotherDestination }

        var builder = PlanBuilder(fileManager: fileManager)
        var unplanned: [LoadedTrack] = []
        var later: [Deferred] = []
        var counts = (skippedPresent: 0, leftAlone: 0, replaced: 0, keptBoth: 0, gaps: 0)

        // Pass 1: every write with a fixed destination, in album order, the
        // same writes `review` reserved. Suffixed names wait for pass 2, so
        // they can never take a path a fixed write needs.
        for album in review.albums {
            let nature = layout.nature(of: album)
            if nature == .present {
                counts.skippedPresent += album.sent.count
                continue
            }
            guard album.status == .differs else {
                let kind: DeviceTransferFilePlan.Copy.Kind = nature == .gaps ? .gap : .new
                for write in layout.writes(for: album) {
                    // Review left this album alone, so no earlier write holds
                    // the path; a clash means review and resolve disagree.
                    guard builder.isFree(write.url) else {
                        unplanned.append(write.source)
                        continue
                    }
                    builder.add(write, kind: kind, album: album.identity, overwrites: false)
                }
                if nature == .gaps {
                    counts.gaps += 1
                    counts.skippedPresent += album.same.count
                }
                continue
            }

            switch decisions[album.identity] {
            case nil, .leave?:
                counts.leftAlone += 1
            case .replace?:
                counts.replaced += 1
                if nature != .differentRelease { counts.skippedPresent += album.same.count }
                let writes = layout.writes(for: album)
                for write in writes {
                    if builder.isFree(write.url) {
                        // Overwrite only what review saw: the file this write
                        // replaces, or a taken path the sheet named. Anything
                        // else found there now fails the write instead.
                        let exists = fileManager.fileExists(atPath: write.url.path)
                        let cleared = write.mayReplace.contains(Self.key(write.url))
                            || album.differences.contains(.pathTaken)
                        builder.add(write, kind: .replacement, album: album.identity, overwrites: exists && cleared)
                    } else {
                        // The batch writes this name already: overwriting it
                        // would lose a track being sent.
                        later.append(.suffixed(write, .replacement, album.identity))
                    }
                }
                builder.planDeletions(for: album, nature: nature, writes: writes)
            case .keepBoth?:
                counts.keptBoth += 1
                later.append(.keepBoth(album))
            }
        }

        // Pass 2: names that step past what is taken.
        for item in later {
            switch item {
            case let .suffixed(write, kind, album):
                builder.addSuffixed(write, kind: kind, album: album)
            case let .keepBoth(album):
                for write in layout.keepBothWrites(for: album, isFolderTaken: builder.holdsWrites(under:)) {
                    builder.addSuffixed(write, kind: .keptBoth, album: album.identity)
                }
            }
        }

        return DeviceTransferFilePlan(
            copies: builder.copies,
            deletionsByAlbum: builder.finalDeletions(musicFolder: layout.musicFolder),
            coverFolders: profile.transferSettings.writesFolderCoverArt ? builder.coverFolders() : [:],
            skippedPresent: counts.skippedPresent,
            leftAlone: counts.leftAlone,
            replacedAlbums: counts.replaced,
            keptBothAlbums: counts.keptBoth,
            gapAlbums: counts.gaps,
            unplanned: unplanned
        )
    }

    // MARK: - Paths

    /// Whether a catalog file is the device's music: inside the music folder,
    /// in no hidden folder, and, when the music folder is the volume itself,
    /// not in `iPod_Control` (a stock iPod's own database and music).
    static func isMusic(_ url: URL, in musicFolder: URL, mountedAt root: URL) -> Bool {
        guard isStrictlyInside(url, musicFolder) else { return false }
        let inner = url.standardizedFileURL.pathComponents
            .dropFirst(musicFolder.standardizedFileURL.pathComponents.count)
        let atVolumeRoot = key(musicFolder) == key(root)
        return !inner.contains { component in
            component.hasPrefix(".")
                || (atVolumeRoot && component.caseInsensitiveCompare("iPod_Control") == .orderedSame)
        }
    }

    /// Two writes of one set share a destination.
    private static func hasClash(_ writes: [Write]) -> Bool {
        var seen: Set<String> = []
        return writes.contains { !seen.insert(key($0.url)).inserted }
    }

    /// A path as a case-insensitive volume sees it.
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `url` lies below `folder` (never `folder` itself).
    static func isStrictlyInside(_ url: URL, _ folder: URL) -> Bool {
        let folderKey = key(folder)
        return key(url).hasPrefix(folderKey == "/" ? "/" : folderKey + "/") && key(url) != folderKey
    }

    static func isInsideOrEqual(_ url: URL, _ folder: URL) -> Bool {
        key(url) == key(folder) || isStrictlyInside(url, folder)
    }
}

// MARK: - Planning

/// One file the plan would write.
private struct Write {
    let source: LoadedTrack
    let url: URL
    /// Keys of device files this write may land on: the file it replaces.
    let mayReplace: Set<String>
    /// The device file a same-release Replace supersedes.
    let supersedes: URL?
}

private enum AlbumNature {
    case present, new, gaps, sameRelease, differentRelease
}

private enum Deferred {
    case suffixed(Write, DeviceTransferFilePlan.Copy.Kind, DeviceAlbumIdentity)
    case keepBoth(DeviceAlbumComparison)
}

/// Where each kind of write goes, for one batch on one device.
private struct Layout {
    let settings: ExternalDeviceTransferSettings
    /// The profile's music folder: every write lands inside it.
    let musicFolder: URL
    let fileManager: FileManager
    /// Natural destination of every track sent, by source path key.
    let natural: [String: URL]

    init(
        albums: [DeviceAlbumComparison],
        profile: ExternalDeviceProfile,
        root: URL,
        reviewedAlbumFolders: [AlbumFolderKey: String],
        fileManager: FileManager
    ) {
        settings = profile.transferSettings
        self.fileManager = fileManager
        let planner = ExternalDeviceTransferPlanner(fileManager: fileManager)
        musicFolder = planner.destinationRoot(for: profile, mountedAt: root)
        let sent = albums.flatMap(\.sent)
        let plans = planner.planTransfers(
            tracks: sent,
            profile: profile,
            mountedAt: root,
            reviewedAlbumFolders: reviewedAlbumFolders,
            naturalNames: true
        )
        natural = Dictionary(
            zip(sent, plans).map { (DeviceTransferResolver.key($0.track.fileURL), $1.destinationURL) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var usesAlbumFolders: Bool { settings.folderStructureMode == .metadataTemplate }

    func nature(of album: DeviceAlbumComparison) -> AlbumNature {
        if album.status == .present { return .present }
        let real = album.differences.subtracting([.pathTaken])
        if album.status == .differs, !real.isEmpty {
            return real.contains(.differentRelease) ? .differentRelease : .sameRelease
        }
        // New or Gaps, possibly turned `.differs` by a taken path only.
        return album.deviceTracks.isEmpty ? .new : .gaps
    }

    /// The writes the album's status calls for: New and Gaps as they are,
    /// a differing album as Replace would write it.
    func writes(for album: DeviceAlbumComparison) -> [Write] {
        switch nature(of: album) {
        case .present:
            return []
        case .new:
            return album.sent.compactMap { track in
                naturalURL(track).map { Write(source: track, url: $0, mayReplace: [], supersedes: nil) }
            }
        case .gaps:
            return album.missing.compactMap { track in
                let folder = usesAlbumFolders ? deviceFolder(for: track, in: album) : nil
                return place(track, in: folder).map { Write(source: track, url: $0, mayReplace: [], supersedes: nil) }
            }
        case .sameRelease:
            let swaps: [Write] = album.changed.compactMap { pair in
                let old = pair.device.track.fileURL
                let oldFolder = old.deletingLastPathComponent()
                let usable = DeviceTransferResolver.isStrictlyInside(old, musicFolder)
                return place(pair.sent, in: usable ? oldFolder : nil).map {
                    Write(source: pair.sent, url: $0,
                          mayReplace: usable ? [DeviceTransferResolver.key(old)] : [],
                          supersedes: usable ? old : nil)
                }
            }
            let additions: [Write] = album.missing.compactMap { track in
                place(track, in: deviceFolder(for: track, in: album))
                    .map { Write(source: track, url: $0, mayReplace: [], supersedes: nil) }
            }
            return swaps + additions
        case .differentRelease:
            // The whole device copy goes, so the new release may land on any of it.
            let replaceable = Set(album.deviceTracks
                .map(\.track.fileURL)
                .filter { DeviceTransferResolver.isStrictlyInside($0, musicFolder) }
                .map(DeviceTransferResolver.key))
            return album.sent.compactMap { track in
                place(track, in: deviceFolder(for: track, in: album))
                    .map { Write(source: track, url: $0, mayReplace: replaceable, supersedes: nil) }
            }
        }
    }

    /// Keep both: a version folder beside the device's copy in a template
    /// layout, else each write at its own place (suffixed later where taken).
    func keepBothWrites(for album: DeviceAlbumComparison, isFolderTaken: (URL) -> Bool) -> [Write] {
        switch nature(of: album) {
        case .new, .gaps:
            // Only a taken path made it differ: keep the foreign file, write beside it.
            return writes(for: album)
        case .present:
            return []
        case .sameRelease, .differentRelease:
            break
        }
        guard usesAlbumFolders, let folder = album.deviceFolder, canHoldVersionSibling(folder) else {
            return album.sent.compactMap { track in
                naturalURL(track).map { Write(source: track, url: $0, mayReplace: [], supersedes: nil) }
            }
        }
        let name = OutputPathPlanner.nextAvailableVersionFolderName(
            for: folder,
            fileManager: fileManager,
            isTaken: isFolderTaken
        )
        let version = folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // The new copy keeps the device copy's disc folders (`CD2/`), so two
        // discs that share file names stay apart, as they are beside it.
        return album.sent.compactMap { track in
            var target = version
            if let discFolder = deviceFolder(for: track, in: album),
               DeviceTransferResolver.isStrictlyInside(discFolder, folder) {
                for component in discFolder.standardizedFileURL.pathComponents
                    .dropFirst(folder.standardizedFileURL.pathComponents.count) {
                    target.appendPathComponent(component, isDirectory: true)
                }
            }
            return place(track, in: target).map { Write(source: track, url: $0, mayReplace: [], supersedes: nil) }
        }
    }

    // MARK: Helpers

    private func naturalURL(_ track: LoadedTrack) -> URL? {
        natural[DeviceTransferResolver.key(track.track.fileURL)]
    }

    /// The track's natural file name in `folder`, or its natural path when
    /// there is no folder to use.
    private func place(_ track: LoadedTrack, in folder: URL?) -> URL? {
        guard let naturalURL = naturalURL(track) else { return nil }
        guard let folder else { return naturalURL }
        return folder.appendingPathComponent(naturalURL.lastPathComponent)
    }

    /// Where a track goes inside the device's copy of its album: beside the
    /// device tracks of the same disc (a `CD2` subfolder when the device uses
    /// them), else the album folder itself, as a template files every disc.
    /// nil when the device copy is not inside the music folder.
    private func deviceFolder(for track: LoadedTrack, in album: DeviceAlbumComparison) -> URL? {
        guard let albumFolder = album.deviceFolder,
              DeviceTransferResolver.isInsideOrEqual(albumFolder, musicFolder)
        else { return nil }
        let disc = Self.disc(of: track)
        if let sibling = album.deviceTracks.first(where: { Self.disc(of: $0) == disc }) {
            let folder = sibling.track.fileURL.deletingLastPathComponent()
            if DeviceTransferResolver.isInsideOrEqual(folder, musicFolder) { return folder }
        }
        return albumFolder
    }

    /// A version folder goes beside the album's folder, so that folder must
    /// lie below the music folder: its sibling then stays inside it.
    private func canHoldVersionSibling(_ folder: URL) -> Bool {
        DeviceTransferResolver.isStrictlyInside(folder, musicFolder)
    }

    private static func disc(of track: LoadedTrack) -> Int {
        track.metadata.discNumber ?? track.track.discNumber ?? 1
    }
}

/// Accumulates copies and deletions, keeping destinations unique.
private struct PlanBuilder {
    let fileManager: FileManager
    private(set) var copies: [DeviceTransferFilePlan.Copy] = []
    private var reserved: Set<String> = []
    private var deletionCandidates: [(album: DeviceAlbumComparison, urls: [URL])] = []

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func isFree(_ url: URL) -> Bool {
        !reserved.contains(DeviceTransferResolver.key(url))
    }

    /// Whether a planned copy already lands in `folder` or below it.
    func holdsWrites(under folder: URL) -> Bool {
        let prefix = DeviceTransferResolver.key(folder) + "/"
        return reserved.contains { $0.hasPrefix(prefix) }
    }

    mutating func add(_ write: Write, kind: DeviceTransferFilePlan.Copy.Kind, album: DeviceAlbumIdentity, overwrites: Bool) {
        reserved.insert(DeviceTransferResolver.key(write.url))
        copies.append(.init(source: write.source, destinationURL: write.url, overwrites: overwrites, kind: kind, album: album))
    }

    /// `write`'s name, or the first ` (n)` after it that neither the plan nor
    /// the device holds.
    mutating func addSuffixed(_ write: Write, kind: DeviceTransferFilePlan.Copy.Kind, album: DeviceAlbumIdentity) {
        let folder = write.url.deletingLastPathComponent()
        let ext = write.url.pathExtension
        let base = write.url.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base) (\(attempt))"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if isFree(candidate) && !fileManager.fileExists(atPath: candidate.path) {
                add(Write(source: write.source, url: candidate, mayReplace: [], supersedes: write.supersedes),
                    kind: kind, album: album, overwrites: false)
                return
            }
            attempt += 1
        }
    }

    /// Candidates only: `finalDeletions` filters them once every copy is known.
    mutating func planDeletions(for album: DeviceAlbumComparison, nature: AlbumNature, writes: [Write]) {
        switch nature {
        case .sameRelease:
            deletionCandidates.append((album, writes.compactMap(\.supersedes)))
        case .differentRelease:
            deletionCandidates.append((album, album.deviceTracks.map(\.track.fileURL)))
        case .present, .new, .gaps:
            break   // a taken path is overwritten, never deleted
        }
    }

    /// The deletions that are safe to run: audio files of the album's device
    /// copy, inside the music folder, that no copy writes or reads.
    func finalDeletions(musicFolder: URL) -> [DeviceAlbumIdentity: [URL]] {
        let written = Set(copies.map { DeviceTransferResolver.key($0.destinationURL) })
        let read = Set(copies.map { DeviceTransferResolver.key($0.source.track.fileURL) })
        var claimed: Set<String> = []
        var result: [DeviceAlbumIdentity: [URL]] = [:]
        for (album, urls) in deletionCandidates {
            let deviceFiles = Set(album.deviceTracks.map { DeviceTransferResolver.key($0.track.fileURL) })
            let safe = urls.filter { url in
                let key = DeviceTransferResolver.key(url)
                return deviceFiles.contains(key)
                    && LibraryScanService.defaultSupportedExtensions.contains(url.pathExtension.lowercased())
                    && DeviceTransferResolver.isStrictlyInside(url, musicFolder)
                    && !written.contains(key)
                    && !read.contains(key)
                    && claimed.insert(key).inserted
            }
            if !safe.isEmpty { result[album.identity, default: []] += safe }
        }
        return result
    }

    /// Each folder a copy lands in, with the first track written there.
    func coverFolders() -> [URL: LoadedTrack] {
        var result: [URL: LoadedTrack] = [:]
        for copy in copies {
            let folder = copy.destinationURL.deletingLastPathComponent().standardizedFileURL
            if result[folder] == nil { result[folder] = copy.source }
        }
        return result
    }
}
