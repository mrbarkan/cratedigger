import Foundation

/// How one track's secure extraction went.
public struct SecureRipTrackResult: Sendable, Equatable {
    public let trackNumber: Int
    public let sectorCount: Int
    /// Sectors that needed re-reading: the two passes disagreed, or C2 flagged
    /// them (or the drive couldn't read them) in either pass.
    public let retriedSectors: Int
    /// Individual sector reads spent on retries, across every attempt.
    public let rereads: Int
    /// Sectors whose C2 pointers were set in pass 1 or pass 2.
    public let c2Sectors: Int
    /// Track-relative sector indexes that never read the same twice without
    /// C2 errors. The output holds the most frequent value for each.
    public let suspiciousSectors: [Int]
    public let timing: Timing
    /// The retry budget, in seconds, when it ran out on this track with
    /// sectors still doubtful (they are among `suspiciousSectors`). Nil when
    /// retrying finished on its own.
    public let retryBudgetExhausted: TimeInterval?

    public struct Timing: Sendable, Equatable {
        public var pass1: TimeInterval
        public var pass2: TimeInterval
        public var retry: TimeInterval
        public var total: TimeInterval { pass1 + pass2 + retry }

        public init(pass1: TimeInterval = 0, pass2: TimeInterval = 0, retry: TimeInterval = 0) {
            self.pass1 = pass1
            self.pass2 = pass2
            self.retry = retry
        }
    }

    public init(trackNumber: Int, sectorCount: Int, retriedSectors: Int, rereads: Int,
                c2Sectors: Int, suspiciousSectors: [Int], timing: Timing,
                retryBudgetExhausted: TimeInterval? = nil) {
        self.trackNumber = trackNumber
        self.sectorCount = sectorCount
        self.retriedSectors = retriedSectors
        self.rereads = rereads
        self.c2Sectors = c2Sectors
        self.suspiciousSectors = suspiciousSectors
        self.timing = timing
        self.retryBudgetExhausted = retryBudgetExhausted
    }

    /// Every sector was read identically twice with no C2 errors.
    public var verified: Bool { suspiciousSectors.isEmpty }

    /// The suspicious sectors as runs, so one long scratch reads as one range.
    public var suspiciousRanges: [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for sector in suspiciousSectors.sorted() {
            if let last = ranges.last, last.upperBound + 1 == sector {
                ranges[ranges.count - 1] = last.lowerBound...sector
            } else {
                ranges.append(sector...sector)
            }
        }
        return ranges
    }
}

