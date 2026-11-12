import Foundation

/// How an album being sent stands against what the device already holds.
public enum DeviceAlbumStatus: String, Sendable {
    /// The device has nothing of this album. Sent without asking.
    case new
    /// Every track sent is already there in the same form. Skipped without asking.
    case present
    /// Nothing differs, some tracks are missing. Filled in without asking.
    case gaps
    /// A track is there in another form, or it is another release. Asked about.
    case differs
}

/// Why an album reads as `.differs`. One album can have several.
public enum DeviceAlbumDifference: String, Hashable, Sendable {
    /// Copy-mode devices only: format, bitrate (lossy only) or sample rate.
    case audioForm
    /// The art that would land is a different pixel size from the device's.
    case artSize
    /// A track at the same disc/track slot has another title, or the
    /// track totals disagree.
    case differentRelease
    /// A planned destination is taken by a file that matched nothing. Never
    /// set by the matcher: the resolver finds it once destinations are planned.
    case pathTaken
}

/// One album of a transfer, compared with the device's copy of it.
public struct DeviceAlbumComparison: Identifiable, Sendable {
    public var id: DeviceAlbumIdentity { identity }
    public let identity: DeviceAlbumIdentity
    public let displayArtist: String
    public let displayAlbum: String
    public var status: DeviceAlbumStatus
    /// Empty unless `status` is `.differs`; says what made it differ.
    public var differences: Set<DeviceAlbumDifference>
    /// Every track sent for this album, de-duplicated by path, in sending order.
    public let sent: [LoadedTrack]
    /// Sent tracks with no counterpart on the device.
    public let missing: [LoadedTrack]
    /// Sent tracks whose counterpart is there in the same form.
    public let same: [LoadedTrack]
    /// Sent tracks whose counterpart is there in another form (audio or art).
    public let changed: [(sent: LoadedTrack, device: LoadedTrack)]
    /// Every track of the compared device copy, matched or not.
    public let deviceTracks: [LoadedTrack]
    /// Folder of the compared device copy (a disc subfolder resolves to the
    /// album folder above it). nil when the device has none.
    public let deviceFolder: URL?
    /// How many device folders hold this album.
    public let deviceCopyCount: Int
    /// Longest side of the art that would land on the device.
    public let sentArtPixels: Int?
    /// Longest side of the compared copy's art.
    public let deviceArtPixels: Int?
    /// The user chose Leave it for this album on this device before. The status
    /// is still computed; callers decide what to do with it.
    public let isLeftAlone: Bool

    public init(
        identity: DeviceAlbumIdentity,
        displayArtist: String,
        displayAlbum: String,
        status: DeviceAlbumStatus,
        differences: Set<DeviceAlbumDifference>,
        sent: [LoadedTrack],
        missing: [LoadedTrack],
        same: [LoadedTrack],
        changed: [(sent: LoadedTrack, device: LoadedTrack)],
        deviceTracks: [LoadedTrack],
        deviceFolder: URL?,
        deviceCopyCount: Int,
        sentArtPixels: Int?,
        deviceArtPixels: Int?,
        isLeftAlone: Bool
    ) {
        self.identity = identity
        self.displayArtist = displayArtist
        self.displayAlbum = displayAlbum
        self.status = status
        self.differences = differences
        self.sent = sent
        self.missing = missing
        self.same = same
        self.changed = changed
        self.deviceTracks = deviceTracks
        self.deviceFolder = deviceFolder
        self.deviceCopyCount = deviceCopyCount
        self.sentArtPixels = sentArtPixels
        self.deviceArtPixels = deviceArtPixels
        self.isLeftAlone = isLeftAlone
    }
}

/// Classifies each album of a device transfer against the device's catalog:
/// new, already present, gaps to fill, or differing (the user decides).
///
/// Tracks are matched by what they are, never by file name, so a format
/// upgrade (MP3 to FLAC changes the extension) is recognised as one. Within an
/// album identity a track's slot is (disc, or 1, track number); when either
/// side has no number, the folded title stands in. Art is compared by pixel
/// size, never by hash, because a conversion re-encodes the art.
public struct DeviceTransferMatcher {
    private let planner = OutputPathPlanner()

    public init() {}

