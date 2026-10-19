import Foundation

// The decidable halves of the app's start and finish sites (spec §3.1).
//
// Each site in the view model begins a job with its labels and ends it with
// an outcome. What those are is a value, not wiring, so it lives here with a
// test; the sites only gather the tallies and pass them in.

public extension BusyOutcome {
    /// A CD or SACD rip's tally. A cancel is never a failure; any failed
    /// track is, because the app then says "Rip Failed" and a blinking check
    /// beside it would be a lie.
    static func rip(cancelled: Bool, failedTracks: Int) -> BusyOutcome {
        if cancelled { return .cancelled }
        return failedTracks > 0 ? .failed : .completed
    }

    /// A job that ended by throwing: cancellation reads as `.cancelled`,
    /// anything else as `.failed`.
    static func thrown(_ error: Error) -> BusyOutcome {
        error is CancellationError ? .cancelled : .failed
    }

    /// A conversion batch: a cancel outranks everything, a batch where
    /// nothing succeeded and something failed failed, and anything else
    /// (partial success included) completed. The summary sheet carries the
    /// errors of a partial success.
    static func conversion(succeeded: Int, failed: Int, cancelled: Int) -> BusyOutcome {
        if cancelled > 0 { return .cancelled }
        return succeeded == 0 && failed > 0 ? .failed : .completed
    }

    /// A copy transfer. Its loop counts a cancelled item as a failure, so
    /// the cancel flag, read from the task before it is dropped, is the only
    /// thing that tells a cancelled partial copy from a finished one.
    static func copyTransfer(wasCancelled: Bool, succeeded: Int, failed: Int) -> BusyOutcome {
        if wasCancelled { return .cancelled }
        return succeeded == 0 && failed > 0 ? .failed : .completed
    }

    /// A device sync. It cannot be cancelled; it failed only when every
    /// entry did.
    static func sync(failed: Int, total: Int) -> BusyOutcome {
        total > 0 && failed >= total ? .failed : .completed
    }

    /// A scan that staged `found` tracks. Nothing found is no success to
    /// blink.
    static func scan(found: Int) -> BusyOutcome {
        found > 0 ? .completed : .failed
    }

    /// A stream download. A cancel that lost the race to the finished file
    /// still delivered it, so success wins.
    static func download(succeeded: Bool, cancelled: Bool) -> BusyOutcome {
        if succeeded { return .completed }
        return cancelled ? .cancelled : .failed
    }
}

public extension BusyLabels {
    /// What a stream download's cassette label reads when the stream has no
    /// channel.
    static let streamFallback = "STREAM"

    /// A conversion's labels: the batch's most common source extension
    /// (case-insensitive, ties to the first seen, blanks ignored) and the
    /// output format's short name (MP3, AAC, ALAC, FLAC, WAV, AIFF, OGG,
    /// OPUS). `OutputFormat.displayName` is not used because "Ogg Vorbis"
    /// is two words on a label sized for one.
    static func conversion(sourceExtensions: [String], target: OutputFormat) -> BusyLabels {
        BusyLabels(source: mostCommon(sourceExtensions), target: target.rawValue)
    }

    /// A stream download's label: the channel, or "STREAM" when it has none.
    static func download(channel: String?) -> BusyLabels {
        let labels = BusyLabels(source: channel)
        return labels.source == nil ? BusyLabels(source: streamFallback) : labels
    }

    private static func mostCommon(_ extensions: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for raw in extensions {
            let ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !ext.isEmpty else { continue }
            if counts[ext] == nil { order.append(ext) }
            counts[ext, default: 0] += 1
        }
        // Strictly greater, so a tie keeps the one seen first.
        var best: (ext: String, count: Int)?
        for ext in order {
            let count = counts[ext, default: 0]
            if count > best?.count ?? 0 { best = (ext, count) }
        }
        return best?.ext
    }
}
