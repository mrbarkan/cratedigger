import CrateDiggerCore
import SwiftUI

/// A job pane's Busy Signals picture (spec §5): the scene of the job the
/// ledger names, animated while it runs and blinking its finished mark.
///
/// Reads the ledger from the view model and hands it to `BusySceneTimeline`,
/// which does the drawing without needing a model, so the snapshot tests can
/// render it from a fixture ledger.
struct BusyPictureView: View {
    @EnvironmentObject private var model: LibraryViewModel
    let recordID: BusyJobID

    var body: some View {
        BusySceneTimeline(ledger: model.busy, recordID: recordID, style: .picture)
    }
}

/// Which of a job's two drawings a timeline shows: the 240 × 100 pane
/// picture or the 96 × 12 rail mini. Both come from the same record and the
/// same scene input; only the Core function and the pen differ.
enum BusySceneStyle: Equatable {
    case picture, mini

    /// Screen points (html:950 for the picture, html:962 for the mini).
    var lineWidth: CGFloat {
        switch self {
        case .picture: return 1.15
        case .mini: return 0.95
        }
    }

    func drawing(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusyDrawing {
        switch self {
        case .picture: return BusyScenes.picture(kind, input)
        case .mini: return BusyScenes.mini(kind, input)
        }
    }
}

/// A Busy Signals clock: a `TimelineView` around `BusyCanvas` that asks for a
/// frame only while something moves. The pane picture and the rail minis
/// both use it.
///
/// - **Cadence.** `BusySignalTiming.cadence`: 1/16 s running, 1/8 s while a
///   finished mark blinks, and paused once it is still (Reduce Motion, or a
///   finished picture whose blink window has closed).
/// - **Hidden windows.** Paused while `AppVisibility` says no window is on
///   screen. Scenes are stateless, so coming back draws the current frame
///   directly; nothing replays.
/// - **The end of the blink.** The ledger changes nothing when a picture's
///   blink window closes, so no publish would re-evaluate this view and the
///   timeline would keep ticking at 1/8 s over a steady frame for as long as
///   the screen stays up. A task sleeps until `BusyLedger.blinkEnd` and then
///   re-evaluates the body, which pauses the timeline. A mini never has a
///   blink end: it blinks until its job is seen, and being seen is a change
///   the ledger publishes (it takes the mini off the rail).
/// - **Reduce Motion.** Every input is still (`sceneInput(still: true)`), the
///   cadence is nil, and progress redraws through ordinary invalidation when
///   the ledger publishes.
struct BusySceneTimeline: View {
    let ledger: BusyLedger
    let recordID: BusyJobID
    var style: BusySceneStyle = .picture

    @ObservedObject private var visibility = AppVisibility.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the blink-end task. Read below, so writing it re-evaluates the
    /// body, and the probe then sees the closed window.
    @State private var wokeAt = Date.distantPast

    var body: some View {
        if let record = ledger.record(recordID) {
            let probe = ledger.sceneInput(for: record, at: max(Date(), wokeAt), still: reduceMotion)
            let cadence = BusySignalTiming.cadence(probe)
            let blinkEnd = cadence == nil ? nil : ledger.blinkEnd(of: record)
            TimelineView(.animation(minimumInterval: cadence ?? 1,
                                    paused: cadence == nil || !visibility.isVisible)) { context in
                // A paused timeline keeps handing out its last tick's date,
                // which can sit inside the closed blink window (mark unlit).
                // Once settled, draw at the probe's date instead.
                let date = cadence == nil ? max(Date(), wokeAt) : context.date
                BusyCanvas(drawing: style.drawing(record.kind,
                                                  ledger.sceneInput(for: record, at: date,
                                                                    still: reduceMotion)),
                           lineWidth: style.lineWidth)
                    .equatable()
            }
            .task(id: blinkEnd) {
                guard let blinkEnd else { return }
                let delay = blinkEnd.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                wokeAt = blinkEnd
            }
        }
    }
}