    /// One comparison per album, in order of first appearance in `sending`.
    public func compare(
        sending: [LoadedTrack],
        catalog: [LoadedTrack],
        settings: ExternalDeviceTransferSettings,
        leftAlone: Set<DeviceAlbumIdentity>
    ) -> [DeviceAlbumComparison] {
        let sent = Self.uniqueByPath(sending)
        let sentIdentities = DeviceAlbumIdentity.identities(for: sent)
        let sentKeys = planner.albumFolderKeys(for: sent)

        var order: [DeviceAlbumIdentity] = []
        var sentByAlbum: [DeviceAlbumIdentity: [LoadedTrack]] = [:]
        for track in sent {
            guard let identity = sentIdentities[track.track.id] else { continue }
            if sentByAlbum[identity] == nil { order.append(identity) }
            sentByAlbum[identity, default: []].append(track)
        }

        let copies = deviceCopies(of: catalog)

        return order.map { identity in
            let tracks = sentByAlbum[identity] ?? []
            return compareAlbum(
                identity: identity,
                sent: tracks,
                key: tracks.first.flatMap { sentKeys[$0.track.id] },
                copies: copies[identity] ?? [],
                settings: settings,
                isLeftAlone: leftAlone.contains(identity)
            )
        }
    }

    // MARK: - Albums

    /// The device's albums by identity, each split into its folders (one folder
    /// per copy, e.g. `Kind of Blue` and `Kind of Blue (2)` after a Keep both).
    private func deviceCopies(of catalog: [LoadedTrack]) -> [DeviceAlbumIdentity: [DeviceCopy]] {
        let unique = Self.uniqueByPath(catalog)
        let identities = DeviceAlbumIdentity.identities(for: unique)
        var copies: [DeviceAlbumIdentity: [DeviceCopy]] = [:]
        for track in unique {
            guard let identity = identities[track.track.id] else { continue }
            let folder = planner.albumSourceFolder(for: track)
            var list = copies[identity, default: []]
            if let index = list.firstIndex(where: { $0.folder == folder }) {
                list[index].tracks.append(track)
            } else {
                list.append(DeviceCopy(folder: folder, tracks: [track]))
            }
            copies[identity] = list
        }
        return copies
    }

    private func compareAlbum(
        identity: DeviceAlbumIdentity,
        sent: [LoadedTrack],
        key: AlbumFolderKey?,
        copies: [DeviceCopy],
        settings: ExternalDeviceTransferSettings,
        isLeftAlone: Bool
    ) -> DeviceAlbumComparison {
        let sentArt = sentArtPixels(sent, settings: settings)
        let candidates = copies.map { classify(sent: sent, against: $0, sentArt: sentArt, settings: settings) }
        let best = candidates.min(by: Self.isPreferred)

        return DeviceAlbumComparison(
            identity: identity,
            displayArtist: Self.displayArtist(sent.first, key: key),
            displayAlbum: Self.displayAlbum(sent.first, key: key),
            status: best?.status ?? .new,
            differences: best?.differences ?? [],
            sent: sent,
            missing: best?.missing ?? sent,
            same: best?.same ?? [],
            changed: best?.changed ?? [],
            deviceTracks: best?.copy.tracks ?? [],
            deviceFolder: best.flatMap { $0.copy.folder.isEmpty ? nil : URL(fileURLWithPath: $0.copy.folder, isDirectory: true) },
            deviceCopyCount: copies.count,
            sentArtPixels: sentArt,
            deviceArtPixels: best?.deviceArt,
            isLeftAlone: isLeftAlone
        )
    }

