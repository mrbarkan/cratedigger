import Darwin
import XCTest
@testable import CrateDiggerCore

/// AppleDouble `._` files built byte for byte the way the macOS kernel writes
/// them on FAT (xnu `vfs_xattr.c`, checked against a twin the kernel wrote on
/// the FAT sandbox, see `FATSandboxTests.testKernelProvenanceTwinMatchesTheFixture`):
/// 4096 bytes, a Finder info entry at 50 holding the `ATTR` block at 84, and
/// the empty resource fork placeholder in the last 286 bytes.
enum AppleDoubleFixture {
    /// The value a tagged process's files carry (`01 02 00` and an 8-byte id).
    static let provenanceValue: [UInt8] = [0x01, 0x02, 0x00, 0xEB, 0x3A, 0xB7, 0xCC, 0xEA, 0x67, 0xDA, 0xC6]

    /// The placeholder fork, written out from a real twin's bytes rather than
    /// from the code under test.
    static let emptyFork: [UInt8] = {
        var fork = [UInt8](repeating: 0, count: 286)
        fork.replaceSubrange(0..<16, with: [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x1E])
        let tag = Array("This resource fork intentionally left blank   ".utf8)
        fork.replaceSubrange(16..<(16 + tag.count), with: tag)
        fork.replaceSubrange(256..<286, with: [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x1E,
                                               0, 0, 0, 0, 0, 0, 0, 0, 0, 0x1C, 0, 0x1E, 0xFF, 0xFF])
        return fork
    }()

    static func provenanceOnly() -> Data {
        twin(attributes: [("com.apple.provenance", provenanceValue)])
    }

    /// One twin. `resourceFork` nil leaves the placeholder; `finderInfo` is
    /// the 32 bytes of Finder info.
    static func twin(attributes: [(name: String, value: [UInt8])],
                     finderInfo: [UInt8] = [UInt8](repeating: 0, count: 32),
                     resourceFork: [UInt8]? = nil) -> Data {
        let fork = resourceFork ?? emptyFork
        let size = 4096
        var b = [UInt8](repeating: 0, count: size)
        func put32(_ v: Int, _ at: Int) { for i in 0..<4 { b[at + i] = UInt8((v >> (24 - 8 * i)) & 0xFF) } }
        func put16(_ v: Int, _ at: Int) { b[at] = UInt8((v >> 8) & 0xFF); b[at + 1] = UInt8(v & 0xFF) }

        put32(0x0005_1607, 0)
        put32(0x0002_0000, 4)
        b.replaceSubrange(8..<24, with: Array("Mac OS X        ".utf8))
        put16(2, 24)
        let forkOffset = size - fork.count
        put32(9, 26); put32(50, 30); put32(forkOffset - 50, 34) // Finder info
        put32(2, 38); put32(forkOffset, 42); put32(fork.count, 46) // resource fork
        b.replaceSubrange(50..<82, with: finderInfo)

        // The ATTR header at 84, its entries from 120, the values after them.
        put32(0x4154_5452, 84)
        put32(forkOffset, 92) // total size
        put16(attributes.count, 118)
        var entry = 120
        let entryLengths = attributes.map { (11 + $0.name.utf8.count + 1 + 3) & ~3 }
        var data = 120 + entryLengths.reduce(0, +)
        put32(data, 96) // data start
        put32(attributes.reduce(0) { $0 + $1.value.count }, 100) // data length
        for (attribute, length) in zip(attributes, entryLengths) {
            let name = Array(attribute.name.utf8) + [0]
            put32(data, entry)
            put32(attribute.value.count, entry + 4)
            b[entry + 10] = UInt8(name.count)
            b.replaceSubrange((entry + 11)..<(entry + 11 + name.count), with: name)
            b.replaceSubrange(data..<(data + attribute.value.count), with: attribute.value)
            entry += length
            data += attribute.value.count
        }
        b.replaceSubrange(forkOffset..<size, with: fork)
        return Data(b)
    }
}

/// The provenance twin: the parser, the removal rule and the executor's use
/// of them, on APFS temp folders standing in for FAT.
final class ProvenanceTwinTests: XCTestCase {
    private var dir: URL!
    private var journalDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceTwinTests-\(UUID().uuidString)", isDirectory: true)
        dir = base.appendingPathComponent("device", isDirectory: true)
        journalDirectory = base.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    // MARK: Parser

