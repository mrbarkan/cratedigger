#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The ledger's lifecycle and its "seen" rule: what is running, what has
/// finished, when a finished job counts as seen, and when it is retired.
/// Every date is `t0 + n`, never `Date()`, so the rules are tested to the
/// second.
final class BusyLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Lifecycle

    func testCompletedOnItsOwnScreenIsSeenAfterADelayAndRetiredOnLeaving() {
        var l = BusyLedger(screen: .conversion, at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        XCTAssertEqual(l.settle(at: at(10.5)), at(11.5))
        XCTAssertNil(l.record(id)?.seenAt)
        _ = l.settle(at: at(11.5))
        XCTAssertNotNil(l.record(id)?.seenAt)
        XCTAssertEqual(l.picture(on: .conversion)?.id, id, "stays while you stay")
        l.show(.other, at: at(20))
        XCTAssertNil(l.record(id), "leaving retires a seen job")
    }

    func testCompletedOffItsScreenStaysUnseenUntilVisited() {
        var l = BusyLedger(screen: .other, at: t0)
        let id = l.begin(.download, on: .dub, at: at(0))
        l.finish(id, .completed, at: at(10))
        XCTAssertNil(l.settle(at: at(500)), "nothing on the glass can be seen")
        XCTAssertNil(l.record(id)?.seenAt)
        l.show(.scan, at: at(600))
        XCTAssertNotNil(l.record(id), "an unseen job survives screen changes")

        l.show(.dub, at: at(700))
        XCTAssertEqual(l.settle(at: at(700.5)), at(701.5), "seen counts from arrival")
        _ = l.settle(at: at(701.5))
        XCTAssertNotNil(l.record(id)?.seenAt)
    }

    /// A rip ends on DUB and loadFolders flips the glass to SCAN in the same
    /// turn. The rip must stay unseen, so its mini blinks on SCAN.
    func testChainedRipThenScanLeavesRipUnseen() {
        var l = BusyLedger(screen: .dub, at: t0)
        let rip = l.begin(.rip, on: .dub, at: at(0))
        l.finish(rip, .completed, at: at(100))
        let scan = l.begin(.scan, on: .scan, at: at(100))
        l.show(.scan, at: at(100))
        _ = l.settle(at: at(200))
        XCTAssertNil(l.record(rip)?.seenAt)
        XCTAssertNotNil(l.record(rip), "still there to blink on the rail")
        XCTAssertEqual(l.picture(on: .scan)?.id, scan)
        XCTAssertEqual(l.picture(on: .dub)?.id, rip, "one click on the mini shows the finished rip")
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [rip], "scan is on its own screen, so only the rip has a mini")
    }

    func testCancelledAndFailedLeaveNoTrace() {
        var l = BusyLedger(at: t0)
        let a = l.begin(.download, on: .dub, at: at(0)); l.finish(a, .cancelled, at: at(1))
        let b = l.begin(.convert, on: .conversion, at: at(2)); l.finish(b, .failed, at: at(3))
        XCTAssertTrue(l.records.isEmpty)
    }

    func testLateUpdateAfterFinishIsIgnored() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 0, total: 5), at: at(0))
        l.finish(id, .completed, at: at(10))
        l.update(id, progress: BusyProgress(completed: 2, total: 5), at: at(11))
        XCTAssertEqual(l.record(id)?.progress.completed, 0)
        XCTAssertEqual(l.record(id)?.unitStartedAt, at(0))
    }

    func testUnknownIDsAreIgnored() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.scan, on: .scan, at: at(0))
        let stranger = BusyJobID(rawValue: id.rawValue + 100)
        let before = l
        l.update(stranger, progress: BusyProgress(completed: 3), at: at(1))
        l.handOver(stranger, to: .rip, progress: .init(), at: at(1))
        l.finish(stranger, .completed, at: at(1))
        XCTAssertEqual(l, before)
    }

    func testASecondFinishDoesNotMoveTheFirst() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        l.finish(id, .completed, at: at(30))
        l.finish(id, .failed, at: at(31))
        XCTAssertEqual(l.record(id)?.finishedAt, at(10))
    }

    func testIDsAreMonotonic() {
        var l = BusyLedger(at: t0)
        let a = l.begin(.scan, on: .scan, at: at(0))
        let b = l.begin(.scan, on: .scan, at: at(1))     // retires a
        let c = l.begin(.convert, on: .conversion, at: at(2))
        XCTAssertLessThan(a.rawValue, b.rawValue)
        XCTAssertLessThan(b.rawValue, c.rawValue)
    }

    func testUpdateRestartsTheUnitOnlyWhenTheCountMoves() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 0, total: 5), at: at(0))
        l.update(id, progress: BusyProgress(completed: 0, total: 6), at: at(5))
        XCTAssertEqual(l.record(id)?.unitStartedAt, at(0), "a new total is not a new unit")
        XCTAssertEqual(l.record(id)?.progress.total, 6)
        l.update(id, progress: BusyProgress(completed: 1, total: 6), at: at(40))
        XCTAssertEqual(l.record(id)?.unitStartedAt, at(40))
        XCTAssertEqual(l.record(id)?.progressEpoch, at(0), "the epoch only moves on begin and handOver")
    }

    // MARK: Supersede, restart, hand over

    func testBeginSupersedesFinishedOnSameScreenAndRestartsSameKind() {
        var l = BusyLedger(at: t0)
        let oldConvert = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(oldConvert, .completed, at: at(10))
        let finishedRip = l.begin(.rip, on: .dub, at: at(11))
        l.finish(finishedRip, .completed, at: at(20))
        let firstScan = l.begin(.scan, on: .scan, at: at(21))
        let download = l.begin(.download, on: .dub, at: at(22))

        XCTAssertNil(l.record(finishedRip), "a new job on DUB supersedes the finished rip")
        XCTAssertNotNil(l.record(oldConvert), "another screen's finished job is untouched")
        XCTAssertNotNil(l.record(firstScan))

        let secondScan = l.begin(.scan, on: .scan, at: at(30))
        XCTAssertNil(l.record(firstScan), "a second dig restarts the scan")
        XCTAssertEqual(l.record(secondScan)?.startedAt, at(30))
        XCTAssertNotNil(l.record(download))

        let transfer = l.begin(.transfer, on: .conversion, at: at(31))
        XCTAssertNil(l.record(oldConvert), "any new job supersedes a finished one on its screen")
        let rip = l.begin(.rip, on: .dub, at: at(32))
        XCTAssertNotNil(l.record(download), "a running job of another kind is not a restart")
        XCTAssertEqual(l.records.map(\.id), [download, secondScan, transfer, rip], "start order")
    }

    func testHandOverKeepsIdentityAndStart() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.secureRead, on: .dub, labels: BusyLabels(target: "flac"),
                         progress: BusyProgress(completed: 0, total: 4), at: at(0))
        l.handOver(id, to: .rip, progress: BusyProgress(completed: 0, total: 4), at: at(1200))
        let record = l.record(id)
        XCTAssertEqual(record?.kind, .rip)
        XCTAssertEqual(record?.startedAt, at(0))
        XCTAssertEqual(record?.unitStartedAt, at(1200))
        XCTAssertEqual(record?.progressEpoch, at(1200))
        XCTAssertEqual(record?.labels.target, "FLAC")
        XCTAssertTrue(record?.isRunning ?? false, "no finished state between the two")
        XCTAssertEqual(l.records.count, 1)
        XCTAssertEqual(l.running(.rip, on: .dub)?.id, id)
        XCTAssertNil(l.running(.secureRead, on: .dub))
    }

    func testHandOverIgnoresAFinishedRecord() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.secureRead, on: .dub, at: at(0))
        l.finish(id, .completed, at: at(10))
        l.handOver(id, to: .rip, progress: .init(), at: at(11))
        XCTAssertEqual(l.record(id)?.kind, .secureRead)
    }

    // MARK: Pictures and screens

    func testPicturePrefersRunningThenNewest() {
        var l = BusyLedger(at: t0)
        XCTAssertNil(l.picture(on: .dub))
        let rip = l.begin(.rip, on: .dub, at: at(0))
        XCTAssertEqual(l.picture(on: .dub)?.id, rip)
        l.finish(rip, .completed, at: at(10))
        XCTAssertEqual(l.picture(on: .dub)?.id, rip, "a finished job still draws")
        XCTAssertNil(l.running(.rip, on: .dub))

        // Two running on DUB at once (the BUSY guards make this rare, but
        // nothing in the ledger forbids it): the newer one draws.
        let download = l.begin(.download, on: .dub, at: at(20))
        let secure = l.begin(.secureRead, on: .dub, at: at(21))
        XCTAssertEqual(l.picture(on: .dub)?.id, secure)
        l.finish(secure, .completed, at: at(30))
        XCTAssertEqual(l.picture(on: .dub)?.id, download, "running beats a newer finished job")
        l.finish(download, .completed, at: at(31))
        XCTAssertEqual(l.picture(on: .dub)?.id, secure, "newest finished, by start, not by finish")
        XCTAssertNil(l.picture(on: .scan))
    }

    func testNoOpShowDoesNotRestartTheSeenTimer() {
        var l = BusyLedger(screen: .other, at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        l.show(.conversion, at: at(20))
        l.show(.conversion, at: at(21))
        XCTAssertEqual(l.screenSince, at(20))
        XCTAssertEqual(l.settle(at: at(21)), at(21.5))
        _ = l.settle(at: at(21.5))
        XCTAssertNotNil(l.record(id)?.seenAt)
    }

    func testShowRetiresOnlySeenRecordsOffTheNewScreen() {
        var l = BusyLedger(screen: .dub, at: t0)
        let rip = l.begin(.rip, on: .dub, at: at(0))
        l.finish(rip, .completed, at: at(1))
        _ = l.settle(at: at(5))
        let convert = l.begin(.convert, on: .conversion, at: at(6))
        l.finish(convert, .completed, at: at(7))
        let scan = l.begin(.scan, on: .scan, at: at(8))
        l.show(.scan, at: at(9))
        XCTAssertNil(l.record(rip), "seen and left")
        XCTAssertNotNil(l.record(convert), "unseen")
        XCTAssertNotNil(l.record(scan), "running")
    }

    // MARK: Settle

    func testSettleNeverReturnsAPastDate() {
        var l = BusyLedger(screen: .dub, at: t0)
        let id = l.begin(.rip, on: .dub, at: at(0))
        XCTAssertNil(l.settle(at: at(5)), "a running job needs no settling")
        l.finish(id, .completed, at: at(10))
        // Seen at 11.5; the blink window ends at 18.
        var date = at(10)
        var wakes: [Date] = []
        while let next = l.settle(at: date) {
            XCTAssertGreaterThan(next, date)
            wakes.append(next)
            date = next
        }
        XCTAssertEqual(wakes, [at(11.5), at(18)])
        XCTAssertNotNil(l.record(id)?.seenAt)
        XCTAssertNil(l.settle(at: at(19)), "blinkEnd + 1: nothing pending")
        XCTAssertNil(l.settle(at: at(18)), "the blink end itself is not after the date")
        for s in stride(from: 10.0, through: 30, by: 0.25) {
            var copy = l
            if let next = copy.settle(at: at(s)) { XCTAssertGreaterThan(next, at(s), "\(s)") }
        }
    }

    func testSettleWakesForTheEarliestPendingRecord() {
        var l = BusyLedger(screen: .other, at: t0)
        let rip = l.begin(.rip, on: .dub, at: at(0))
        l.finish(rip, .completed, at: at(10))
        let download = l.begin(.download, on: .dub, at: at(11))
        l.finish(download, .completed, at: at(12))
        XCTAssertNil(l.record(rip), "the download superseded the rip")
        l.show(.dub, at: at(20))
        XCTAssertEqual(l.settle(at: at(20)), at(21.5))
    }

    // MARK: Scene inputs

    func testSceneTimeIsQuantizedAndFreezesAtFinish() {
        var l = BusyLedger(screen: .scan, at: t0)
        let id = l.begin(.scan, on: .scan, at: at(0))
        let running = l.sceneInput(for: l.record(id)!, at: at(3.3), still: false)
        XCTAssertEqual(running.time, 3.25)
        XCTAssertEqual(running.unitTime, 3.25)
        XCTAssertNil(running.finished)
        XCTAssertFalse(running.blinking)

        l.finish(id, .completed, at: at(10.06))
        let finished = l.sceneInput(for: l.record(id)!, at: at(12.3), still: false)
        XCTAssertEqual(finished.time, 10, "frozen at the finish")
        XCTAssertEqual(finished.finished, 2.125)
        XCTAssertEqual(finished.unitFraction, 1)
        XCTAssertEqual(l.sceneInput(for: l.record(id)!, at: at(50), still: false).time, 10)
    }

    func testUnitFractionEstimatesFromAverageAndCaps() {
        var l = BusyLedger(screen: .dub, at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 0, total: 5), at: at(0))
        func fraction(_ s: TimeInterval) -> Double {
            l.sceneInput(for: l.record(id)!, at: at(s), still: false).unitFraction
        }
        XCTAssertEqual(fraction(0), 0)
        XCTAssertEqual(fraction(15), 0.5, accuracy: 1e-9, "30 s fallback with nothing completed")
        XCTAssertEqual(fraction(100), 0.95, "capped")

        l.update(id, progress: BusyProgress(completed: 2, total: 5), at: at(120))
        XCTAssertEqual(fraction(120), 0)
        XCTAssertEqual(fraction(150), 0.5, accuracy: 1e-9, "60 s average")
        XCTAssertEqual(fraction(165), 0.75, accuracy: 1e-9)
        XCTAssertEqual(fraction(1000), 0.95, "capped")
    }

    func testUnitFractionSurvivesAnInstantFirstUnit() {
        var l = BusyLedger(screen: .dub, at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 0, total: 5), at: at(0))
        l.update(id, progress: BusyProgress(completed: 3, total: 5), at: at(0))
        for s in [0.0, 1, 30] {
            let u = l.sceneInput(for: l.record(id)!, at: at(s), still: false).unitFraction
            XCTAssertTrue(u.isFinite && u >= 0 && u <= 0.95, "\(s): \(u)")
        }
    }

    func testHandOverRestartsTheUnitAverage() {
        var l = BusyLedger(screen: .dub, at: t0)
        let id = l.begin(.secureRead, on: .dub, progress: BusyProgress(completed: 0, total: 4), at: at(0))
        l.handOver(id, to: .rip, progress: BusyProgress(completed: 0, total: 4), at: at(1200))
        l.update(id, progress: BusyProgress(completed: 1, total: 4), at: at(1260))
        let input = l.sceneInput(for: l.record(id)!, at: at(1290), still: false)
        XCTAssertEqual(input.unitFraction, 0.5, accuracy: 1e-9, "60 s average, not 1260 s")
        XCTAssertEqual(input.time, 1290, "scene time still runs from the read's start")
    }

    func testStillInputIsSteadyAndUsesKeyTime() {
        var l = BusyLedger(screen: .dub, at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 1, total: 5), at: at(0))
        let inputs = [0.0, 0.01, 7.3, 900].map { l.sceneInput(for: l.record(id)!, at: at($0), still: true) }
        for input in inputs {
            XCTAssertEqual(input.time, BusyScenes.keyTime(.rip))
            XCTAssertEqual(input.unitTime, 0.5)
            XCTAssertEqual(input.unitFraction, 0.5)
            XCTAssertTrue(input.still)
            XCTAssertFalse(input.blinking)
            XCTAssertEqual(input, inputs[0], "the same frame at any wall time")
        }

        l.finish(id, .completed, at: at(1000))
        let finished = l.sceneInput(for: l.record(id)!, at: at(1000.3), still: true)
        XCTAssertTrue(finished.markLit, "finished marks are steady under Reduce Motion")
        XCTAssertFalse(finished.blinking)
        XCTAssertEqual(finished.unitFraction, 1)
    }

    /// A finished still holds the frame the job ended on, not the key frame:
    /// a scan that ran into its fourth crate keeps that crate and the whole
    /// pile, where the key time would show crate A–F and a pile of two or
    /// three. Still fixed: any wall time gives the same input.
    func testFinishedStillFreezesAtTheFinishNotTheKeyTime() {
        var l = BusyLedger(screen: .scan, at: t0)
        let id = l.begin(.scan, on: .scan, progress: BusyProgress(completed: 900, total: 1000), at: at(0))
        l.finish(id, .completed, at: at(19.06))
        let inputs = [19.5, 40, 900].map { l.sceneInput(for: l.record(id)!, at: at($0), still: true) }
        for input in inputs {
            XCTAssertEqual(input.time, 19, "q(finishedAt − startedAt)")
            XCTAssertTrue(input.still)
            XCTAssertTrue(input.markLit)
            XCTAssertEqual(input.unitTime, 0.5)
        }
        XCTAssertEqual(ScanScene.picture(inputs[0]), ScanScene.picture(inputs[2]), "the same frame at any wall time")
        XCTAssertNotEqual(inputs[0].time, BusyScenes.keyTime(.scan))
        XCTAssertEqual(inputs[0].time, l.sceneInput(for: l.record(id)!, at: at(40), still: false).time,
                       "the same frozen time as with motion on")

        // The picture it draws: the fourth crate (T–Z) and a fuller pile
        // than the key frame's.
        let held = ScanScene.picture(inputs[0])
        var key = inputs[0]
        key.time = BusyScenes.keyTime(.scan)
        let keyFrame = ScanScene.picture(key)
        XCTAssertTrue(held.shapes.contains { if case .text("T–Z", _, _, _, _) = $0 { return true }; return false })
        XCTAssertGreaterThan(Self.pileRecords(held), Self.pileRecords(keyFrame))
    }

    /// The scan's picked-pile records: closed, glass-filled quads centred on
    /// the pile.
    static func pileRecords(_ d: BusyDrawing) -> Int {
        d.shapes.filter {
            guard case let .path(points, true, .foreground?, .background?) = $0, points.count == 4 else { return false }
            return abs(points.map(\.x).reduce(0, +) / 4 - ScanScene.pileX) < 0.001
        }.count
    }

    func testUnseenMiniBlinksFromTheFinish() {
        var l = BusyLedger(screen: .other, at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        func input(_ s: TimeInterval) -> BusySceneInput { l.sceneInput(for: l.record(id)!, at: at(s), still: false) }
        XCTAssertTrue(input(10).markLit)
        XCTAssertFalse(input(10.5).markLit)
        XCTAssertTrue(input(11).markLit)
        XCTAssertTrue(input(5000).blinking, "an unseen mini blinks until visited")
    }

    func testPictureBlinkCountsFromArrivalNotFromFinish() {
        var l = BusyLedger(screen: .other, at: t0)
        let id = l.begin(.rip, on: .dub, at: at(0))
        l.finish(id, .completed, at: at(10))
        l.show(.dub, at: at(100))
        func input(_ s: TimeInterval) -> BusySceneInput { l.sceneInput(for: l.record(id)!, at: at(s), still: false) }
        XCTAssertTrue(input(100).markLit)
        XCTAssertFalse(input(100.5).markLit)
        XCTAssertTrue(input(101).markLit)
        XCTAssertFalse(input(107.5).markLit)
        XCTAssertTrue(input(107.9).blinking)
        _ = l.settle(at: at(102))
        XCTAssertNotNil(l.record(id)?.seenAt)
        for s in [108.0, 108.5, 109, 500] {
            XCTAssertTrue(input(s).markLit, "steady after the window: \(s)")
            XCTAssertFalse(input(s).blinking, "\(s)")
        }
        XCTAssertNil(l.settle(at: at(109)))
    }

    func testFinishedOnItsOwnScreenBlinksFromTheFinish() {
        var l = BusyLedger(screen: .conversion, at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        func input(_ s: TimeInterval) -> BusySceneInput { l.sceneInput(for: l.record(id)!, at: at(s), still: false) }
        XCTAssertFalse(input(10.5).markLit)
        XCTAssertTrue(input(17.9).blinking)
        XCTAssertFalse(input(18).blinking)
        XCTAssertTrue(input(18.5).markLit)
    }

    /// The picture's blink stops on its own, with nothing in the ledger
    /// changing (it was seen long before), so the view needs this date to
    /// pause its timeline. It must agree with `sceneInput`'s `blinking`.
    func testBlinkEndIsWhereThePictureStopsBlinking() {
        var l = BusyLedger(screen: .other, at: t0)
        let id = l.begin(.rip, on: .dub, at: at(0))
        XCTAssertNil(l.blinkEnd(of: l.record(id)!), "a running job has no finished blink")
        l.finish(id, .completed, at: at(10))
        XCTAssertNil(l.blinkEnd(of: l.record(id)!), "an unseen mini blinks until it is seen")

        l.show(.dub, at: at(100))
        let end = try! XCTUnwrap(l.blinkEnd(of: l.record(id)!))
        XCTAssertEqual(end, at(108), "counted from arrival")
        func input(_ s: TimeInterval) -> BusySceneInput { l.sceneInput(for: l.record(id)!, at: at(s), still: false) }
        XCTAssertTrue(input(107.9).blinking)
        XCTAssertFalse(input(108).blinking)

        _ = l.settle(at: at(102))
        XCTAssertEqual(l.blinkEnd(of: l.record(id)!), at(108), "being seen does not move it")
    }

    func testSceneInputCarriesProgressAndLabels() {
        var l = BusyLedger(at: t0)
        let progress = BusyProgress(completed: 2, total: 9, lossless: true)
        let id = l.begin(.convert, on: .conversion, labels: BusyLabels(source: "wav", target: "flac"),
                         progress: progress, at: at(0))
        let input = l.sceneInput(for: l.record(id)!, at: at(1), still: false)
        XCTAssertEqual(input.progress, progress)
        XCTAssertEqual(input.labels, BusyLabels(source: "WAV", target: "FLAC"))
        XCTAssertTrue(input.markLit, "a running input matches BusySceneInput's default")
    }
}
#endif
