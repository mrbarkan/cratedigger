import Foundation

/// One job the ledger knows about, running or finished.
///
/// Only the ledger changes a record, so every setter is internal: the app
/// reads records and drives them through `BusyLedger`'s verbs, which is where
/// the lifecycle rules live.
public struct BusyJobRecord: Equatable, Sendable, Identifiable {
    public let id: BusyJobID
    /// Changes at most once, secureRead → rip, through `handOver`.
    public internal(set) var kind: BusyJobKind
    public let screen: BusyScreen
    public let labels: BusyLabels
    /// Ordering and scene time; never reset, not even by a hand-over.
    public let startedAt: Date
    public internal(set) var progress: BusyProgress
    /// When `progress.completed` last changed: the start of the current unit.
    public internal(set) var unitStartedAt: Date
    /// When the current kind's units began counting: set by `begin` and reset
    /// by `handOver`. The rip's per-track average is measured from here, so a
    /// secure rip's long read never inflates the encode's estimate.
    public internal(set) var progressEpoch: Date
    public internal(set) var finishedAt: Date?
    /// When the finished job's screen had been on the glass long enough to
    /// count as seen. A seen record is retired as soon as the glass leaves it.
    public internal(set) var seenAt: Date?

    public var isRunning: Bool { finishedAt == nil }
}

/// The single answer to "what is running, what has finished, and has anyone
/// seen it".
///
/// A value type with every date passed in, so each rule below is a Core test
/// rather than view-model glue:
///
/// - **Seen.** A finished record is seen once its screen has been on the
///   glass for `BusySignalTiming.seenAfter`, counted from
///   max(finishedAt, screenSince). The delay is what lets a rip that ends on
///   DUB, with `loadFolders` flipping the glass to SCAN in the same turn,
///   stay unseen and blink on the rail.
/// - **Retired.** A seen record is removed as soon as the glass leaves its
///   screen. A cancelled or failed job is removed at once.
/// - **Superseded.** A new job retires any finished record on its screen and
///   any running record of its own kind on its screen (a restart).
public struct BusyLedger: Equatable, Sendable {
    /// In start order, oldest first.
    public private(set) var records: [BusyJobRecord] = []
    /// What the glass shows now.
    public private(set) var screen: BusyScreen
    /// When the glass last changed screen.
    public private(set) var screenSince: Date
    /// The next ID `begin` hands out. Never reused, so a later job always
    /// has a larger raw value.
    private var nextID = 1

    /// A job with nothing completed yet estimates its unit as this long, so
    /// the first track's file fills over half a minute rather than not at all.
    static let fallbackUnitDuration: TimeInterval = 30
    /// A running unit's estimate stops short of full: the unit is done when
    /// the count says so, not when the average says it should be.
    static let maxUnitFraction: Double = 0.95

    public init(screen: BusyScreen = .other, at date: Date) {
        self.screen = screen
        self.screenSince = date
    }

    // MARK: Lifecycle

    /// Starts a job. Retires any finished record on the same screen (it was
    /// superseded) and any running record of the same kind on the same
    /// screen (a restart, e.g. a second dig cancelling the first).
    @discardableResult
    public mutating func begin(_ kind: BusyJobKind, on screen: BusyScreen,
                               labels: BusyLabels = .init(), progress: BusyProgress = .init(),
                               at date: Date) -> BusyJobID {
        let id = BusyJobID(rawValue: nextID)
        nextID += 1
        records.removeAll { record in
            record.screen == screen && (!record.isRunning || record.kind == kind)
        }
        records.append(BusyJobRecord(id: id, kind: kind, screen: screen, labels: labels,
                                     startedAt: date, progress: progress,
                                     unitStartedAt: date, progressEpoch: date,
                                     finishedAt: nil, seenAt: nil))
        return id
    }

    /// Ignored for unknown or finished ids, so a late progress hop that lands
    /// after the finish cannot revive a job. A change in `completed` starts a
    /// new unit; a change in the total alone does not.
    public mutating func update(_ id: BusyJobID, progress: BusyProgress, at date: Date) {
        guard let index = runningIndex(id) else { return }
        if progress.completed != records[index].progress.completed {
            records[index].unitStartedAt = date
        }
        records[index].progress = progress
    }

