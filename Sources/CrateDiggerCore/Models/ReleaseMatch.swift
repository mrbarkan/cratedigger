import Foundation

/// Where a release candidate came from. Every source is free and needs no user
/// account; the badge is shown in the review sheet so the user can judge a
/// proposal by its origin.
///
/// `acoustID` is the odd one out: the release data itself still comes from
/// MusicBrainz, but the badge says how the release was *found*, and "we
/// listened to it" is a very different claim from "we searched your tags".
public enum ReleaseSource: String, Codable, Sendable, CaseIterable {
    case musicBrainz = "MusicBrainz"
    case iTunes = "iTunes"
    case acoustID = "AcoustID"

    public var label: String { rawValue }

    /// True when the candidate was identified from the audio rather than the
    /// tags, which is what makes its score trustworthy on an untagged file.
    public var isAudioMatch: Bool { self == .acoustID }
}

/// One track of the selection, reduced to what a lookup can actually use.
public struct QueryTrack: Equatable, Sendable {
    public var title: String?
    public var trackNumber: Int?
    public var durationSeconds: Double?

    public init(title: String? = nil, trackNumber: Int? = nil, durationSeconds: Double? = nil) {
        self.title = title
        self.trackNumber = trackNumber
        self.durationSeconds = durationSeconds
    }
}

/// What we know about the selection, used to search. Built by
/// `MetadataMatchService.query(for:)` from tags, falling back to file/folder
/// names so an untagged rip can still be matched.
public struct ReleaseQuery: Equatable, Sendable {
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var tracks: [QueryTrack]

    public init(artist: String? = nil, album: String? = nil, year: Int? = nil, tracks: [QueryTrack] = []) {
        self.artist = artist
        self.album = album
        self.year = year
        self.tracks = tracks
    }

    /// Nothing to search with — the caller should say so rather than firing a
    /// request that can only return noise.
    public var isEmpty: Bool {
        (artist?.isEmpty ?? true)
            && (album?.isEmpty ?? true)
            && tracks.allSatisfy { $0.title?.isEmpty ?? true }
    }
}

/// One track on a candidate release.
public struct ReleaseTrack: Equatable, Sendable {
    public var position: Int
    public var discNumber: Int
    public var title: String
    public var artist: String?
    public var durationSeconds: Double?
    /// MusicBrainz recording MBID, when the source reports one. DEEP SCAN pairs
    /// files to slots by this: a fingerprint names the recording outright, so
    /// an untagged file lands on the right track instead of being guessed into
    /// position.
    public var recordingID: String?

    public init(
        position: Int,
        discNumber: Int = 1,
        title: String,
        artist: String? = nil,
        durationSeconds: Double? = nil,
        recordingID: String? = nil
    ) {
        self.position = position
        self.discNumber = discNumber
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.recordingID = recordingID
    }
}

/// A release a provider offered as a possible match for the selection.
public struct ReleaseCandidate: Identifiable, Equatable, Sendable {
    public var source: ReleaseSource
    public var providerID: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var totalTracks: Int?
    public var totalDiscs: Int?
    public var tracks: [ReleaseTrack]
    public var artworkURL: URL?

    public var id: String { "\(source.rawValue):\(providerID)" }

    public init(
        source: ReleaseSource,
        providerID: String,
        title: String,
        artist: String,
        year: Int? = nil,
        genre: String? = nil,
        totalTracks: Int? = nil,
        totalDiscs: Int? = nil,
        tracks: [ReleaseTrack] = [],
        artworkURL: URL? = nil
    ) {
        self.source = source
        self.providerID = providerID
        self.title = title
        self.artist = artist
        self.year = year
        self.genre = genre
        self.totalTracks = totalTracks
        self.totalDiscs = totalDiscs
        self.tracks = tracks
        self.artworkURL = artworkURL
    }
}

/// What one selected track would become if this release is accepted.
public struct TrackTagProposal: Identifiable, Equatable, Sendable {
    public let trackID: UUID
    /// The track's current display title, for the sheet's row label.
    public let trackTitle: String
    public let current: ConversionMetadata
    public let proposed: ConversionMetadata
    /// Fields where `proposed` actually differs from `current` — the only ones
    /// worth showing or writing.
    public let changedFields: [MetadataRepairField]

    public var id: UUID { trackID }

    public init(
        trackID: UUID,
        trackTitle: String,
        current: ConversionMetadata,
        proposed: ConversionMetadata,
        changedFields: [MetadataRepairField]
    ) {
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.current = current
        self.proposed = proposed
        self.changedFields = changedFields
    }
}

/// A scored release plus the per-track changes accepting it would make.
public struct ReleaseMatch: Identifiable, Equatable, Sendable {
    public let candidate: ReleaseCandidate
    /// 0…1. Above `MetadataMatchService.minimumScore` to be offered at all.
    public let score: Double
    public let trackProposals: [TrackTagProposal]

    public var id: String { candidate.id }

    /// Fields this release would change on at least one track — the rows the
    /// review sheet shows.
    public var changedFields: [MetadataRepairField] {
        let changed = Set(trackProposals.flatMap { $0.changedFields })
        return MetadataRepairField.allCases.filter { changed.contains($0) }
    }

    public var hasChanges: Bool { !changedFields.isEmpty }

    public init(candidate: ReleaseCandidate, score: Double, trackProposals: [TrackTagProposal]) {
        self.candidate = candidate
        self.score = score
        self.trackProposals = trackProposals
    }
}
