#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The secure read's picture and mini (html:419-447), pinned to the states
/// `SecureRipEngine` really emits: rereads stay 0 through both passes and
/// only count in `.retry`, where they count attempts rather than cells.
final class SecureReadSceneTests: XCTestCase {
    // MARK: - Inputs

    static func input(ordinal: Int = 3, count: Int = 8, phase: SecureRipEngine.Phase,
                      fraction: Double, rereads: Int = 0, time: TimeInterval = 1.25,
                      finished: TimeInterval? = nil, lit: Bool = true) -> BusySceneInput {
        let secure = BusySecureRead(SecureDiscRip.Progress(
            trackOrdinal: ordinal, trackCount: count,
            track: .init(trackNumber: ordinal, phase: phase, fraction: fraction, rereads: rereads),
            discRereads: rereads))
        return BusySceneInput(progress: BusyProgress(secure: secure),
                              time: time, finished: finished, markLit: lit,
                              blinking: finished != nil)
    }

    /// The 60 sector-map cells live at x ≥ 158, y ≥ 24 (html:437); nothing
    /// else in the picture is drawn there.
    static let mapArea = CGRect(x: 157, y: 23, width: 80, height: 50)

    static func mapRects(_ d: BusyDrawing, stroke: BusyInk?, fill: BusyInk?) -> [CGRect] {
        d.shapes.compactMap { shape in
            guard case let .rect(r, s, f) = shape, s == stroke, f == fill, mapArea.contains(r) else { return nil }
            return r
        }
    }

    // MARK: - Picture

