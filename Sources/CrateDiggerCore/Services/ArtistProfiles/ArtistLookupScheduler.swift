import Foundation

/// Which artists the background worker looks up next, and in what order
/// (spec §4, Scheduling and Refresh). Pure: the profiles are read through a
/// closure and the clock is passed in, so the order is testable.
///
/// Due: an artist never looked up; a confirmed one checked more than 180
/// days ago; a "not found" one checked more than 30 days ago. Never an
/// uncertain one (the page is asking the owner) or a rejected one (the
/// owner said "None of these"): only Look Up Again, which resets the
/// identity first, looks those up again. An `.unknown` identity is always
/// due, whatever its date: it is either new, or reset by Look Up Again or
/// by a confirmed id MusicBrainz no longer has.
///
/// Order: the `priority` names first, in the order given (the artist the
/// owner clicked, the one now playing), due whatever their age; then the
/// rest, most tracks first. "Once per launch" for a priority name is the
/// app's to keep: it drops the name from `priority` once it was looked up.
public struct ArtistLookupScheduler: Sendable {
    public static let confirmedRefresh: TimeInterval = 180 * 86_400
    public static let notFoundRetry: TimeInterval = ArtistPictureRecord.notFoundLifetime   // 30 days

    /// Folded names that stand for nobody in particular: a compilation's
    /// bucket, a missing tag, and MusicBrainz's own `[unknown]`.
    static let placeholderKeys: Set<String> = [
        "variousartists", "various", "va", "unknownartist", "unknown", "unknownalbumartist",
    ]

    public init() {}

    /// Artists due for a lookup, most tracks first, with `priority` names first.
    /// Two spellings that fold to one key are one artist, the tracks of both
    /// counted: the name returned is the spelling with the most tracks (the
    /// earlier one in `artists` on a tie). A priority name is returned as
    /// given.
    public func due(artists: [(name: String, trackCount: Int)], profiles: (String) -> ArtistProfile?,
                    priority: [String], now: Date) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in priority where Self.isLookedUp(name) {
            let key = PodBoxArtName.folded(name)
            guard seen.insert(key).inserted, Self.mayLookUp(profiles(name)) else { continue }
            result.append(name)
        }

        var tracksByKey: [String: (name: String, count: Int)] = [:]
        for artist in artists where Self.isLookedUp(artist.name) {
            let key = PodBoxArtName.folded(artist.name)
            if let earlier = tracksByKey[key] {
                let name = artist.trackCount > earlier.count ? artist.name : earlier.name
                tracksByKey[key] = (name, earlier.count + artist.trackCount)
            } else {
                tracksByKey[key] = (artist.name, artist.trackCount)
            }
        }
        let ordered = tracksByKey.filter { !seen.contains($0.key) }.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
        for artist in ordered where Self.isDue(profiles(artist.name), now: now) {
            result.append(artist.name)
        }
        return result
    }

    /// False for Various Artists, Unknown Artist, an empty name and a name
    /// that folds to nothing: they get library stats, never a lookup.
    public static func isLookedUp(_ name: String) -> Bool {
        let key = PodBoxArtName.folded(name)
        return !key.isEmpty && !placeholderKeys.contains(key)
    }

    /// Whether the record's age calls for a lookup.
    static func isDue(_ profile: ArtistProfile?, now: Date) -> Bool {
        guard let profile else { return true }
        func olderThan(_ age: TimeInterval) -> Bool {
            guard let checked = profile.checkedAt else { return true }
            return now.timeIntervalSince(checked) > age
        }
        switch profile.identity {
        case .unknown: return true
        case .confirmed: return olderThan(confirmedRefresh)
        case .notFound: return olderThan(notFoundRetry)
        case .uncertain, .rejected: return false
        }
    }

    /// Whether any automatic lookup may run at all: a priority skips the
    /// wait, never the owner's open question or their "None of these".
    static func mayLookUp(_ profile: ArtistProfile?) -> Bool {
        switch profile?.identity {
        case .uncertain?, .rejected?: return false
        default: return true
        }
    }

    // MARK: - Failures

    /// The first pause after a failed lookup, and the longest.
    public static let firstBackoff: Duration = .seconds(30), longestBackoff: Duration = .seconds(1_800)

    /// The worker's pause before its next lookup after `failures` failed
    /// ones in a row: none after a success (the count goes back to zero),
    /// then 30 s, doubling each time, never more than 30 minutes.
    public static func backoff(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return .zero }
        // 30 s × 2^6 is past the cap already, so the shift never overflows.
        let pause = firstBackoff * (1 << min(failures - 1, 6))
        return min(pause, longestBackoff)
    }

    /// What a failed lookup means for the worker; nil for cancellation (the
    /// worker stopping, not a failure). Every failure also counts toward
    /// `backoff`.
    public static func failure(_ error: Error) -> ArtistLookupFailure? {
        if error is CancellationError { return nil }
        if let store = error as? ArtistProfileStoreError {
            switch store {
            case .unreadableStore, .unreachableIndexFolder: return .stopWorker
            case .unnamedArtist, .unreadablePhoto, .photoTooLarge: return .skipArtist
            }
        }
        if let lookup = error as? ArtistLookupError {
            return lookup == .timedOut ? .retryLater : .skipArtist
        }
        if let source = ArtistPictureSourceError.reading(error), source == .quota || source.stopsTheRun {
            return .retryLater
        }
        return .skipArtist
    }
}

