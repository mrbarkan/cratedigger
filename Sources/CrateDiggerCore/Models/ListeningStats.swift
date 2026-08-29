import Foundation

/// What CrateDigger knows about your relationship with a track, as opposed to
/// what it knows about the file.
///
/// Kept apart from `AudioTrack` and `ConversionMetadata` on purpose: those
/// describe the recording and are rebuilt whenever a file is rescanned,
/// retagged or relinked. This is the part that would be irreplaceable if a
/// rebuild dropped it. See `ListeningStore`.
///
/// WARNING: This struct is persisted to disk as the irreplaceable half of the
/// listening history. Any new field must either be Optional or provide a decoder
/// default, because a missing field during decode would fail the entire history
/// load. There is no migration mechanism here.
public struct ListeningStats: Codable, Sendable, Equatable {
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayed: Date?
    /// When this track entered *this library*, which is not the file's creation
    /// date: a 2003 rip added last Tuesday should sort as last Tuesday.
    public var dateAdded: Date
    /// 0 means unrated, which is a different thing from rated zero. 1...5
    /// otherwise. An Int rather than an Int? because ratings get compared and
    /// sorted constantly and an optional would put a `??` at every one of
    /// those sites. Clamped on write so no UI has to defend against a 7.
    public var rating: Int {
        didSet { rating = min(max(rating, 0), 5) }
    }

    public init(
        playCount: Int = 0,
        skipCount: Int = 0,
        lastPlayed: Date? = nil,
        dateAdded: Date,
        rating: Int = 0
    ) {
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.rating = min(max(rating, 0), 5)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.playCount = try container.decode(Int.self, forKey: .playCount)
        self.skipCount = try container.decode(Int.self, forKey: .skipCount)
        self.lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        self.dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let decodedRating = try container.decode(Int.self, forKey: .rating)
        self.rating = min(max(decodedRating, 0), 5)
    }

    enum CodingKeys: String, CodingKey {
        case playCount
        case skipCount
        case lastPlayed
        case dateAdded
        case rating
    }

    /// Whether the user has expressed an opinion, as distinct from a low one.
    public var isRated: Bool { rating > 0 }

    public mutating func recordPlay(at date: Date) {
        playCount += 1
        lastPlayed = date
    }

    /// A skip leaves `lastPlayed` alone: you did not listen to it, so it should
    /// not surface in "recently played".
    public mutating func recordSkip() {
        skipCount += 1
    }
}
