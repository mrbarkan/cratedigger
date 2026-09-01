import Foundation

/// Which part of a value a proposed change actually touches.
///
/// The tag review sheet was showing two long strings side by side and leaving
/// the reader to spot the difference. For most rows that difference is one
/// letter — "(Honeymoon is Over.)" → "(Honeymoon Is Over.)" — which is
/// invisible at a glance, so a casing tidy-up and a wholesale retitle looked
/// exactly alike. Splitting each value into unchanged head / changed middle /
/// unchanged tail lets the sheet emphasise only the part that moves.
public enum ValueDiff {
    /// One value cut into the part before the change, the change, and the part
    /// after it. The three concatenated give the original string back.
    public struct Split: Equatable, Sendable {
        public let head: String
        public let changed: String
        public let tail: String

        public init(head: String, changed: String, tail: String) {
            self.head = head
            self.changed = changed
            self.tail = tail
        }

        /// Nothing differs — the two values were equal.
        public var isEmpty: Bool { changed.isEmpty }
    }

    /// Split `current` and `proposed` on their common prefix and suffix.
    ///
    /// The span is widened to whole words: a bare one-character highlight
    /// ("u" → "U") is technically precise and practically unreadable, whereas
    /// "up." → "Up." reads at a glance.
    public static func split(current: String, proposed: String) -> (current: Split, proposed: Split) {
        let a = Array(current)
        let b = Array(proposed)

        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }

        // Equal values: no span to widen, and widening one would invent a
        // highlight for a change that isn't there.
        guard head < a.count || head < b.count else {
            return (Split(head: current, changed: "", tail: ""),
                    Split(head: proposed, changed: "", tail: ""))
        }

        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        // Back both boundaries out to whitespace so the highlight covers words
        // rather than letters. Only ever shrinks the unchanged parts, so the
        // head/tail lengths stay valid for both strings.
        while head > 0, !a[head - 1].isWhitespace { head -= 1 }
        while tail > 0, !a[a.count - tail].isWhitespace { tail -= 1 }

        return (split(a, head: head, tail: tail), split(b, head: head, tail: tail))
    }

    private static func split(_ chars: [Character], head: Int, tail: Int) -> Split {
        let end = chars.count - tail
        return Split(
            head: String(chars[0..<head]),
            changed: String(chars[head..<end]),
            tail: String(chars[end...])
        )
    }
}
