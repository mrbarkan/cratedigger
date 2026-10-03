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
                                          .playNextSelection, .playLastSelection, .rate,
                                          .browserKeyboard, .selectAll]
        for command in selection {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .compact), .disabled, "\(command)")
        }
    }

    /// Arrows and ⌘A move the browser selection through the key monitor and
    /// the responder chain, not a menu item, so they need the policy too.
    func testBrowserKeyboardAndSelectAllAreDisabledInCompact() {
        XCTAssertEqual(CompactCommandPolicy.availability(.browserKeyboard, in: .compact), .disabled)
        XCTAssertEqual(CompactCommandPolicy.availability(.selectAll, in: .compact), .disabled)
        XCTAssertEqual(CompactCommandPolicy.availability(.browserKeyboard, in: .full), .available)
    }

    func testEveryCommandIsClassified() {
        // A new case must land in one of the two compact lists above.
        XCTAssertEqual(PlayerCommand.allCases.count, 11)
    }
}
#endif
