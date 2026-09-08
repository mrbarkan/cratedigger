import XCTest
@testable import CrateDiggerCore

final class PatchBayGoActionTests: XCTestCase {

    func testNothingArmedIsThePlainCrateConvert() {
        let action = PatchBayGoAction.resolve(
            pendingDeviceName: nil, armedDeviceName: nil, armedDeviceIsConnected: false
        )
        XCTAssertEqual(action, .convert)
        XCTAssertEqual(action.label, "CONVERT")
        XCTAssertFalse(action.isDeviceRun)
    }

    func testHandOffOutranksAnArmedQueue() {
        let action = PatchBayGoAction.resolve(
            pendingDeviceName: "iPod", armedDeviceName: "SD Card", armedDeviceIsConnected: true
        )
        XCTAssertEqual(action, .sendToDevice(deviceName: "iPod"))
        XCTAssertEqual(action.label, "SEND TO IPOD")
    }

    /// The reported bug: a queue for a plugged-in device offered SYNC NOW on
    /// the device strip and CONVERT in the cockpit, for the same tracks.
    func testArmedConnectedDeviceQueueSyncs() {
        let action = PatchBayGoAction.resolve(
            pendingDeviceName: nil, armedDeviceName: "iPod", armedDeviceIsConnected: true
        )
        XCTAssertEqual(action, .syncToDevice(deviceName: "iPod"))
        XCTAssertEqual(action.label, "SYNC TO IPOD")
        XCTAssertTrue(action.isDeviceRun)
    }

    func testArmedUnpluggedDeviceQueueBakesInstead() {
        let action = PatchBayGoAction.resolve(
            pendingDeviceName: nil, armedDeviceName: "iPod", armedDeviceIsConnected: false
        )
        XCTAssertEqual(action, .preConvertForDevice(deviceName: "iPod"))
        XCTAssertEqual(action.label, "PRE-CONVERT FOR IPOD")
    }
}
