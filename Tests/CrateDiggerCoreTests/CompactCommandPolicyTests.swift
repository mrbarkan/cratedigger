#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class CompactCommandPolicyTests: XCTestCase {
    func testEverythingIsAvailableInTheFullLayout() {
        for command in PlayerCommand.allCases {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .full), .available, "\(command)")
        }
    }

    func testBrowserCommandsExpandFirstInCompact() {
        for command in [PlayerCommand.find, .goToCurrentSong, .selectDisplay] {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .compact), .expandsFirst, "\(command)")
        }
    }

    func testSelectionCommandsAreDisabledInCompact() {
        let selection: [PlayerCommand] = [.revealSelection, .convertSelected, .transferToDevice,
                                          .playNextSelection, .playLastSelection, .rate]
        for command in selection {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .compact), .disabled, "\(command)")
        }
    }

    func testEveryCommandIsClassified() {
        // A new case must land in one of the two compact lists above.
        XCTAssertEqual(PlayerCommand.allCases.count, 9)
    }
}
#endif
