import Foundation

/// The shape of a CD-DA sector, and of the C2 error pointers a drive can
/// return beside it.
public enum CDSector {
    /// One sector of Red Book audio: 588 stereo frames of 16-bit PCM,
    /// little-endian, which is already what a WAV file holds.
    public static let audioBytes = 2352
    /// One bit per audio byte: set when the drive's C2 error correction could
    /// not vouch for that byte.
    public static let c2Bytes = 294
    /// 75 sectors make one second of audio (a CD "frame" in mm:ss.ff).
    public static let perSecond = 75
}

/// What one read of `count` consecutive sectors returned.
public struct CDSectorRead: Sendable, Equatable {
    /// `count × CDSector.audioBytes` bytes of PCM.
    public var audio: Data
    /// `count × CDSector.c2Bytes` bytes of C2 flags, or nil when the read
    /// didn't ask for them.
    public var c2: Data?

    public init(audio: Data, c2: Data?) {
        self.audio = audio
        self.c2 = c2
    }
}

public enum CDSectorReadError: Error, Equatable, LocalizedError {
    /// The raw device node couldn't be opened, or the volume isn't a disc.
    case deviceUnavailable(path: String, errno: Int32)
    /// The drive refused a read.
    case readFailed(lba: Int, count: Int, errno: Int32)
    /// The drive answered with less than was asked for, or without the C2
    /// pointers it was asked for. Padding it would shift every later sector.
    case shortRead(expectedSectors: Int)
    /// The drive reads audio but refuses, or fails, every read that asks for
    /// C2 error pointers too. Secure Mode can't verify without them.
    case noC2Support
    /// Pass 1 couldn't read so much of a track (a long unbroken stretch, or
    /// too large a share of it) that the disc is damaged past re-reading, was
    /// ejected, or the drive stopped answering. Ripping on would write silence.
    case tooManyUnreadable(track: Int, sectors: Int)

    /// A read error the disc itself caused (a scratch the drive gave up on),
    /// which secure extraction answers by re-reading. Anything else (the disc
    /// ejected, a refused ioctl) means reading can't go on at all.
    public var isMediaError: Bool {
        if case .readFailed(_, _, let code) = self { return code == EIO }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let path, let code):
            return "Couldn't open \(path) (errno \(code): \(String(cString: strerror(code))))."
        case .readFailed(let lba, let count, let code):
            return "The drive refused to read \(count) sectors at \(lba) (errno \(code): \(String(cString: strerror(code))))."
        case .shortRead(let count):
            return "The drive returned less than the \(count) sectors asked for, or no C2 error data."
        case .noC2Support:
            return "The drive can't report read errors (C2)."
        case .tooManyUnreadable(let track, let sectors):
            return "The drive couldn't read \(sectors) sectors of track \(track)."
        }
    }
}

/// Raw sector access to an audio CD. `SecureRipEngine` runs against this so the
/// whole verification algorithm can be tested without a drive.
public protocol CDSectorReading: AnyObject {
    /// Read `count` sectors starting at logical block `lba` (0 = the start of
    /// track 1's audio, after the 150-sector lead-in pregap). With `c2` the
    /// result carries the drive's C2 error pointers too.
    func readSectors(at lba: Int, count: Int, c2: Bool) throws -> CDSectorRead
}
