import Combine
import CrateDiggerCore
import Foundation

// MARK: - Screen mapping

extension OLEDView {
    /// Core's mirror of this screen. Only the four screens that host a job
    /// have one of their own; every other screen, SEARCH included, is `.other`.
    var busyScreen: BusyScreen {
        switch self {
        case .dub: return .dub
        case .conversion: return .conversion
        case .scan: return .scan
        case .devices: return .devices
        case .nowPlaying, .remoteSync, .search, .stats: return .other
        }
    }
}

extension BusyScreen {
    /// The screen a mini's click goes to. Nil for `.other`, which no job is
    /// ever drawn on.
    var oledView: OLEDView? {
        switch self {
        case .dub: return .dub
        case .conversion: return .conversion
        case .scan: return .scan
        case .devices: return .devices
        case .other: return nil
        }
    }
}

/// The progress channels that carry a safety net (spec §2.3): a running
/// record on one of them is ended `.failed` when the channel goes idle and
/// no finish site ended it. Scan has no net, only a log, because unstamped
/// work shares its channel.
enum BusyChannel: Hashable {
    case conversion, sync
}

/// One channel's edge state, held by its sink. A class so the escaping sink
/// closure and the delayed checks it starts share one copy without needing
/// stored properties on the view model.
private final class BusyChannelEdge {
    var wasRunning = false
    /// Bumped on every rising edge, so a delayed check started at a falling
    /// edge can tell the channel ran again in the meantime.
    var generation = 0
}

// MARK: - Glue

/// Busy Signals' view-model glue: the one place that writes `busy`.
///
/// Jobs are stamped explicitly at the sites that start and finish them; this
/// file never infers a job from `oledView` or from a progress channel. The
/// channels only feed progress into records that a start site already began,
/// and the safety net only ends a record whose finish site was missed.
@MainActor
extension LibraryViewModel {

    /// How long a safety-netted channel must stay idle before its armed
    /// record is ended as missed.
    static let busySafetyNetDelay: TimeInterval = 3
    /// How long the scan channel must stay idle before a still-running scan
    /// record is logged as missing its finish site.
    static let busyScanOrphanLogDelay: TimeInterval = 30
    /// The settle task never sleeps less than this, so a date that lands a
    /// hair in the past can never turn it into a busy loop.
    static let busySettleFloor: TimeInterval = 0.05

    /// What the glass shows: compact always shows NOW.
    var busyVisibleScreen: BusyScreen {
        isCompactPlayer ? .other : oledView.busyScreen
    }

    // MARK: Lifecycle verbs

    /// Starts a job on `screen` and returns its id for the finish site.
    @discardableResult
    func beginBusyJob(_ kind: BusyJobKind, on screen: OLEDView,
                      labels: BusyLabels = .init(), lossless: Bool = false) -> BusyJobID {
        let id = busy.begin(kind, on: screen.busyScreen, labels: labels,
                            progress: BusyProgress(lossless: lossless), at: Date())
        // A start site often writes its channel's first snapshot before it
        // begins the job, so that snapshot has already gone by: feed it now.
        feedBusyFromChannels(id)
        armBusySafetyNet(for: id)
        rescheduleBusySettle()
        return id
    }

    /// Ends a job. Nil is a no-op, so a call site can pass an optional id.
    func endBusyJob(_ id: BusyJobID?, _ outcome: BusyOutcome) {
        guard let id else { return }
        mutateBusy { $0.finish(id, outcome, at: Date()) }
        rescheduleBusySettle()
    }

    /// Secure read → rip, in place: same id and start, so the rail neither
    /// reorders nor blinks. The new kind's counts start from zero, keeping
    /// only the start site's `lossless`.
    func handBusyJob(_ id: BusyJobID?, to kind: BusyJobKind) {
        guard let id, let record = busy.record(id), record.isRunning else { return }
        mutateBusy {
            $0.handOver(id, to: kind, progress: BusyProgress(lossless: record.progress.lossless), at: Date())
        }
        // The encode's first snapshot was written before the hand-over, while
        // the record was still a secure read the conversion sink ignores.
        feedBusyFromChannels(id)
        armBusySafetyNet(for: id)
        rescheduleBusySettle()
    }

    /// What `screen`'s pane draws, or nil. A screen that never hosts a job
    /// draws nothing.
    func busyPicture(on screen: OLEDView) -> BusyJobRecord? {
        let busyScreen = screen.busyScreen
        guard busyScreen != .other else { return nil }
        return busy.picture(on: busyScreen)
    }

    /// A mini was clicked: expand first in compact (`CompactCommandPolicy`
    /// says `.selectDisplay` expands first), then switch to the job's screen.
    func showBusyJob(_ id: BusyJobID) {
        guard let target = busy.record(id)?.screen.oledView else { return }
        if CompactCommandPolicy.availability(.selectDisplay, in: playerLayout) == .expandsFirst {
            expandToFull()
        }
        oledView = target
    }

    /// From `oledView.didSet` and `playerLayout.didSet`.
    func noteBusyScreenChanged() {
        mutateBusy { $0.show(busyVisibleScreen, at: Date()) }
        rescheduleBusySettle()
    }

