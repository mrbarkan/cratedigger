#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The scan scene's own invariants, each one a piece of the user's feedback
/// on the sketch: a camera high enough that no record's bottom edge shows, a
/// picked pile of crate-sized records, crates that keep cycling A–F to T–Z
/// (and hold still at the finish), and a mini whose fallen record stays in
/// its crate.
final class ScanSceneTests: XCTestCase {
    // MARK: - Inputs

    static func input(time: TimeInterval, finished: Bool = false, lit: Bool = true) -> BusySceneInput {
        BusySceneInput(progress: BusyProgress(completed: 5, total: 10),
                       time: time, unitTime: 0, unitFraction: 0,
                       finished: finished ? 1 : nil, markLit: lit,
                       still: false, blinking: finished)
    }

    static func picture(_ time: TimeInterval, finished: Bool = false, lit: Bool = true) -> BusyDrawing {
        ScanScene.picture(input(time: time, finished: finished, lit: lit))
    }

    /// Every 1/8 s step of one crate's flipping, plus one finished frame.
    static let flippingTimes: [TimeInterval] = (0..<36).map { Double($0) / 8 }

    // MARK: - Picture

    func testRecordBottomsAreHiddenBehindTheFrontWall() {
        let wall = CGRect(x: ScanScene.crateCentre - 44, y: 72, width: 88, height: 20)
        let drawings = Self.flippingTimes.map { Self.picture($0) } + [Self.picture(6, finished: true)]
        var records = 0
        for (index, d) in drawings.enumerated() {
            guard let wallIndex = d.shapes.firstIndex(of: .rect(wall, stroke: .foreground, fill: .background)) else {
                XCTFail("frame \(index): no front wall at \(wall)"); continue
            }
            let before = d.shapes[..<wallIndex]
            for shape in before {
                guard let box = BusyDrawing.box(of: shape) else { continue }
                XCTAssertLessThanOrEqual(box.maxY, ScanScene.front + 4 + 1e-9,
                                         "frame \(index): \(shape) reaches below the wall's top")
                switch shape {
                case .rect(_, _, .background?), .path(_, true, _, .background?): records += 1
                default: break
                }
            }
        }
        // The check above must have had records to check: the back ones still
        // standing and the front one, in every frame but the spent crate's.
        XCTAssertGreaterThan(records, 36, "records drawn behind the wall")
    }

    func testRecordBottomsAreHiddenInBothCratesOfASwap() {
        // The four swap steps of the first crate: two crates on the glass,
        // each with its own wall at its own cx. Each crate's shapes run from
        // its dim back rim to its wall, and nothing in that run may reach
        // below the wall's top.
        for step in 36..<40 {
            let time = Double(step) / 8
            guard let u = ScanScene.moment(time).swap else {
                XCTFail("step \(step) is not a swap"); continue
            }
            let d = Self.picture(time)
            let crates: [(name: String, cx: CGFloat, records: Int)] = [
                ("outgoing", ScanScene.crateCentre - u * ScanScene.swapDistance, 0),
                ("incoming", ScanScene.crateCentre + (1 - u) * ScanScene.swapDistance, ScanScene.recordCount),
            ]
            for crate in crates {
                let label = "step \(step) \(crate.name) crate at \(crate.cx)"
                let rim = d.shapes.firstIndex {
                    if case let .line(from, to, .dim, _) = $0 {
                        return from == CGPoint(x: crate.cx - ScanScene.backHalf, y: ScanScene.back)
                            && to == CGPoint(x: crate.cx + ScanScene.backHalf, y: ScanScene.back)
                    }
                    return false
                }
                let wall = CGRect(x: crate.cx - ScanScene.frontHalf, y: ScanScene.front,
                                  width: 2 * ScanScene.frontHalf, height: 20)
                guard let rim, let wallIndex = d.shapes.firstIndex(of: .rect(wall, stroke: .foreground, fill: .background)),
                      rim < wallIndex else {
                    XCTFail("\(label): no back rim followed by a front wall"); continue
                }
                var records = 0
                for shape in d.shapes[rim..<wallIndex] {
                    guard let box = BusyDrawing.box(of: shape) else { continue }
                    XCTAssertLessThanOrEqual(box.maxY, ScanScene.front + 4 + 1e-9,
                                             "\(label): \(shape) reaches below the wall's top")
                    switch shape {
                    case .rect(_, _, .background?), .path(_, true, _, .background?): records += 1
                    default: break
                    }
                }
                // The outgoing crate is spent; the incoming one is full, so
                // the bound above was checked against every one of its records.
                XCTAssertEqual(records, crate.records, "\(label): records behind the wall")
            }
        }
    }

