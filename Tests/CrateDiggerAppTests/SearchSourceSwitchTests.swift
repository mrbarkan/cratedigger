#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Which source switches carry a live search with them.
///
/// The sidebar counts every crate's matches while you search, so clicking one
/// is navigating *inside* the results and the query has to survive. Everything
/// else is a different library — a disc, a playlist, a phone — where the query
/// you typed about your crates means nothing.
final class SearchSourceSwitchTests: XCTestCase {

    func testTheLocalLibraryIsCrateShaped() {
        XCTAssertTrue(LibrarySource.localAll.isLocalLibrary)
        XCTAssertTrue(LibrarySource.localCrate(name: "Jazz").isLocalLibrary)
        XCTAssertTrue(LibrarySource.prepCrate.isLocalLibrary)
    }

    func testEverythingElseIsNot() {
        XCTAssertFalse(LibrarySource.remote.isLocalLibrary)
        XCTAssertFalse(LibrarySource.playlist(name: "Party").isLocalLibrary)
        XCTAssertFalse(LibrarySource.cd(volumePath: "/Volumes/CD").isLocalLibrary)
        XCTAssertFalse(LibrarySource.device(volumePath: "/Volumes/IPOD").isLocalLibrary)
        XCTAssertFalse(LibrarySource.offlineDevice(profileID: UUID()).isLocalLibrary)
        XCTAssertFalse(LibrarySource.radio(category: nil).isLocalLibrary)
    }

    /// Crate to crate, crate to All Records, either to the Prep Crate: the same
    /// library, so the query stays.
    func testASwitchInsideTheLocalLibraryKeepsTheQuery() {
        XCTAssertTrue(LibrarySource.localCrate(name: "Jazz")
            .keepsSearch(movingTo: .localCrate(name: "Vinyls")))
        XCTAssertTrue(LibrarySource.localCrate(name: "Jazz").keepsSearch(movingTo: .localAll))
        XCTAssertTrue(LibrarySource.localAll.keepsSearch(movingTo: .prepCrate))
    }

    func testLeavingTheLocalLibraryClearsIt() {
        XCTAssertFalse(LibrarySource.localCrate(name: "Jazz")
            .keepsSearch(movingTo: .cd(volumePath: "/Volumes/CD")))
        XCTAssertFalse(LibrarySource.localAll.keepsSearch(movingTo: .playlist(name: "Party")))
        XCTAssertFalse(LibrarySource.radio(category: nil).keepsSearch(movingTo: .localAll),
                       "arriving from somewhere else brings no query worth keeping")
    }
}
#endif
