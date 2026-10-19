#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The invariants every Busy Signals scene owes the renderer, whatever it
/// draws: it stays inside its unit space, it is a pure function of its input
/// (so the 8 fps grid really does mean "no redraw inside a step"), and it
/// never strokes in the background ink. Written before the scenes so each one
/// is bound by them the moment it lands; the two that only make sense for a
/// real picture skip the kinds that are still stubs.
///
/// The shared mini glyphs are pinned here too, because every mini draws them.
final class BusySceneTests: XCTestCase {
    // MARK: - Inputs

    /// One scene input, built the way `BusyLedger.sceneInput` would build it
    /// for a raw (unquantized) `time`.
    ///
    /// `fraction` is spread over ten units. For a secure read it becomes a
    /// read ten tracks long, split into its two passes, with 0.9 standing in
    /// for the retry phase (rereads 40, past the six-cell cap). For a convert
    /// it picks lossless from 0.5 up. Labels are given whenever the fraction
    /// is, so the nil-label path is covered by the indeterminate state.
    static func input(_ kind: BusyJobKind, fraction: Double?, time: TimeInterval,
                      finished: TimeInterval? = nil, lit: Bool = true, still: Bool = false) -> BusySceneInput {
        let q = BusySignalTiming.quantized
        var progress = BusyProgress(completed: fraction.map { Int(($0 * 10).rounded(.down)) } ?? 3,
                                    total: fraction == nil ? nil : 10,
                                    lossless: (fraction ?? 0) >= 0.5)
        if kind == .secureRead, let fraction {
            progress.secure = secure(fraction)
        }
        let labels = fraction == nil ? BusyLabels() : BusyLabels(source: "FLAC", target: "MP3")

        if still {
            // The ledger's rule: the key time while running, the frozen
            // elapsed time once finished.
            return BusySceneInput(progress: progress, labels: labels,
                                  time: finished == nil ? BusyScenes.keyTime(kind) : q(time),
                                  unitTime: 0.5, unitFraction: finished == nil ? 0.5 : 1,
                                  finished: finished.map(q), markLit: true, still: true, blinking: false)
        }
        let unitTime = q(time.truncatingRemainder(dividingBy: 1))
        return BusySceneInput(progress: progress, labels: labels,
                              time: q(time), unitTime: unitTime,
                              unitFraction: finished == nil ? min(0.95, q(time) / 4) : 1,
                              finished: finished.map(q), markLit: lit,
                              still: false, blinking: finished != nil)
    }

    /// A ten-track secure read at `fraction` of the disc.
    static func secure(_ fraction: Double) -> BusySecureRead {
        if fraction == 0.9 {
            return BusySecureRead(SecureDiscRip.Progress(
                trackOrdinal: 9, trackCount: 10,
                track: .init(trackNumber: 9, phase: .retry, fraction: 0.5, rereads: 40),
                discRereads: 40))
        }
        let position = fraction * 10
        let ordinal = min(Int(position.rounded(.down)), 9) + 1
        let within = position - Double(ordinal - 1)
        let phase: SecureRipEngine.Phase = within < 0.5 ? .pass1 : .pass2
        let phaseFraction = phase == .pass1 ? within * 2 : (within - 0.5) * 2
        return BusySecureRead(SecureDiscRip.Progress(
            trackOrdinal: ordinal, trackCount: 10,
            track: .init(trackNumber: ordinal, phase: phase, fraction: phaseFraction, rereads: 0),
            discRereads: 0))
    }

    static let fractions: [Double?] = [0, 0.1, 0.5, 0.9, 1, nil]
    static let times: [TimeInterval] = [0, 0.7, 3.3, 19.9]

