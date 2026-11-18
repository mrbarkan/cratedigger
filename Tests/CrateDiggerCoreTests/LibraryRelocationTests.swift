#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LibraryRelocationTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func plan(
        tracks: [String], newRoot: String, candidates: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) -> LibraryRelocation.Plan? {
        let outcome = LibraryRelocation.plan(
            tracks: tracks.map(url), newRoot: url(newRoot), candidates: candidates.map(url))
        guard case .relocate(let plan) = outcome else {
            XCTFail("expected a plan, got \(outcome)", file: file, line: line)
            return nil
        }
        return plan
    }

    // MARK: - Finding the copy

    func testCopiedLibraryMapsEveryTrackToTheSameRelativePath() throws {
        let plan = try XCTUnwrap(plan(
            tracks: ["/Volumes/Old/Music/Can/Tago Mago/01.flac", "/Volumes/Old/Music/Can/Tago Mago/02.flac"],
            newRoot: "/Volumes/New/Music",
            candidates: ["/Volumes/New/Music/Can/Tago Mago/01.flac", "/Volumes/New/Music/Can/Tago Mago/02.flac"]
        ))
        XCTAssertEqual(plan.oldRoot.path, "/Volumes/Old/Music")
        XCTAssertEqual(plan.newRoot.path, "/Volumes/New/Music")
        XCTAssertEqual(plan.moves, [
            url("/Volumes/Old/Music/Can/Tago Mago/01.flac"): url("/Volumes/New/Music/Can/Tago Mago/01.flac"),
            url("/Volumes/Old/Music/Can/Tago Mago/02.flac"): url("/Volumes/New/Music/Can/Tago Mago/02.flac"),
        ])
        XCTAssertEqual(plan.withoutCopy, 0)
        XCTAssertEqual(plan.alreadyInLibrary, 0)
    }

    /// Picking the drive rather than the folder still works: the old root is
    /// then the drive the library was on.
    func testPickingTheDriveFindsTheLibraryThroughItsFolders() throws {
        let plan = try XCTUnwrap(plan(
            tracks: ["/Volumes/Old/Music/Can/01.flac"],
            newRoot: "/Volumes/New",
            candidates: ["/Volumes/New/Music/Can/01.flac"]
        ))
        XCTAssertEqual(plan.oldRoot.path, "/Volumes/Old")
        XCTAssertEqual(plan.moves[url("/Volumes/Old/Music/Can/01.flac")], url("/Volumes/New/Music/Can/01.flac"))
    }

    /// The difference from `RelinkMatcher`: these tracks are not missing, so a
    /// file that merely shares a name is not taken for a copy.
    func testSameFileNameInAnotherFolderIsNotACopy() {
        let outcome = LibraryRelocation.plan(
            tracks: [url("/Volumes/Old/Music/Can/Tago Mago/01.flac")],
            newRoot: url("/Volumes/New/Music"),
            candidates: [url("/Volumes/New/Music/Neu!/Neu! 75/01.flac")]
        )
        XCTAssertEqual(outcome, .noCopyFound)
    }

    func testTrackWithNoCopyStaysAndIsCounted() throws {
        let plan = try XCTUnwrap(plan(
            tracks: ["/Volumes/Old/Music/Can/01.flac", "/Volumes/Old/Music/Can/02.flac"],
            newRoot: "/Volumes/New/Music",
            candidates: ["/Volumes/New/Music/Can/01.flac"]
        ))
        XCTAssertEqual(Array(plan.moves.keys), [url("/Volumes/Old/Music/Can/01.flac")])
        XCTAssertEqual(plan.withoutCopy, 1)
    }

    /// One root per run, the one most tracks sit under. A stray file elsewhere
    /// that happens to have a namesake in the new folder is left alone.
    func testTracksOutsideTheOldRootAreLeftAlone() throws {
        let plan = try XCTUnwrap(plan(
            tracks: [
                "/Volumes/Old/Music/Can/01.flac",
                "/Volumes/Old/Music/Can/02.flac",
                "/Users/me/Downloads/loose.mp3",
            ],
            newRoot: "/Volumes/New/Music",
            candidates: [
                "/Volumes/New/Music/Can/01.flac",
                "/Volumes/New/Music/Can/02.flac",
                "/Volumes/New/Music/loose.mp3",
            ]
        ))
        XCTAssertEqual(plan.oldRoot.path, "/Volumes/Old/Music")
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertNil(plan.moves[url("/Users/me/Downloads/loose.mp3")])
        XCTAssertEqual(plan.withoutCopy, 0, "a track outside the old root is not a track without a copy")
    }

    /// Drives disagree about case and about composed or decomposed accents
    /// (HFS+ against exFAT), and the copy is the same file all the same. The
    /// track is pointed at the name as the new drive spells it.
    func testCaseAndUnicodeFormDoNotHideACopy() throws {
        let decomposed = "/Volumes/Old/Music/Cafe\u{301} Tacvba/Re/01.flac"
        let precomposed = "/Volumes/New/music/Caf\u{e9} Tacvba/RE/01.FLAC"
        let plan = try XCTUnwrap(plan(
            tracks: [decomposed], newRoot: "/Volumes/New/music", candidates: [precomposed]))
        XCTAssertEqual(plan.moves[url(decomposed)]?.path, url(precomposed).path)
    }

    // MARK: - Nothing to do

    func testLibraryAlreadyInTheNewFolderIsAlreadyThere() {
        let outcome = LibraryRelocation.plan(
            tracks: [url("/Volumes/New/Music/Can/01.flac")],
            newRoot: url("/Volumes/New/Music"),
            candidates: [url("/Volumes/New/Music/Can/01.flac")]
        )
        XCTAssertEqual(outcome, .alreadyThere)
    }

    func testNoTracksIsNoCopyFound() {
        XCTAssertEqual(
            LibraryRelocation.plan(tracks: [], newRoot: url("/Volumes/New"), candidates: [url("/Volumes/New/a.flac")]),
            .noCopyFound)
    }

    /// A copy the library already holds as its own track cannot be relocated
    /// onto: the crate would hold the same file twice.
    func testCopyAlreadyInTheLibraryIsLeftAlone() throws {
        let plan = try XCTUnwrap(plan(
            tracks: [
                "/Volumes/Old/Music/Can/01.flac",
                "/Volumes/Old/Music/Can/02.flac",
                "/Volumes/New/Music/Can/01.flac",
            ],
            newRoot: "/Volumes/New/Music",
            candidates: ["/Volumes/New/Music/Can/01.flac", "/Volumes/New/Music/Can/02.flac"]
        ))
        XCTAssertEqual(Array(plan.moves.keys), [url("/Volumes/Old/Music/Can/02.flac")])
        XCTAssertEqual(plan.alreadyInLibrary, 1)
        XCTAssertEqual(plan.withoutCopy, 0)
    }

    func testEveryCopyAlreadyInTheLibraryIsAlreadyThere() {
        let outcome = LibraryRelocation.plan(
            tracks: [url("/Volumes/Old/Music/Can/01.flac"), url("/Volumes/New/Music/Can/01.flac")],
            newRoot: url("/Volumes/New/Music"),
            candidates: [url("/Volumes/New/Music/Can/01.flac")]
        )
        XCTAssertEqual(outcome, .alreadyThere)
    }

    // MARK: - Folders that follow

    func testCounterpartOfTheOldRootIsTheNewRoot() {
        XCTAssertEqual(
            LibraryRelocation.counterpart(
                of: url("/Volumes/Old/Music"), from: url("/Volumes/Old/Music"), to: url("/Volumes/New/Tunes"))?.path,
            "/Volumes/New/Tunes")
    }

    func testCounterpartOfAFolderInsideKeepsItsPlace() {
        XCTAssertEqual(
            LibraryRelocation.counterpart(
                of: url("/Volumes/Old/Music/Library"), from: url("/Volumes/Old"), to: url("/Volumes/New"))?.path,
            "/Volumes/New/Music/Library")
    }

    func testFolderOutsideTheOldRootHasNoCounterpart() {
        XCTAssertNil(LibraryRelocation.counterpart(
            of: url("/Users/me/Music"), from: url("/Volumes/Old/Music"), to: url("/Volumes/New/Music")))
        XCTAssertNil(LibraryRelocation.counterpart(
            of: url("/Volumes/Old/Music2"), from: url("/Volumes/Old/Music"), to: url("/Volumes/New/Music")),
            "a folder whose name only starts the same is not inside")
    }

    // MARK: - The index left on the old drive

    func testIndexOnTheOldDriveIsNamed() {
        XCTAssertEqual(
            LibraryRelocation.driveStillHoldingIndex(
                indexFolder: url("/Volumes/Old/Crates"),
                oldRoot: url("/Volumes/Old/Music"), newRoot: url("/Volumes/New/Music")),
            "Old")
    }

    func testIndexElsewhereOrOnTheSameDriveAsTheCopyIsNotNamed() {
        XCTAssertNil(LibraryRelocation.driveStillHoldingIndex(
            indexFolder: url("/Users/me/Library/Application Support/CrateDigger/Crates"),
            oldRoot: url("/Volumes/Old/Music"), newRoot: url("/Volumes/New/Music")))
        XCTAssertNil(LibraryRelocation.driveStillHoldingIndex(
            indexFolder: url("/Volumes/Old/Crates"),
            oldRoot: url("/Volumes/Old/Music"), newRoot: url("/Volumes/Old/Music Copy")))
        XCTAssertNil(LibraryRelocation.driveStillHoldingIndex(
            indexFolder: url("/Volumes/Third/Crates"),
            oldRoot: url("/Volumes/Old/Music"), newRoot: url("/Volumes/New/Music")))
    }

    // MARK: - Words

    private func textPlan(moves: Int, withoutCopy: Int = 0, alreadyInLibrary: Int = 0) -> LibraryRelocation.Plan {
        var map: [URL: URL] = [:]
        for i in 0..<moves {
            map[url("/Volumes/Old/Music/\(i).flac")] = url("/Volumes/New/Music/\(i).flac")
        }
        return LibraryRelocation.Plan(
            oldRoot: url("/Volumes/Old/Music"), newRoot: url("/Volumes/New/Music"),
            moves: map, withoutCopy: withoutCopy, alreadyInLibrary: alreadyInLibrary)
    }

    func testConfirmationNamesBothFoldersAndSaysNothingMoves() {
        let text = LibraryRelocationText.confirmation(textPlan(moves: 2))
        XCTAssertEqual(text.title, "Relocate 2 tracks to “/Volumes/New/Music”?")
        XCTAssertEqual(
            text.message,
            "Each has a copy there, at the same place it has in “/Volumes/Old/Music”. "
                + "Crates, play counts and ratings follow. No file is moved or deleted.")
    }

    func testConfirmationCountsWhatStaysBehind() {
        let one = LibraryRelocationText.confirmation(textPlan(moves: 1, withoutCopy: 1, alreadyInLibrary: 1))
        XCTAssertEqual(one.title, "Relocate 1 track to “/Volumes/New/Music”?")
        XCTAssertTrue(one.message.hasPrefix("It has a copy there, at the same place it has in"), one.message)
        XCTAssertTrue(one.message.contains("\n\n1 track has no copy there and stays where it is."), one.message)
        XCTAssertTrue(
            one.message.contains("\n\n1 track is in the library at both places already and is left alone."),
            one.message)

        let many = LibraryRelocationText.confirmation(textPlan(moves: 3, withoutCopy: 4, alreadyInLibrary: 5))
        XCTAssertTrue(many.message.contains("\n\n4 tracks have no copy there and stay where they are."), many.message)
        XCTAssertTrue(
            many.message.contains("\n\n5 tracks are in the library at both places already and are left alone."),
            many.message)
    }

    func testSummarySaysWhereTheTracksPlayFrom() {
        let text = LibraryRelocationText.summary(
            textPlan(moves: 2), relocated: 2, musicFolderFollowed: false, driveStillHoldingIndex: nil)
        XCTAssertEqual(text.title, "Library Relocated")
        XCTAssertEqual(text.message, "2 tracks now play from “/Volumes/New/Music”.")
    }

    func testSummaryAddsTheMusicFolderWhatStayedAndTheIndex() {
        let text = LibraryRelocationText.summary(
            textPlan(moves: 1, withoutCopy: 2), relocated: 1,
            musicFolderFollowed: true, driveStillHoldingIndex: "Old")
        XCTAssertEqual(
            text.message,
            "1 track now plays from “/Volumes/New/Music”. The Music Folder points there too. "
                + "2 tracks had no copy there and stayed where they were."
                + "\n\nThe Crates Index is still on “Old”. Before you retire that drive, "
                + "use Move Index Files… in Preferences to bring it along.")
    }

    func testNothingToDoMessagesNameTheFolder() {
        let none = LibraryRelocationText.noCopyFound(in: url("/Volumes/New/Music"))
        XCTAssertEqual(none.title, "No Copy Found")
        XCTAssertTrue(none.message.contains("“/Volumes/New/Music”"), none.message)

        let there = LibraryRelocationText.alreadyThere(in: url("/Volumes/New/Music"))
        XCTAssertEqual(there.title, "Already There")
        XCTAssertTrue(there.message.contains("“/Volumes/New/Music”"), there.message)
    }
}
#endif
