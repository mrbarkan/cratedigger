import Darwin
import XCTest
@testable import CrateDiggerCore

/// What macOS does on a real FAT volume, settled on a disk image instead of
/// the owner's iPod (spec "How tests prove them without a device", S1 to S7).
/// Skipped unless `CRATEDIGGER_FAT_SANDBOX` names a mounted FAT volume
/// outside /Volumes:
///
///     eval "$(scripts/fat-sandbox.sh up "$SCRATCH")"
///     scripts/test.sh --filter FATSandboxTests
///     scripts/fat-sandbox.sh down "$SCRATCH"
///
/// The S findings are recorded as activities and printed; they assert only
/// what the door relies on. Each test works in a fresh folder on the image
/// and removes it afterwards.
final class FATSandboxTests: XCTestCase {
    private var sandbox: URL!
    private var run: URL!
    private var mac: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["CRATEDIGGER_FAT_SANDBOX"], !raw.isEmpty else {
            throw XCTSkip("CRATEDIGGER_FAT_SANDBOX is not set; see scripts/fat-sandbox.sh")
        }
        guard let real = realpath(raw, nil) else { throw XCTSkip("CRATEDIGGER_FAT_SANDBOX (\(raw)) does not exist") }
        let path = String(cString: real)
        free(real)
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            throw XCTSkip("CRATEDIGGER_FAT_SANDBOX is under /Volumes; the sandbox never runs there")
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw XCTSkip("cannot read the file system at \(path)") }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == "msdos" else { throw XCTSkip("\(path) is \(type), not a FAT volume") }

        sandbox = URL(fileURLWithPath: path, isDirectory: true)
        run = sandbox.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        mac = FileManager.default.temporaryDirectory
            .appendingPathComponent("FATSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let run { try? FileManager.default.removeItem(at: run) } // on the sandbox image only
        if let mac { try? FileManager.default.removeItem(at: mac) }
    }

    // MARK: Helpers

    /// Names in a folder, `._` files included (Foundation hides them).
    private func names(_ folder: URL) -> [String] {
        (AppleDoubleSweeper.entryNames(inFolder: folder.path) ?? []).sorted()
    }

    /// Raw name bytes as the file system hands them back.
    private func rawNames(_ folder: URL) -> [[UInt8]] {
        guard let dir = opendir(folder.path) else { return [] }
        defer { closedir(dir) }
        var result: [[UInt8]] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if bytes != [0x2e], bytes != [0x2e, 0x2e] { result.append(bytes) }
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    private func hasTwin(_ url: URL) -> Bool {
        names(url.deletingLastPathComponent()).contains("._" + url.lastPathComponent)
    }

    /// Bytes of the attribute name list (0 = none, -1 = could not ask).
    private func attributeCount(_ url: URL) -> Int {
        listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    }

    private func setAttribute(_ url: URL, name: String = "com.example.test", value: String = "v") {
        _ = Data(value.utf8).withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
    }

    /// A Mac-side source file carrying an extended attribute, which is what
    /// makes macOS write a `._` twin when the attribute travels to FAT.
    private func macSource(_ name: String, _ data: Data = Data("audio bytes".utf8)) throws -> URL {
        let url = mac.appendingPathComponent(name)
        try data.write(to: url)
        setAttribute(url)
        XCTAssertGreaterThan(attributeCount(url), 0, "the Mac source should carry an attribute")
        return url
    }

    private func finding(_ name: String, _ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("FAT sandbox \(name):\n\(text)")
        XCTContext.runActivity(named: "\(name): \(lines.joined(separator: "; "))") { _ in }
    }

    private func temporaryItemsExists() -> Bool {
        names(sandbox).contains(".TemporaryItems")
    }

    private func leftovers(under folder: URL) -> [String] {
        var found: [String] = []
        for name in names(folder) {
            let url = folder.appendingPathComponent(name)
            if name.hasPrefix("._") || name.hasSuffix(DeviceFileIO.tempSuffix) { found.append(name) }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                found += leftovers(under: url).map { name + "/" + $0 }
            }
        }
        return found
    }

    // MARK: S1 to S3: which writes leave a twin or a staging folder

    func testS1WhichWritesCreateTwins() throws {
        let hadTemporaryItems = temporaryItemsExists()
        var lines: [String] = []
        func report(_ label: String, _ url: URL) {
            lines.append("\(label): twin \(hasTwin(url) ? "YES" : "no"), attributes on the copy \(attributeCount(url) > 0 ? "yes" : "none")")
        }

        let source = try macSource("source.m4a")

        let viaCopyItem = run.appendingPathComponent("copyItem.m4a")
        try FileManager.default.copyItem(at: source, to: viaCopyItem)
        report("FileManager.copyItem from a source with an attribute", viaCopyItem)

        let viaCopyfile = run.appendingPathComponent("copyfileData.m4a")
        XCTAssertEqual(copyfile(source.path, viaCopyfile.path, nil, copyfile_flags_t(COPYFILE_DATA)), 0)
        report("copyfile(COPYFILE_DATA)", viaCopyfile)

        let viaDoor = run.appendingPathComponent("copyDataOnly.m4a")
        try DeviceFileIO.copyDataOnly(from: source, to: viaDoor)
        report("DeviceFileIO.copyDataOnly", viaDoor)

        let viaDataWrite = run.appendingPathComponent("dataWrite.jpg")
        try Data("jpeg".utf8).write(to: viaDataWrite)
        report("Data.write(to:)", viaDataWrite)

        let viaAtomic = run.appendingPathComponent("dataWriteAtomic.jpg")
        try Data("jpeg".utf8).write(to: viaAtomic, options: .atomic)
        report("Data.write(to:, .atomic)", viaAtomic)
        let atomicLeftStaging = !hadTemporaryItems && temporaryItemsExists()
        lines.append("S3 Data.write(.atomic) left .TemporaryItems at the volume root: \(atomicLeftStaging ? "YES" : "no")")

        if let ffmpeg = ExternalToolLocator().resolveOptional(.ffmpeg) {
            let viaFFmpeg = run.appendingPathComponent("ffmpeg.m4a")
            let process = Process()
            process.executableURL = ffmpeg.url
            process.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                 "-t", "0.2", "-c:a", "aac", "-y", viaFFmpeg.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                report("ffmpeg writing straight to FAT", viaFFmpeg)
            } else {
                lines.append("ffmpeg: exited \(process.terminationStatus), not measured")
            }
        } else {
            lines.append("ffmpeg: not installed, not measured")
        }

        // S2: an attribute set on a FAT file, then stripped.
        let tagged = run.appendingPathComponent("tagged.mp3")
        try Data("mp3".utf8).write(to: tagged)
        setAttribute(tagged)
        lines.append("S2 setxattr on a FAT file makes a twin: \(hasTwin(tagged) ? "YES" : "no")")
        DeviceFileIO.stripExtendedAttributes(at: tagged)
        lines.append("S2 stripExtendedAttributes then removes the twin: \(hasTwin(tagged) ? "no, it stays" : "YES")")

        finding("S1-S3", lines)
        // The door's own copy must never leave one; the rest is reported, not asserted.
        XCTAssertFalse(hasTwin(viaDoor))

        if atomicLeftStaging {
            // Ours to tidy: the sandbox image, made by this test.
            try? FileManager.default.removeItem(at: sandbox.appendingPathComponent(".TemporaryItems"))
        }
    }

    func testCopyDataOnlyLeavesNoTwinOnFAT() throws {
        let source = try macSource("01 - Zebra.m4a", Data(repeating: 0x41, count: 300_000))
        let destination = run.appendingPathComponent("01 - Zebra.m4a")
        try DeviceFileIO.copyDataOnly(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertLessThanOrEqual(attributeCount(destination), 0)
        XCTAssertEqual(names(run), ["01 - Zebra.m4a"])
        XCTAssertEqual(leftovers(under: run), [])
    }

    func testWriteAtomicallyLeavesNoTemporaryItemsFolder() throws {
        let hadTemporaryItems = temporaryItemsExists()
        let cover = run.appendingPathComponent("cover.jpg")
        try DeviceFileIO.writeAtomically(Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]), to: cover)

        XCTAssertEqual(try Data(contentsOf: cover), Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]))
        if !hadTemporaryItems {
            XCTAssertFalse(temporaryItemsExists(), "writeAtomically must not stage through .TemporaryItems")
        }
        XCTAssertEqual(names(run), ["cover.jpg"])
        XCTAssertEqual(leftovers(under: run), [])
    }

    // MARK: S4

    func testRenameOverExistingWorksOnFAT() throws {
        let file = run.appendingPathComponent("cover.jpg")
        try DeviceFileIO.writeAtomically(Data("first".utf8), to: file)
        try DeviceFileIO.writeAtomically(Data("second, longer".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("second, longer".utf8))

        let other = run.appendingPathComponent("other.jpg")
        try Data("third".utf8).write(to: other)
        XCTAssertEqual(Darwin.rename(other.path, file.path), 0, String(cString: strerror(errno)))
        XCTAssertEqual(try Data(contentsOf: file), Data("third".utf8))
        XCTAssertEqual(names(run), ["cover.jpg"])
    }

    // MARK: S5, S6: what names become

    func testS5NFDNameBytes() throws {
        let nfd = "Gdan\u{0301}sk.m4a"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8))
        try DeviceFileIO.writeAtomically(Data("x".utf8), to: run.appendingPathComponent(nfd))

        let stored = rawNames(run)
        var nfcStat = stat()
        var nfdStat = stat()
        finding("S5", [
            "written as NFD bytes: \(hex(Array(nfd.utf8)))",
            "stored as: \(stored.map(hex).joined(separator: " | "))",
            "stored bytes are NFC: \(stored.contains(Array(nfc.utf8)) ? "YES" : "no"), NFD: \(stored.contains(Array(nfd.utf8)) ? "YES" : "no")",
            "found by its NFC name: \(stat(run.appendingPathComponent(nfc).path, &nfcStat) == 0 ? "YES" : "no"), by its NFD name: \(stat(run.appendingPathComponent(nfd).path, &nfdStat) == 0 ? "YES" : "no")",
        ])
        XCTAssertEqual(stored.count, 1)
    }

    func testS6QuestionMarkAndTrailingDot() throws {
        var lines: [String] = []
        for name in ["What?.m4a", "Trailing.", "Trailing space ", "Dots...m4a"] {
            let url = run.appendingPathComponent(name)
            do {
                try DeviceFileIO.writeAtomically(Data(name.utf8), to: url)
                let readable = (try? Data(contentsOf: url)) == Data(name.utf8)
                lines.append("\"\(name)\": written, read back by the same name: \(readable ? "YES" : "no")")
            } catch {
                lines.append("\"\(name)\": refused, \(error.localizedDescription)")
            }
        }
        lines.append("stored names: \(rawNames(run).map { "\"\(String(decoding: $0, as: UTF8.self))\" (\(hex($0)))" }.joined(separator: ", "))")
        finding("S6", lines)
        XCTAssertEqual(leftovers(under: run), [], "no temp may survive a refused name")
    }

    // MARK: S7: the executor on real FAT

    func testExecutorSuiteOnFAT() throws {
        let album = "Music/Beach House/2010 Teen Dream"
        let track = "\(album)/01 - Zebra.m4a"
        let coverPath = "\(album)/cover.jpg"
        let source = try macSource("zebra.m4a", Data(repeating: 0x42, count: 200_000))
        let journal = DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal"))
        let uuid = DeviceFileExecutor.systemVolumeUUID(run)
        let executor = DeviceFileExecutor(volumeRoot: run, expectedVolumeUUID: uuid,
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal)
        let session = UUID()

        // Create.
        let create: [DeviceFileOperation] = [
            .write(relativePath: track, role: .audio, contents: .file(source)),
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("cover v1".utf8))),
        ]
        XCTAssertEqual(executor.apply(create, sessionID: session), [.written, .written])
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent(track)), try Data(contentsOf: source))
        XCTAssertEqual(leftovers(under: run), [])

        // Unchanged, dates kept.
        let dateBefore = try FileManager.default.attributesOfItem(
            atPath: run.appendingPathComponent(coverPath).path)[.modificationDate] as? Date
        XCTAssertEqual(executor.apply(create, sessionID: session), [.unchanged, .unchanged])
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: run.appendingPathComponent(coverPath).path)[.modificationDate] as? Date, dateBefore)

        // Replace an owned file: backed up on the Mac first.
        XCTAssertEqual(executor.apply([.write(relativePath: coverPath, role: .cover,
                                              contents: .data(Data("cover v2".utf8)))], sessionID: session),
                       [.written])
        let replaced = try XCTUnwrap(journal.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
        XCTAssertEqual(replaced.kind, .replaced)
        XCTAssertEqual(try Data(contentsOf: journal.folder.appendingPathComponent(try XCTUnwrap(replaced.backupFile))),
                       Data("cover v1".utf8))

        // A foreign file is refused.
        try Data("the owner's".utf8).write(to: run.appendingPathComponent("\(album)/folder.jpg"))
        try Data("the owner's".utf8).write(to: run.appendingPathComponent("Music/Beach House/cover.jpg"))
        XCTAssertEqual(executor.apply([.write(relativePath: "Music/Beach House/cover.jpg", role: .cover,
                                              contents: .data(Data("ours".utf8)))], sessionID: session),
                       [.refusedForeign])

        // A proven twin is swept; a look-alike stays.
        try FakeIPod.appleDoubleBytes().write(to: run.appendingPathComponent("\(album)/._02 - Norway.m4a"))
        let lookAlike = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64)
        try lookAlike.write(to: run.appendingPathComponent("\(album)/._03 - Lover.m4a"))
        let sweep = AppleDoubleSweeper().plan(volumeRoot: run, scope: nil,
                                              mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
        XCTAssertEqual(sweep.candidates, ["\(album)/._02 - Norway.m4a"])
        XCTAssertEqual(executor.apply(sweep.operations, sessionID: session), [.deleted])
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent("\(album)/._03 - Lover.m4a")), lookAlike)
        try FileManager.default.removeItem(at: run.appendingPathComponent("\(album)/._03 - Lover.m4a"))

        // Owned delete and a user's Replace.
        XCTAssertEqual(executor.apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger),
                                       .delete(relativePath: track, reason: .userReplace)], sessionID: session),
                       [.deleted, .deleted])
        XCTAssertEqual(names(run.appendingPathComponent(album)), ["folder.jpg"])
        XCTAssertEqual(leftovers(under: run), [])
        finding("S7", ["executor create, unchanged, replace, foreign, sweep and delete on FAT: as on APFS",
                       "volume UUID reported for the image: \(uuid ?? "none")"])
    }
}
