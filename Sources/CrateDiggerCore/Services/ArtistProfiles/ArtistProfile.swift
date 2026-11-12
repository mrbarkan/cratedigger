import Foundation

/// What is known about an artist, as one set of fields. A profile keeps two
/// of these, the looked-up one and the owner's, and shows them merged
/// (`ArtistProfile.facts`). Every field is optional: nil means "nothing
/// here", and in the owner's set it means "not set by the owner".
public struct ArtistFacts: Codable, Hashable, Sendable {
    /// "Person", "Group", "Orchestra", "Choir", or another MusicBrainz artist type.
    public var kind: String?
    /// "Bristol, England".
    public var origin: String?
    /// Life-span years, "1991". A nil `end` reads as "to now".
    public var begin: String?, end: String?
    public var bio: String?
    /// The Wikipedia article a fetched bio came from, for its credit. Set
    /// only for fetched Wikipedia text; an owner's bio never carries one.
    public var bioSourceURL: URL?
    public var members: [ArtistMember]?
    public var genres: [String]?
    public var links: [ArtistLink]?

    public init(kind: String? = nil, origin: String? = nil, begin: String? = nil, end: String? = nil,
                bio: String? = nil, bioSourceURL: URL? = nil, members: [ArtistMember]? = nil,
                genres: [String]? = nil, links: [ArtistLink]? = nil) {
        self.kind = kind
        self.origin = origin
        self.begin = begin
        self.end = end
        self.bio = bio
        self.bioSourceURL = bioSourceURL
        self.members = members
        self.genres = genres
        self.links = links
    }

    /// Lenient: a field of the wrong type reads as absent, and one bad
    /// member or link does not lose the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(String.self, .kind)
        origin = c.lenient(String.self, .origin)
        begin = c.lenient(String.self, .begin)
        end = c.lenient(String.self, .end)
        bio = c.lenient(String.self, .bio)
        bioSourceURL = c.lenient(URL.self, .bioSourceURL)
        members = c.lossyArray(ArtistMember.self, .members)
        genres = c.lossyArray(String.self, .genres)
        links = c.lossyArray(ArtistLink.self, .links)
    }
}

extension ArtistFacts {
    /// These facts, with each field that is nil here taken from `other`.
    func filling(from other: ArtistFacts) -> ArtistFacts {
        ArtistFacts(kind: kind ?? other.kind, origin: origin ?? other.origin, begin: begin ?? other.begin,
                    end: end ?? other.end, bio: bio ?? other.bio, bioSourceURL: bioSourceURL ?? other.bioSourceURL,
                    members: members ?? other.members, genres: genres ?? other.genres, links: links ?? other.links)
    }
}

/// One member of a group, from MusicBrainz's member-of-band relations.
public struct ArtistMember: Codable, Hashable, Sendable {
    public var name: String
    public var begin: String?
    public var end: String?
    public var isCurrent: Bool

    public init(name: String, begin: String? = nil, end: String? = nil, isCurrent: Bool) {
        self.name = name
        self.begin = begin
        self.end = end
        self.isCurrent = isCurrent
    }
}

public struct ArtistLink: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case musicBrainz, wikipedia, other }
    public var kind: Kind
    public var url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

/// One photo of an artist: a reference to bytes in the `ArtistPhotos`
/// folder (`<hash>.jpg` or `.png`), never the bytes themselves.
public struct ArtistPhoto: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case owner, library, deezer, commons, migrated }

    /// SHA-256 of the stored bytes, lowercase hex: the file's name.
    public var hash: String
    public var source: Source
    /// The source's own id (a Deezer artist id, a MusicBrainz id for a
    /// Commons picture). A migrated photo keeps `<old source>:<old id>`.
    public var sourceID: String?
    public var credit: ArtistPictureCredit?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var added: Date
    /// A migrated 400 px photo awaiting its original, which the background
    /// worker fetches from here to replace it at full size.
    public var replaceFromURL: URL?

    public init(hash: String, source: Source, sourceID: String? = nil, credit: ArtistPictureCredit? = nil,
                pixelWidth: Int, pixelHeight: Int, added: Date, replaceFromURL: URL? = nil) {
        self.hash = hash
        self.source = source
        self.sourceID = sourceID
        self.credit = credit
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.added = added
        self.replaceFromURL = replaceFromURL
    }

    /// What `rejectedPhotoSources` remembers when the owner removes this
    /// photo: `<source>:<sourceID>`, so a lookup never adds it back. nil for
    /// the owner's own photos and for a photo with no source id. A migrated
    /// photo's id is already `<old source>:<old id>`, which is what a later
    /// lookup of that source would produce.
    public var rejectionKey: String? {
        guard source != .owner, let sourceID, !sourceID.isEmpty else { return nil }
        return source == .migrated ? sourceID : "\(source.rawValue):\(sourceID)"
    }
}