    /// Secure read → rip, in place: same id, same `startedAt`, no finished
    /// state in between, so the rail neither reorders nor blinks. Resets
    /// `unitStartedAt` and `progressEpoch` to `date`, so the encode's
    /// per-track average starts fresh. Ignored for unknown or finished ids.
    public mutating func handOver(_ id: BusyJobID, to kind: BusyJobKind,
                                  progress: BusyProgress, at date: Date) {
        guard let index = runningIndex(id) else { return }
        records[index].kind = kind
        records[index].progress = progress
        records[index].unitStartedAt = date
        records[index].progressEpoch = date
    }

    /// `.completed` keeps the record as finished; `.cancelled` and `.failed`
    /// remove it at once (the app already reports those its own way, and a
    /// finished frame would claim work that never happened). Ignored for
    /// unknown ids and for a record that has already finished, so a second
    /// finish can neither move the first nor take a completed job away.
    public mutating func finish(_ id: BusyJobID, _ outcome: BusyOutcome, at date: Date) {
        guard let index = runningIndex(id) else { return }
        switch outcome {
        case .completed: records[index].finishedAt = date
        case .cancelled, .failed: records.remove(at: index)
        }
    }

    // MARK: The glass

    /// The glass changed screen. Retires seen records whose screen it left.
    ///
    /// A `show` of the screen already up changes nothing, so a republish that
    /// re-sends the same screen never restarts the seen timer.
    public mutating func show(_ screen: BusyScreen, at date: Date) {
        if screen != self.screen {
            self.screen = screen
            screenSince = date
        }
        records.removeAll { $0.seenAt != nil && $0.screen != screen }
    }

    /// Marks finished records seen once their screen has been on the glass
    /// for `seenAfter` since max(finishedAt, screenSince). Returns the next
    /// date, strictly after `date`, at which settling could change something
    /// (a pending seen mark, or the end of a picture's blink window), or nil.
    ///
    /// Never a date at or before `date`: a past date would make the view
    /// model's settle task re-fire at its 0.05 s floor forever and republish
    /// the whole `LibraryViewModel` at ~20 Hz.
    public mutating func settle(at date: Date) -> Date? {
        var next: Date?
        func consider(_ candidate: Date) {
            guard candidate > date else { return }
            next = min(next ?? candidate, candidate)
        }
        for index in records.indices {
            let record = records[index]
            guard record.screen == screen, let anchor = arrival(of: record) else { continue }
            if record.seenAt == nil {
                let seenDate = anchor.addingTimeInterval(BusySignalTiming.seenAfter)
                if date >= seenDate {
                    records[index].seenAt = date
                } else {
                    consider(seenDate)
                }
            }
            consider(anchor.addingTimeInterval(BusySignalTiming.pictureBlinkDuration))
        }
        return next
    }

    // MARK: Queries

    public func record(_ id: BusyJobID) -> BusyJobRecord? {
        records.first { $0.id == id }
    }

    /// A running job of `kind` on `screen`, the newest if there are several.
    /// What the progress sinks feed.
    public func running(_ kind: BusyJobKind, on screen: BusyScreen) -> BusyJobRecord? {
        records.last { $0.isRunning && $0.kind == kind && $0.screen == screen }
    }

    /// What a pane draws: the newest running record on that screen, else the
    /// newest finished, unretired one.
    public func picture(on screen: BusyScreen) -> BusyJobRecord? {
        records.last { $0.isRunning && $0.screen == screen }
            ?? records.last { $0.screen == screen }
    }

