import CoreGraphics

/// What the annunciator rail's mini cluster holds: which jobs, in what order,
/// and how wide it is.
public struct BusyRailLayout: Equatable, Sendable {
    /// The jobs drawn as minis, 0…2 of them, in start order.
    public var shown: [BusyJobID]
    /// The "+N" for the jobs that did not fit; 0 means no label.
    public var overflow: Int
    /// What the cluster occupies, its trailing padding included; 0 when empty.
    public var width: CGFloat

    public init(shown: [BusyJobID], overflow: Int, width: CGFloat) {
        self.shown = shown
        self.overflow = overflow
        self.width = width
    }

    /// No minis and no label: the rail draws nothing and reserves no width.
    public static let empty = BusyRailLayout(shown: [], overflow: 0, width: 0)
}

/// The rail's policy for job minis: every screen but a job's own shows a
/// 96 × 12 "source - - - destination" of it beside the annunciators.
///
/// The cluster gives way before the annunciators ever clip: it drops a mini,
/// then both, then the "+N" too, and is empty rather than cut off. The app
/// measures `available` (the rail less the annunciators and `RailLive`'s
/// floor) and the label's width; everything else is decided here.
public enum BusyRail {
    static let maxShown = 2
    static let miniWidth: CGFloat = 96, miniHeight: CGFloat = 12
    /// Between minis, and between the last mini and "+N" (html:76).
    static let spacing: CGFloat = 12
    /// After the cluster, before the annunciators (html:76).
    static let trailing: CGFloat = 14

    /// Every record that belongs on the rail now: not on the glass's current
    /// screen, and either running or finished but not yet seen. In start
    /// order, so nothing reshuffles when a job finishes.
    ///
    /// Under `.other` (NOW, the other screens, and compact) no job is on its
    /// own screen, so every one qualifies.
    public static func entries(_ ledger: BusyLedger) -> [BusyJobRecord] {
        ledger.records.filter { record in
            record.screen != ledger.screen && (record.isRunning || record.seenAt == nil)
        }
    }

    /// As many minis as fit in `available` (at most `maxShown`), plus "+N"
    /// for the rest. If even "+N" won't fit, the cluster is empty rather than
    /// clipped. `overflowLabelWidth` is the measured width of the "+N" text.
    public static func layout(_ entries: [BusyJobRecord], available: CGFloat,
                              overflowLabelWidth: CGFloat) -> BusyRailLayout {
        guard !entries.isEmpty else { return .empty }
        for shown in stride(from: min(maxShown, entries.count), through: 0, by: -1) {
            let overflow = entries.count - shown
            var width = CGFloat(shown) * miniWidth + CGFloat(max(0, shown - 1)) * spacing
            if overflow > 0 {
                width += (shown > 0 ? spacing : 0) + overflowLabelWidth
            }
            width += trailing
            if width <= available {
                return BusyRailLayout(shown: entries.prefix(shown).map(\.id),
                                      overflow: overflow, width: width)
            }
        }
        return .empty
    }
}