    /// Settles the ledger now and sleeps until the next date it says could
    /// change something. Terminates because `settle` never returns a date at
    /// or before its argument.
    func rescheduleBusySettle() {
        busySettleTask?.cancel()
        busySettleTask = nil
        var next: Date?
        mutateBusy { next = $0.settle(at: Date()) }
        guard let next else { return }
        let delay = max(next.timeIntervalSinceNow, Self.busySettleFloor)
        busySettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rescheduleBusySettle()
        }
    }

    // MARK: Wiring

    /// Called once from `init` beside `wirePlaybackBindings()`, after
    /// `oledView` and `playerLayout` are restored.
    func wireBusySignals() {
        busyChannelCancellables.removeAll()

        let conversionEdge = BusyChannelEdge()
        $conversionProgress
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    self?.conversionChannelChanged(snapshot, edge: conversionEdge)
                }
            }
            .store(in: &busyChannelCancellables)

        $secureRipProgress
            .sink { [weak self] progress in
                MainActor.assumeIsolated {
                    guard let self, let progress,
                          let record = self.busy.records.last(where: { $0.isRunning && $0.kind == .secureRead })
                    else { return }
                    var next = record.progress
                    next.secure = BusySecureRead(progress)
                    self.mutateBusy { $0.update(record.id, progress: next, at: Date()) }
                }
            }
            .store(in: &busyChannelCancellables)

        let scanEdge = BusyChannelEdge()
        $scanProgress
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    self?.scanChannelChanged(snapshot, edge: scanEdge)
                }
            }
            .store(in: &busyChannelCancellables)

        let syncEdge = BusyChannelEdge()
        $deviceSyncProgress
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    self?.syncChannelChanged(snapshot, edge: syncEdge)
                }
            }
            .store(in: &busyChannelCancellables)

        // `didSet` does not run for the stores `init` makes, so without this
        // a relaunch onto CNVRT, DUB, SCAN or DEV would leave the ledger on
        // `.other`, and a job started there would get a mini on its own rail.
        busy.show(busyVisibleScreen, at: Date())
    }

    // MARK: Channels

    /// The running record the conversion channel feeds. The BUSY guards make
    /// rip, convert, download and copy transfer exclusive on it.
    private var conversionChannelRecord: BusyJobRecord? {
        busy.records.last { Self.conversionChannelCarries($0) }
    }

    private static func conversionChannelCarries(_ record: BusyJobRecord) -> Bool {
        guard record.isRunning else { return false }
        switch record.kind {
        case .rip, .convert, .download: return true
        case .transfer: return record.screen == .conversion
        case .secureRead, .scan: return false
        }
    }

    private static func syncChannelCarries(_ record: BusyJobRecord) -> Bool {
        record.isRunning && record.kind == .transfer && record.screen == .devices
    }

    private func conversionChannelChanged(_ snapshot: ConversionProgressSnapshot, edge: BusyChannelEdge) {
        // `.idle` carries zero counts; feeding it would wipe a running job's
        // progress in the moment before its finish site ends it.
        if snapshot.isRunning || snapshot.jobsTotal > 0, let record = conversionChannelRecord {
            let next = record.progress.with(completed: snapshot.jobsCompleted, total: snapshot.jobsTotal)
            mutateBusy { $0.update(record.id, progress: next, at: Date()) }
        }
        trackSafetyNetEdge(.conversion, isRunning: snapshot.isRunning, edge: edge,
                           armable: { [weak self] in self?.conversionChannelRecord },
                           isIdle: { [weak self] in !(self?.conversionProgress.isRunning ?? false) })
    }

    private func syncChannelChanged(_ snapshot: DeviceSyncProgressSnapshot?, edge: BusyChannelEdge) {
        if let snapshot, let record = busy.running(.transfer, on: .devices) {
            let next = record.progress.with(completed: snapshot.completed, total: snapshot.total)
            mutateBusy { $0.update(record.id, progress: next, at: Date()) }
        }
        trackSafetyNetEdge(.sync, isRunning: snapshot?.isRunning ?? false, edge: edge,
                           armable: { [weak self] in self?.busy.running(.transfer, on: .devices) },
                           isIdle: { [weak self] in !(self?.deviceSyncProgress?.isRunning ?? false) })
    }

    /// Scan: feeds progress and only ever logs. Album moves, consolidate,
    /// copy-to-library and the Adding → crate status share this channel and
    /// can finish while a dig runs, so going idle here must never end a dig.
    private func scanChannelChanged(_ snapshot: ScanProgress, edge: BusyChannelEdge) {
        if snapshot.isRunning, let record = busy.running(.scan, on: .scan) {
            let next = record.progress.with(completed: snapshot.filesProbed, total: snapshot.totalCandidates)
            mutateBusy { $0.update(record.id, progress: next, at: Date()) }
        }
        if snapshot.isRunning, !edge.wasRunning {
            edge.generation += 1
        } else if !snapshot.isRunning, edge.wasRunning {
            let generation = edge.generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.busyScanOrphanLogDelay * 1_000_000_000))
                guard let self, edge.generation == generation, !self.scanProgress.isRunning,
                      self.busy.running(.scan, on: .scan) != nil else { return }
                AppLog.ui.warning("Busy scan still running \(Int(Self.busyScanOrphanLogDelay), privacy: .public) s after the scan channel went idle: a finish site may be missing")
            }
        }
        edge.wasRunning = snapshot.isRunning
    }

    /// The safety net for one channel. At the rising edge it arms the
    /// channel's running record; at the falling edge it waits, then ends that
    /// record `.failed` (removed, never a fake success) and logs, if nothing
    /// ended it meanwhile.
    private func trackSafetyNetEdge(_ channel: BusyChannel, isRunning: Bool, edge: BusyChannelEdge,
                                    armable: @escaping () -> BusyJobRecord?,
                                    isIdle: @escaping () -> Bool) {
        defer { edge.wasRunning = isRunning }
        if isRunning, !edge.wasRunning {
            edge.generation += 1
            busySafetyArmed[channel] = armable()?.id
        } else if !isRunning, edge.wasRunning, let armed = busySafetyArmed[channel] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.busySafetyNetDelay * 1_000_000_000))
                guard let self, let record = self.busy.record(armed), record.isRunning else { return }
                // Still idle, or already re-armed for a newer job: either way
                // nothing is going to end this record any more.
                let reArmed = self.busySafetyArmed[channel] != armed
                guard isIdle() || reArmed else { return }
                AppLog.ui.warning("Busy job \(record.kind.rawValue, privacy: .public) ended by the safety net: a finish site is missing")
                if !reArmed { self.busySafetyArmed[channel] = nil }
                self.endBusyJob(armed, .failed)
            }
        }
    }

    /// Arms the safety net for a record that was begun (or handed over) after
    /// its channel's rising edge had already gone by. The BUSY guards make
    /// the newest record on a channel its owner, so it replaces any earlier
    /// one.
    private func armBusySafetyNet(for id: BusyJobID) {
        guard let record = busy.record(id) else { return }
        if conversionProgress.isRunning, Self.conversionChannelCarries(record) {
            busySafetyArmed[.conversion] = id
        }
        if deviceSyncProgress?.isRunning == true, Self.syncChannelCarries(record) {
            busySafetyArmed[.sync] = id
        }
    }

    /// Feeds a just-begun (or just-handed-over) record the counts its channel
    /// already holds. Secure read is left to its own sink: a stale
    /// `secureRipProgress` from an earlier rip must not paint a new one.
    private func feedBusyFromChannels(_ id: BusyJobID) {
        guard let record = busy.record(id), record.isRunning else { return }
        var next: BusyProgress?
        if Self.conversionChannelCarries(record), conversionProgress.isRunning {
            next = record.progress.with(completed: conversionProgress.jobsCompleted,
                                        total: conversionProgress.jobsTotal)
        } else if Self.syncChannelCarries(record), let sync = deviceSyncProgress, sync.isRunning {
            next = record.progress.with(completed: sync.completed, total: sync.total)
        } else if record.kind == .scan, record.screen == .scan, scanProgress.isRunning {
            next = record.progress.with(completed: scanProgress.filesProbed, total: scanProgress.totalCandidates)
        }
        guard let next else { return }
        mutateBusy { $0.update(id, progress: next, at: Date()) }
    }

    /// Applies a change to a copy and publishes only when it changed
    /// something, so a settle or show that is a no-op never republishes the
    /// whole view model.
    private func mutateBusy(_ change: (inout BusyLedger) -> Void) {
        var copy = busy
        change(&copy)
        if copy != busy { busy = copy }
    }

    // MARK: DEBUG

    #if DEBUG
    /// The `CRATEDIGGER_BUSY` hook's driver: begins each kind on its default
    /// screen and walks it 0 → 40 units over 20 s, then completes it; with
    /// `finished`, completes at once. Touches only the ledger, never a real
    /// channel, so the safety net never sees these records.
    func debugSimulateBusyJobs(_ kinds: [BusyJobKind], finished: Bool) {
        let steps = 40
        for kind in kinds {
            guard let screen = kind.defaultScreen.oledView else { continue }
            let labels: BusyLabels
            switch kind {
            case .convert: labels = BusyLabels(source: "FLAC", target: "MP3")
            case .download: labels = BusyLabels(source: "STREAM")
            default: labels = BusyLabels()
            }
            let id = beginBusyJob(kind, on: screen, labels: labels)
            if finished {
                debugSetBusyProgress(id, completed: steps, total: steps)
                endBusyJob(id, .completed)
                continue
            }
            Task { @MainActor [weak self] in
                for step in 1...steps {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.debugSetBusyProgress(id, completed: step, total: steps)
                }
                self?.endBusyJob(id, .completed)
            }
        }
    }

    private func debugSetBusyProgress(_ id: BusyJobID, completed: Int, total: Int) {
        guard let record = busy.record(id) else { return }
        let next = record.progress.with(completed: completed, total: total)
        mutateBusy { $0.update(id, progress: next, at: Date()) }
    }
    #endif
}
