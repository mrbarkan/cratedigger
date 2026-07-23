#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class DSDOutputPolicyTests: XCTestCase {
    // The xDuoo XD05 Basic's USB rates (no 705.6k → no DSD256 DoP).
    private let xd05: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    func testAutoRoutesSupportedRatesNative() {
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .native(dopFrameRateHz: 176_400))
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 5_644_800,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .native(dopFrameRateHz: 352_800))
    }

    func testUnsupportedRateFallsBackToPCM() {
        // DSD256 needs 705.6k the XD05 doesn't expose.
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 11_289_600,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .pcmDecode)
        // Built-in output (max 96k) never goes native, even in Native mode.
        XCTAssertEqual(DSDOutputPolicy.route(mode: .native, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: [44100, 48000, 96000]),
                       .pcmDecode)
    }

    func testPCMModeAndNonStereoAlwaysDecode() {
        XCTAssertEqual(DSDOutputPolicy.route(mode: .pcm, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .pcmDecode)
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 2_822_400,
                                             channelCount: 6, deviceSampleRates: xd05),
                       .pcmDecode)
    }
}
#endif