    func testParsesAProvenanceOnlyTwin() throws {
        let parsed = try XCTUnwrap(AppleDoubleFile(AppleDoubleFixture.provenanceOnly()))
        XCTAssertEqual(parsed.attributeNames, ["com.apple.provenance"])
        XCTAssertTrue(parsed.finderInfoIsEmpty)
        XCTAssertTrue(parsed.resourceForkIsEmpty)
        XCTAssertEqual(parsed.entries.map(\.type), [9, 2])
        XCTAssertTrue(parsed.holdsOnlyProvenance)
    }

    func testEmptyResourceForkIsMacOSsPlaceholder() {
        XCTAssertEqual(AppleDoubleFile.emptyResourceFork, Data(AppleDoubleFixture.emptyFork))
    }

    func testAnotherAttributeIsNotProvenanceOnly() throws {
        for attributes in [
            [("com.apple.provenance", AppleDoubleFixture.provenanceValue), ("com.example.test", [0x76])],
            [("com.example.test", [0x76]), ("com.apple.provenance", AppleDoubleFixture.provenanceValue)],
            [("com.apple.quarantine", Array("0081;6543;App;".utf8))],
            [("com.apple.provenancex", AppleDoubleFixture.provenanceValue)],
        ] {
            let parsed = try XCTUnwrap(AppleDoubleFile(AppleDoubleFixture.twin(attributes: attributes)))
            XCTAssertEqual(parsed.attributeNames, attributes.map(\.0))
            XCTAssertFalse(parsed.holdsOnlyProvenance, "\(attributes.map(\.0))")
        }
    }

    func testResourceForkOrFinderInfoIsNotProvenanceOnly() throws {
        var fork = AppleDoubleFixture.emptyFork
        fork[8...11] = [0, 0, 0, 4] // a data length: a fork that holds something
        let withFork = AppleDoubleFixture.twin(attributes: [("com.apple.provenance", AppleDoubleFixture.provenanceValue)],
                                               resourceFork: fork)
        let parsedFork = try XCTUnwrap(AppleDoubleFile(withFork))
        XCTAssertFalse(parsedFork.resourceForkIsEmpty)
        XCTAssertFalse(parsedFork.holdsOnlyProvenance)

        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x01 // a Finder flag
        let withInfo = AppleDoubleFixture.twin(attributes: [("com.apple.provenance", AppleDoubleFixture.provenanceValue)],
                                               finderInfo: info)
        let parsedInfo = try XCTUnwrap(AppleDoubleFile(withInfo))
        XCTAssertFalse(parsedInfo.finderInfoIsEmpty)
        XCTAssertFalse(parsedInfo.holdsOnlyProvenance)
    }

    func testNoAttributeBlockIsNotProvenanceOnly() throws {
        // The header and zeros, as `FakeIPod.appleDoubleBytes` (a twin of something unknown).
        let bare = try XCTUnwrap(AppleDoubleFile(FakeIPod.appleDoubleBytes()))
        XCTAssertNil(bare.attributeNames)
        XCTAssertFalse(bare.holdsOnlyProvenance)

        // An ATTR block listing no attribute holds nothing at all: no other
        // attribute, so a new one may go.
        let empty = try XCTUnwrap(AppleDoubleFile(AppleDoubleFixture.twin(attributes: [])))
        XCTAssertEqual(empty.attributeNames, [])
        XCTAssertTrue(empty.holdsOnlyProvenance)
    }

    func testAnUnexpectedEntryIsNotProvenanceOnly() throws {
        var bytes = [UInt8](AppleDoubleFixture.provenanceOnly())
        bytes[26...29] = [0, 0, 0, 3] // the Finder info entry relabelled "real name"
        let parsed = try XCTUnwrap(AppleDoubleFile(Data(bytes)))
        XCTAssertNil(parsed.attributeNames)
        XCTAssertFalse(parsed.holdsOnlyProvenance)
    }

