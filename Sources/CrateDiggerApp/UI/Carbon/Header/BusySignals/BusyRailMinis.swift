import CrateDiggerCore
import SwiftUI

/// The annunciator rail's Busy Signals cluster (spec §4): a 96 × 12
/// "source - - - destination" mini for every job that is not on the glass's
/// current screen, and "+N" for those that did not fit. Clicking a mini goes
/// to its job's screen.
///
/// Reads the ledger from the view model and hands it to `BusyRailSlot`, which
/// needs no model, so tests can render the rail from a fixture ledger.
struct BusyRailMinis: View {
    @EnvironmentObject private var model: LibraryViewModel
    /// What the rail can spare: see `BusyRailSlot.available(...)`.
    let available: CGFloat

    var body: some View {
        BusyRailSlot(ledger: model.busy, available: available) { model.showBusyJob($0) }
    }
}

/// The cluster in its zero-height slot.
///
/// **It never changes the rail's height.** The rail is one text line tall
/// (11.88 pt for JetBrains Mono at 9 pt, ≈ 9.8 pt for Llama '97's
/// PixelOperatorMono8), so a 12 pt mini in the flow would grow it, and the
/// pane and cell rail under it would jump whenever a mini came or went. The
/// slot is a `Color.clear` as wide as the cluster and 0 pt tall: it gives the
/// rail the width and nothing else. The cluster is drawn in the slot's
/// overlay, unclipped, centred on the text line like the annunciators.
///
/// The overlay is leading-aligned rather than centred so the minis start at
/// the same x whatever "+N" measures: its width is the fixed
/// `overflowLabelWidth` budget, not a measurement, and any difference lands
/// in the 14 pt gap before the annunciators instead of shifting the minis.
///
/// With nothing to show there is no slot at all, so an idle rail lays out
/// exactly as it did before Busy Signals.
struct BusyRailSlot: View {
    let ledger: BusyLedger
    let available: CGFloat
    /// False only in offscreen renders: `ImageRenderer` cannot draw an
    /// AppKit view, and paints the drag guard as a yellow placeholder over
    /// the mini it sits behind.
    var guardsWindowDrag = true
    let select: (BusyJobID) -> Void

    /// The width budgeted for "+N" in mono 8 bold: "+9" is ≈ 10 pt in
    /// JetBrains Mono, "+12" ≈ 15 pt, with a little over for a theme's mono
    /// override.
    static let overflowLabelWidth: CGFloat = 16

    /// What the cluster may occupy: the rail, less the annunciator block and
    /// `RailLive`'s floor. Never negative.
    ///
    /// `liveFloor` is measured (`RailLiveContent` reports it), trailing
    /// padding included: on NOW (and in compact, which is pinned to NOW) the
    /// "NOW PLAYING" label, elsewhere the clock, "NOW PLAYING:" and the
    /// title's "…". The title takes what is left, so it is the title that
    /// gives way to the minis, never the clock.
    static func available(railWidth: CGFloat, annunciatorWidth: CGFloat, liveFloor: CGFloat) -> CGFloat {
        max(0, railWidth - annunciatorWidth - liveFloor)
    }

    var body: some View {
        let layout = BusyRail.layout(BusyRail.entries(ledger), available: available,
                                     overflowLabelWidth: Self.overflowLabelWidth)
        if layout.width > 0 {
            Color.clear
                .frame(width: layout.width, height: 0)
                .overlay(alignment: .leading) {
                    BusyRailCluster(ledger: ledger, layout: layout,
                                    guardsWindowDrag: guardsWindowDrag, select: select)
                }
        }
    }

    // MARK: Accessibility

    /// "CD-RIP, 40 percent", "CD-RIP, finished", or just "CD-RIP" while the
    /// total is unknown (spec §4).
    static func accessibilityLabel(for record: BusyJobRecord) -> String {
        let name = record.kind.label
        if !record.isRunning { return "\(name), finished" }
        guard let fraction = record.progress.fraction else { return name }
        return "\(name), \(Int((fraction * 100).rounded())) percent"
    }

    /// "Shows the DUB screen": the name printed on that screen's annunciator.
    static func accessibilityHint(for record: BusyJobRecord) -> String {
        guard let screen = record.screen.oledView else { return "" }
        return "Shows the \(screen.label.uppercased()) screen"
    }
}

/// The minis and "+N", laid out by `BusyRail.layout`.
///
/// The sizes repeat `BusyRail`'s internal tuning constants (96 × 12 minis,
/// 12 pt apart, 14 pt before the annunciators, html:76), which Core keeps
/// internal; `BusyRailMinisTests` pins the two sets together.
struct BusyRailCluster: View {
    static let miniSize = CGSize(width: 96, height: 12)
    static let spacing: CGFloat = 12
    static let trailing: CGFloat = 14

    let ledger: BusyLedger
    let layout: BusyRailLayout
    let guardsWindowDrag: Bool
    let select: (BusyJobID) -> Void

    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(layout.shown, id: \.self) { id in
                if let record = ledger.record(id) {
                    Button { select(id) } label: {
                        BusySceneTimeline(ledger: ledger, recordID: id, style: .mini)
                            .frame(width: Self.miniSize.width, height: Self.miniSize.height)
                            // The whole 96 × 12, not just the lit strokes.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The rail's top few points sit in the transparent
                    // titlebar strip, where a click would drag the window.
                    .background { if guardsWindowDrag { WindowDragGuard() } }
                    .accessibilityLabel(BusyRailSlot.accessibilityLabel(for: record))
                    .accessibilityHint(BusyRailSlot.accessibilityHint(for: record))
                }
            }
            if layout.overflow > 0 {
                Text("+\(layout.overflow)")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(theme.oledForeground.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel("\(layout.overflow) more")
            }
        }
        .padding(.trailing, Self.trailing)
        .fixedSize()
    }
}
