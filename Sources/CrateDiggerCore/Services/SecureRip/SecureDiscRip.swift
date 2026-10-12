import Foundation

/// A whole disc's secure extraction: each planned track through
/// `SecureRipEngine`, one after another, into WAVs in a working folder. The
/// rip then converts those instead of cddafs's `.aiff` files.
public enum SecureDiscRip {
    public struct Progress: Sendable, Equatable {
        /// 1-based position of the track being read within this rip.
        public var trackOrdinal: Int
        public var trackCount: Int
        public var track: SecureRipEngine.Progress
        /// Sector re-reads across the disc so far.
        public var discRereads: Int

        public init(trackOrdinal: Int, trackCount: Int, track: SecureRipEngine.Progress, discRereads: Int) {
            self.trackOrdinal = trackOrdinal
            self.trackCount = trackCount
            self.track = track
            self.discRereads = discRereads
        }
    }

    public struct Output: Sendable, Equatable {
        public let plan: SecureRipTrackPlan
        public let wavURL: URL
        public let result: SecureRipTrackResult
    }

    /// Read every track in `plans`, in order. Stops at the first error,
    /// leaving whatever was written in `directory` for the caller to remove
    /// with the folder.
    public static func run(
        plans: [SecureRipTrackPlan],
        audioArea: Range<Int>,
        engine: SecureRipEngine,
        into directory: URL,
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) throws -> [Output] {
        if let first = plans.first?.sectors.lowerBound, let last = plans.last?.sectors.upperBound, first < last {
            try probe(engine.reader, sectors: first ..< last)
        }
        var outputs: [Output] = []
        var earlierRereads = 0
        for (offset, plan) in plans.enumerated() {
            let url = directory.appendingPathComponent(String(format: "track-%02d.wav", plan.trackNumber))
            let result = try engine.ripTrack(
                number: plan.trackNumber, sectors: plan.sectors, audioArea: audioArea, to: url,
                isCancelled: isCancelled,
                progress: { track in
                    progress(Progress(trackOrdinal: offset + 1, trackCount: plans.count, track: track,
                                      discRereads: earlierRereads + track.rereads))
                }
            )
            earlierRereads += result.rereads
            outputs.append(Output(plan: plan, wavURL: url, result: result))
        }
        return outputs
    }

    /// Before anything is read for real: can this drive read the disc raw, and
    /// can it report C2 errors while doing it? Without the first nothing can
    /// be ripped; without the second nothing can be verified, and every C2
    /// read would fail as if the sector were unreadable, sending the rip into
    /// hours of retries that could only end in silence.
    ///
    /// One sector each at the start, middle and end of `sectors`. A scratch
    /// can make one of them fail, so only all of them failing condemns the
    /// drive; any error other than a media error condemns it at once.
    public static func probe(_ reader: CDSectorReading, sectors: Range<Int>) throws {
        let spots = Array(Set([sectors.lowerBound, sectors.lowerBound + sectors.count / 2, sectors.upperBound - 1])).sorted()

        var readable: [Int] = []
        var lastMediaError: CDSectorReadError?
        for lba in spots {
            do {
                _ = try reader.readSectors(at: lba, count: 1, c2: false)
                readable.append(lba)
            } catch let error as CDSectorReadError where error.isMediaError {
                lastMediaError = error
            }
        }
        if readable.isEmpty, let lastMediaError { throw lastMediaError }

        for lba in readable {
            do {
                let read = try reader.readSectors(at: lba, count: 1, c2: true)
                if read.audio.count == CDSector.audioBytes, read.c2?.count == CDSector.c2Bytes { return }
            } catch let error as CDSectorReadError {
                // The plain read of this sector just worked, so a refusal here
                // is the C2 request itself, whatever errno the drive picked
                // for it. Only the drive vanishing outright is reported as that.
                if case .readFailed(_, _, let code) = error, [ENXIO, ENODEV, EBADF].contains(code) {
                    throw error
                }
            }
        }
        throw CDSectorReadError.noC2Support
    }

    /// What to tell someone whose Secure Mode rip couldn't start or stopped.
    /// Every message says how to get the disc ripped anyway, since the switch
    /// promised verification and a silent fallback would break that promise.
    public static func failureMessage(for error: Error) -> String {
        let turnOff = "Turn Secure Mode off to rip normally."
        switch error {
        case CDSectorReadError.deviceUnavailable(_, let code):
            return "Secure Mode couldn't open the drive to read the disc directly (errno \(code): \(describe(code))). \(turnOff)"
        case CDSectorReadError.readFailed(_, _, let code):
            return "Secure Mode couldn't read the disc directly (errno \(code): \(describe(code))). If the disc was ejected, insert it again. Otherwise, turn Secure Mode off to rip normally."
        case CDSectorReadError.shortRead, CDSectorReadError.noC2Support:
            return "This drive can't report read errors (C2), which Secure Mode needs to check every sector. Nothing was ripped. \(turnOff)"
        case CDSectorReadError.tooManyUnreadable(let track, let sectors):
            let seconds = max(1, sectors / CDSector.perSecond)
            return "Secure Mode stopped on track \(track): the drive couldn't read \(seconds) second\(seconds == 1 ? "" : "s") of it. The disc may be damaged or was ejected, or the drive stopped responding. Nothing was ripped. Clean the disc and try again, or turn Secure Mode off to rip normally."
        case let error as SecureRipTrackPlan.PlanError:
            return error.localizedDescription
        default:
            return "Secure Mode couldn't write its working copy of the disc (\(error.localizedDescription)). Free some space on the startup disk, or turn Secure Mode off to rip normally."
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Cancellation that a reading thread can poll and the main thread can set.
public final class SecureRipCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
