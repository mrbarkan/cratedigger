import XCTest
@testable import CrateDiggerCore

final class VolumeCapacityTests: XCTestCase {
    /// The boot volume always has *some* free space — a nil or 0 here means the
    /// resource-key read broke, which is what showed a mounted iPod as
    /// "0.0 GB FREE · 100% USED".
    func testBootVolumeReportsFreeSpace() throws {
        let free = try XCTUnwrap(URL(fileURLWithPath: "/").volumeFreeBytes)
        XCTAssertGreaterThan(free, 0)
    }

    func testUnmountedPathReportsNothing() {
        XCTAssertNil(URL(fileURLWithPath: "/Volumes/CrateDiggerNoSuchVolume").volumeFreeBytes)
    }

    /// A destination not made yet still has a volume: the free-space
    /// preflight must not be skipped for a device's first transfer.
    func testFolderNotMadeYetAsksTheNearestExistingOne() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeCapacityTests-\(UUID().uuidString)/Music/Artist", isDirectory: true)
        XCTAssertNil(missing.volumeFreeBytes)
        XCTAssertGreaterThan(try XCTUnwrap(missing.volumeFreeBytesNearby), 0)
    }
}