    /// Every state a scene must draw sanely: running at each fraction,
    /// finished with the mark lit and unlit, the still key frame and the
    /// finished still, each at every time.
    static func matrix(_ kind: BusyJobKind) -> [BusySceneInput] {
        times.flatMap { time -> [BusySceneInput] in
            fractions.map { input(kind, fraction: $0, time: time) } + [
                input(kind, fraction: 1, time: time, finished: 2, lit: true),
                input(kind, fraction: 1, time: time, finished: 2.5, lit: false),
                input(kind, fraction: 0.5, time: time, still: true),
                input(kind, fraction: 1, time: time, finished: 2, still: true),
            ]
        }
    }

    /// Whether a kind's picture is still the Task 6 stub. The tests that
    /// compare two real frames skip these until the scene lands.
    static func isStub(_ kind: BusyJobKind) -> Bool {
        BusyScenes.picture(kind, input(kind, fraction: 0.5, time: 1)).shapes.isEmpty
    }

    // MARK: - Generic invariants

    /// The one exception is the scan's crate swap, which slides crates
    /// sideways past the scene's edges on purpose and leaves the canvas edge
    /// to cut them, as the sketch did. It is held inside the scene's height,
    /// and every other frame of the scan is held inside the scene outright.
    func testPicturesStayInsideSceneSpace() {
        var swaps = 0
        for kind in BusyJobKind.allCases {
            for input in Self.matrix(kind) {
                let d = BusyScenes.picture(kind, input)
                XCTAssertEqual(d.size, BusyDrawing.sceneSize, "\(kind)")
                if kind == .scan, ScanScene.moment(input.time).swap != nil, !input.isFinished {
                    swaps += 1
                    XCTAssertTrue(Self.isInside(d, horizontally: false), "\(kind) \(input): \(d.bounds)")
                } else {
                    XCTAssertTrue(Self.isInside(d), "\(kind) \(input): \(d.bounds)")
                }
            }
        }
        XCTAssertGreaterThan(swaps, 0, "the matrix never lands in a crate swap; the exception is untested")
    }

    func testMinisStayInsideMiniSpace() {
        for kind in BusyJobKind.allCases {
            for input in Self.matrix(kind) {
                let d = BusyScenes.mini(kind, input)
                XCTAssertEqual(d.size, BusyDrawing.miniSize, "\(kind)")
                XCTAssertTrue(Self.isInside(d), "\(kind) \(input): \(d.bounds)")
            }
        }
    }

    func testSameInputSameDrawing() {
        for kind in BusyJobKind.allCases {
            for input in Self.matrix(kind) {
                XCTAssertEqual(BusyScenes.picture(kind, input), BusyScenes.picture(kind, input), "\(kind)")
                XCTAssertEqual(BusyScenes.mini(kind, input), BusyScenes.mini(kind, input), "\(kind)")
            }
        }
    }

    func testTimesInsideOneStepDrawTheSame() {
        for kind in BusyJobKind.allCases {
            for fraction in Self.fractions {
                // 3.30 and 3.36 both quantize to 3.25.
                let a = Self.input(kind, fraction: fraction, time: 3.30)
                let b = Self.input(kind, fraction: fraction, time: 3.36)
                XCTAssertEqual(a, b, "\(kind)")
                XCTAssertEqual(a.time, 3.25)
                XCTAssertEqual(BusyScenes.picture(kind, a), BusyScenes.picture(kind, b), "\(kind)")
                XCTAssertEqual(BusyScenes.mini(kind, a), BusyScenes.mini(kind, b), "\(kind)")
            }
        }
    }

