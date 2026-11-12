import Darwin
import XCTest
@testable import CrateDiggerCore

final class DeviceFileIOTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceFileIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func tempFiles() -> [String] {
        let walker = FileManager.default.enumerator(atPath: dir.path)
        return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(DeviceFileIO.tempSuffix) }
    }

    func testCopyDataOnlyCopiesBytesAndKeepsSourceDate() throws {
        let source = try file("src/a.m4a", Data("audio bytes".utf8))
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let destination = try file("dst/keep", Data()).deletingLastPathComponent().appendingPathComponent("a.m4a")

        try DeviceFileIO.copyDataOnly(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("audio bytes".utf8))
        let copied = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        XCTAssertEqual(try XCTUnwrap(copied).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCopyDataOnlyDropsExtendedAttributes() throws {
        let source = try file("a.m4a", Data("x".utf8))
        let value = Data("v".utf8)
        let set = value.withUnsafeBytes { setxattr(source.path, "com.example.test", $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(set, 0)
        XCTAssertGreaterThan(listxattr(source.path, nil, 0, 0), 0)
        let destination = dir.appendingPathComponent("b.m4a")

        try DeviceFileIO.copyDataOnly(from: source, to: destination)

        XCTAssertEqual(listxattr(destination.path, nil, 0, XATTR_NOFOLLOW), 0)
    }

    func testStripExtendedAttributesRemovesAll() throws {
        let url = try file("a.jpg", Data("x".utf8))
        for name in ["com.example.one", "com.example.two", "com.example.caf\u{E9}"] {
            _ = Data("v".utf8).withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, 1, 0, 0) }
        }
        DeviceFileIO.stripExtendedAttributes(at: url)
        XCTAssertEqual(listxattr(url.path, nil, 0, 0), 0)
    }

    func testCopyLeavesNoTempFile() throws {
        let source = try file("a.m4a", Data("x".utf8))
        let destination = dir.appendingPathComponent("out/a.m4a")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try DeviceFileIO.copyDataOnly(from: source, to: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path),
                       ["a.m4a"])
        XCTAssertEqual(tempFiles(), [])
    }

    func testCopyFailureRemovesTemp() throws {
        let source = try file("a.m4a", Data("x".utf8))
        let destination = dir.appendingPathComponent("missing/a.m4a")
        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: source, to: destination))
        XCTAssertEqual(tempFiles(), [])

        let missingSource = dir.appendingPathComponent("nope.m4a")
        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: missingSource, to: dir.appendingPathComponent("b.m4a")))
        XCTAssertEqual(tempFiles(), [])
    }

    func testRenameFailureRemovesTemp() throws {
        // A folder where the file should go: the temp is written, the rename fails.
        let source = try file("a.m4a", Data("x".utf8))
        let blocker = dir.appendingPathComponent("b.m4a")
        try FileManager.default.createDirectory(at: blocker.appendingPathComponent("inside"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: source, to: blocker))
        XCTAssertThrowsError(try DeviceFileIO.writeAtomically(Data("y".utf8), to: blocker))
        XCTAssertEqual(tempFiles(), [])
    }

    func testWriteAtomicallyReplacesExisting() throws {
        let url = try file("cover.jpg", Data("old".utf8))
        try DeviceFileIO.writeAtomically(Data("new".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(tempFiles(), [])

        let fresh = dir.appendingPathComponent("fresh.jpg")
        try DeviceFileIO.writeAtomically(Data(), to: fresh)
        XCTAssertEqual(try Data(contentsOf: fresh), Data())
    }

    func testCopyAndWriteNeverDeleteATwin() throws {
        // Removing twins is the sweep's job (backed up first), never a side effect of a write.
        let source = try file("src/a.m4a", Data("x".utf8))
        let destination = try file("a.m4a", Data("old".utf8))
        let twin = try file("._a.m4a", FakeIPod.appleDoubleBytes())
        try DeviceFileIO.copyDataOnly(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: twin), FakeIPod.appleDoubleBytes())

        let cover = try file("cover.jpg", Data("old".utf8))
        let coverTwin = try file("._cover.jpg", FakeIPod.appleDoubleBytes())
        try DeviceFileIO.writeAtomically(Data("new".utf8), to: cover)
        XCTAssertEqual(try Data(contentsOf: coverTwin), FakeIPod.appleDoubleBytes())
    }

    func testDateFailureAfterRenameIsNotAFailedWrite() throws {
        final class NoDates: FileManager {
            override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let source = try file("src/a.m4a", Data("audio".utf8))
        let destination = dir.appendingPathComponent("a.m4a")
        XCTAssertNoThrow(try DeviceFileIO.copyDataOnly(from: source, to: destination, fileManager: NoDates()))
        XCTAssertEqual(try Data(contentsOf: destination), Data("audio".utf8))
        XCTAssertEqual(tempFiles(), [])
    }

    func testProvenAppleDoubleAcceptsARealTwin() throws {
        XCTAssertTrue(DeviceFileIO.isProvenAppleDouble(try file("._x.m4a", FakeIPod.appleDoubleBytes())))
        XCTAssertTrue(DeviceFileIO.isProvenAppleDouble(try file("._y.m4a", FakeIPod.appleDoubleBytes(size: 26))))
        XCTAssertTrue(DeviceFileIO.isProvenAppleDouble(try file("._z.m4a", FakeIPod.appleDoubleBytes(size: 128 * 1024))))
    }

    func testProvenAppleDoubleRefusesLookAlike() throws {
        let twin = try file("._x.m4a", Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64))
        XCTAssertFalse(DeviceFileIO.isProvenAppleDouble(twin))
    }

    func testProvenAppleDoubleRefusesOversize() throws {
        XCTAssertFalse(DeviceFileIO.isProvenAppleDouble(try file("._x.m4a", FakeIPod.appleDoubleBytes(size: 129 * 1024))))
    }

    func testProvenAppleDoubleRefusesTinySymlinkAndFifo() throws {
        XCTAssertFalse(DeviceFileIO.isProvenAppleDouble(try file("._x.m4a", FakeIPod.appleDoubleBytes(size: 10))))
        let real = try file("real", FakeIPod.appleDoubleBytes())
        let link = dir.appendingPathComponent("._link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertFalse(DeviceFileIO.isProvenAppleDouble(link))
        let fifo = dir.appendingPathComponent("._fifo.m4a")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        XCTAssertFalse(DeviceFileIO.isProvenAppleDouble(fifo))
    }

    func testRemoveMissingFileIsNotAnError() throws {
        XCTAssertNoThrow(try DeviceFileIO.remove(dir.appendingPathComponent("never-there.m4a")))
        let url = try file("a.m4a", Data("x".utf8))
        try DeviceFileIO.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSHA256KnownValue() throws {
        let url = try file("abc", Data("abc".utf8))
        XCTAssertEqual(try DeviceFileIO.sha256(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAppleDoubleHeader() {
        XCTAssertTrue(DeviceFileIO.isAppleDoubleHeader(FakeIPod.appleDoubleBytes(size: 8)))
        XCTAssertFalse(DeviceFileIO.isAppleDoubleHeader(Data([0x00, 0x05, 0x16, 0x07])))
        // AppleSingle magic, and the right magic with the wrong version.
        XCTAssertFalse(DeviceFileIO.isAppleDoubleHeader(Data([0x00, 0x05, 0x16, 0x00, 0x00, 0x02, 0x00, 0x00])))
        XCTAssertFalse(DeviceFileIO.isAppleDoubleHeader(Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x01, 0x00, 0x00])))
    }
}
