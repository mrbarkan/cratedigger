import XCTest
@testable import CrateDiggerApp

/// The NOW screen's spectrum is only as alive as its driver. Screenshots of the
/// tour can't show it (the old footer meter captured dark too), so the driver's
/// promises are pinned here with a fake spectrum and a real main run loop.
@MainActor
final class MeterDriverTests: XCTestCase {

    func testPlayingLightsEveryColumn() {
        let meters = MeterDriver()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }

        meters.start()
        pump(until: { meters.bands.allSatisfy { $0 > 0.5 } })

        XCTAssertTrue(meters.bands.allSatisfy { $0 > 0.5 }, "bands after start: \(meters.bands)")
        meters.halt()
    }

    func testStoppingFadesBackToZero() {
        let meters = MeterDriver()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }
        meters.start()
        pump(until: { meters.bands.allSatisfy { $0 > 0.5 } })

        meters.stop()
        pump(until: { meters.bands.allSatisfy { $0 == 0 } }, timeout: 3)

        XCTAssertEqual(meters.bands, Array(repeating: 0, count: 12))
    }

    func testHaltClearsAtOnce() {
        let meters = MeterDriver()
        meters.spectrumProvider = { Array(repeating: 0.9, count: 12) }
        meters.start()
        pump(until: { meters.bands.allSatisfy { $0 > 0.5 } })

        meters.halt()

        XCTAssertEqual(meters.bands, Array(repeating: 0, count: 12))
    }

    func testNoProviderStaysDark() {
        let meters = MeterDriver()
        meters.start()
        pump(until: { false }, timeout: 0.3)

        XCTAssertEqual(meters.bands, Array(repeating: 0, count: 12))
        meters.halt()
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