    func testFlippedRecordsLeanOverTheWallAfterIt() {
        // At 4.25 s eleven records are flipped; those that were not finds
        // lean forward over the wall, drawn after it on purpose.
        let d = Self.picture(4.25)
        let wall = CGRect(x: ScanScene.crateCentre - 44, y: 72, width: 88, height: 20)
        guard let wallIndex = d.shapes.firstIndex(of: .rect(wall, stroke: .foreground, fill: .background)) else {
            return XCTFail("no wall")
        }
        let lean = d.shapes[wallIndex...].contains {
            if case let .path(points, true, .foreground?, .background?) = $0 {
                return points.first?.y == ScanScene.front - 3
            }
            return false
        }
        XCTAssertTrue(lean, "the flipped records lean on the wall")
    }

    func testPickedPileRecordsAreCrateRecordWidth() {
        let d = Self.picture(19)
        let quads = Self.pileQuads(d)
        XCTAssertFalse(quads.isEmpty, "by 19 s the dig has turned up finds")
        XCTAssertLessThanOrEqual(quads.count, 8)
        for quad in quads {
            XCTAssertEqual(quad[1].x - quad[0].x, 2 * 44 * 0.9, accuracy: 0.1)
            XCTAssertEqual(quad[0].y, quad[1].y, "the bottom edge is level")
        }
    }

    func testPileCountsTheFindsFlippedSoFar() {
        // Recount the finds the way the sketch does, at a time inside the
        // second crate's flipping (counter 1, f 4, phase 2: five flipped).
        let time = 5 + 14.0 / 8
        let flipped = 12 + 4 + 1
        let finds = (0..<flipped).filter { ScanScene.isFind($0) }.count
        XCTAssertEqual(Self.pileQuads(Self.picture(time)).count, min(finds, 8))
    }

    func testDividersCycleInOrder() {
        let names = ["A–F", "G–M", "N–S", "T–Z"]
        for counter in 0..<8 {
            let d = Self.picture(Double(counter) * 5 + 1)
            XCTAssertEqual(Self.dividers(d), [names[counter % 4]], "crate \(counter)")
        }
    }

    func testSwapSlidesToTheNextCrateEvenFromTZ() {
        // 19.5 s: counter 3 (T–Z) starts its swap, A–F sliding in.
        XCTAssertEqual(Self.dividers(Self.picture(19.5)), ["T–Z", "A–F"])
        XCTAssertEqual(Self.dividers(Self.picture(4.5)), ["A–F", "G–M"])
    }

    func testFinishedHoldsTheCrateOnScreen() {
        XCTAssertEqual(Self.dividers(Self.picture(6.0, finished: true)), ["G–M"], "counter 1, flipping")
        XCTAssertEqual(Self.dividers(Self.picture(4.75, finished: true)), ["G–M"], "inside the first swap: the incoming crate")
        XCTAssertEqual(Self.dividers(Self.picture(16.0, finished: true)), ["T–Z"])
    }

    func testFinishedCrateIsSpentAndItsPileHoldsTheWholeCrate() {
        let d = Self.picture(6.0, finished: true)
        let finds = (0..<24).filter { ScanScene.isFind($0) }.count
        XCTAssertEqual(Self.pileQuads(d).count, min(finds, 8))
        // Every record is flipped, so none stands behind the wall.
        let wall = CGRect(x: ScanScene.crateCentre - 44, y: 72, width: 88, height: 20)
        let wallIndex = d.shapes.firstIndex(of: .rect(wall, stroke: .foreground, fill: .background))
        XCTAssertNotNil(wallIndex)
        if let wallIndex {
            XCTAssertFalse(d.shapes[..<wallIndex].contains {
                if case .rect(_, _, .background?) = $0 { return true }
                return false
            }, "every record is flipped")
        }
    }

    func testDoneOnlyWhenFinishedAndLit() {
        XCTAssertTrue(Self.texts(Self.picture(6, finished: true, lit: true)).contains("DONE"))
        XCTAssertFalse(Self.texts(Self.picture(6, finished: true, lit: false)).contains("DONE"))
        XCTAssertFalse(Self.texts(Self.picture(6)).contains("DONE"))
        let done = Self.picture(6, finished: true).shapes.contains {
            if case .text("DONE", _, _, _, .hot) = $0 { return true }
            return false
        }
        XCTAssertTrue(done, "DONE is hot")
    }

    func testFinishedFrameIgnoresTheClockAfterTheFinish() {
        // `time` is frozen at the finish; only `finished` keeps counting, and
        // the picture reads nothing from it but the blink.
        var a = Self.input(time: 6, finished: true)
        var b = a
        a.finished = 1
        b.finished = 7.5
        XCTAssertEqual(ScanScene.picture(a), ScanScene.picture(b))
    }

