#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Integration-level: runs against the machine's real default output device.
/// Every Mac has one, and every output device supports at least one rate.
final class AudioOutputManagerRateTests: XCTestCase {
    func testDefaultDeviceReportsRates() throws {
        let manager = AudioOutputManager()
        let device = try XCTUnwrap(manager.defaultOutputDeviceID())
        let rates = manager.availableSampleRates(deviceID: device)
        XCTAssertFalse(rates.isEmpty)
        let nominal = try XCTUnwrap(manager.nominalSampleRate(deviceID: device))
        XCTAssertGreaterThan(nominal, 0)
    }

    func testNilUIDResolvesToDefaultDevice() throws {
        let manager = AudioOutputManager()
        XCTAssertEqual(manager.deviceID(forUID: nil), manager.defaultOutputDeviceID())
        XCTAssertEqual(manager.deviceID(forUID: "no-such-uid-ever"), manager.defaultOutputDeviceID())
    }
}
#endif
