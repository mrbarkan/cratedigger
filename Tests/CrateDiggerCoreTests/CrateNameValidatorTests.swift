import XCTest
@testable import CrateDiggerCore

final class CrateNameValidatorTests: XCTestCase {
    func testAcceptsUniqueTrimmedName() {
        let result = CrateNameValidator.validate("  House Classics  ", existing: ["Personal Crate"])
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "House Classics")
    }

    func testRejectsEmpty() {
        XCTAssertFalse(CrateNameValidator.validate("", existing: []).isValid)
    }

    func testRejectsWhitespaceOnly() {
        XCTAssertFalse(CrateNameValidator.validate("   \n ", existing: []).isValid)
    }

    func testRejectsSlash() {
        XCTAssertFalse(CrateNameValidator.validate("Soul/Funk", existing: []).isValid)
    }

    func testRejectsColon() {
        XCTAssertFalse(CrateNameValidator.validate("2024:Q1", existing: []).isValid)
    }

    func testRejectsLeadingDot() {
        XCTAssertFalse(CrateNameValidator.validate(".hidden", existing: []).isValid)
    }

    func testRejectsCaseInsensitiveDuplicate() {
        let result = CrateNameValidator.validate("personal crate", existing: ["Personal Crate", "Disco"])
        XCTAssertFalse(result.isValid)
    }

    func testAcceptsUniqueAgainstExisting() {
        let result = CrateNameValidator.validate("Disco", existing: ["Personal Crate", "House"])
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "Disco")
    }

    func testRenamingToSameNameIsAllowed() {
        // Renaming a crate to its own (current) name must not be a "duplicate".
        let result = CrateNameValidator.validate("Disco", existing: ["Disco", "House"], currentName: "Disco")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "Disco")
    }

    func testCaseOnlyRenameOfCurrentNameIsAllowed() {
        let result = CrateNameValidator.validate("DISCO", existing: ["Disco", "House"], currentName: "Disco")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitizedName, "DISCO")
    }
}