    /// The same, through the production path: `BusyLedger.sceneInput` must
    /// itself put two wall times inside one step on the same input, so the
    /// scenes' purity really does mean no redraw inside a step.
    func testLedgerPutsTimesInsideOneStepOnTheSameInput() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for kind in BusyJobKind.allCases {
            var ledger = BusyLedger(screen: kind.defaultScreen, at: start)
            let id = ledger.begin(kind, on: kind.defaultScreen,
                                  labels: BusyLabels(source: "FLAC", target: "MP3"),
                                  progress: BusyProgress(completed: 2, total: 10), at: start)
            guard let record = ledger.record(id) else { XCTFail("\(kind) not recorded"); continue }
            let a = ledger.sceneInput(for: record, at: start.addingTimeInterval(3.30), still: false)
            let b = ledger.sceneInput(for: record, at: start.addingTimeInterval(3.36), still: false)
            XCTAssertEqual(a, b, "\(kind)")
            XCTAssertEqual(a.time, 3.25, "\(kind)")
            XCTAssertEqual(a.unitTime, 3.25, "\(kind)")
            XCTAssertEqual(BusyScenes.picture(kind, a), BusyScenes.picture(kind, b), "\(kind)")
            XCTAssertEqual(BusyScenes.mini(kind, a), BusyScenes.mini(kind, b), "\(kind)")
        }
    }

    func testStillFrameDrawsTheSameAtAnyWallTime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for kind in BusyJobKind.allCases {
            var ledger = BusyLedger(screen: kind.defaultScreen, at: start)
            let id = ledger.begin(kind, on: kind.defaultScreen,
                                  progress: BusyProgress(completed: 2, total: 10), at: start)
            guard let record = ledger.record(id) else { XCTFail("\(kind) not recorded"); continue }
            let early = ledger.sceneInput(for: record, at: start.addingTimeInterval(1.3), still: true)
            let late = ledger.sceneInput(for: record, at: start.addingTimeInterval(97.7), still: true)
            XCTAssertEqual(early.time, BusyScenes.keyTime(kind), "\(kind)")
            XCTAssertEqual(BusyScenes.picture(kind, early), BusyScenes.picture(kind, late), "\(kind)")
            XCTAssertEqual(BusyScenes.mini(kind, early), BusyScenes.mini(kind, late), "\(kind)")
        }
    }

    func testBackgroundInkOnlyEverFills() {
        for kind in BusyJobKind.allCases {
            for input in Self.matrix(kind) {
                for d in [BusyScenes.picture(kind, input), BusyScenes.mini(kind, input)] {
                    for shape in d.shapes {
                        XCTAssertFalse(Self.strokesInBackground(shape), "\(kind) \(input): \(shape)")
                    }
                }
            }
        }
    }

    func testFinishedDiffersFromRunning() throws {
        var undrawn: [BusyJobKind] = []
        var failed = false
        for kind in BusyJobKind.allCases {
            guard !Self.isStub(kind) else { undrawn.append(kind); continue }
            for time in Self.times {
                let running = Self.input(kind, fraction: 1, time: time)
                let finished = Self.input(kind, fraction: 1, time: time, finished: 2, lit: true)
                if BusyScenes.picture(kind, running) == BusyScenes.picture(kind, finished) {
                    XCTFail("\(kind) picture at \(time): finished draws like running"); failed = true
                }
                if BusyScenes.mini(kind, running) == BusyScenes.mini(kind, finished) {
                    XCTFail("\(kind) mini at \(time): finished draws like running"); failed = true
                }
            }
        }
        // Skip only when every drawn kind passed, so a skip can never hide a
        // failure, and a kind that lands is checked even while others wait.
        try XCTSkipIf(!failed && !undrawn.isEmpty, "\(undrawn) not drawn yet")
    }

    func testMarkLitOnAndOffDiffer() throws {
        var undrawn: [BusyJobKind] = []
        var failed = false
        for kind in BusyJobKind.allCases {
            guard !Self.isStub(kind) else { undrawn.append(kind); continue }
            for time in Self.times {
                let lit = Self.input(kind, fraction: 1, time: time, finished: 2, lit: true)
                let unlit = Self.input(kind, fraction: 1, time: time, finished: 2, lit: false)
                // The finished cassette has no blinking element in the
                // approved look (a steady hot DONE, html:702), so its picture
                // is rightly the same either way. Its mini still blinks.
                if kind != .download, BusyScenes.picture(kind, lit) == BusyScenes.picture(kind, unlit) {
                    XCTFail("\(kind) picture at \(time): the mark does not blink"); failed = true
                }
                if BusyScenes.mini(kind, lit) == BusyScenes.mini(kind, unlit) {
                    XCTFail("\(kind) mini at \(time): the destination does not blink"); failed = true
                }
            }
        }
        try XCTSkipIf(!failed && !undrawn.isEmpty, "\(undrawn) not drawn yet")
    }

    // MARK: - Shared mini glyphs

    func testMiniTrackLightsDashesWithProgress() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        BusyGlyphs.miniTrack(&d, Self.input(.convert, fraction: 0.5, time: 1.3))
        XCTAssertEqual(Self.lines(in: d, .cool), 4)
        XCTAssertEqual(Self.lines(in: d, .dim), 4)
        XCTAssertEqual(Self.lines(in: d, .hot), 1, "one packet walking while running")
        XCTAssertTrue(Self.isInside(d))
    }

    func testMiniTrackLightsNothingWithoutAFraction() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        BusyGlyphs.miniTrack(&d, Self.input(.scan, fraction: nil, time: 1.3))
        XCTAssertEqual(Self.lines(in: d, .cool), 0)
        XCTAssertEqual(Self.lines(in: d, .dim), 8)
        XCTAssertEqual(Self.lines(in: d, .hot), 1)
    }

    func testMiniTrackIsFullAndStillWhenFinished() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        BusyGlyphs.miniTrack(&d, Self.input(.scan, fraction: 0.5, time: 1.3, finished: 1))
        XCTAssertEqual(Self.lines(in: d, .cool), 8)
        XCTAssertEqual(Self.lines(in: d, .hot), 0, "no packet once finished")
    }

    func testMiniTrackPacketWalksWithTheStep() {
        func packetX(_ time: TimeInterval) -> CGFloat? {
            var d = BusyDrawing(size: BusyDrawing.miniSize)
            BusyGlyphs.miniTrack(&d, Self.input(.rip, fraction: 0.1, time: time))
            for case let .line(from, _, .hot, _) in d.shapes { return from.x }
            return nil
        }
        XCTAssertEqual(packetX(0), 15.5)
        XCTAssertEqual(packetX(0.125), 15.5 + 8.25)
        XCTAssertEqual(packetX(1.0), 15.5, "step 8 wraps back to the first dash")
    }

    func testMiniEndInkIsHotOnlyWhenFinishedAndLit() {
        XCTAssertEqual(BusyGlyphs.miniEndInk(Self.input(.rip, fraction: 1, time: 3, finished: 1, lit: true)), .hot)
        XCTAssertEqual(BusyGlyphs.miniEndInk(Self.input(.rip, fraction: 1, time: 3, finished: 1, lit: false)), .foreground)
        XCTAssertEqual(BusyGlyphs.miniEndInk(Self.input(.rip, fraction: 0.5, time: 3)), .foreground,
                       "a running job's mark defaults to lit, but it is not finished")
        XCTAssertEqual(BusyGlyphs.miniEndInk(Self.input(.rip, fraction: 1, time: 3, finished: 1, still: true)), .hot,
                       "Reduce Motion holds an unseen destination steady hot")
    }

    // MARK: - Shared picture glyphs

    func testNoteGlyphsScaleAboutTheirHead() {
        var single = BusyDrawing(size: BusyDrawing.sceneSize)
        BusyGlyphs.note(&single, x: 100, y: 50, kind: 0, ink: .cool, scale: 1)
        XCTAssertEqual(single.shapes.count, 3, "head, stem, flag")
        XCTAssertEqual(single.shapes.first, .ellipse(center: CGPoint(x: 100, y: 50),
                                                     radii: CGSize(width: 2.8, height: 2),
                                                     rotation: -0.35, fill: .cool))
        XCTAssertEqual(single.inks, [.cool])

        var pair = BusyDrawing(size: BusyDrawing.sceneSize)
        BusyGlyphs.note(&pair, x: 100, y: 50, kind: 1, ink: .cool, scale: 0.6)
        XCTAssertEqual(pair.shapes.count, 5, "two heads, two stems, a beam")
        guard case let .line(from, to, _, weight) = pair.shapes.last else { return XCTFail("no beam") }
        XCTAssertEqual(from.x, 100 + 2.5 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(from.y, 50 - 10 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(to.x, 100 + 9 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(weight, 2.2 * 0.6, accuracy: 1e-9, "the beam is 2.2× a stem, scaled with the glyph")
        // The whole glyph sits up and to the right of its head, inside 10 units.
        XCTAssertLessThan(pair.bounds.maxX, 100 + 10)
        XCTAssertGreaterThan(pair.bounds.minY, 50 - 10)
    }

    func testDiscDrawsItsRingsGroovesAndAHotIndex() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        BusyGlyphs.disc(&d, cx: 50, cy: 50, radius: 36, angle: 0)
        XCTAssertEqual(d.shapes.count, 9, "four rings, four groove arcs, one index line")
        XCTAssertEqual(d.bounds, CGRect(x: 14, y: 14, width: 72, height: 72))
        guard case let .line(from, to, .hot, _) = d.shapes.last else { return XCTFail("no hot index") }
        XCTAssertEqual(from, CGPoint(x: 55, y: 50))
        XCTAssertEqual(to, CGPoint(x: 61, y: 50))
    }

    // MARK: - Cadence

    func testCadenceTicksTwicePerStepRunningAndPausesWhenStillOrSettled() {
        XCTAssertEqual(BusySignalTiming.cadence(Self.input(.rip, fraction: 0.5, time: 1)), 1.0 / 16)
        XCTAssertEqual(BusySignalTiming.cadence(Self.input(.rip, fraction: 1, time: 1, finished: 1)), 1.0 / 8,
                       "a pending blink ticks at the step rate")
        XCTAssertNil(BusySignalTiming.cadence(Self.input(.rip, fraction: 0.5, time: 1, still: true)))
        var settled = Self.input(.rip, fraction: 1, time: 1, finished: 20)
        settled.blinking = false
        XCTAssertNil(BusySignalTiming.cadence(settled), "a finished, settled picture never ticks")
    }

    // MARK: - Helpers

    /// Inside its unit space, allowing half a unit for round caps; an empty
    /// drawing (a stub picture) trivially is.
    /// With `horizontally` false only the vertical extent is checked.
    static func isInside(_ d: BusyDrawing, horizontally: Bool = true) -> Bool {
        guard !d.shapes.isEmpty else { return true }
        let box = CGRect(origin: .zero, size: d.size).insetBy(dx: -0.5, dy: -0.5)
        let bounds = d.bounds
        guard horizontally else { return bounds.minY >= box.minY && bounds.maxY <= box.maxY }
        return box.contains(bounds)
    }

    static func lines(in d: BusyDrawing, _ ink: BusyInk) -> Int {
        d.shapes.filter {
            if case let .line(_, _, lineInk, _) = $0 { return lineInk == ink }
            return false
        }.count
    }

    /// `.background` is the glass itself: an occluding fill only. Stroked or
    /// written in it, a shape would cut a dark line through whatever is under
    /// it, and on a theme whose surface is not black it would show.
    static func strokesInBackground(_ shape: BusyShape) -> Bool {
        switch shape {
        case let .line(_, _, ink, _), let .arc(_, _, _, _, ink),
             let .quadCurve(_, _, _, ink), let .text(_, _, _, _, ink):
            return ink == .background
        case let .path(_, _, stroke, _), let .circle(_, _, stroke, _),
             let .rect(_, stroke, _), let .roundedRect(_, _, stroke, _):
            return stroke == .background
        case .ellipse, .clipBegin, .clipEnd:
            return false
        }
    }
}
#endif
