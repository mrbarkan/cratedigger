import Foundation

/// How aggressively to detect track breaks. True between-songs gaps on vinyl are
/// short bursts of *near-total* silence; quiet musical passages inside a long song
/// are neither truly silent nor sustained that long. The conservative `.default`
/// biases toward long, clear silences so long songs aren't split internally.
public struct RecordDetectionSensitivity: Sendable, Equatable {
    /// Anything quieter than this counts as silence (dBFS, negative).
    public var noiseFloorDb: Double
    /// A silence must last at least this long to count as a track break (seconds).
    public var minSilenceSeconds: Double

    public init(noiseFloorDb: Double, minSilenceSeconds: Double) {
        self.noiseFloorDb = noiseFloorDb
        self.minSilenceSeconds = minSilenceSeconds
    }

    /// Conservative default: only genuine, sustained gaps register.
    public static let `default` = RecordDetectionSensitivity(noiseFloorDb: -38, minSilenceSeconds: 2.0)

    /// Map a 0…1 slider (0 = fewest splits, 1 = most) onto detection knobs, across
    /// the spec's ranges: noise floor -42…-30 dB, min silence 2.8…1.2 s.
    public static func fromSlider(_ t: Double) -> RecordDetectionSensitivity {
        let c = min(max(t, 0), 1)
        return RecordDetectionSensitivity(
            noiseFloorDb: -42 + c * 12,        // c=0 → -42 dB, c=1 → -30 dB
            minSilenceSeconds: 2.8 - c * 1.6   // c=0 → 2.8 s,  c=1 → 1.2 s
        )
    }
}

public enum RecordDividerError: Error, Equatable {
    case noAudioDuration
    case commandFailed(Int32, String)
}

/// Detects track boundaries inside one long recording (e.g. a vinyl-side rip) by
/// running ffmpeg's `silencedetect` filter and deriving `RecordMarker`s from the
/// silent gaps. The argument vector and the silence→marker derivation are pure
/// (and unit-tested with a fake `CommandRunning`); only `detect` spawns a process.
///
/// `@unchecked Sendable`: the only non-Sendable member is the injected
/// `CommandRunning`; in production that's the stateless `ProcessCommandRunner`,
/// so `detect` is safe to run off the main actor.
public struct RecordDividerService: @unchecked Sendable {
    private let ffmpegURL: URL
    private let runner: CommandRunning

    public init(ffmpegURL: URL, runner: CommandRunning = ProcessCommandRunner()) {
        self.ffmpegURL = ffmpegURL
        self.runner = runner
    }

    /// Silences within ~this many seconds of the start/end are treated as the
    /// lead-in / run-out groove and dropped rather than split on.
    public static let edgeSilenceEpsilon: Double = 1.5

    /// Tracks shorter than this are merged into a neighbour (a brief quiet moment
    /// shouldn't become its own track). There is no maximum track length.
    public static let defaultFloorSeconds: Double = 30

    /// The ffmpeg argument vector for silence detection on `fileURL`.
    public static func arguments(fileURL: URL,
                                 sensitivity: RecordDetectionSensitivity = .default) -> [String] {
        let db = String(format: "%.0f", sensitivity.noiseFloorDb)
        let d = String(format: "%.2f", sensitivity.minSilenceSeconds)
        return [
            "-hide_banner", "-nostats",
            "-i", fileURL.path,
            "-af", "silencedetect=noise=\(db)dB:d=\(d)",
            "-f", "null", "-"
        ]
    }

    /// Run ffmpeg and derive candidate track markers. `totalDuration` is the file's
    /// known length (from the scan) — used for the final track's end.
    public func detect(fileURL: URL,
                       totalDuration: Double,
                       sensitivity: RecordDetectionSensitivity = .default) throws -> [RecordMarker] {
        guard totalDuration > 0 else { throw RecordDividerError.noAudioDuration }
        let out = try runner.run(executableURL: ffmpegURL,
                                 arguments: Self.arguments(fileURL: fileURL, sensitivity: sensitivity))
        guard out.terminationStatus == 0 else {
            throw RecordDividerError.commandFailed(out.terminationStatus, out.standardError)
        }
        // silencedetect writes to stderr.
        return Self.markers(fromSilenceLog: out.standardError, totalDuration: totalDuration)
    }

