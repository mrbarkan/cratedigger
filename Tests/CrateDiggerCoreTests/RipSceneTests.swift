#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The CD rip's picture and mini (html:357-389), pinned where the port could
/// drift from the approved look: the stack never grows into the check, a
/// completion only drops a slab when the stack really grows, the disc and the
/// check honour the finish, and the mini's file fills with the unit.
final class RipSceneTests: XCTestCase {
    // MARK: - Inputs

    /// A rip input with explicit counts. `unitTime` defaults past the half
    /// second a slab takes to fall, so nothing is in the air unless a test
    /// asks for it.
    static func input(completed: Int, total: Int?, time: TimeInterval = 7.25,
                      unitTime: TimeInterval = 1, unitFraction: Double = 0.4,
                      finished: TimeInterval? = nil, lit: Bool = true) -> BusySceneInput {
        BusySceneInput(progress: BusyProgress(completed: completed, total: total),
                       time: time, unitTime: unitTime, unitFraction: unitFraction,
                       finished: finished, markLit: lit, still: false, blinking: finished != nil)
    }

    /// A slab is a 28 × 3 rect: static ones in foreground, the falling one cool.
    static func slabs(_ d: BusyDrawing, _ ink: BusyInk? = nil) -> [CGRect] {
        d.shapes.compactMap { shape -> CGRect? in
            guard case let .rect(r, stroke, _) = shape, r.width == 28, r.height == 3 else { return nil }
            if let ink, stroke != ink { return nil }
            return r
        }
    }

    static let check = [CGPoint(x: 205, y: 56), CGPoint(x: 210, y: 61), CGPoint(x: 221, y: 48)]

    static func hasCheck(_ d: BusyDrawing) -> Bool {
        d.shapes.contains { $0 == .path(points: check, closed: false, stroke: .hot, fill: nil) }
    }

    // MARK: - Stack

    func testStackShowsAtMostFiveSlabsAndStaysBelowTheCheck() {
        for total in [20, 6] {
            for input in [Self.input(completed: total, total: total),
                          Self.input(completed: total, total: total, finished: 1)] {
                let d = RipScene.picture(input)
                let slabs = Self.slabs(d)
                XCTAssertEqual(slabs.count, 5, "total \(total): one slab per fifth of the disc")
                XCTAssertEqual(Self.slabs(d, .foreground).count, 5, "total \(total): all landed")
                for slab in slabs {
                    XCTAssertGreaterThan(slab.minY, 61, "total \(total): a slab reaches the check's vertex")
                }
            }
        }
    }

    func testShortDiscsStackOneSlabPerTrack() {
        let d = RipScene.picture(Self.input(completed: 3, total: 4))
        XCTAssertEqual(Self.slabs(d, .foreground).map(\.minY), [85, 80, 75])
    }

    func testCompletionThatKeepsTheShownCountDropsNothing() {
        // 20 tracks: k = 1 and k = 2 both show one slab.
        let d = RipScene.picture(Self.input(completed: 2, total: 20, unitTime: 0.125))
        XCTAssertEqual(Self.slabs(d, .foreground).count, 1)
        XCTAssertEqual(Self.slabs(d, .cool).count, 0, "nothing falls")
    }

    func testCompletionThatGrowsTheStackDropsOneSlab() {
        // 20 tracks: k = 5 shows two slabs, k = 4 showed one.
        let falling = RipScene.picture(Self.input(completed: 5, total: 20, unitTime: 0.25))
        XCTAssertEqual(Self.slabs(falling, .foreground).count, 1, "the one already there")
        let cool = Self.slabs(falling, .cool)
        XCTAssertEqual(cool.count, 1)
        // Halfway down (u = 0.5) from the file's foot to slabY(1) = 80.
        XCTAssertEqual(cool.first?.minX ?? 0, (162 + 198) / 2, accuracy: 1e-9)
        XCTAssertEqual(cool.first?.minY ?? 0, (58 + 80) / 2, accuracy: 1e-9)

        let landed = RipScene.picture(Self.input(completed: 5, total: 20, unitTime: 0.5))
        XCTAssertEqual(Self.slabs(landed, .foreground).map(\.minY), [85, 80])
        XCTAssertEqual(Self.slabs(landed, .cool).count, 0)
    }

    func testFallingSlabStepsAtEightFramesASecond() {
        func y(_ unitTime: TimeInterval) -> CGFloat? {
            Self.slabs(RipScene.picture(Self.input(completed: 1, total: 3, unitTime: unitTime)), .cool).first?.minY
        }
        XCTAssertEqual(y(0), 58)
        XCTAssertEqual(y(0.124), 58, "held for the whole step")
        XCTAssertEqual(y(0.375) ?? 0, 58 + (85 - 58) * 0.75, accuracy: 1e-9)
    }

    func testNothingFallsOnceFinished() {
        let d = RipScene.picture(Self.input(completed: 5, total: 5, unitTime: 0.125, finished: 0.125))
        XCTAssertEqual(Self.slabs(d, .cool).count, 0)
        XCTAssertEqual(Self.slabs(d, .foreground).count, 5)
    }

    // MARK: - Disc, notes, file

    func testDiscStopsWhenFinished() {
        let early = RipScene.picture(Self.input(completed: 5, total: 5, time: 40.5, finished: 0.5))
        let late = RipScene.picture(Self.input(completed: 5, total: 5, time: 40.5, finished: 6))
        let disc = Array(early.shapes.prefix(9))
        XCTAssertTrue(disc.contains(.circle(center: CGPoint(x: 50, y: 50), radius: 36, stroke: .foreground, fill: nil)),
                      "the disc is drawn first")
        XCTAssertEqual(disc, Array(late.shapes.prefix(9)))
        XCTAssertEqual(early, late, "a finished frame only changes with the blink")
    }

