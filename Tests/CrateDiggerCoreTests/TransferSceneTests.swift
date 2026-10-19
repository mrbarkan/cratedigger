#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The device transfer's picture and mini (html:729-771), pinned to the
/// user's iPod simplifications: the big iPod is an outline, a screen holding
/// only Apple's no-entry "do not disconnect" sign (a blinking check once
/// done) and a bare click wheel; the mini iPod is an outline, a solid screen
/// and a solid wheel.
final class TransferSceneTests: XCTestCase {
    // MARK: - Fixtures

    /// The iPod's screen (html:762).
    static let screen = CGRect(x: 167, y: 15, width: 38, height: 28)
    static let signCentre = CGPoint(x: 186, y: 29)
    static let wheelCentre = CGPoint(x: 186, y: 64)

    static func running(fraction: Double = 0.4, time: TimeInterval = 1.25) -> BusySceneInput {
        BusySceneInput(progress: BusyProgress(completed: Int(fraction * 380), total: 380),
                       time: time, unitTime: 0.25, unitFraction: 0.3)
    }

    static func finished(lit: Bool, time: TimeInterval = 9.5, since: TimeInterval = 0.5) -> BusySceneInput {
        BusySceneInput(progress: BusyProgress(completed: 380, total: 380),
                       time: time, unitTime: 0.25, unitFraction: 1,
                       finished: since, markLit: lit, blinking: true)
    }

    /// Every shape drawn inside the screen, not counting the screen's own
    /// outline.
    static func shapesInsideScreen(_ d: BusyDrawing) -> [BusyShape] {
        let inner = screen.insetBy(dx: 0.5, dy: 0.5)
        return d.shapes.filter { shape in
            guard let box = BusyDrawing.box(of: shape) else { return false }
            return inner.contains(box)
        }
    }

    static func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func isCircle(_ shape: BusyShape, centre: CGPoint, radius r: CGFloat,
                         stroke: BusyInk?, fill: BusyInk?) -> Bool {
        guard case let .circle(c, radius, s, f) = shape else { return false }
        return close(c, centre) && abs(radius - r) < 0.01 && s == stroke && f == fill
    }

    // MARK: - The iPod screen

    func testRunningScreenShowsOnlyTheNoEntrySign() {
        for time in [0, 0.625, 1.25, 7.875] as [TimeInterval] {
            let inside = Self.shapesInsideScreen(TransferScene.picture(Self.running(time: time)))
            XCTAssertEqual(inside.count, 2, "at \(time): \(inside)")
            XCTAssertEqual(inside.filter {
                Self.isCircle($0, centre: Self.signCentre, radius: 8, stroke: .hot, fill: nil)
            }.count, 1, "one hot ring of r 8 at (186, 29)")
            let diagonals = inside.filter {
                guard case let .line(from, to, ink, _) = $0, ink == .hot else { return false }
                // From the ring's upper left to its lower right (-3π/4 → π/4).
                return Self.close(from, BusyNoise.polar(186, 29, 8, -Double.pi * 3 / 4))
                    && Self.close(to, BusyNoise.polar(186, 29, 8, Double.pi / 4))
            }
            XCTAssertEqual(diagonals.count, 1, "one hot diagonal across the ring")
        }
    }

    func testFinishedScreenShowsABlinkingCheck() {
        let lit = Self.shapesInsideScreen(TransferScene.picture(Self.finished(lit: true)))
        XCTAssertEqual(lit.count, 1, "\(lit)")
        guard case let .path(points, closed, stroke, fill)? = lit.first else {
            return XCTFail("expected the check polyline, got \(lit)")
        }
        XCTAssertEqual(points, [CGPoint(x: 180, y: 29), CGPoint(x: 184.5, y: 33.5), CGPoint(x: 193, y: 24)])
        XCTAssertFalse(closed)
        XCTAssertEqual(stroke, .hot)
        XCTAssertNil(fill)
        XCTAssertFalse(lit.contains { if case .circle = $0 { return true } else { return false } },
                       "the no-entry ring is gone once finished")

        let unlit = Self.shapesInsideScreen(TransferScene.picture(Self.finished(lit: false)))
        XCTAssertTrue(unlit.isEmpty, "the off half of the blink leaves the screen empty: \(unlit)")
    }

    // MARK: - The click wheel

    func testClickWheelIsBare() {
        for input in [Self.running(), Self.finished(lit: true), Self.finished(lit: false)] {
            let d = TransferScene.picture(input)
            let atWheel = d.shapes.filter {
                guard case let .circle(c, _, _, _) = $0 else { return false }
                return Self.close(c, Self.wheelCentre)
            }
            XCTAssertEqual(atWheel.count, 2)
            XCTAssertTrue(atWheel.contains { Self.isCircle($0, centre: Self.wheelCentre, radius: 16,
                                                           stroke: .foreground, fill: nil) })
            XCTAssertTrue(atWheel.contains { Self.isCircle($0, centre: Self.wheelCentre, radius: 5.5,
                                                           stroke: .foreground, fill: nil) })
            // Nothing else on the wheel: no menu label, no play/pause glyphs.
            let wheelBox = CGRect(x: 170, y: 48, width: 32, height: 32)
            let onWheel = d.shapes.filter { shape in
                guard let box = BusyDrawing.box(of: shape) else { return false }
                return wheelBox.contains(box)
            }
            XCTAssertEqual(onWheel.count, 2, "\(onWheel)")
        }
    }