    func testMalformedTwinsDoNotParse() {
        let good = [UInt8](AppleDoubleFixture.provenanceOnly())
        func with(_ change: (inout [UInt8]) -> Void) -> Data {
            var bytes = good
            change(&bytes)
            return Data(bytes)
        }
        XCTAssertNil(AppleDoubleFile(Data(good.prefix(25))), "shorter than a header")
        XCTAssertNil(AppleDoubleFile(with { $0[5] = 1 }), "AppleDouble version 1")
        XCTAssertNil(AppleDoubleFile(with { $0[3] = 0x00 }), "AppleSingle")
        XCTAssertNil(AppleDoubleFile(with { $0[24...25] = [0x02, 0x00] }), "more entries than fit")
        XCTAssertNil(AppleDoubleFile(with { $0[46...49] = [0, 0, 0x10, 0] }), "a fork past the end")
        XCTAssertNil(AppleDoubleFile(with { $0[34...37] = [0, 0, 0, 16] }), "Finder info under 32 bytes")
        XCTAssertNil(AppleDoubleFile(with { $0[118...119] = [0xFF, 0xFF] }), "more attributes than the block holds")
        XCTAssertNil(AppleDoubleFile(with { $0[92...95] = [0, 0, 0, 140] }), "a name running past the block")
        XCTAssertNil(AppleDoubleFile(with { $0[130] = 20 }), "a name without its NUL")
        XCTAssertNil(AppleDoubleFile(with { $0[124...127] = [0, 0, 0x7F, 0] }), "a value past the block")
        XCTAssertNil(AppleDoubleFile(with { $0[131] = 0xFF }), "a name that is not UTF-8")
        XCTAssertNil(AppleDoubleFile(with { $0[92...95] = [0, 0, 0x10, 0] }), "a block past its entry")
    }

    // MARK: The removal rule

    func testRemovesOnlyAProvenanceOnlyTwin() throws {
        let removable = try file("._a.m4a", AppleDoubleFixture.provenanceOnly())
        XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(removable), .removed)
        XCTAssertFalse(exists(removable))

