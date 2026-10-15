#if DEBUG
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// `CRATEDIGGER_BUSY`'s grammar (spec §12). Worth pinning because a hook that
/// misreads its value fails quietly: the screen just stays empty, which reads
/// as a broken picture rather than a typo on the command line.
final class BusyDebugRequestTests: XCTestCase {

    func testOneKindRunsUnfinished() {
        XCTAssertEqual(BusyDebugRequest("convert"),
                       BusyDebugRequest.make([.convert], finished: false))
    }

    func testCommaSeparatedKindsKeepTheirOrder() {
        XCTAssertEqual(BusyDebugRequest("rip,scan")?.kinds, [.rip, .scan])
    }

    func testDoneSuffixAppliesToTheWholeValue() {
        let request = BusyDebugRequest("rip,download:done")
        XCTAssertEqual(request?.kinds, [.rip, .download])
        XCTAssertEqual(request?.finished, true)
    }

    func testRawValuesAreCaseSensitiveLikeOLEDView() {
        XCTAssertEqual(BusyDebugRequest("secureRead")?.kinds, [.secureRead])
        XCTAssertNil(BusyDebugRequest("SCAN"))
    }

    func testWhitespaceAndEmptyTokensAreTolerated() {
        XCTAssertEqual(BusyDebugRequest(" rip , ,scan ")?.kinds, [.rip, .scan])
    }

    func testUnknownKindsAreReportedNotDropped() {
        let request = BusyDebugRequest("rip,secure,scan")
        XCTAssertEqual(request?.kinds, [.rip, .scan])
        XCTAssertEqual(request?.unknown, ["secure"])
    }

    func testAValueNamingNoKindIsNil() {
        XCTAssertNil(BusyDebugRequest(""))
        XCTAssertNil(BusyDebugRequest(":done"))
        XCTAssertNil(BusyDebugRequest("1"))
    }

    func testEveryKindParsesFromItsRawValue() {
        for kind in BusyJobKind.allCases {
            XCTAssertEqual(BusyDebugRequest(kind.rawValue)?.kinds, [kind])
        }
    }
}

private extension BusyDebugRequest {
    static func make(_ kinds: [BusyJobKind], finished: Bool) -> BusyDebugRequest? {
        BusyDebugRequest(kinds.map(\.rawValue).joined(separator: ",") + (finished ? ":done" : ""))
    }
}
#endif
