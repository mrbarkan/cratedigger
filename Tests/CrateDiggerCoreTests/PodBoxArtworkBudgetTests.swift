import XCTest
@testable import CrateDiggerCore

final class PodBoxArtworkBudgetTests: XCTestCase {
    func testCountsExistingFilesOfAnyOwner() {
        let budget = PodBoxArtworkBudget(existingNames: ["Björk.jpg", "AC-DC - Powerage.png", "x.jpg"])
        XCTAssertEqual(budget.remainingFiles, PodBoxArtworkBudget.files - 3)
        // UTF-8 length plus one per name: 11 + 21 + 6.
        XCTAssertEqual(budget.remainingNameBytes, PodBoxArtworkBudget.nameBytes - (11 + 21 + 6))
        XCTAssertEqual(PodBoxArtworkBudget.files, 1_900)
        XCTAssertEqual(PodBoxArtworkBudget.nameBytes, 44 * 1024)
        XCTAssertEqual(PodBoxArtworkBudget.people, 8_192)
    }

    func testStopsAtFileLimit() {
        var budget = PodBoxArtworkBudget(existingNames: (0..<1_899).map { "\($0).jpg" })
        XCTAssertEqual(budget.remainingFiles, 1)
        XCTAssertTrue(budget.take(fileName: "One.jpg"))
        XCTAssertEqual(budget.remainingFiles, 0)
        XCTAssertFalse(budget.take(fileName: "Two.jpg"))
    }

    func testStopsAtNameBytes() {
        // Three names of 15,000 bytes each plus their terminators fill 45,003 of 45,056.
        let long = String(repeating: "a", count: 14_996) + ".jpg"
        var budget = PodBoxArtworkBudget(existingNames: [long, long, long])
        XCTAssertEqual(budget.remainingNameBytes, 45_056 - 45_003)
        XCTAssertFalse(budget.take(fileName: String(repeating: "b", count: 49) + ".jpg"), "54 bytes > 53 left")
        XCTAssertTrue(budget.take(fileName: String(repeating: "b", count: 48) + ".jpg"), "53 bytes fit exactly")
        XCTAssertEqual(budget.remainingNameBytes, 0)
        XCTAssertFalse(budget.take(fileName: "c"))
    }

    func testFailedTakeChangesNothing() {
        var budget = PodBoxArtworkBudget(existingNames: (0..<1_900).map { "\($0).jpg" })
        let files = budget.remainingFiles
        let bytes = budget.remainingNameBytes
        XCTAssertFalse(budget.take(fileName: "More.jpg"))
        XCTAssertEqual(budget.remainingFiles, files)
        XCTAssertEqual(budget.remainingNameBytes, bytes)

        // Over the limit already (the owner's own files): nothing left, nothing negative.
        var over = PodBoxArtworkBudget(existingNames: (0..<2_000).map { "\($0).jpg" })
        XCTAssertEqual(over.remainingFiles, 0)
        XCTAssertFalse(over.take(fileName: "x.jpg"))
        XCTAssertEqual(over.remainingFiles, 0)
    }
}