/// What the background worker does after a lookup failed (spec §4,
/// Failures). Nothing is stored for the artist in any case.
public enum ArtistLookupFailure: Equatable, Sendable {
    /// The network or a service is not answering (offline, a timeout, a 5xx,
    /// a rate limit): the same artist is asked again after the pause.
    case retryLater
    /// This artist's answer could not be used (a broken reply, a picture
    /// that would not keep): the artist is not asked again this session,
    /// so one bad record never holds the worker in a loop.
    case skipArtist
    /// The profile store cannot be written (its file unreadable, its folder
    /// gone): the worker stops until the store is made again.
    case stopWorker
}

/// Why the background worker is not running now (spec §4, Scheduling).
/// Any one of them pauses it; it resumes where it stopped, since the
/// store's `checkedAt` is the cursor.
public struct ArtistLookupPauses: Equatable, Sendable {
    /// Settings ▸ Integrations ▸ "Look up artist info and photos" is off.
    public var disabled: Bool
    public var scanning: Bool
    /// A conversion or a device transfer is running.
    public var transferring: Bool
    public var hidden: Bool
    public var lowPower: Bool
    public var offline: Bool
    public var libraryDisconnected: Bool

    public init(disabled: Bool = false, scanning: Bool = false, transferring: Bool = false, hidden: Bool = false,
                lowPower: Bool = false, offline: Bool = false, libraryDisconnected: Bool = false) {
        self.disabled = disabled
        self.scanning = scanning
        self.transferring = transferring
        self.hidden = hidden
        self.lowPower = lowPower
        self.offline = offline
        self.libraryDisconnected = libraryDisconnected
    }

    public var isPaused: Bool {
        disabled || scanning || transferring || hidden || lowPower || offline || libraryDisconnected
    }
}

/// The library as the background worker reads it: each artist (the album
/// artist, else the artist, as the inspector names a track's artist) with
/// how many tracks they have, their album titles for the identity match,
/// and the owner's own picture of them beside the music. Built once per
/// pass off the main actor from every track the library holds, whichever
/// crate is being browsed.
public struct ArtistLookupLibrary: Sendable {
    /// Every spelling with its track count, in no particular order: the
    /// scheduler folds spellings together and orders them.
    public let artists: [(name: String, trackCount: Int)]
    private let titlesByKey: [String: [String]]
    private let folders: ArtistPictureSession.LibraryFolders

    public init(tracks: [LoadedTrack]) {
        var counts: [String: Int] = [:]
        var titles: [String: Set<String>] = [:]
        for track in tracks {
            let name = Self.artistName(of: track)
            counts[name, default: 0] += 1
            let album = (track.metadata.album ?? track.track.album).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = PodBoxArtName.folded(name)
            if !album.isEmpty, !key.isEmpty { titles[key, default: []].insert(album) }
        }
        artists = counts.map { (name: $0.key, trackCount: $0.value) }
        titlesByKey = titles.mapValues { $0.sorted() }
        folders = ArtistPictureSession.LibraryFolders(tracks: tracks)
    }

    /// The album titles of every spelling that folds like `name`.
    public func albumTitles(for name: String) -> [String] {
        titlesByKey[PodBoxArtName.folded(name)] ?? []
    }

    /// The owner's own picture of `name` in the library's folders, if any.
    /// Looks at files: off the main actor.
    public func picture(for name: String) -> URL? {
        folders.picture(for: name)
    }

    /// The artist a track belongs to, as the library groups it: the album
    /// artist, else the artist.
    public static func artistName(of loaded: LoadedTrack) -> String {
        let albumArtist = loaded.metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !albumArtist.isEmpty { return albumArtist }
        return loaded.metadata.artist ?? loaded.track.artist
    }
}
