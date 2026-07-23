import XCTest
@testable import CrateDiggerCore

final class DSDFormatTests: XCTestCase {
    func testStandardRatesMapToLabels() {
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 2_822_400), "DSD64")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 5_644_800), "DSD128")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 11_289_600), "DSD256")
    }

    func testNonDSDRateReturnsNil() {
        XCTAssertNil(DSDFormat.label(sampleRateHz: 44_100))
        XCTAssertNil(DSDFormat.label(sampleRateHz: 176_400))
        XCTAssertNil(DSDFormat.label(sampleRateHz: nil))
    }

    func testGenericDSDForNonStandardHighRate() {
        // A DSD-range rate that isn't a clean 64x multiple still reads as DSD.
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 3_000_000), "DSD")
    }

    func testFfprobeByteRatesMapToLabels() {
        // ffprobe reports DSD sample_rate in bytes/sec (bit rate ÷ 8) for the
        // dsd_*_planar codecs real DSF files use — verified against a real
        // sacd_extract rip. The label call is gated on isDSDCodec, so a PCM
        // rate like 352.8 kHz DXD never reaches this mapping.
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 352_800), "DSD64")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 705_600), "DSD128")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 1_411_200), "DSD256")
        XCTAssertNil(DSDFormat.label(sampleRateHz: 192_000))
    }

    func testCodecNameDetection() {
        XCTAssertTrue(DSDFormat.isDSDCodec("dsd_lsbf"))
        XCTAssertTrue(DSDFormat.isDSDCodec("DSD_MSBF_PLANAR"))
        XCTAssertFalse(DSDFormat.isDSDCodec("flac"))
        XCTAssertFalse(DSDFormat.isDSDCodec(nil))
    }
}
