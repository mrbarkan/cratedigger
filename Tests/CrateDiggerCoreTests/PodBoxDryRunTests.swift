import XCTest
@testable import CrateDiggerCore

/// The DEBUG dry run (owner's check M1): a text report of what CrateDigger
/// sees on a device and what a cleanup would remove, built without writing a
/// byte. The FakeIPod is a temp folder on APFS, so the sweep is told it is FAT.
final class PodBoxDryRunTests: XCTestCase {
    private var iPod: FakeIPod!
    private var before: [String: String] = [:]

    override func setUpWithError() throws {
        iPod = try FakeIPod()
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a", "02 - Silver Soul.m4a"], appleDoubleTwins: true)
        // A twin of a text file: proven AppleDouble, but not media, so left alone.
        try iPod.addFile("Music/Notes/._todo.txt", FakeIPod.appleDoubleBytes())
        try iPod.addFile("Music/Notes/todo.txt", Data("milk".utf8))
        before = try iPod.manifest()
    }

    override func tearDownWithError() throws {
        iPod.assertPlayerStateUntouched(since: before)
        iPod = nil
    }

    private func report() -> String {
        PodBoxDryRun.report(volumeRoot: iPod.root, musicSubpath: "Music", fileSystemType: { _ in "msdos" })
    }

    func testReportNamesFirmwareAndPrefix() {
        let text = report()
        XCTAssertTrue(text.contains("PodBox · iPod Video · build 8 Nov 2026 · library layout 5"), text)
        XCTAssertTrue(text.contains("ipodvideo"), text)
        XCTAssertTrue(text.contains("/<HDD0>"), text)
        XCTAssertTrue(text.contains("msdos"), text)
        XCTAssertTrue(text.contains("appleDoubleSweep"), text)
    }

    func testReportCountsCandidates() {
        let text = report()
        // Two tracks and a cover, each with a twin.
        XCTAssertTrue(text.contains("3 Mac metadata files would be removed"), text)
        XCTAssertTrue(text.contains("Music/Classics/Beach House/2010 Teen Dream/._01 - Zebra.m4a"), text)
        XCTAssertTrue(text.contains("not media: 1"), text)
        XCTAssertTrue(text.contains("4096 bytes or less: 3"), text)
    }

    func testReportEndsWithZeroFilesWritten() {
        let lines = report().split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.last, "0 files would be written")
    }

    func testReportLeavesEverythingUntouched() throws {
        let files = iPod.allRelativePaths()
        let dates = try files.map { try FileManager.default.attributesOfItem(
            atPath: iPod.root.appendingPathComponent($0).path)[.modificationDate] as? Date }

        _ = report()

        XCTAssertEqual(iPod.allRelativePaths(), files)
        let after = try files.map { try FileManager.default.attributesOfItem(
            atPath: iPod.root.appendingPathComponent($0).path)[.modificationDate] as? Date }
        XCTAssertEqual(after, dates)
    }

    func testNamesSectionListsNonASCIIAndOddNames() throws {
        // NFD on purpose: the report shows the bytes as stored.
        let gdansk = "2008 Live in Gdan\u{301}sk"
        try iPod.addFile("Music/Classics/David Gilmour/\(gdansk)/02 - Wearing the Inside Out.m4a", Data("x".utf8))
        try iPod.addFile("Music/Odd/What?.m4a", Data("x".utf8))
        try iPod.addFile("Music/Odd/Vol./01.m4a", Data("x".utf8))
        try iPod.addFile("Music/Odd/Fine.m4a", Data("x".utf8))

        let text = report()

        let hex = gdansk.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertTrue(text.contains(hex), text)
        XCTAssertTrue(text.contains("cc 81"), "the NFD combining accent is shown as stored")
        XCTAssertTrue(text.contains("Music/Odd/What?.m4a"), text)
        XCTAssertTrue(text.contains("Music/Odd/Vol."), text)
        XCTAssertFalse(text.contains("Music/Odd/Fine.m4a"), text)
    }

    func testNoRockboxSaysSo() throws {
        let plain = try FakeIPod(flavour: .noRockbox)
        let text = PodBoxDryRun.report(volumeRoot: plain.root, musicSubpath: "Music", fileSystemType: { _ in "msdos" })
        XCTAssertTrue(text.contains("No .rockbox folder"), text)
        XCTAssertTrue(text.hasSuffix("0 files would be written\n"), text)
    }
}
