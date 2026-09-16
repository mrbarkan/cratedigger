#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// A library index on an external drive used to vanish when the drive was out:
/// the bookmark failed, the app quietly used an empty folder in Application
/// Support, and wrote a fresh Personal Crate into it. `LibraryLocation` is the
/// decision that replaces that guess.
final class LibraryLocationTests: XCTestCase {

    private let mounted: Set<String> = ["Macintosh HD", "MUSIC"]
    private func isMounted(_ name: String) -> Bool { mounted.contains(name) }

    func testNoBookmarkMeansNoFolderWasChosen() {
        let location = LibraryLocation.resolve(
            bookmarkChosen: false, resolvedFolder: nil, lastKnownFolder: nil, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .notChosen)
    }

    func testAFolderOnTheInternalDiskIsAvailable() {
        let folder = URL(fileURLWithPath: "/Users/someone/Music/Crates")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: folder, lastKnownFolder: nil, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .available(folder))
    }

    func testAFolderOnAMountedDriveIsAvailable() {
        let folder = URL(fileURLWithPath: "/Volumes/MUSIC/CD_CI")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: folder, lastKnownFolder: nil, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .available(folder))
    }

    /// Whether macOS hands back the old path for a drive that is gone is not
    /// something to rely on, so a resolved path is still checked.
    func testAResolvedFolderOnAnUnmountedDriveIsDisconnected() {
        let folder = URL(fileURLWithPath: "/Volumes/ARCHIVE/Crates")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: folder, lastKnownFolder: nil, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .disconnected(volumeName: "ARCHIVE", folder: folder))
    }

    func testAnUnresolvableBookmarkFallsBackToTheLastKnownFolder() {
        let lastKnown = URL(fileURLWithPath: "/Volumes/ARCHIVE/Crates")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: nil, lastKnownFolder: lastKnown, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .disconnected(volumeName: "ARCHIVE", folder: lastKnown))
    }

    func testTheLastKnownFolderIsUsedWhenItsDriveIsBack() {
        let lastKnown = URL(fileURLWithPath: "/Volumes/MUSIC/CD_CI")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: nil, lastKnownFolder: lastKnown, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .available(lastKnown))
    }

    func testTheResolvedFolderWinsOverTheLastKnownOne() {
        let resolved = URL(fileURLWithPath: "/Volumes/MUSIC/Moved")
        let lastKnown = URL(fileURLWithPath: "/Volumes/MUSIC/CD_CI")
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: resolved, lastKnownFolder: lastKnown, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .available(resolved))
    }

    /// Nothing to go on: never pretend the library is empty, and never say
    /// which drive when nobody knows.
    func testAChosenFolderWithNothingKnownIsDisconnectedWithoutAName() {
        let location = LibraryLocation.resolve(
            bookmarkChosen: true, resolvedFolder: nil, lastKnownFolder: nil, isVolumeMounted: isMounted
        )
        XCTAssertEqual(location, .disconnected(volumeName: nil, folder: nil))
        XCTAssertTrue(location.isDisconnected)
    }

    func testOnlyDisconnectedCountsAsDisconnected() {
        XCTAssertFalse(LibraryLocation.notChosen.isDisconnected)
        XCTAssertFalse(LibraryLocation.available(URL(fileURLWithPath: "/tmp")).isDisconnected)
    }

    // MARK: - Volume names

    func testVolumeNameReadsTheDriveUnderVolumes() {
        XCTAssertEqual(LibraryLocation.volumeName(of: URL(fileURLWithPath: "/Volumes/MUSIC/CD_CI")), "MUSIC")
        XCTAssertEqual(LibraryLocation.volumeName(of: URL(fileURLWithPath: "/Volumes/MUSIC")), "MUSIC")
        XCTAssertEqual(LibraryLocation.volumeName(of: URL(fileURLWithPath: "/Volumes/My Drive/a b")), "My Drive")
    }

    func testVolumeNameIsNilOffTheVolumesTree() {
        XCTAssertNil(LibraryLocation.volumeName(of: URL(fileURLWithPath: "/Volumes")))
        XCTAssertNil(LibraryLocation.volumeName(of: URL(fileURLWithPath: "/Users/someone/Music")))
    }

    func testVolumeNameIsReadFromTheStandardizedPath() {
        let dotted = URL(fileURLWithPath: "/Volumes/MUSIC/../ARCHIVE/Crates")
        XCTAssertEqual(LibraryLocation.volumeName(of: dotted), "ARCHIVE")
    }
}
#endif