/// A MusicBrainz artist the lookup could not tell apart from others of the
/// same name, kept so the artist page can ask "Is this them?".
public struct ArtistIdentityCandidate: Codable, Hashable, Sendable {
    public var musicBrainzID: String
    public var name: String
    public var disambiguation: String?
    public var origin: String?
    public var releaseTitles: [String]

    public init(musicBrainzID: String, name: String, disambiguation: String? = nil, origin: String? = nil,
                releaseTitles: [String] = []) {
        self.musicBrainzID = musicBrainzID
        self.name = name
        self.disambiguation = disambiguation
        self.origin = origin
        self.releaseTitles = releaseTitles
    }
}

/// Everything CrateDigger knows about one artist, for the artist page and
/// for a PodBox iPod. Keyed by `PodBoxArtName.folded` of the name, the key
/// the artist picture records use, so the app and the iPod share one record.
///
/// Looked-up facts and the owner's are kept apart (`fetched`, `owner`); a
/// lookup only ever writes `fetched`, `identity` and `checkedAt`. Everything
/// else here is the owner's, or follows from what the owner did.
public struct ArtistProfile: Codable, Hashable, Sendable {
    /// Who the lookup thinks this artist is on MusicBrainz.
    public enum Identity: Hashable, Sendable {
        /// Never looked up.
        case unknown
        case confirmed(musicBrainzID: String, wikidataID: String?)
        /// More than one artist could be this one; the page asks.
        case uncertain([ArtistIdentityCandidate])
        case notFound
        /// The owner said "None of these": no lookups until Look Up Again.
        case rejected
    }

    public var foldedKey: String
    public var displayName: String
    public var identity: Identity
    /// MusicBrainz ids the owner said are not this artist ("Not This Artist").
    public var rejectedMusicBrainzIDs: [String]
    public var fetched: ArtistFacts?
    public var owner: ArtistFacts?
    /// In the order they were added. The default is chosen separately.
    public var photos: [ArtistPhoto]
    /// Photos the lookup found but did not download: references only.
    public var photoCandidates: [ArtistPictureRecord.HeldCandidate]
    /// `ArtistPhoto.rejectionKey`s of photos the owner removed.
    public var rejectedPhotoSources: [String]
    /// The hash of the default photo, one of `photos`.
    public var defaultPhoto: String?
    /// The owner chose the default; no lookup changes it.
    public var defaultPickedByOwner: Bool
    /// The owner wants no photo: the app shows the placeholder and the iPod gets nothing.
    public var noPhoto: Bool
    /// The app still shows the photo, but the iPod gets nothing.
    public var notOnIPod: Bool
    /// When the lookup last ran for this artist; nil when it never has.
    public var checkedAt: Date?
    /// When a picture search for the iPod (the Artist Pictures sheet's Find
    /// Missing, or one inside a transfer) last found nothing. Kept apart from
    /// `checkedAt`, the background lookup's cursor, so a search never makes
    /// the lookup think it ran.
    public var photoSearchedAt: Date?

    public init(foldedKey: String, displayName: String, identity: Identity = .unknown,
                rejectedMusicBrainzIDs: [String] = [], fetched: ArtistFacts? = nil, owner: ArtistFacts? = nil,
                photos: [ArtistPhoto] = [], photoCandidates: [ArtistPictureRecord.HeldCandidate] = [],
                rejectedPhotoSources: [String] = [], defaultPhoto: String? = nil, defaultPickedByOwner: Bool = false,
                noPhoto: Bool = false, notOnIPod: Bool = false, checkedAt: Date? = nil,
                photoSearchedAt: Date? = nil) {
        self.foldedKey = foldedKey
        self.displayName = displayName
        self.identity = identity
        self.rejectedMusicBrainzIDs = rejectedMusicBrainzIDs
        self.fetched = fetched
        self.owner = owner
        self.photos = photos
        self.photoCandidates = photoCandidates
        self.rejectedPhotoSources = rejectedPhotoSources
        self.defaultPhoto = defaultPhoto
        self.defaultPickedByOwner = defaultPickedByOwner
        self.noPhoto = noPhoto
        self.notOnIPod = notOnIPod
        self.checkedAt = checkedAt
        self.photoSearchedAt = photoSearchedAt
    }

