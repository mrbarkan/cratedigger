#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The copy is only ever read while the real index is out of reach, so the one
/// thing it must never do is lose a good copy to a bad one.
final class LibraryIndexCopyTests: XCTestCase {

    private let copiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testCopiesOnlyIndexFilesAndRecordsTheSource() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            let source = try makeSource(in: root, files: [
                "Personal Crate.cdcrate", "library.cdtracks", "library.cdplays",
                ".DS_Store", "song.flac", "cover.jpg"
            ])
            let copy = LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy"))

            let record = try copy.write(from: source, now: copiedAt)

            XCTAssertEqual(try names(in: copy.directory), [
                "Personal Crate.cdcrate", "copy.json", "library.cdplays", "library.cdtracks"
            ])
            XCTAssertEqual(record.sourcePath, source.path)
            XCTAssertEqual(copy.record(), record)
            XCTAssertEqual(copy.record()?.copiedAt, copiedAt)
        }
    }

    func testTheCopiedFilesKeepTheirContents() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            let source = try makeSource(in: root, files: ["library.cdtracks"])
            try Data("[{\"title\":\"One\"}]".utf8).write(to: source.appendingPathComponent("library.cdtracks"))
            let copy = LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy"))

            try copy.write(from: source, now: copiedAt)

            let copied = try Data(contentsOf: copy.directory.appendingPathComponent("library.cdtracks"))
            XCTAssertEqual(String(decoding: copied, as: UTF8.self), "[{\"title\":\"One\"}]")
        }
    }

    func testANewCopyDropsCratesDeletedSince() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            let source = try makeSource(in: root, files: ["A.cdcrate", "B.cdcrate", "library.cdtracks"])
            let copy = LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy"))
            try copy.write(from: source, now: copiedAt)

            try FileManager.default.removeItem(at: source.appendingPathComponent("B.cdcrate"))
            try copy.write(from: source, now: copiedAt.addingTimeInterval(60))

            XCTAssertEqual(try names(in: copy.directory), ["A.cdcrate", "copy.json", "library.cdtracks"])
            XCTAssertEqual(copy.record()?.copiedAt, copiedAt.addingTimeInterval(60))
        }
    }

    /// The drive pulled out mid-read is the case this exists for.
    func testAFailedCopyLeavesThePreviousCopyIntact() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            let source = try makeSource(in: root, files: ["A.cdcrate", "library.cdtracks"])
            let copy = LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy"))
            try copy.write(from: source, now: copiedAt)

            let unreadable = source.appendingPathComponent("B.cdcrate")
            FileManager.default.createFile(atPath: unreadable.path, contents: Data("[]".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

            XCTAssertThrowsError(try copy.write(from: source, now: copiedAt.addingTimeInterval(60)))

            XCTAssertEqual(try names(in: copy.directory), ["A.cdcrate", "copy.json", "library.cdtracks"])
            XCTAssertEqual(copy.record()?.copiedAt, copiedAt)
            XCTAssertEqual(try names(in: root), ["LibraryCopy", "Source"], "no half-written copy left behind")
        }
    }

    func testAMissingSourceThrowsAndKeepsThePreviousCopy() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            let source = try makeSource(in: root, files: ["library.cdtracks"])
            let copy = LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy"))
            try copy.write(from: source, now: copiedAt)

            XCTAssertThrowsError(try copy.write(from: root.appendingPathComponent("Gone"), now: copiedAt))

            XCTAssertEqual(copy.record()?.copiedAt, copiedAt)
        }
    }

    func testNoCopyHasNoRecord() throws {
        try withTemporaryDirectory(prefix: "index-copy") { root in
            XCTAssertNil(LibraryIndexCopy(directory: root.appendingPathComponent("LibraryCopy")).record())
        }
    }

    func testTheRecordNamesTheDriveTheLibraryCameFrom() {
        let record = LibraryIndexCopy.Record(sourcePath: "/Volumes/MUSIC/CD_CI", copiedAt: copiedAt)
        XCTAssertEqual(record.volumeName, "MUSIC")
        XCTAssertEqual(record.sourceFolder, URL(fileURLWithPath: "/Volumes/MUSIC/CD_CI"))
        XCTAssertNil(LibraryIndexCopy.Record(sourcePath: "/Users/someone/Crates", copiedAt: copiedAt).volumeName)
    }

    // MARK: - The index file list

    func testIndexFilesAreTheCratesTheTrackStoreAndThePlays() {
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/Personal Crate.cdcrate")))
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/library.cdtracks")))
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/library.cdplays")))
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/Upper.CDCRATE")))
        XCTAssertFalse(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/Old.cdlib")))
        XCTAssertFalse(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/Old.cdlib.bak")))
        XCTAssertFalse(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/.DS_Store")))
    }

    // MARK: - Helpers

    private func makeSource(in root: URL, files: [String]) throws -> URL {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in files {
            FileManager.default.createFile(atPath: source.appendingPathComponent(name).path, contents: Data("[]".utf8))
        }
        return source
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
#endif
