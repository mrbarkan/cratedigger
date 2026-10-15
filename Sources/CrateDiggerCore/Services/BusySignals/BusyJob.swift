import Foundation

/// The six jobs that draw a Busy Signals picture.
///
/// A secure read is its own kind rather than a phase of a rip because it
/// draws a different scene (the sector grid, not the spinning disc). When the
/// verified WAVs go on to be encoded, the ledger hands the same job over to
/// `.rip`, keeping its identity and start time.
public enum BusyJobKind: String, CaseIterable, Sendable {
    case rip, secureRead, convert, scan, download, transfer

    /// The word the rail mini and the notice plate print for this job.
    public var label: String {
        switch self {
        case .rip: return "CD-RIP"
        case .secureRead: return "SECURE READ"
        case .convert: return "CONVERT"
        case .scan: return "SCAN"
        case .download: return "DOWNLOAD"
        case .transfer: return "TRANSFER"
        }
    }

    /// The screen a job of this kind is drawn on when its start site names
    /// no other. Ripping, secure reading and downloading all share DUB, the
    /// getting-audio-in screen; a device transfer runs on DEVICES even though
    /// it converts, because that is where the user started it.
    public var defaultScreen: BusyScreen {
        switch self {
        case .rip, .secureRead, .download: return .dub
        case .convert: return .conversion
        case .scan: return .scan
        case .transfer: return .devices
        }
    }
}

/// Core's mirror of the app's `OLEDView` (which Core cannot see), the same
/// way `BrowserEmptyKind.Source` mirrors `LibrarySource`. `other` is every
/// screen that never hosts a job: NOW, SYNC, SRCH, STAT, and compact.
public enum BusyScreen: String, CaseIterable, Sendable {
    case dub, conversion, scan, devices, other
}

/// How a job ended. Only `.completed` leaves a finished picture behind; a
/// cancelled or failed job is removed outright, because a finished frame
/// would claim work that never happened.
public enum BusyOutcome: Sendable, Equatable {
    case completed, cancelled, failed
}

/// A job's identity in the ledger. Handed out monotonically by `begin`, so
/// a later job always has a larger raw value, and kept across a hand-over.
///
/// The initialiser is internal on purpose: only the ledger mints IDs, so the
/// app can never hold one that `begin` did not issue. Core tests reach it
/// through `@testable import`.
public struct BusyJobID: Hashable, Sendable {
    public let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Short words a scene prints: the codec on a converted file, the channel
/// on a cassette label. Uppercased, trimmed and cut to 12 characters on init
/// and on every set (trimmed again after the cut, so a cut that lands on a
/// space never leaves one dangling and throwing a centred label off by a
/// glyph), and an empty word reads as nil, so a scene never has to measure a
/// string that would run off its label.
public struct BusyLabels: Equatable, Sendable {
    /// The longest word a scene's label has room for at its font.
    static let maxLength = 12

    public var source: String? {
        didSet { source = Self.word(source) }
    }
    public var target: String? {
        didSet { target = Self.word(target) }
    }

    public init(source: String? = nil, target: String? = nil) {
        self.source = Self.word(source)
        self.target = Self.word(target)
    }

    private static func word(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.uppercased().prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where a Secure Mode read stands, copied out of `SecureDiscRip.Progress`
/// so the scene can draw the pass, the phase and the re-reads without
/// reaching into the rip engine.
public struct BusySecureRead: Equatable, Sendable {
    /// 1-based.
    public var trackOrdinal: Int
    public var trackCount: Int
    public var phase: SecureRipEngine.Phase
    /// 0…1 within the phase. NaN reads as 0, so the bar can never go NaN.
    public var phaseFraction: Double {
        didSet { phaseFraction = Self.unit(phaseFraction) }
    }
    /// Sector re-reads on this track, not across the disc. The engine only
    /// counts them in `.retry` (it reports 0 through both passes), and the
    /// scene lights at most six hot cells for them.
    public var rereads: Int

    public init(_ progress: SecureDiscRip.Progress) {
        self.trackOrdinal = progress.trackOrdinal
        self.trackCount = progress.trackCount
        self.phase = progress.track.phase
        self.phaseFraction = Self.unit(progress.track.fraction)
        self.rereads = progress.track.rereads
    }

    /// The bar across the disc. The two passes take about the same time, so
    /// each is half a track; re-reading has no predictable length, so it gets
    /// the last sliver rather than a share the bar would then sit on.
    ///
    /// The one copy: DubPane's Secure Read bar reads it too, so the pane and
    /// the scene can never disagree about how far the read has got. It was
    /// moved here verbatim from `DubPane.secureOverall`; the one difference is
    /// upstream of the formula: `phaseFraction` is clamped to 0…1 (NaN as 0)
    /// where the old copy read the engine's fraction raw, so an out-of-range
    /// report moves the bar less than it used to, never more.
    public var overall: Double {
        let within: Double
        switch phase {
        case .pass1: within = phaseFraction * 0.48
        case .pass2: within = 0.48 + phaseFraction * 0.48
        case .retry: within = 0.96 + phaseFraction * 0.04
        }
        let done = Double(trackOrdinal - 1) + within
        return min(max(done / Double(max(trackCount, 1)), 0), 1)
    }

    /// Clamps to 0…1; NaN reads as 0.
    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

/// How far a job has got, in the counts its start site already keeps.
///
/// Values are sanitised on the way in rather than in every scene, as
/// `MatrixInput` does: `completed` never goes negative, and a `total` that
/// is nil, zero or negative is kept as given but reads as "unknown", so a
/// scene draws its indeterminate motion instead of dividing by it.
public struct BusyProgress: Equatable, Sendable {
    /// Units done so far (tracks, files); never negative.
    public var completed: Int {
        didSet { completed = Self.count(completed) }
    }
    /// Units in the whole job; nil or ≤ 0 means unknown.
    public var total: Int?
    /// Convert only: whether the running preset is lossless, which picks a
    /// lossless re-box over a lossy squash. Set from the preset that is
    /// actually running, not from the format picker's current selection.
    public var lossless: Bool
    /// Set while a Secure Mode read is running; its own bar then wins over
    /// the counts.
    public var secure: BusySecureRead?

    public init(completed: Int = 0, total: Int? = nil, lossless: Bool = false, secure: BusySecureRead? = nil) {
        self.completed = Self.count(completed)
        self.total = total
        self.lossless = lossless
        self.secure = secure
    }

    /// 0…1, or nil while the total is unknown. It is `secure.overall` when a
    /// secure read is running, else `completed / total` clamped, so a count
    /// that overshoots its total (a file added mid-scan) still reads as full.
    public var fraction: Double? {
        if let secure { return secure.overall }
        guard let total, total > 0 else { return nil }
        return min(Double(completed) / Double(total), 1)
    }

    /// The same progress with new counts, keeping `lossless` and `secure`:
    /// the update sites only know the counts, and must not wipe what the
    /// start site decided.
    public func with(completed: Int, total: Int?) -> BusyProgress {
        var copy = self
        copy.completed = completed
        copy.total = total
        return copy
    }

    private static func count(_ value: Int) -> Int {
        max(0, value)
    }
}
