#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class BrowserEmptyKindTests: XCTestCase {
    func testPrepCrateExplainsItself() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .prepCrate, disconnected: false), .prepCrate)
    }

    func testEmptyNamedCrateIsNotNoLibrary() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localCrate(name: "Jazz"), disconnected: false),
                       .emptyCrate(name: "Jazz"))
    }

    func testAllRecordsWithNothingIsNoLibrary() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localAll, disconnected: false), .noLibrary)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .other, disconnected: false), .noLibrary)
    }

    func testDisconnectedWinsForLocalSourcesOnly() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localAll, disconnected: true), .disconnected)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localCrate(name: "Jazz"), disconnected: true), .disconnected)
        // The Prep Crate and non-library sources keep their own message: that is
        // today's behaviour (`isLocalSource` excludes them) and it stays.
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .prepCrate, disconnected: true), .prepCrate)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .other, disconnected: true), .noLibrary)
    }
}
#endif
