import XCTest
@testable import CrateDiggerCore

final class AutoEQTests: XCTestCase {

    /// A real AutoEQ export, shape and spacing included.
    private let sample = """
    Preamp: -6.1 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON PK Fc 1150 Hz Gain -3.4 dB Q 1.20
    Filter 3: ON PK Fc 3200 Hz Gain 4.1 dB Q 2.00
    Filter 4: OFF PK Fc 8000 Hz Gain 9.9 dB Q 1.00
    Filter 5: ON HPQ Fc 30 Hz Gain 0.0 dB Q 0.70
    """

    func testParsesFiltersPreampAndSkipsDisabled() {
        let profile = AutoEQParser.parse(sample)
        XCTAssertEqual(profile.preampDB, -6.1, accuracy: 0.001)
        XCTAssertEqual(profile.filters.count, 3)          // the OFF and the HPQ drop out
        XCTAssertEqual(profile.unsupportedCount, 1)       // HPQ is a high-pass

        XCTAssertEqual(profile.filters[0].kind, .lowShelf)
        XCTAssertEqual(profile.filters[0].frequency, 105)
        XCTAssertEqual(profile.filters[0].gainDB, 5.5, accuracy: 0.001)
        XCTAssertEqual(profile.filters[1].kind, .peaking)
        XCTAssertEqual(profile.filters[2].q, 2.0, accuracy: 0.001)
    }

    func testParsingIgnoresProseAndBlankLines() {
        let profile = AutoEQParser.parse("""
        # Sennheiser HD 600 (oratory1990)
        Notes: paste this into your EQ

        Filter 1: ON PK Fc 200 Hz Gain 2.0 dB Q 1.00
        """)
        XCTAssertEqual(profile.filters.count, 1)
        XCTAssertEqual(profile.preampDB, 0)
    }

    func testEmptyTextYieldsEmptyProfile() {
        XCTAssertTrue(AutoEQParser.parse("nothing to see here").isEmpty)
    }

    /// A peaking filter is 0 dB far from its centre and its full gain at it.
    func testResponseIsGainAtCentreAndFlatFarAway() {
        let filter = AutoEQFilter(kind: .peaking, frequency: 1000, gainDB: 6, q: 1.41)
        XCTAssertEqual(AutoEQMapper.response(of: filter, at: 1000), 6, accuracy: 0.05)
        XCTAssertEqual(AutoEQMapper.response(of: filter, at: 40), 0, accuracy: 0.3)
    }

    /// The whole point of the fit: the 12 bands together must reproduce the
    /// parametric curve, not merely sample it. Naive per-centre sampling
    /// overshoots because neighbouring bands overlap.
    func testFittedBandsReproduceTheCurve() {
        let profile = AutoEQParser.parse(sample)
        let result = AutoEQMapper.map(profile)

        XCTAssertEqual(result.gains.count, EqualizerProcessor.bandCount)
        XCTAssertLessThan(result.fitErrorDB, 1.0, "12 bands should track this curve within a dB")
        XCTAssertEqual(result.clampedBands, 0)

        // Bass shelf lifts the low bands, the 1.15 kHz dip pulls a mid down.
        XCTAssertGreaterThan(result.gains[0], 2)
        let midIndex = EqualizerProcessor.centerFrequencies.firstIndex { $0 > 1000 } ?? 0
        XCTAssertLessThan(result.gains[midIndex], 0)
    }

    func testFlatProfileMapsToFlatBands() {
        let result = AutoEQMapper.map(AutoEQProfile(preampDB: 0, filters: [], unsupportedCount: 0))
        XCTAssertTrue(result.gains.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.fitErrorDB, 0, accuracy: 0.0001)
    }

    func testExtremeCurveClampsToFaderRangeAndReportsIt() {
        let profile = AutoEQProfile(
            preampDB: 0,
            filters: [AutoEQFilter(kind: .peaking, frequency: 1000, gainDB: 24, q: 1.41)],
            unsupportedCount: 0
        )
        let result = AutoEQMapper.map(profile)
        XCTAssertGreaterThan(result.clampedBands, 0)
        XCTAssertTrue(result.gains.allSatisfy { abs($0) <= 12 })
    }

    /// Gains land on the faders' 0.5 dB detents, so an imported curve can be
    /// nudged from the UI without the first drag snapping it somewhere else.
    func testGainsSnapToHalfDecibelSteps() {
        let result = AutoEQMapper.map(AutoEQParser.parse(sample))
        for gain in result.gains {
            XCTAssertEqual(gain * 2, (gain * 2).rounded(), accuracy: 0.0001)
        }
    }
}
