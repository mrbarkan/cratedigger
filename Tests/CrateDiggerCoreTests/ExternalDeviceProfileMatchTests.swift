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

    /// Whether a file lies on a mounted device that has a profile: what a
    /// writer outside the device door asks before writing there.
    func testProfileDeviceHoldingAFile() {
        let ipod = device("IPOD", "/Volumes/IPOD", uuid: "UUID-A")
        let stick = device("STICK", "/Volumes/STICK", uuid: "UUID-S")
        let profiles = [ExternalDeviceProfile(name: "IPOD", rootDisplayPath: "/Volumes/IPOD", volumeUUID: "UUID-A")]
        let devices = [ipod, stick]

        XCTAssertEqual(MountedDevice.profileDevice(holding: URL(fileURLWithPath: "/Volumes/IPOD/Music/A/01.mp3"),
                                                   in: devices, profiles: profiles), ipod)
        XCTAssertEqual(MountedDevice.profileDevice(holding: URL(fileURLWithPath: "/volumes/ipod/Music"),
                                                   in: devices, profiles: profiles), ipod, "FAT ignores case")
        XCTAssertNil(MountedDevice.profileDevice(holding: URL(fileURLWithPath: "/Volumes/STICK/x.mp3"),
                                                 in: devices, profiles: profiles), "a volume no profile names")
        XCTAssertNil(MountedDevice.profileDevice(holding: URL(fileURLWithPath: "/Volumes/IPOD 1/x.mp3"),
                                                 in: devices, profiles: profiles))
        XCTAssertNil(MountedDevice.profileDevice(holding: URL(fileURLWithPath: "/Users/me/Music/x.mp3"),
                                                 in: devices, profiles: profiles))
    }
}