    func testSwapIsClippedToTheScene() {
        let d = Self.picture(19.875)
        XCTAssertGreaterThanOrEqual(d.bounds.minX, -0.5)
        XCTAssertLessThanOrEqual(d.bounds.maxX, 240.5)
        guard case .clipBegin(let rect, 0) = d.shapes.first(where: {
            if case .clipBegin = $0 { return true }
            return false
        }) else { return XCTFail("the crates are not clipped") }
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 240, height: 100))
    }

    func testKeyFrameShowsTheFrontRecordStandingWithItsCover() {
        // keyTime: four flipped, phase 0, the front record's face drawn with art.
        let t = ScanScene.keyTime
        XCTAssertEqual(BusySignalTiming.step(t) % 40, 12)
        let d = Self.picture(t)
        let artLines = d.shapes.filter {
            if case .path(_, false, .cool?, nil) = $0 { return true }
            if case .path(_, false, .hot?, nil) = $0 { return true }
            return false
        }
        XCTAssertFalse(artLines.isEmpty, "the front record shows its cover")
    }

    // MARK: - Mini

    func testMiniFallenRecordStaysInsideTheCrate() {
        for time in [0.25, 0.625, 1.0] {
            let input = Self.input(time: time)
            XCTAssertEqual(input.step % 3, 2)
            let d = ScanScene.mini(input)
            let fallen = d.shapes.compactMap { shape -> (CGFloat, CGFloat)? in
                if case let .line(from, to, .cool, _) = shape, from.y == 7.6 { return (min(from.x, to.x), max(from.x, to.x)) }
                return nil
            }
            XCTAssertEqual(fallen.count, 1, "at \(time)")
            for (minX, maxX) in fallen {
                XCTAssertGreaterThanOrEqual(minX, 85)
                XCTAssertLessThanOrEqual(maxX, 95.4)
            }
        }
    }

    func testMiniFrontRecordStandsThenTips() {
        func cool(_ time: TimeInterval, finished: Bool = false) -> [CGRect] {
            ScanScene.mini(Self.input(time: time, finished: finished)).shapes.compactMap {
                if case let .rect(rect, .cool?, .background?) = $0 { return rect }
                return nil
            }
        }
        XCTAssertEqual(cool(0), [CGRect(x: 86.2, y: 2.6, width: 8, height: 5)], "phase 0 stands")
        XCTAssertEqual(cool(0.125), [CGRect(x: 85.8, y: 4.6, width: 8.8, height: 3)], "phase 1 tips")
        XCTAssertEqual(cool(0.25), [], "phase 2 lies flat")
        XCTAssertEqual(cool(0.25, finished: true), [CGRect(x: 86.2, y: 2.6, width: 8, height: 5)],
                       "finished stands still")
    }

    func testMiniCrateBlinksAndFolderIsTheSource() {
        func wallInk(_ lit: Bool) -> BusyInk? {
            ScanScene.mini(Self.input(time: 3, finished: true, lit: lit)).shapes.compactMap {
                if case let .rect(rect, ink, .background?) = $0, rect.minY == 6.6 { return ink }
                return nil
            }.first
        }
        XCTAssertEqual(wallInk(true), .hot)
        XCTAssertEqual(wallInk(false), .foreground)
        let d = ScanScene.mini(Self.input(time: 3))
        XCTAssertEqual(d.shapes.first, .path(points: [CGPoint(x: 1, y: 3), CGPoint(x: 4.5, y: 3),
                                                      CGPoint(x: 5.6, y: 4.3), CGPoint(x: 11, y: 4.3),
                                                      CGPoint(x: 11, y: 10.6), CGPoint(x: 1, y: 10.6)],
                                             closed: true, stroke: .foreground, fill: nil))
    }

    // MARK: - Helpers

    /// The picked pile's records: closed, background-filled quads drawn after
    /// the crates' clip, bottom-left then bottom-right first.
    static func pileQuads(_ d: BusyDrawing) -> [[CGPoint]] {
        guard let clipEnd = d.shapes.lastIndex(of: .clipEnd) else { return [] }
        return d.shapes[clipEnd...].compactMap {
            if case let .path(points, true, .foreground?, .background?) = $0, points.count == 4 { return points }
            return nil
        }
    }

    /// The divider labels on the crate walls, left to right in draw order.
    static func dividers(_ d: BusyDrawing) -> [String] {
        d.shapes.compactMap {
            if case let .text(s, _, _, _, .dim) = $0 { return s }
            return nil
        }
    }

    static func texts(_ d: BusyDrawing) -> [String] {
        d.shapes.compactMap {
            if case let .text(s, _, _, _, _) = $0 { return s }
            return nil
        }
    }
}
#endif