    /// The frame inputs for a record at `date`. `still` is Reduce Motion: a
    /// half-done unit and steady marks, and a scene time that never depends
    /// on when the view happened to redraw.
    ///
    /// - **Running and still:** the scene's key time, so the one frame reads
    ///   (the front record showing its cover, a file under the press).
    /// - **Finished, still or not:** the elapsed time frozen at the finish,
    ///   `q(finishedAt − startedAt)`. That is as fixed as the key time, and it
    ///   is the frame the job actually ended on: the crate that was on screen
    ///   at the finish and the whole picked pile, where the key time would
    ///   hold the first crate and a pile of two or three.
    public func sceneInput(for record: BusyJobRecord, at date: Date, still: Bool) -> BusySceneInput {
        let q = BusySignalTiming.quantized
        let finished = record.finishedAt.map { q(date.timeIntervalSince($0)) }
        let time: TimeInterval
        if let finishedAt = record.finishedAt {
            time = q(finishedAt.timeIntervalSince(record.startedAt))
        } else {
            time = still ? BusyScenes.keyTime(record.kind) : q(date.timeIntervalSince(record.startedAt))
        }
        let unitTime = still ? 0.5 : q(date.timeIntervalSince(record.unitStartedAt))

        let unitFraction: Double
        if finished != nil {
            unitFraction = 1
        } else if still {
            unitFraction = 0.5
        } else {
            unitFraction = min(Self.maxUnitFraction, unitTime / averageUnitDuration(of: record))
        }

        let (markLit, blinking) = mark(of: record, at: date, still: still)
        return BusySceneInput(progress: record.progress, labels: record.labels,
                              time: time, unitTime: unitTime, unitFraction: unitFraction,
                              finished: finished, markLit: markLit,
                              still: still, blinking: blinking)
    }

    /// When a finished record's blink stops on its own: the end of
    /// `pictureBlinkDuration` from its arrival on its screen. Nothing in the
    /// ledger changes at that moment (the record was seen long before), so a
    /// view that ticks for the blink reads this to know when to stop.
    ///
    /// Nil while running, and for an unseen record off its screen: a mini
    /// blinks for as long as it stays unseen, and becoming seen is a change
    /// the ledger publishes.
    public func blinkEnd(of record: BusyJobRecord) -> Date? {
        guard let finishedAt = record.finishedAt else { return nil }
        if record.seenAt == nil && record.screen != screen { return nil }
        return max(finishedAt, screenSince).addingTimeInterval(BusySignalTiming.pictureBlinkDuration)
    }

    // MARK: Private

    private func runningIndex(_ id: BusyJobID) -> Int? {
        records.firstIndex { $0.id == id && $0.isRunning }
    }

    /// When a finished record's screen and its finish were both there to see:
    /// max(finishedAt, screenSince). Nil while running. Only meaningful for a
    /// record on the current screen.
    private func arrival(of record: BusyJobRecord) -> Date? {
        record.finishedAt.map { max($0, screenSince) }
    }

    /// The average unit so far, measured from `progressEpoch` to the last
    /// completed unit; the fallback with nothing completed, or when units
    /// completed so fast the average is not a usable divisor.
    private func averageUnitDuration(of record: BusyJobRecord) -> TimeInterval {
        let completed = record.progress.completed
        guard completed > 0 else { return Self.fallbackUnitDuration }
        let average = record.unitStartedAt.timeIntervalSince(record.progressEpoch) / Double(completed)
        return average.isFinite && average > 0 ? average : Self.fallbackUnitDuration
    }

    /// Whether the finished mark is lit, and whether a blink is still pending.
    ///
    /// - Running: lit (the input's default), no blink.
    /// - Still: steady on.
    /// - Unseen and off its screen (the rail mini): blinks from the finish
    ///   for as long as it stays unseen.
    /// - On its screen: blinks for `pictureBlinkDuration` from its arrival,
    ///   so it blinks when you arrive and not only when the job ended, then
    ///   holds steady.
    private func mark(of record: BusyJobRecord, at date: Date, still: Bool) -> (lit: Bool, blinking: Bool) {
        guard let finishedAt = record.finishedAt, !still else { return (true, false) }
        guard let end = blinkEnd(of: record) else {
            return (BusySignalTiming.blink(date.timeIntervalSince(finishedAt)), true)
        }
        if date < end {
            let sinceArrival = date.timeIntervalSince(max(finishedAt, screenSince))
            return (BusySignalTiming.blink(sinceArrival), true)
        }
        return (true, false)
    }
}