    // MARK: - Motion

    func testPacketsRideTheCableOnlyWhileRunning() {
        func packets(_ d: BusyDrawing) -> Int {
            d.shapes.filter {
                guard case let .rect(rect, nil, .cool?) = $0 else { return false }
                return abs(rect.width - 3.2) < 0.01 && abs(rect.height - 3.2) < 0.01
            }.count
        }
        XCTAssertEqual(packets(TransferScene.picture(Self.running())), 3)
        XCTAssertEqual(packets(TransferScene.picture(Self.finished(lit: true))), 0)
        // They hop one cable dot per 8 fps step.
        XCTAssertNotEqual(TransferScene.picture(Self.running(time: 1.25)),
                          TransferScene.picture(Self.running(time: 1.375)))
    }

    func testOneLaptopRowLightsWhileRunningAndNoneOnceFinished() {
        func coolRows(_ d: BusyDrawing) -> [CGFloat] {
            d.shapes.compactMap {
                guard case let .line(from, _, .cool, _) = $0, from.x == 18 else { return nil }
                return from.y
            }
        }
        // A new row every 0.6 s: 1.25 s is row 2, 3.0 s wraps to row 0.
        XCTAssertEqual(coolRows(TransferScene.picture(Self.running(time: 1.25))), [31 + 2 * 5.5])
        XCTAssertEqual(coolRows(TransferScene.picture(Self.running(time: 3.0))), [31])
        XCTAssertEqual(coolRows(TransferScene.picture(Self.finished(lit: true))), [])
    }

    func testLitRowStaysInRangeForAnyClock() {
        XCTAssertEqual(TransferScene.litRow(at: 0), 0)
        XCTAssertEqual(TransferScene.litRow(at: 1.25), 2)
        XCTAssertEqual(TransferScene.litRow(at: 3.0), 0)
        // A clock the ledger never produces still lights a real row, and
        // never traps on the Int conversion.
        for time in [-0.1, -7.3, .nan, .infinity, -.infinity, 1e300] {
            XCTAssertTrue((0..<TransferScene.rowCount).contains(TransferScene.litRow(at: time)), "\(time)")
        }
        XCTAssertEqual(TransferScene.litRow(at: -7.3), 0)
    }

    // MARK: - The mini

    func testMiniIPodHasSolidScreenAndWheel() {
        for input in [Self.running(), Self.finished(lit: true), Self.finished(lit: false)] {
            let d = TransferScene.mini(input)
            XCTAssertTrue(d.shapes.contains {
                guard case let .rect(rect, nil, .foreground?) = $0 else { return false }
                return Self.close(rect.origin, CGPoint(x: 88, y: 2))
                    && abs(rect.width - 4.6) < 0.01 && abs(rect.height - 2.8) < 0.01
            }, "a solid foreground screen block")
            XCTAssertTrue(d.shapes.contains {
                Self.isCircle($0, centre: CGPoint(x: 90.3, y: 7.9), radius: 2, stroke: nil, fill: .foreground)
            }, "a solid foreground click wheel")
        }
    }

    func testMiniIPodOutlineTakesTheEndInk() {
        func outline(_ input: BusySceneInput) -> BusyInk? {
            for shape in TransferScene.mini(input).shapes {
                if case let .roundedRect(rect, _, stroke, _) = shape, Self.close(rect.origin, CGPoint(x: 86.6, y: 0.6)) {
                    return stroke
                }
            }
            return nil
        }
        XCTAssertEqual(outline(Self.running()), .foreground)
        XCTAssertEqual(outline(Self.finished(lit: true)), .hot)
        XCTAssertEqual(outline(Self.finished(lit: false)), .foreground)
    }

    func testMiniLaptopIsTheSource() {
        let d = TransferScene.mini(Self.running())
        XCTAssertTrue(d.shapes.contains { $0 == .rect(CGRect(x: 2, y: 1.8, width: 8.4, height: 5.8),
                                                      stroke: .foreground, fill: nil) })
        // Laptop, track and iPod all stay left of / right of the dashes.
        XCTAssertLessThanOrEqual(d.bounds.minX, 1)
        XCTAssertTrue(CGRect(origin: .zero, size: BusyDrawing.miniSize).insetBy(dx: -0.5, dy: -0.5).contains(d.bounds))
    }

    func testKeyFrameShowsTheSign() {
        let still = BusySceneInput(progress: BusyProgress(completed: 100, total: 380),
                                   time: TransferScene.keyTime, unitTime: 0.5, unitFraction: 0.5, still: true)
        XCTAssertEqual(Self.shapesInsideScreen(TransferScene.picture(still)).count, 2)
    }
}
#endif
