import Foundation

/// What CrateDigger knows about your relationship with a track, as opposed to
/// what it knows about the file.
///
/// Kept apart from `AudioTrack` and `ConversionMetadata` on purpose: those
/// describe the recording and are rebuilt whenever a file is rescanned,
/// retagged or relinked. This is the part that would be irreplaceable if a
/// rebuild dropped it. See `ListeningStore`.
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
