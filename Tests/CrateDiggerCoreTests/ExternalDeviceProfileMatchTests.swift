import XCTest
@testable import CrateDiggerCore

/// Guards the fix for "any Rockbox iPod matches the one saved profile": every iPod
/// mounts at /Volumes/IPOD with volume name "IPOD", so matching must key on the
/// stable volume UUID when it's known, not the shared path/name.
final class ExternalDeviceProfileMatchTests: XCTestCase {
    private func device(_ name: String, _ path: String, uuid: String?) -> MountedDevice {
        MountedDevice(name: name, volumeURL: URL(fileURLWithPath: path), volumeUUID: uuid)
    }

    func testDistinguishesTwoIdenticalIPodsByVolumeUUID() {
        let a = ExternalDeviceProfile(name: "IPOD", rootDisplayPath: "/Volumes/IPOD", volumeUUID: "UUID-A")
        let b = ExternalDeviceProfile(name: "IPOD", rootDisplayPath: "/Volumes/IPOD", volumeUUID: "UUID-B")
        let profiles = [a, b]

        XCTAssertEqual(ExternalDeviceProfile.match(device("IPOD", "/Volumes/IPOD", uuid: "UUID-B"), in: profiles)?.id, b.id)
        XCTAssertEqual(ExternalDeviceProfile.match(device("IPOD", "/Volumes/IPOD", uuid: "UUID-A"), in: profiles)?.id, a.id)
    }

    func testStoredUUIDRejectsADifferentDeviceWithSameNameAndPath() {
        // The reported bug: profile is bound to iPod A; a *different* iPod B with the
        // same name and mount path must NOT be recognized as this device.
        let saved = ExternalDeviceProfile(name: "IPOD", rootDisplayPath: "/Volumes/IPOD", volumeUUID: "UUID-A")
        XCTAssertNil(ExternalDeviceProfile.match(device("IPOD", "/Volumes/IPOD", uuid: "UUID-B"), in: [saved]))
    }

    func testLegacyProfileWithoutUUIDFallsBackToPathThenName() {
        let byPath = ExternalDeviceProfile(name: "Old Name", rootDisplayPath: "/Volumes/IPOD", volumeUUID: nil)
        XCTAssertEqual(ExternalDeviceProfile.match(device("IPOD", "/Volumes/IPOD", uuid: "UUID-X"), in: [byPath])?.id, byPath.id)

        let byName = ExternalDeviceProfile(name: "IPOD", rootDisplayPath: nil, volumeUUID: nil)
        XCTAssertEqual(ExternalDeviceProfile.match(device("IPOD", "/Volumes/OTHER", uuid: "UUID-X"), in: [byName])?.id, byName.id)
    }

    func testUnknownVolumeMatchesNothing() {
        let saved = ExternalDeviceProfile(name: "IPOD", rootDisplayPath: "/Volumes/IPOD", volumeUUID: "UUID-A")
        XCTAssertNil(ExternalDeviceProfile.match(device("USB DRIVE", "/Volumes/USB", uuid: "UUID-Z"), in: [saved]))
    }
}