    // MARK: - Pure derivation

    /// Parse a `silencedetect` log and derive contiguous track markers.
    ///
    /// Interior gaps are cut at the silence midpoint (each track keeps a little
    /// head/tail). A lead-in silence at the very start and a run-out silence at the
    /// very end are dropped. Tracks shorter than `defaultFloorSeconds` merge into a
    /// neighbour. Always returns at least one marker for a positive-duration file.
    public static func markers(fromSilenceLog log: String,
                               totalDuration: Double) -> [RecordMarker] {
        let silences = parseSilences(from: log, totalDuration: totalDuration)
        let duration = max(totalDuration, silences.last?.end ?? 0)

        var interior = silences
        var start = 0.0
        if let first = interior.first, first.start <= edgeSilenceEpsilon {
            start = first.end
            interior.removeFirst()
        }
        var end = duration
        if let last = interior.last, last.end >= duration - edgeSilenceEpsilon {
            end = last.start
            interior.removeLast()
        }
        guard end > start else {
            return [RecordMarker(startSeconds: 0, endSeconds: duration, title: title(1, of: 1))]
        }

        let cuts = interior
            .map { ($0.start + $0.end) / 2 }
            .filter { $0 > start && $0 < end }
            .sorted()

        let bounds = [start] + cuts + [end]
        var segments: [(Double, Double)] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1] > bounds[i] {
            segments.append((bounds[i], bounds[i + 1]))
        }
        segments = mergeShort(segments, floor: defaultFloorSeconds)

        let count = segments.count
        return segments.enumerated().map { i, seg in
            RecordMarker(startSeconds: seg.0, endSeconds: seg.1, title: title(i + 1, of: count))
        }
    }

    private static func title(_ n: Int, of total: Int) -> String {
        let width = max(2, String(total).count)
        return "Track " + String(format: "%0\(width)d", n)
    }

    /// Merge any segment shorter than `floor` into a neighbour (previous when one
    /// exists, otherwise the following segment).
    private static func mergeShort(_ segments: [(Double, Double)], floor: Double) -> [(Double, Double)] {
        guard !segments.isEmpty else { return [] }
        var result: [(Double, Double)] = []
        for seg in segments {
            if seg.1 - seg.0 < floor, let last = result.last {
                result[result.count - 1] = (last.0, seg.1)   // grow the previous track
            } else {
                result.append(seg)
            }
        }
        // A short *first* segment had no previous to merge into — merge it forward.
        while result.count >= 2, result[0].1 - result[0].0 < floor {
            result[1] = (result[0].0, result[1].1)
            result.removeFirst()
        }
        return result
    }

    private static func parseSilences(from log: String,
                                      totalDuration: Double) -> [(start: Double, end: Double)] {
        var result: [(Double, Double)] = []
        var pendingStart: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            if let s = value(after: "silence_start:", in: line) {
                pendingStart = max(0, s)
            } else if let e = value(after: "silence_end:", in: line) {
                result.append((pendingStart ?? 0, e))
                pendingStart = nil
            }
        }
        // File ended mid-silence (no closing silence_end) → trailing silence to EOF.
        if let s = pendingStart {
            result.append((s, max(totalDuration, s)))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// The first numeric token following `token` on `line` (e.g. the `123.4` in
    /// `silence_end: 123.4 | silence_duration: 2.0`).
    private static func value(after token: String, in line: Substring) -> Double? {
        guard let r = line.range(of: token) else { return nil }
        var num = ""
        for ch in line[r.upperBound...].drop(while: { $0 == " " }) {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                num.append(ch)
            } else {
                break
            }
        }
        return Double(num)
    }
}
