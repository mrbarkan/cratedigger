#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class DoPPackerTests: XCTestCase {
    func testMarkerAlternation() {
        XCTAssertEqual(DoPPacker.markers, [0x05, 0xFA])
    }

    func testWordPacksMarkerAndBitReversedPayload() {
        // LSB-first byte 0x01 (earliest bit set) must become MSB-first 0x80.
        XCTAssertEqual(DoPPacker.word(marker: 0x05, older: 0x01, newer: 0x00, lsbFirst: true),
                       0x05_80_00)
        // MSB-first bytes pass through unreversed.
        XCTAssertEqual(DoPPacker.word(marker: 0x05, older: 0x01, newer: 0x00, lsbFirst: false),
                       0x05_01_00)
    }

    func testWordWithHighMarkerIsNegative24Bit() {
        // 0xFA in the top byte makes the 24-bit word negative after sign extension.
        let word = DoPPacker.word(marker: 0xFA, older: 0, newer: 0, lsbFirst: true)
        XCTAssertEqual(word, Int32(bitPattern: 0xFFFA_0000))
        XCTAssertLessThan(word, 0)
    }

    func testFloatEncodingIsExactFor24Bit() {
        XCTAssertEqual(DoPPacker.float(fromWord: 0x05_80_00), Float(0x058000) / 8_388_608)
        XCTAssertEqual(DoPPacker.float(fromWord: -8_388_608), -1.0)
    }

    func testDSDSilenceMeasuresZeroAmplitude() {
        // 0x69 = 01101001 — four 1s of eight: the standard DSD idle pattern.
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0x69, count: 64)), 0, accuracy: 1e-9)
        // All-ones (DC full positive) and all-zeros both measure full scale.
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0xFF, count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0x00, count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(DSDLevelMeter.amplitude(of: []), 0)
    }

    func testMeterScaleMatchesDocumentedAnchors() {
        // -48 dBFS → 0 and 0 dBFS → 0.80 — the anchors MeterDriver calibrates to.
        XCTAssertEqual(PlaybackMeterScale.position(fromLinear: 1.0), 0.80, accuracy: 1e-9)
        XCTAssertEqual(PlaybackMeterScale.position(fromLinear: pow(10, -48.0 / 20)), 0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackMeterScale.position(fromLinear: 0), 0)
    }
}
#endif