    func testDiscTurnsWithTheClock() {
        func index(_ time: TimeInterval) -> BusyShape? { RipScene.picture(Self.input(completed: 1, total: 5, time: time)).shapes.dropFirst(8).first }
        XCTAssertNotEqual(index(1), index(1.125))
        XCTAssertEqual(index(0), .line(from: CGPoint(x: 55, y: 50), to: CGPoint(x: 61, y: 50), ink: .hot, weight: 1))
    }

    func testNotesFlyOnlyWhileRunning() {
        func heads(_ d: BusyDrawing) -> Int {
            d.shapes.filter { if case .ellipse = $0 { return true } else { return false } }.count
        }
        // At 1.25 s notes 0, 1 and 2 are in flight: a single (1 head), a
        // pair (2) and a single (1).
        XCTAssertEqual(heads(RipScene.picture(Self.input(completed: 0, total: 5, time: 1.25))), 4)
        XCTAssertEqual(heads(RipScene.picture(Self.input(completed: 5, total: 5, time: 1.25, finished: 1))), 0)
    }

    func testFileFillsWithTheUnitAndReadsOKWhenFinished() {
        func fill(_ u: Double) -> Int {
            RipScene.picture(Self.input(completed: 1, total: 5, unitFraction: u)).shapes.filter {
                if case let .line(from, to, .cool, _) = $0 { return from.x == 168 && to.x == 184 }
                return false
            }.count
        }
        XCTAssertEqual(fill(0), 1, "one line at fill 0, as the sketch's loop starts at the bottom")
        XCTAssertEqual(fill(0.95), 8, "57 down to 39.5 in 2.5 steps")

        let running = RipScene.picture(Self.input(completed: 1, total: 5))
        XCTAssertTrue(running.shapes.contains(.text("T02", at: CGPoint(x: 176, y: 26), size: 6, align: .center, ink: .dim)))
        let done = RipScene.picture(Self.input(completed: 5, total: 5, finished: 1))
        XCTAssertTrue(done.shapes.contains(.text("OK", at: CGPoint(x: 176, y: 47), size: 7, align: .center, ink: .hot)))
        XCTAssertFalse(done.shapes.contains { if case let .text(s, _, _, _, _) = $0 { return s.hasPrefix("T") } else { return false } })
    }

    func testTrackLabelNeverPassesTheTotal() {
        let d = RipScene.picture(Self.input(completed: 5, total: 5))
        XCTAssertTrue(d.shapes.contains(.text("T05", at: CGPoint(x: 176, y: 26), size: 6, align: .center, ink: .dim)))
    }

    func testCheckOnlyWhenFinishedAndLit() {
        XCTAssertFalse(Self.hasCheck(RipScene.picture(Self.input(completed: 5, total: 5))))
        XCTAssertTrue(Self.hasCheck(RipScene.picture(Self.input(completed: 5, total: 5, finished: 1, lit: true))))
        XCTAssertFalse(Self.hasCheck(RipScene.picture(Self.input(completed: 5, total: 5, finished: 1, lit: false))))
    }

    // MARK: - Mini

    func testMiniFileFillFollowsUnitFraction() {
        func fill(_ u: Double) -> Int {
            RipScene.mini(Self.input(completed: 1, total: 5, unitFraction: u)).shapes.filter {
                if case let .line(from, _, .cool, _) = $0 { return from.x > 80 }
                return false
            }.count
        }
        XCTAssertEqual(fill(0), 1, "the sketch's loop starts at the bottom line (html:284)")
        XCTAssertEqual(fill(0.95), 4)
    }

    func testMiniDiscTurnsWhileRunningAndRestsWhenFinished() {
        func index(_ d: BusyDrawing) -> BusyShape? {
            d.shapes.first { if case .line(_, _, .hot, _) = $0 { return true } else { return false } }
        }
        let rest = BusyShape.line(from: CGPoint(x: 7.8, y: 6), to: CGPoint(x: 10, y: 6), ink: .hot, weight: 1)
        XCTAssertEqual(index(RipScene.mini(Self.input(completed: 5, total: 5, time: 3.125, finished: 1))), rest)
        XCTAssertNotEqual(index(RipScene.mini(Self.input(completed: 1, total: 5, time: 3.125))), rest)
    }

    func testMiniFileBlinksHotWhenFinished() {
        func outline(_ d: BusyDrawing) -> BusyInk? {
            for case let .path(points, true, stroke, _) in d.shapes where points.first?.x == 86 { return stroke }
            return nil
        }
        XCTAssertEqual(outline(RipScene.mini(Self.input(completed: 1, total: 5))), .foreground)
        XCTAssertEqual(outline(RipScene.mini(Self.input(completed: 5, total: 5, finished: 1, lit: true))), .hot)
        XCTAssertEqual(outline(RipScene.mini(Self.input(completed: 5, total: 5, finished: 1, lit: false))), .foreground)
    }

    // MARK: - Still frame

    func testKeyTimeHasNotesInFlight() {
        let d = RipScene.picture(BusySceneInput(progress: BusyProgress(completed: 2, total: 10),
                                                time: RipScene.keyTime, unitTime: 0.5, unitFraction: 0.5,
                                                still: true))
        XCTAssertTrue(d.shapes.contains { if case .ellipse = $0 { return true } else { return false } })
    }
}
#endif
