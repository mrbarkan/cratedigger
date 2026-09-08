import Foundation

/// One entry in a conversion/sync report's detail log.
///
/// Every writer of those logs uses the same shape — `[ok] some/path.m4a`, with
/// an optional ` — note` and, for a failure, an indented second line carrying
/// the reason. The summary sheet used to print the whole block as one wall of
/// monospace, so an 18-file sync wrapped into a paragraph nobody reads. Parsing
/// it here keeps the sheet a list of files and this a testable value.
public struct TransferLogLine: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case ok, skipped, failed, cancelled, other

        /// The tags the log writers actually use. Anything else is `.other`,
        /// which still shows the line — a report is never worth hiding because
        /// a new tag turned up.
        init(tag: String) {
            switch tag {
            case "ok":                  self = .ok
            case "skip", "skipped":     self = .skipped
            case "failed", "fail":      self = .failed
            case "cancelled":           self = .cancelled
            default:                    self = .other
            }
        }

        /// Chip text. Nil for a line that carried no tag at all.
        public var badge: String? {
            switch self {
            case .ok:        return "OK"
            case .skipped:   return "SKIP"
            case .failed:    return "FAIL"
            case .cancelled: return "STOP"
            case .other:     return nil
            }
        }
    }

    public let id: Int
    public let outcome: Outcome
    /// The path or filename the entry is about.
    public let path: String
    /// The trailing " — …" note, or a failure's indented reason.
    public let note: String?

    /// Last path component — what the row leads with.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Everything before the name, for the dim second line. Empty when the
    /// entry is a bare filename.
    public var parent: String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    public init(id: Int, outcome: Outcome, path: String, note: String?) {
        self.id = id
        self.outcome = outcome
        self.path = path
        self.note = note
    }

    public static func parse(_ details: String) -> [TransferLogLine] {
        var out: [TransferLogLine] = []
        for raw in details.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // An indented line continues the entry above it (a failure reason).
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                let reason = line.trimmingCharacters(in: .whitespaces)
                if let last = out.popLast() {
                    let joined = [last.note, reason.isEmpty ? nil : reason]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    out.append(TransferLogLine(id: last.id, outcome: last.outcome,
                                               path: last.path, note: joined.isEmpty ? nil : joined))
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            var outcome = Outcome.other
            var rest = trimmed
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let tag = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).lowercased()
                outcome = Outcome(tag: tag)
                rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            let (path, note) = splitNote(rest)
            out.append(TransferLogLine(id: out.count, outcome: outcome, path: path, note: note))
        }
        return out
    }

    /// " — " is the writers' note separator; an em dash inside a filename is
    /// not, so only the first one splits.
    private static func splitNote(_ text: String) -> (String, String?) {
        guard let range = text.range(of: " — ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]),
                String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
