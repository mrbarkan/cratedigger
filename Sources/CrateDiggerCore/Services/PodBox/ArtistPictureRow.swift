import Foundation

/// What the owner has changed in the Artist Pictures sheet and not yet
/// applied, by folded key. Apply writes it into the artist's profile
/// (`ArtistPictureRow.apply`), the same record the artist page shows.
public enum ArtistPictureEdit: Hashable, Sendable {
    /// A picture the owner chose: an offered candidate, or a file of their
    /// own. `prepared` is the 400 px JPEG the iPod would get, for the sheet's
    /// thumbnail; `original` is what becomes the artist's default photo.
    case picked(prepared: Data, original: Data, source: ArtistPictureSourceID, candidate: ArtistPictureCandidate?)
    /// "Don't Send to iPod": the profile's `notOnIPod`, which hides nothing
    /// in the app and which no lookup changes.
    case noPicture
    /// Takes back "Don't Send to iPod" and drops the held candidates and the
    /// last "nothing found", so Find may look again. The artist's photos stay.
    case clear
}

/// One artist in the Artist Pictures sheet: what the player shows or would
/// get for them, and where that picture came from.
public struct ArtistPictureRow: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        /// The player already shows a picture (the owner's, or one CrateDigger wrote).
        case onDevice
        /// A picture is waiting in the store to be written.
        case ready
        /// Name matches were found but none is sure: the owner picks.
        case check
        /// Nothing known yet.
        case none
        /// The owner kept the artist off the iPod, or wants no photo at all.
        case rejected
        /// The player cannot match any file name to this name.
        case unnameable
    }

    /// The folded key (`PodBoxArtName.folded`); the name itself when it folds to nothing.
    public let id: String
    public let name: String, trackCount: Int
    public let state: State
    /// "DEVICE", "DISK", "DEEZER", "COMMONS", "PICKED", "READY", "CHECK",
    /// "NONE", "NOT ON IPOD" (the owner's "Don't Send to iPod") or "NO
    /// PICTURE" (the owner's "No Photo", which hides it in the app too).
    public let badge: String
    /// The device-relative file the player shows, for `.onDevice` (nil when
    /// the simulation cannot say which).
    public let devicePath: String?
    /// The candidates to pick from, for `.check`.
    public let candidates: [ArtistPictureCandidate]
    /// Who made the picture and under what licence, when its source says (Commons).
    public let credit: ArtistPictureCredit?
    /// For `.none`: when a lookup last found nothing, while that answer is
    /// still trusted (30 days). Find skips the row until then, unless the
    /// owner asks to look again.
    public let notFoundAt: Date?
    /// For `.ready` from the profile: the default photo's hash, whose bytes
    /// the sheet shows.
    public let photoHash: String?

    public init(id: String, name: String, trackCount: Int, state: State, badge: String, devicePath: String? = nil,
                candidates: [ArtistPictureCandidate] = [], credit: ArtistPictureCredit? = nil,
                notFoundAt: Date? = nil, photoHash: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.state = state
        self.badge = badge
        self.devicePath = devicePath
        self.candidates = candidates
        self.credit = credit
        self.notFoundAt = notFoundAt
        self.photoHash = photoHash
    }

    /// Most tracks first, then by name. `uncertain` holds the candidates a
    /// Find Missing run offered this session, by folded key, which win over
    /// the candidates held in the profile from an earlier one; `edits` are
    /// the sheet's unapplied changes, which win over the profiles. Reads the
    /// profile store and checks files: off the main actor.
    public static func rows(artists: [ArtistOnDevice], tree: DeviceArtTree, profiles store: ArtistProfileStore,
                            uncertain: [String: [ArtistPictureCandidate]],
                            edits: [String: ArtistPictureEdit] = [:], now: Date = Date()) -> [ArtistPictureRow] {
        let profiles = ArtistPictureProfiles(store: store)
        return artists
            .sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }
            .map { row(for: $0, tree: tree, profiles: profiles, store: store, uncertain: uncertain, edits: edits,
                       now: now) }
    }

    /// The rows Find Missing looks up: every row to check, and every row
    /// without a picture except one with a fresh "not found" (the same
    /// 30-day rule `ArtistPictureSession.namesToFind` keeps), unless its id is
    /// in `lookAgain`, the rows the owner asked to look again.
    public static func findTargets(_ rows: [ArtistPictureRow], lookAgain: Set<String> = []) -> [ArtistPictureRow] {
        rows.filter { row in
            switch row.state {
            case .check: return true
            case .none: return row.notFoundAt == nil || lookAgain.contains(row.id)
            case .onDevice, .ready, .rejected, .unnameable: return false
            }
        }
    }

    /// Apply has something to write: at least one picture ready.
    public static func canApply(_ rows: [ArtistPictureRow]) -> Bool {
        rows.contains { $0.state == .ready }
    }

    /// Writes one of the sheet's edits into the profile for `name`, as the
    /// owner's word. A picked picture becomes one of the artist's photos
    /// (the owner's file kept as given, a candidate stored as a fetched photo
    /// under its own source, id and credit) and the owner's default, and the
    /// artist goes back to the iPod (`notOnIPod` and `noPhoto` off: picking
    /// a picture says the owner wants one). "Don't Send to iPod" sets
    /// `notOnIPod`; Clear is `ArtistPictureEdit.clear`. Throws as `addPhoto`
    /// does. Does not save; store I/O and image work, so off the main actor.
    public static func apply(_ edit: ArtistPictureEdit, name: String, to profiles: ArtistProfileStore) throws {
        switch edit {
        case let .picked(_, original, source, candidate):
            let photo: ArtistPhoto
            if let candidate, ArtistLookupRun.photoSource(candidate.source) != nil {
                photo = try profiles.addCandidatePhoto(name: name, candidate: ArtistPictureRecord.HeldCandidate(candidate),
                                                       data: original)
            } else {
                let photoSource = source == .userFile ? ArtistPhoto.Source.owner
                    : ArtistLookupRun.photoSource(source) ?? .owner
                photo = try profiles.addPhoto(name: name, data: original, source: photoSource,
                                              sourceID: candidate?.sourceID, credit: candidate?.credit)
            }
            profiles.update(name: name) { profile in
                profile.notOnIPod = false
                profile.noPhoto = false
            }
            profiles.setDefault(name: name, hash: photo.hash)
        case .noPicture:
            profiles.update(name: name) { $0.notOnIPod = true }
        case .clear:
            profiles.update(name: name) { profile in
                profile.notOnIPod = false
                profile.photoCandidates = []
                profile.photoSearchedAt = nil
            }
        }
    }

    /// The badge for a stored or picked picture's source.
    static func badge(for source: ArtistPictureSourceID?, picked: Bool) -> String {
        if picked { return "PICKED" }
        switch source {
        case .libraryFolder?: return "DISK"
        case .deezer?: return "DEEZER"
        case .commons?: return "COMMONS"
        case .userFile?: return "PICKED"
        case .fanartTV?, .discogs?, .theAudioDB?, nil: return "READY"
        }
    }

    /// The badge for a profile's photo: the owner's own or the owner's pick
    /// is PICKED; a migrated one reads its old source from its id.
    static func badge(for photo: ArtistPhoto, pickedByOwner: Bool) -> String {
        if pickedByOwner { return "PICKED" }
        var source = photo.source
        if source == .migrated, let prefix = photo.sourceID?.split(separator: ":", maxSplits: 1).first,
           let named = ArtistPhoto.Source(rawValue: String(prefix)) {
            source = named
        }
        switch source {
        case .owner: return "PICKED"
        case .library: return "DISK"
        case .deezer: return "DEEZER"
        case .commons: return "COMMONS"
        case .migrated: return "READY"
        }
    }

    // MARK: - Private

    private static func row(for artist: ArtistOnDevice, tree: DeviceArtTree, profiles: ArtistPictureProfiles,
                            store: ArtistProfileStore, uncertain: [String: [ArtistPictureCandidate]],
                            edits: [String: ArtistPictureEdit], now: Date) -> ArtistPictureRow {
        let key = artist.foldedKey.isEmpty ? artist.name : artist.foldedKey
        func make(_ state: State, _ badge: String, path: String? = nil, candidates: [ArtistPictureCandidate] = [],
                  credit: ArtistPictureCredit? = nil, notFoundAt: Date? = nil, photoHash: String? = nil)
            -> ArtistPictureRow {
            ArtistPictureRow(id: key, name: artist.name, trackCount: artist.trackCount, state: state, badge: badge,
                             devicePath: path, candidates: candidates, credit: credit, notFoundAt: notFoundAt,
                             photoHash: photoHash)
        }

        guard PodBoxArtName.fileStem(for: artist.name) != nil else { return make(.unnameable, "NONE") }

        // What the player shows now outranks anything waiting: nothing would replace it.
        switch PodBoxArtLookup.artistPicture(for: artist.name, albumFolders: artist.albumFolders, tree: tree) {
        case .found(let path): return make(.onDevice, "DEVICE", path: path)
        case .uncertain: return make(.onDevice, "DEVICE")
        case .none: break
        }

        let edit = edits[key]
        switch edit {
        case let .picked(_, _, source, candidate)?:
            return make(.ready, badge(for: source, picked: true), credit: candidate?.credit)
        case .noPicture?:
            return make(.rejected, "NOT ON IPOD")
        case .clear?, nil:
            break
        }
        var profile = profiles.profile(forName: artist.name)
        if edit == .clear {
            profile?.notOnIPod = false
            profile?.photoCandidates = []
            profile?.photoSearchedAt = nil
        }
        if let profile {
            if profile.noPhoto { return make(.rejected, "NO PICTURE") }
            if profile.notOnIPod { return make(.rejected, "NOT ON IPOD") }
            if let photo = ArtistPictureProfiles.iPodPhoto(of: profile), store.hasPhotoFile(hash: photo.hash) {
                return make(.ready, badge(for: photo, pickedByOwner: profile.defaultPickedByOwner), credit: photo.credit,
                            photoHash: photo.hash)
            }
        }
        if let offered = uncertain[key], !offered.isEmpty {
            return make(.check, "CHECK", candidates: offered)
        }
        if let held = profile?.photoCandidates, !held.isEmpty {
            return make(.check, "CHECK", candidates: held.prefix(ArtistPictureFinder.maximumUncertain)
                .map { $0.candidate(named: artist.name) })
        }
        if let date = ArtistPictureProfiles.freshNotFound(profile, now: now) {
            return make(.none, "NONE", notFoundAt: date)
        }
        return make(.none, "NONE")
    }
}
