import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The NOW screen's matrix is only as alive as its driver. Screenshots of the
/// tour can't show it (the old footer meter captured dark too), so the driver's
/// promises are pinned here with a fake spectrum and a real main run loop.
@MainActor
final class MeterDriverTests: XCTestCase {

    func testPlayingLightsEveryColumn() {
        let meters = MeterDriver()
        meters.animation = VerticalVUAnimation()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }

        meters.start()
        pump(until: { Self.everyColumnLit(meters.frame) })

        XCTAssertTrue(Self.everyColumnLit(meters.frame), "frame after start: \(meters.frame)")
        meters.halt()
    }

    func testStoppingFadesBackToDarkAndHalts() {
        let meters = MeterDriver()
        meters.animation = VerticalVUAnimation()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }
        meters.start()
        pump(until: { Self.everyColumnLit(meters.frame) })

        meters.stop()
        pump(until: { !meters.isTicking }, timeout: 3)

        XCTAssertEqual(meters.frame, .dark)
        XCTAssertFalse(meters.isTicking, "the timer should stop once the matrix has faded")
    }

    func testHaltClearsAtOnce() {
        let meters = MeterDriver()
        meters.animation = VerticalVUAnimation()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }
        meters.start()
        pump(until: { Self.everyColumnLit(meters.frame) })

        meters.halt()

        XCTAssertEqual(meters.frame, .dark)
        XCTAssertFalse(meters.isTicking)
    }

    func testNoProviderStaysDark() {
        let meters = MeterDriver()
        meters.animation = VerticalVUAnimation()
        meters.start()
        pump(until: { false }, timeout: 0.3)

        XCTAssertEqual(meters.frame, .dark)
        meters.halt()
    }

    func testSwappingTheAnimationStartsFromDark() {
        let meters = MeterDriver()
        meters.animation = VerticalVUAnimation()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }
        meters.start()
        pump(until: { Self.everyColumnLit(meters.frame) })

        meters.animation = HorizontalVUAnimation()

        XCTAssertEqual(meters.frame, .dark)
        meters.halt()
    }

    /// A paused record's levels can settle while an Explosions ring is still
    /// on its way out. The driver has to keep ticking until the ring has
    /// faded, or it freezes mid-flight on the glass.
    ///
    /// A near-instant release makes the levels settle on the first tick after
    /// the pause, well inside the ring's half-second life, so the only thing
    /// left to keep the timer running is the ring. The ticks are stepped by
    /// hand at the timer's 30 fps, so the ring ages by exactly the time the
    /// test says, however busy the machine is.
    func testTimerOutlivesAPauseWhileAnExplosionsRingTravels() {
        let meters = MeterDriver(releaseTau: 0.002)
        meters.animation = ExplosionsAnimation()
        // Bass only: the step from silence is a hit on the first tick.
        meters.spectrumProvider = { [1, 1, 1] + Array(repeating: 0, count: 9) }
        meters.start()
        XCTAssertTrue(meters.isTicking, "precondition: start() runs the timer")
        meters.advance(by: Self.tick)
        XCTAssertFalse(Self.rings(meters).isEmpty, "a bass step should launch a ring")

        meters.stop()
        for _ in 0..<3 { meters.advance(by: Self.tick) }    // 0.1 s into a 0.5 s life

        XCTAssertFalse(Self.rings(meters).isEmpty, "the ring should still be travelling")
        XCTAssertTrue(meters.isTicking, "the timer must not halt while a ring is still on the glass")
        XCTAssertNotEqual(meters.frame, .dark)

        // Bounded, so a ring that never fades fails here instead of hanging.
        var ticks = 0
        while meters.isTicking, ticks < 60 {
            meters.advance(by: Self.tick)
            ticks += 1
        }

        XCTAssertFalse(meters.isTicking, "the timer should halt once the ring has faded")
        XCTAssertTrue(Self.rings(meters).isEmpty)
        XCTAssertEqual(meters.frame, .dark)
        XCTAssertGreaterThan(ticks, 10, "the ring should have kept the timer alive for most of its life")
    }

    /// The control for the test above: with nothing that outlives the beat,
    /// the same quick release halts the timer on the very next tick.
    func testTimerHaltsAsSoonAsAStatelessAnimationSettles() {
        let meters = MeterDriver(releaseTau: 0.002)
        meters.animation = VerticalVUAnimation()
        meters.spectrumProvider = { [1, 1, 1] + Array(repeating: 0, count: 9) }
        meters.start()
        XCTAssertTrue(meters.isTicking, "precondition: start() runs the timer")
        meters.advance(by: Self.tick)
        XCTAssertNotEqual(meters.frame, .dark)

        meters.stop()
        meters.advance(by: Self.tick)

        XCTAssertFalse(meters.isTicking)
        XCTAssertEqual(meters.frame, .dark)
    }

    // MARK: - Helpers

    /// One tick of the driver's 30 fps timer.
    private static let tick: TimeInterval = 1.0 / 30

    private static func everyColumnLit(_ frame: MatrixFrame) -> Bool {
        (0..<MatrixFrame.columns).allSatisfy { frame[column: $0, row: 0].intensity > 0 }
    }

    private static func rings(_ meters: MeterDriver) -> [ExplosionsAnimation.Ring] {
        (meters.animation as? ExplosionsAnimation)?.rings ?? []
    }

    /// Runs the main run loop, which carries both the driver's Timer and the
    /// main-actor hop each tick makes, until `condition` holds or time runs out.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 1.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