    /// A copy that makes the album Present wins; otherwise the one sharing the
    /// most tracks. A tie goes to the shorter folder path, which is the one the
    /// planner names first (`Kind of Blue` before `Kind of Blue (2)`).
    private static func isPreferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsPresent = lhs.status == .present, rhsPresent = rhs.status == .present
        if lhsPresent != rhsPresent { return lhsPresent }
        if lhs.matchedCount != rhs.matchedCount { return lhs.matchedCount > rhs.matchedCount }
        if lhs.copy.folder.count != rhs.copy.folder.count { return lhs.copy.folder.count < rhs.copy.folder.count }
        return lhs.copy.folder < rhs.copy.folder
    }

    // MARK: - One copy

    private func classify(
        sent: [LoadedTrack],
        against copy: DeviceCopy,
        sentArt: Int?,
        settings: ExternalDeviceTransferSettings
    ) -> Candidate {
        let deviceArt = Self.deviceArtPixels(copy.tracks)
        let artDiffers: Bool = {
            guard let sentArt else { return false }
            return deviceArt != sentArt
        }()
        let comparesAudio = settings.mode == .copyOriginals

        let pairs = Self.pair(sent, with: copy.tracks)
        var missing: [LoadedTrack] = []
        var same: [LoadedTrack] = []
        var changed: [(sent: LoadedTrack, device: LoadedTrack)] = []
        var differences: Set<DeviceAlbumDifference> = []

        for (offset, track) in sent.enumerated() {
            guard let pair = pairs[offset] else {
                missing.append(track)
                continue
            }
            let device = copy.tracks[pair.index]

            if pair.bySlot, Self.isDifferentRelease(track, device) {
                differences.insert(.differentRelease)
            }
            let audioDiffers = comparesAudio && AudioForm(track) != AudioForm(device)
            if audioDiffers { differences.insert(.audioForm) }
            if artDiffers { differences.insert(.artSize) }

            if audioDiffers || artDiffers {
                changed.append((sent: track, device: device))
            } else {
                same.append(track)
            }
        }

        if Self.trackTotalsDisagree(sent: sent, device: copy.tracks) {
            differences.insert(.differentRelease)
        }

        let status: DeviceAlbumStatus
        if !differences.isEmpty {
            status = .differs
        } else if missing.isEmpty {
            status = .present
        } else {
            status = .gaps
        }
        return Candidate(
            copy: copy, status: status, differences: differences,
            missing: missing, same: same, changed: changed, deviceArt: deviceArt
        )
    }

    /// Each sent track's device counterpart (index into `deviceTracks`), one
    /// to one. Every slot match (disc, track number) is made first; only then
    /// does a track left over fall back to its folded title, and only against
    /// a device track where either side has no number. Two passes, so an
    /// unnumbered track earlier in the list can never take the device track a
    /// later numbered one needs. `bySlot` marks the slot matches, the only kind
    /// that can reveal a different release.
    private static func pair(
        _ sent: [LoadedTrack],
        with deviceTracks: [LoadedTrack]
    ) -> [(index: Int, bySlot: Bool)?] {
        var pairs: [(index: Int, bySlot: Bool)?] = Array(repeating: nil, count: sent.count)
        var claimed = Array(repeating: false, count: deviceTracks.count)
        let deviceSlots = deviceTracks.map(Slot.init)

        for (offset, track) in sent.enumerated() {
            let slot = Slot(track)
            guard slot.number != nil,
                  let index = deviceSlots.indices.first(where: { !claimed[$0] && deviceSlots[$0] == slot })
            else { continue }
            claimed[index] = true
            pairs[offset] = (index, true)
        }

        for (offset, track) in sent.enumerated() where pairs[offset] == nil {
            let numbered = Slot(track).number != nil
            let title = foldedTitle(track)
            guard let index = deviceTracks.indices.first(where: {
                !claimed[$0]
                    && (!numbered || deviceSlots[$0].number == nil)
                    && foldedTitle(deviceTracks[$0]) == title
            }) else { continue }
            claimed[index] = true
            pairs[offset] = (index, false)
        }
        return pairs
    }

    // MARK: - Different release

    private static func isDifferentRelease(_ sent: LoadedTrack, _ device: LoadedTrack) -> Bool {
        if foldedTitle(sent) != foldedTitle(device) { return true }
        if let lhs = trackTotal(sent), let rhs = trackTotal(device), lhs != rhs { return true }
        return false
    }

    /// Per disc, the track totals both sides carry share no value: catches a
    /// different release even when no track pairs up (device has 1 and 3 of
    /// an 11-track release, the 5-track one sends 2 and 4). One side without
    /// totals is never a difference.
    private static func trackTotalsDisagree(sent: [LoadedTrack], device: [LoadedTrack]) -> Bool {
        func totalsByDisc(_ tracks: [LoadedTrack]) -> [Int: Set<Int>] {
            var result: [Int: Set<Int>] = [:]
            for track in tracks {
                guard let total = trackTotal(track) else { continue }
                result[Slot(track).disc, default: []].insert(total)
            }
            return result
        }
        let deviceTotals = totalsByDisc(device)
        return totalsByDisc(sent).contains { disc, totals in
            guard let other = deviceTotals[disc] else { return false }
            return totals.isDisjoint(with: other)
        }
    }

    // MARK: - Art

    /// The longest side of the art the device would show for this album once
    /// the transfer wrote it: `DeviceWrittenArt` under the settings' art mode
    /// (copy mode: the files' own art) and folder-art switch.
    private func sentArtPixels(_ sent: [LoadedTrack], settings: ExternalDeviceTransferSettings) -> Int? {
        DeviceWrittenArt.readBack(
            of: sent,
            artworkMode: settings.mode == .copyOriginals ? nil : settings.artworkMode,
            cap: settings.artworkMaxDimension,
            deviceProfile: settings.deviceProfile,
            writesFolderCoverArt: settings.writesFolderCoverArt
        )?.side
    }

    /// The device copy's art: embedded, or a folder image beside it (a Rockbox
    /// `cover.jpg`). Remote art cached by the scan is not on the device.
    private static func deviceArtPixels(_ tracks: [LoadedTrack]) -> Int? {
        DeviceWrittenArt.longestSide(of: tracks, from: [.embedded, .folderImage])
    }

    // MARK: - Display

    /// The track's own artist spelling ("AC/DC") unless the album was reunited
    /// under another bucket (a compilation's Various Artists).
    private static func displayArtist(_ track: LoadedTrack?, key: AlbumFolderKey?) -> String {
        let bucket = key?.artistBucket ?? ""
        guard let track,
              let raw = nonEmpty(track.metadata.albumArtist) ?? nonEmpty(track.metadata.artist) ?? nonEmpty(track.track.artist)
        else { return bucket }
        return PathComponentSanitizer.sanitize(raw, fallback: "") == bucket ? raw : bucket
    }

    private static func displayAlbum(_ track: LoadedTrack?, key: AlbumFolderKey?) -> String {
        let raw = track.flatMap { nonEmpty($0.metadata.album) ?? nonEmpty($0.track.album) } ?? key?.album ?? ""
        return OutputPathPlanner.strippingDiscSuffix(raw)
    }

    // MARK: - Helpers

    /// Drops later entries at a path already seen: a crate listing one file
    /// twice must not send it twice.
    private static func uniqueByPath(_ tracks: [LoadedTrack]) -> [LoadedTrack] {
        var seen: Set<String> = []
        return tracks.filter { seen.insert($0.track.fileURL.standardizedFileURL.path).inserted }
    }

    private static func foldedTitle(_ track: LoadedTrack) -> String {
        DeviceAlbumIdentity.fold(nonEmpty(track.metadata.title) ?? track.track.title)
    }

    private static func trackTotal(_ track: LoadedTrack) -> Int? {
        track.metadata.trackTotal ?? track.track.trackTotal
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Private types

private struct DeviceCopy {
    let folder: String
    var tracks: [LoadedTrack]
}

private struct Candidate {
    let copy: DeviceCopy
    let status: DeviceAlbumStatus
    let differences: Set<DeviceAlbumDifference>
    let missing: [LoadedTrack]
    let same: [LoadedTrack]
    let changed: [(sent: LoadedTrack, device: LoadedTrack)]
    let deviceArt: Int?

    var matchedCount: Int { same.count + changed.count }
}

/// Where a track sits in its album: (disc, or 1, track number).
private struct Slot: Equatable {
    let disc: Int
    let number: Int?

    init(_ track: LoadedTrack) {
        disc = track.metadata.discNumber ?? track.track.discNumber ?? 1
        number = track.metadata.trackNumber ?? track.track.trackNumber
    }
}

/// What "the same form" means on a copy-mode device. Lossless files ignore
/// bitrate, which only reflects how well the audio compressed.
private struct AudioForm: Equatable {
    let format: String
    let bitrateKbps: Int?
    let sampleRateHz: Int?

    init(_ track: LoadedTrack) {
        let format = (track.track.formatName ?? "").lowercased()
        self.format = format
        let lossless = VersionLabel.isLossless(format) || format.hasPrefix("pcm")
        bitrateKbps = lossless ? nil : track.track.bitrateKbps
        sampleRateHz = track.track.sampleRateHz
    }
}
