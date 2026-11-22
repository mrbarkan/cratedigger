import XCTest

final class FakeIPodTests: XCTestCase {
    func testManifestCoversProtectedTreesOnly() throws {
        let iPod = try FakeIPod()
        try iPod.addAlbum(category: "Classics", artist: "Beach House", folder: "2010 Teen Dream",
                          tracks: ["01 - Zebra.m4a"], appleDoubleTwins: true)
        try iPod.addFile(".scrobbler.log", Data("#AUDIOSCROBBLER/1.1\n".utf8))

        let manifest = try iPod.manifest()

        XCTAssertNotNil(manifest[".rockbox/library/format.dat"])
        XCTAssertNotNil(manifest[".rockbox/config.cfg"])
        XCTAssertNotNil(manifest[".rockbox_backup/x.txt"])
        XCTAssertNotNil(manifest[".backup/x.zip"])
        XCTAssertNotNil(manifest["iPod_Control/iTunes/iTunesDB"])
        XCTAssertNotNil(manifest[".scrobbler.log"])
        for key in manifest.keys {
            let first = key.split(separator: "/").first.map(String.init) ?? key
            XCTAssertTrue(FakeIPod.protectedTrees.contains(first) || key == ".scrobbler.log",
                          "\(key) is outside the protected trees")
        }
    }

    func testAssertUntouchedFailsWhenARockboxFileChanges() throws {
        let iPod = try FakeIPod()
        let before = try iPod.manifest()
        try iPod.addFile(".rockbox/config.cfg", Data("statusbar: on\n".utf8))

        XCTExpectFailure("A changed .rockbox file must fail the check") {
            iPod.assertPlayerStateUntouched(since: before)
        }
    }

    /// Foundation's directory listings hide `._` files on macOS; the manifest
    /// must not, or a sweep that deleted one in `.rockbox` would go unseen.
    func testManifestSeesAppleDoubleFilesInProtectedTrees() throws {
        let iPod = try FakeIPod()
        try iPod.addFile(".rockbox/themes/._scrim.cfg", FakeIPod.appleDoubleBytes())
        let before = try iPod.manifest()
        XCTAssertNotNil(before[".rockbox/themes/._scrim.cfg"])
        XCTAssertTrue(iPod.allRelativePaths().contains(".rockbox/themes/._scrim.cfg"))

        try FileManager.default.removeItem(at: iPod.root.appendingPathComponent(".rockbox/themes/._scrim.cfg"))
        XCTExpectFailure("A removed ._ file in .rockbox must fail the check") {
            iPod.assertPlayerStateUntouched(since: before)
        }
    }

    func testAppleDoubleBytesHaveMagicAndVersion() {
        let bytes = FakeIPod.appleDoubleBytes()
        XCTAssertEqual(bytes.count, 4096)
        XCTAssertEqual([UInt8](bytes.prefix(8)), [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00])
        XCTAssertTrue(bytes.dropFirst(8).allSatisfy { $0 == 0 })
        XCTAssertEqual(FakeIPod.appleDoubleBytes(size: 26).count, 26)
    }
}