    func testFilledCellsFollowPhaseFraction() {
        let pass1 = SecureReadScene.picture(Self.input(phase: .pass1, fraction: 0.5))
        XCTAssertEqual(Self.mapRects(pass1, stroke: .cool, fill: nil).count, 30, "pass 1 draws outlines")
        XCTAssertEqual(Self.mapRects(pass1, stroke: nil, fill: .cool).count, 0)

        let pass2 = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 0.5))
        XCTAssertEqual(Self.mapRects(pass2, stroke: nil, fill: .cool).count, 30, "pass 2 draws solids")
        XCTAssertEqual(Self.mapRects(pass2, stroke: .cool, fill: nil).count, 0)

        let odd = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 0.26))
        XCTAssertEqual(Self.mapRects(odd, stroke: nil, fill: .cool).count, 15, "⌊0.26 × 60⌋")
    }

    func testPassesNeverDrawOrange() {
        for phase in [SecureRipEngine.Phase.pass1, .pass2] {
            for fraction in [0.0, 0.3, 0.75, 1.0] {
                let d = SecureReadScene.picture(Self.input(phase: phase, fraction: fraction))
                XCTAssertEqual(Self.mapRects(d, stroke: nil, fill: .hot).count, 0, "\(phase) \(fraction)")
            }
        }
        // Even if a report ever carried rereads outside the retry loop.
        let odd = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, rereads: 9))
        XCTAssertEqual(Self.mapRects(odd, stroke: nil, fill: .hot).count, 0)
    }

    func testRetryDrawsAFullMapWithCappedOrange() {
        let three = SecureReadScene.picture(Self.input(phase: .retry, fraction: 0.2, rereads: 3))
        let hot = Self.mapRects(three, stroke: nil, fill: .hot)
        let cool = Self.mapRects(three, stroke: nil, fill: .cool)
        XCTAssertEqual(hot.count + cool.count, 60, "the retry map is full")
        XCTAssertEqual(hot.count, 3)

        let forty = SecureReadScene.picture(Self.input(phase: .retry, fraction: 0.2, rereads: 40))
        XCTAssertEqual(Self.mapRects(forty, stroke: nil, fill: .hot).count, 6, "capped at a tenth of the map")
        XCTAssertEqual(Self.mapRects(forty, stroke: nil, fill: .cool).count, 54)
    }

    func testRetryOrangeCellsAreTheSketchsHashOrder() {
        // Track 3 (k = 2): the hot cells are the indices with the lowest
        // BusyNoise.unit(200 + i), so they land where the sketch's would.
        let d = SecureReadScene.picture(Self.input(ordinal: 3, phase: .retry, fraction: 0, rereads: 2))
        func noise(_ i: Int) -> Double { BusyNoise.unit(Double(200 + i)) }
        let order: [Int] = (0..<60).sorted { (a: Int, b: Int) -> Bool in noise(a) < noise(b) }
        let hot = Self.mapRects(d, stroke: nil, fill: .hot)
        XCTAssertEqual(hot.count, 2)
        for i in order.prefix(2) {
            let x: CGFloat = 158 + CGFloat(i % 10) * 7.6
            let y: CGFloat = 24 + CGFloat(i / 10) * 7.6
            let found = hot.contains { (r: CGRect) -> Bool in abs(r.minX - x) < 1e-9 && abs(r.minY - y) < 1e-9 }
            XCTAssertTrue(found, "cell \(i)")
        }
    }

    func testRetryLabelsTheSledAndHeader() {
        let d = SecureReadScene.picture(Self.input(ordinal: 4, phase: .retry, fraction: 0.5, rereads: 1))
        let texts = d.shapes.compactMap { shape -> String? in
            if case let .text(s, _, _, _, _) = shape { return s }
            return nil
        }
        XCTAssertTrue(texts.contains("RE"))
        XCTAssertTrue(texts.contains("TRK 04 · RE-READ"))

        let pass2 = SecureReadScene.picture(Self.input(ordinal: 4, phase: .pass2, fraction: 0.5))
        let pass2Texts = pass2.shapes.compactMap { shape -> String? in
            if case let .text(s, _, _, _, _) = shape { return s }
            return nil
        }
        XCTAssertTrue(pass2Texts.contains("P2"))
        XCTAssertTrue(pass2Texts.contains("TRK 04 · PASS 2"))
    }

    func testAtMostTwelveBandRings() {
        let d = SecureReadScene.picture(Self.input(ordinal: 17, count: 30, phase: .pass1, fraction: 0.4))
        let dimRings = d.shapes.filter { shape in
            guard case let .circle(_, r, .dim, nil) = shape else { return false }
            return r >= 13 && r <= 36
        }
        XCTAssertLessThanOrEqual(dimRings.count, 12)
        XCTAssertGreaterThan(dimRings.count, 0)

        // The current track's band is outlined cool, inside the disc.
        let coolRings = d.shapes.compactMap { shape -> CGFloat? in
            guard case let .circle(_, r, .cool, nil) = shape else { return nil }
            return r
        }
        XCTAssertEqual(coolRings.count, 2)
        XCTAssertTrue(coolRings.allSatisfy { $0 >= 13 && $0 <= 36 })
    }

    func testSledWalksTheBandWithThePhase() {
        func sledX(_ fraction: Double) -> CGFloat? {
            let d = SecureReadScene.picture(Self.input(phase: .pass1, fraction: fraction))
            for case let .rect(r, .foreground, .background) in d.shapes { return r.midX }
            return nil
        }
        // Track 3 of 8: band from 13 + 23·2/8 to 13 + 23·3/8, from cx 52.
        XCTAssertEqual(try XCTUnwrap(sledX(0)), 52 + 18.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sledX(1)), 52 + 21.625, accuracy: 1e-9)
    }

    func testFinishedMapIsFullAndOKBlinks() {
        let lit = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, time: 20, finished: 1, lit: true))
        XCTAssertEqual(Self.mapRects(lit, stroke: nil, fill: .cool).count, 60)
        XCTAssertTrue(lit.shapes.contains {
            if case .text("OK", _, _, _, .hot) = $0 { return true }
            return false
        })

        let unlit = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, time: 20, finished: 1.5, lit: false))
        XCTAssertEqual(Self.mapRects(unlit, stroke: nil, fill: .cool).count, 60)
        XCTAssertFalse(unlit.shapes.contains {
            if case .text("OK", _, _, _, _) = $0 { return true }
            return false
        })
    }

    func testFinishedPictureDropsTheSledAndHangsTheTickOnTime() {
        // The scene does not freeze the spindle itself: the ledger stops
        // `time` at the finish. So the finished picture must read nothing but
        // `time` for its motion, never how long ago the finish was...
        let a = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, time: 20, finished: 1, lit: true))
        let b = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, time: 20, finished: 3, lit: true))
        XCTAssertEqual(a, b, "elapsed time since the finish changes nothing")

        // ...and the index tick does follow `time`, which is what the frozen
        // clock holds still.
        func tick(_ d: BusyDrawing) -> CGPoint? {
            for case let .line(_, to, .hot, _) in d.shapes { return to }
            return nil
        }
        let later = SecureReadScene.picture(Self.input(phase: .pass2, fraction: 1, time: 20.1, finished: 1, lit: true))
        XCTAssertNotNil(tick(a))
        XCTAssertNotEqual(tick(a), tick(later), "the tick is driven by time alone")

        // The sled is parked: no laser dot, no pass label, no band outlined.
        // The same frame unfinished draws all three, so their absence is the
        // finish's doing, not the clock's (the laser dot blinks on the step).
        let runningInput = Self.input(phase: .pass2, fraction: 1, time: 20)
        XCTAssertEqual(runningInput.step % 2, 0, "pick a time on the laser's lit step")
        let running = SecureReadScene.picture(runningInput)
        XCTAssertTrue(running.shapes.contains {
            if case .circle(_, _, nil, .hot) = $0 { return true }
            return false
        })
        XCTAssertTrue(running.shapes.contains {
            if case .text("P2", _, _, _, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(running.shapes.contains {
            if case .circle(_, _, .cool, nil) = $0 { return true }
            return false
        })
        XCTAssertFalse(a.shapes.contains {
            if case .circle(_, _, nil, .hot) = $0 { return true }
            return false
        }, "no laser dot")
        XCTAssertFalse(a.shapes.contains {
            if case let .text(s, _, _, _, _) = $0 { return ["P1", "P2", "RE"].contains(s) }
            return false
        }, "no sled label")
        XCTAssertFalse(a.shapes.contains {
            if case .circle(_, _, .cool, nil) = $0 { return true }
            return false
        }, "no current band")
    }

    // MARK: - Mini

    func testMiniGridFollowsPhaseFraction() {
        func filled(_ input: BusySceneInput) -> Int {
            SecureReadScene.mini(input).shapes.filter {
                guard case let .rect(r, nil, _) = $0 else { return false }
                return r.minX >= 86 && r.width == 3.6
            }.count
        }
        XCTAssertEqual(filled(Self.input(phase: .pass1, fraction: 0)), 0)
        XCTAssertEqual(filled(Self.input(phase: .pass1, fraction: 0.6)), 2)
        XCTAssertEqual(filled(Self.input(phase: .pass2, fraction: 0.99)), 3)
        XCTAssertEqual(filled(Self.input(phase: .pass2, fraction: 1, finished: 1)), 4)
    }

    func testMiniGridBlinksHotWhenFinished() {
        let lit = SecureReadScene.mini(Self.input(phase: .pass2, fraction: 1, finished: 1, lit: true))
        let unlit = SecureReadScene.mini(Self.input(phase: .pass2, fraction: 1, finished: 1.5, lit: false))
        func gridInks(_ d: BusyDrawing) -> [BusyInk] {
            d.shapes.compactMap {
                guard case let .rect(r, nil, fill) = $0, r.minX >= 86 else { return nil }
                return fill
            }
        }
        XCTAssertEqual(gridInks(lit), Array(repeating: .hot, count: 4))
        XCTAssertEqual(gridInks(unlit), Array(repeating: .cool, count: 4))
    }

    func testMiniDiscIndexStopsWhenFinished() {
        func index(_ input: BusySceneInput) -> CGPoint? {
            for case let .line(_, to, .hot, _) in SecureReadScene.mini(input).shapes where to.x < 12 { return to }
            return nil
        }
        let a = index(Self.input(phase: .pass1, fraction: 0.5, time: 0.25))
        let b = index(Self.input(phase: .pass1, fraction: 0.5, time: 0.375))
        XCTAssertNotEqual(a, b, "the disc turns 30° a step")
        let done = try? XCTUnwrap(index(Self.input(phase: .pass2, fraction: 1, time: 20, finished: 1)))
        XCTAssertEqual(done?.x ?? 0, 10, accuracy: 1e-9, "parked at angle 0")
        XCTAssertEqual(done?.y ?? 0, 6, accuracy: 1e-9)
    }

    // MARK: - Missing progress

    func testDrawsWithoutASecureReport() {
        // The ledger can begin a secure read before the engine's first report.
        let d = SecureReadScene.picture(BusySceneInput(time: 0.5))
        XCTAssertFalse(d.shapes.isEmpty)
        XCTAssertTrue(CGRect(origin: .zero, size: d.size).insetBy(dx: -0.5, dy: -0.5).contains(d.bounds))
        XCTAssertEqual(Self.mapRects(d, stroke: .cool, fill: nil).count, 0)
    }
}
#endif