    /// What the page shows: the owner's value over the fetched one, field by
    /// field. An owner's empty string means the owner cleared that field, so
    /// it shows nothing; an owner's empty list likewise. The Wikipedia credit
    /// goes with the fetched bio only: any owner bio, even a cleared one,
    /// drops it.
    public var facts: ArtistFacts {
        let owner = owner ?? ArtistFacts(), fetched = fetched ?? ArtistFacts()
        func text(_ path: KeyPath<ArtistFacts, String?>) -> String? {
            guard let mine = owner[keyPath: path] else { return fetched[keyPath: path] }
            return mine.isEmpty ? nil : mine
        }
        return ArtistFacts(
            kind: text(\.kind), origin: text(\.origin), begin: text(\.begin), end: text(\.end),
            bio: text(\.bio), bioSourceURL: owner.bio == nil ? fetched.bioSourceURL : nil,
            members: owner.members ?? fetched.members, genres: owner.genres ?? fetched.genres,
            links: owner.links ?? fetched.links)
    }

    /// The photo to show and send to the iPod; nil when the owner asked for
    /// no photo or there is no default.
    public var defaultPhotoRef: ArtistPhoto? {
        guard !noPhoto, let defaultPhoto else { return nil }
        return photos.first { $0.hash == defaultPhoto }
    }

    /// Lenient, so a file written by a newer version or edited by hand still
    /// loads: only the name is required; any other field that is missing or
    /// will not decode takes its default, and one bad photo, candidate or
    /// link does not lose the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        foldedKey = c.lenient(String.self, .foldedKey) ?? ""
        identity = c.lenient(Identity.self, .identity) ?? .unknown
        rejectedMusicBrainzIDs = c.lossyArray(String.self, .rejectedMusicBrainzIDs) ?? []
        fetched = c.lenient(ArtistFacts.self, .fetched)
        owner = c.lenient(ArtistFacts.self, .owner)
        photos = c.lossyArray(ArtistPhoto.self, .photos) ?? []
        photoCandidates = c.lossyArray(ArtistPictureRecord.HeldCandidate.self, .photoCandidates) ?? []
        rejectedPhotoSources = c.lossyArray(String.self, .rejectedPhotoSources) ?? []
        defaultPhoto = c.lenient(String.self, .defaultPhoto)
        defaultPickedByOwner = c.lenient(Bool.self, .defaultPickedByOwner) ?? false
        noPhoto = c.lenient(Bool.self, .noPhoto) ?? false
        notOnIPod = c.lenient(Bool.self, .notOnIPod) ?? false
        checkedAt = c.lenient(Date.self, .checkedAt)
        photoSearchedAt = c.lenient(Date.self, .photoSearchedAt)
    }
}

/// Stored as `{"state": "confirmed", "musicBrainzID": ..., "wikidataID": ...}`
/// or `{"state": "uncertain", "candidates": [...]}`, so the file reads plainly.
/// A state this version does not know reads as `.unknown` (looked up again).
extension ArtistProfile.Identity: Codable {
    private enum CodingKeys: String, CodingKey { case state, musicBrainzID, wikidataID, candidates }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.lenient(String.self, .state) {
        case "confirmed":
            guard let id = c.lenient(String.self, .musicBrainzID), !id.isEmpty else {
                DecodingLosses.note(in: decoder)
                self = .unknown
                return
            }
            self = .confirmed(musicBrainzID: id, wikidataID: c.lenient(String.self, .wikidataID))
        case "uncertain":
            self = .uncertain(c.lossyArray(ArtistIdentityCandidate.self, .candidates) ?? [])
        case "notFound": self = .notFound
        case "rejected": self = .rejected
        case "unknown": self = .unknown
        default:
            DecodingLosses.note(in: decoder)
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try c.encode("unknown", forKey: .state)
        case let .confirmed(musicBrainzID, wikidataID):
            try c.encode("confirmed", forKey: .state)
            try c.encode(musicBrainzID, forKey: .musicBrainzID)
            try c.encodeIfPresent(wikidataID, forKey: .wikidataID)
        case .uncertain(let candidates):
            try c.encode("uncertain", forKey: .state)
            try c.encode(candidates, forKey: .candidates)
        case .notFound:
            try c.encode("notFound", forKey: .state)
        case .rejected:
            try c.encode("rejected", forKey: .state)
        }
    }
}

// MARK: - Lenient decoding

/// Counts what a lenient decode had to leave out, so the store knows to
/// keep a copy of the file it read before writing over it.
final class DecodingLosses: @unchecked Sendable {
    var count = 0

    static func note(in decoder: Decoder) {
        (decoder.userInfo[.decodingLosses] as? DecodingLosses)?.count += 1
    }
}

extension CodingUserInfoKey {
    static let decodingLosses = CodingUserInfoKey(rawValue: "CrateDigger.decodingLosses")!
}

/// Decodes as nil instead of throwing, so one bad element of an array is
/// skipped while the container still moves on to the next.
struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            value = nil
            DecodingLosses.note(in: decoder)
        }
    }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it is missing or will not decode.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// The elements that decode; nil when the key is missing or not an array.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        lenient([LossyElement<T>].self, key)?.compactMap(\.value)
    }
}