        let other = AppleDoubleFixture.twin(attributes: [("com.apple.provenance", AppleDoubleFixture.provenanceValue),
                                                         ("com.example.test", [0x76])])
        var fork = AppleDoubleFixture.emptyFork
        fork[8...11] = [0, 0, 0, 4]
        let withFork = AppleDoubleFixture.twin(attributes: [("com.apple.provenance", AppleDoubleFixture.provenanceValue)],
                                               resourceFork: fork)
        for (name, bytes) in [("._b.m4a", other), ("._c.m4a", withFork), ("._d.m4a", FakeIPod.appleDoubleBytes())] {
            let twin = try file(name, bytes)
            XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(twin), .kept, name)
            XCTAssertEqual(try Data(contentsOf: twin), bytes, name)
        }
        XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(dir.appendingPathComponent("._none.m4a")), .absent)
    }

    func testKeepsASymlinkFolderOrOversizedTwin() throws {
        let real = try file("real", AppleDoubleFixture.provenanceOnly())
        let link = dir.appendingPathComponent("._link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(link), .kept)
        XCTAssertTrue(exists(link))
        XCTAssertTrue(exists(real))

        let folder = dir.appendingPathComponent("._Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(folder), .kept)
        XCTAssertTrue(exists(folder))

        let big = try file("._big.m4a", AppleDoubleFixture.provenanceOnly() + Data(count: 128 * 1024))
        XCTAssertEqual(DeviceFileIO.removeProvenanceTwin(big), .kept)
        XCTAssertTrue(exists(big))
    }

    func testANotedTwinThatWasAlreadyThereIsNeverRemovable() throws {
        let target = dir.appendingPathComponent("a.m4a")
        let temp = DeviceFileIO.tempURL(for: target)
        XCTAssertEqual(ProvenanceTwins.beforeWriting(target, through: temp).removable,
                       [dir.appendingPathComponent("._a.m4a"), dir.appendingPathComponent("._a.m4a.cdtmp")])

        _ = try file("._a.m4a", AppleDoubleFixture.provenanceOnly())
        XCTAssertEqual(ProvenanceTwins.beforeWriting(target, through: temp).removable,
                       [dir.appendingPathComponent("._a.m4a.cdtmp")])

        // A twin at the temp's name is moved onto the target's by the rename,
        // so neither may go.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("._a.m4a"))
        _ = try file("._a.m4a.cdtmp", AppleDoubleFixture.provenanceOnly())
        XCTAssertEqual(ProvenanceTwins.beforeWriting(target, through: temp).removable, [])

        let outer = dir.appendingPathComponent("Music", isDirectory: true)
        let inner = outer.appendingPathComponent("Artist", isDirectory: true)
        XCTAssertEqual(ProvenanceTwins.beforeCreating([outer, inner]).removable,
                       [dir.appendingPathComponent("._Music"), outer.appendingPathComponent("._Artist")])
        _ = try file("._Music", AppleDoubleFixture.provenanceOnly())
        XCTAssertEqual(ProvenanceTwins.beforeCreating([outer, inner]).removable,
                       [outer.appendingPathComponent("._Artist")])
    }

    func testRemovalIsRefusedWhenTheTwinChangesBeforeUnlink() throws {
        // The re-check before unlink is removeProvenAppleDouble's: other bytes
        // at the same name are not deleted.
        let twin = try file("._a.m4a", AppleDoubleFixture.provenanceOnly())
        let proof = try XCTUnwrap(DeviceFileIO.proveAppleDouble(twin))
        try AppleDoubleFixture.twin(attributes: [("com.apple.provenance", [0x01, 0x02, 0x00, 0, 0, 0, 0, 0, 0, 0, 1])])
            .write(to: twin)
        XCTAssertEqual(try DeviceFileIO.removeProvenAppleDouble(twin, proof: proof), .changed)
        XCTAssertTrue(exists(twin))
    }

    // MARK: The executor

    /// An executor on `dir` that treats it as FAT; `plant` stands in for the
    /// kernel, writing a twin beside whatever lands.
    private func executor(fileSystem: String = "msdos", plant: ((URL) -> Void)? = nil) -> DeviceFileExecutor {
        DeviceFileExecutor(volumeRoot: dir, expectedVolumeUUID: "TEST-VOLUME",
                           policy: DeviceWritePolicy(musicSubpath: "Music"),
                           journal: DeviceWriteJournal(profileID: UUID(), directory: journalDirectory),
                           volumeUUID: { _ in "TEST-VOLUME" }, freeSpace: { _ in 1 << 40 },
                           fileSystemType: { _ in fileSystem }, rootMustBeMountPoint: false, afterLanding: plant)
    }

    private func plantTwin(_ bytes: Data) -> (URL) -> Void {
        { url in try? bytes.write(to: DeviceFileIO.twinURL(of: url)) }
    }

    /// Every `._` name under `dir`, relative, sorted (Foundation hides them).
    private func twins(under folder: URL? = nil) -> [String] {
        let root = folder ?? dir!
        var found: [String] = []
        for name in AppleDoubleSweeper.entryNames(inFolder: root.path) ?? [] {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix("._") { found.append(name) }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                found += twins(under: url).map { name + "/" + $0 }
            }
        }
        return found.sorted()
    }

    func testExecutorRemovesTheProvenanceTwinsItsWriteCaused() throws {
        let source = try file("mac/zebra.m4a", Data("audio".utf8))
        let ops: [DeviceFileOperation] = [
            .write(relativePath: "Music/Beach House/Teen Dream/01 - Zebra.m4a", role: .audio, contents: .file(source)),
            .write(relativePath: "Music/Beach House/Teen Dream/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8))),
        ]
        let results = executor(plant: plantTwin(AppleDoubleFixture.provenanceOnly())).apply(ops, sessionID: UUID())
        XCTAssertEqual(results, [.written, .written])
        XCTAssertEqual(twins().filter { !$0.hasPrefix("mac") }, [], "the new folders' and files' twins are all gone")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Music/Beach House/Teen Dream/cover.jpg")),
                       Data("jpeg".utf8))
    }

    func testExecutorKeepsATwinCarryingAnythingElse() throws {
        let other = AppleDoubleFixture.twin(attributes: [("com.apple.provenance", AppleDoubleFixture.provenanceValue),
                                                         ("com.example.test", [0x76])])
        let results = executor(plant: plantTwin(other)).apply(
            [.write(relativePath: "Music/A/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8)))],
            sessionID: UUID())
        XCTAssertEqual(results, [.written])
        XCTAssertEqual(twins(), ["._Music", "Music/._A", "Music/A/._cover.jpg"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Music/A/._cover.jpg")), other)
    }

    func testExecutorNeverRemovesATwinThatWasThereBefore() throws {
        // Orphans at the names of a folder and a file the write will create.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Music/Other"),
                                                withIntermediateDirectories: true)
        let folderTwin = try file("Music/._A", AppleDoubleFixture.provenanceOnly())
        let fileTwin = try file("Music/Other/._cover.jpg", AppleDoubleFixture.provenanceOnly())
        // The kernel stands in: a twin beside whatever lands, where there is none.
        let plantWhereNone: (URL) -> Void = { url in
            let twin = DeviceFileIO.twinURL(of: url)
            if !FileManager.default.fileExists(atPath: twin.path) { try? AppleDoubleFixture.provenanceOnly().write(to: twin) }
        }
        let results = executor(plant: plantWhereNone).apply(
            [.write(relativePath: "Music/A/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8))),
             .write(relativePath: "Music/Other/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8)))],
            sessionID: UUID())
        XCTAssertEqual(results, [.written, .written])
        XCTAssertEqual(twins(), ["Music/._A", "Music/Other/._cover.jpg"], "only the twins that were there before remain")
        XCTAssertEqual(try Data(contentsOf: folderTwin), AppleDoubleFixture.provenanceOnly())
        XCTAssertEqual(try Data(contentsOf: fileTwin), AppleDoubleFixture.provenanceOnly())
    }

    func testExecutorKeepsTheTargetTwinWhenOneWasAtTheTempName() throws {
        // On FAT the rename moves a twin at the temp's name onto the target's,
        // so a new-looking target twin may be one that was there before.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Music"), withIntermediateDirectories: true)
        let tempTwin = try file("Music/._cover.jpg.cdtmp", AppleDoubleFixture.provenanceOnly())
        let results = executor(plant: plantTwin(AppleDoubleFixture.provenanceOnly())).apply(
            [.write(relativePath: "Music/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8)))],
            sessionID: UUID())
        XCTAssertEqual(results, [.written])
        XCTAssertEqual(twins(), ["Music/._cover.jpg", "Music/._cover.jpg.cdtmp"])
        XCTAssertTrue(exists(tempTwin))
    }

    func testExecutorLeavesTwinsAloneOffFAT() throws {
        let results = executor(fileSystem: "apfs", plant: plantTwin(AppleDoubleFixture.provenanceOnly())).apply(
            [.write(relativePath: "Music/A/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8)))],
            sessionID: UUID())
        XCTAssertEqual(results, [.written])
        XCTAssertEqual(twins(), ["._Music", "Music/._A", "Music/A/._cover.jpg"],
                       "off FAT a `._` file is something a user made: the door never removes one")
    }

    func testExecutorRemovesATwinLeftAtTheTempName() throws {
        // As if the rename had not moved the temp's twin along.
        let results = executor(plant: { url in
            guard url.pathExtension == "jpg" else { return } // the file, not its folder
            try? AppleDoubleFixture.provenanceOnly().write(to: DeviceFileIO.twinURL(of: DeviceFileIO.tempURL(for: url)))
        }).apply([.write(relativePath: "Music/cover.jpg", role: .cover, contents: .data(Data("jpeg".utf8)))],
                 sessionID: UUID())
        XCTAssertEqual(results, [.written])
        XCTAssertEqual(twins(), [])
    }

    func testExecutorJournalsNothingForATwin() throws {
        let executor = executor(plant: plantTwin(AppleDoubleFixture.provenanceOnly()))
        let session = UUID()
        XCTAssertEqual(executor.apply([.write(relativePath: "Music/cover.jpg", role: .cover,
                                              contents: .data(Data("jpeg".utf8)))], sessionID: session), [.written])
        XCTAssertEqual(executor.journal.records(sessionID: session).filter { $0.kind != .tempIntent }.map(\.relativePath),
                       ["Music/cover.jpg"])
    }
}
