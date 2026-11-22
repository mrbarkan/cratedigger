import XCTest
@testable import CrateDiggerCore

/// Mounting only reads (spec invariant I6); extras, play import and
/// scrobbling also need the device matched by volume UUID.
final class DeviceSessionGateTests: XCTestCase {
    func testMountAllowsOnlyProbe() {
        XCTAssertEqual(DeviceAction.allCases.count, 6)
        for matched in [false, true] {
            for action in DeviceAction.allCases {
                XCTAssertEqual(DeviceSessionGate.allows(action, trigger: .mount, matchedByUUID: matched),
                               action == .probe, "\(action), matchedByUUID: \(matched)")
            }
        }
    }

    func testUserActionWithoutUUIDAllowsTransferAndSweepOnly() {
        let allowed = DeviceAction.allCases.filter {
            DeviceSessionGate.allows($0, trigger: .userAction, matchedByUUID: false)
        }
        XCTAssertEqual(allowed, [.probe, .transferAudio, .sweep])
    }

    func testUserActionWithUUIDAllowsEverything() {
        for action in DeviceAction.allCases {
            XCTAssertTrue(DeviceSessionGate.allows(action, trigger: .userAction, matchedByUUID: true), "\(action)")
        }
    }
}