/// A position on a CD, in the disc's own units.
public enum CDTimecode {
    /// `mm:ss.ff`, ff being the sector (1/75 s) within the second: the form a
    /// CD player and cue sheet use.
    public static func format(sector: Int) -> String {
        let sector = max(0, sector)
        let frames = sector % CDSector.perSecond
        let seconds = sector / CDSector.perSecond
        return String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, frames)
    }

    /// `mm:ss`, for copy where the frame is noise.
    public static func formatMinutesSeconds(sector: Int) -> String {
        let seconds = max(0, sector) / CDSector.perSecond
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// One track's place on the disc, for the raw reader.
public struct SecureRipTrackPlan: Sendable, Equatable {
    public let trackNumber: Int
    /// The cddafs `.aiff` this track is mounted as. The rip's jobs and tags are
    /// keyed by it, so the verified WAV can take its place in the job.
    public let sourceURL: URL
    /// Logical blocks, as `CDSectorReading` addresses them.
    public let sectors: Range<Int>

    public init(trackNumber: Int, sourceURL: URL, sectors: Range<Int>) {
        self.trackNumber = trackNumber
        self.sourceURL = sourceURL
        self.sectors = sectors
    }

    public enum PlanError: Error, Equatable, LocalizedError {
        case noTableOfContents
        case trackCountMismatch(files: Int, toc: Int)

        public var errorDescription: String? {
            switch self {
            case .noTableOfContents:
                return "This disc has no table of contents, so Secure Mode can't find its tracks. Turn Secure Mode off to rip normally."
            case .trackCountMismatch(let files, let toc):
                return "The disc shows \(files) tracks but its table of contents lists \(toc), so Secure Mode can't tell which sectors are which track. Turn Secure Mode off to rip normally."
            }
        }
    }

    /// Pair each mounted track with its sectors. By position, not by the
    /// number in the file name: the TOC drops data tracks, and a mixed-mode
    /// disc whose data comes first numbers its audio from 2.
    public static func plans(for tracks: [CDTrack], toc: CompactDiscTOC?) throws -> [SecureRipTrackPlan] {
        guard let toc else { throw PlanError.noTableOfContents }
        let ranges = toc.trackLBARanges
        let ordered = tracks.sorted { $0.trackNumber < $1.trackNumber }
        guard ordered.count == ranges.count else {
            throw PlanError.trackCountMismatch(files: ordered.count, toc: ranges.count)
        }
        return zip(ordered, ranges).map { track, range in
            SecureRipTrackPlan(trackNumber: track.trackNumber, sourceURL: track.fileURL, sectors: range)
        }
    }
}

extension CompactDiscTOC {
    /// The 2-second lead-in every TOC offset includes. Logical block 0 is the
    /// first sector after it.
    public static let leadInSectors = 150

    /// Each audio track's logical blocks. A track runs to the next one's
    /// start, so a pregap belongs to the track before it, which is also how
    /// cddafs cuts its `.aiff` files.
    public var trackLBARanges: [Range<Int>] {
        zip(trackOffsets, trackLengthsInSectors).map { offset, length in
            let start = offset - Self.leadInSectors
            return start ..< start + length
        }
    }

    /// Every logical block of audio on the disc. Cache-defeating reads stay
    /// inside it: past the leadout there's nothing a drive will read as audio.
    public var audioLBARange: Range<Int> {
        let start = (trackOffsets.first ?? Self.leadInSectors) - Self.leadInSectors
        return max(0, start) ..< max(0, leadoutBlock - Self.leadInSectors)
    }
}

/// The words the rip's completion alert says about Secure Mode.
public enum SecureRipReport {
    public static func summary(_ results: [SecureRipTrackResult]) -> String {
        let unverified = results.filter { !$0.verified }.sorted { $0.trackNumber < $1.trackNumber }
        guard !unverified.isEmpty else {
            let subject = results.count == 1 ? "The track was" : "All \(results.count) tracks"
            return "\(subject) verified: every sector read identically."
        }
        let lines = unverified.map { result -> String in
            let where_ = positions(result.suspiciousRanges)
            if let budget = result.retryBudgetExhausted {
                let minutes = max(1, Int((budget / 60).rounded()))
                return "Track \(result.trackNumber): retrying stopped after \(minutes) minute\(minutes == 1 ? "" : "s"), so it couldn't verify \(where_)."
            }
            return "Track \(result.trackNumber): couldn't verify \(where_)."
        }
        let verifiedCount = results.count - unverified.count
        var text = lines.joined(separator: "\n")
        if verifiedCount > 0 {
            text = "\(verifiedCount) of \(results.count) tracks verified.\n" + text
        }
        let advice = unverified.count == 1
            ? "Clean the disc and re-rip that track."
            : "Clean the disc and re-rip those tracks."
        return text + "\n" + advice
    }

    /// "01:02, 02:10 to 02:14". Runs that land in the same second collapse,
    /// since mm:ss can't tell them apart anyway.
    static func positions(_ ranges: [ClosedRange<Int>]) -> String {
        var labels: [String] = []
        for range in ranges {
            let start = CDTimecode.formatMinutesSeconds(sector: range.lowerBound)
            let end = CDTimecode.formatMinutesSeconds(sector: range.upperBound)
            let label = start == end ? start : "\(start) to \(end)"
            if labels.last != label { labels.append(label) }
        }
        // A disc that is mostly scratch would list hundreds; the first few say
        // enough to find it.
        let limit = 6
        guard labels.count > limit else { return labels.joined(separator: ", ") }
        return labels.prefix(limit).joined(separator: ", ") + " and \(labels.count - limit) more"
    }
}
